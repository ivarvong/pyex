defmodule Pyex.Interpreter do
  @moduledoc """
  Tree-walking evaluator for the Pyex AST.

  Functions are first-class values stored in the environment.
  Control flow (return, break, continue, suspend) is handled
  via tagged tuples that unwind naturally through the call stack.
  Python exceptions are `{:exception, message}` tuples that
  propagate identically -- no Elixir raise/rescue for Python
  error semantics.

  Every execution is instrumented via `Pyex.Ctx` for Temporal-style
  deterministic replay. Decision points (branches, loop iterations,
  side effects) are recorded as events. On replay the interpreter
  consumes logged events instead of re-executing, enabling suspend,
  resume, branch, and time-travel debugging.
  """

  import Bitwise, only: [band: 2, bor: 2, bxor: 2, bsl: 2, bsr: 2, bnot: 1]

  alias Pyex.{Builtins, Ctx, Env, Methods, Parser}
  alias Pyex.Interpreter.{Format, Helpers, Import, Iteration, Match, Unittest}

  @type pyvalue ::
          integer()
          | float()
          | :infinity
          | :neg_infinity
          | :nan
          | String.t()
          | boolean()
          | nil
          | [pyvalue()]
          | %{optional(pyvalue()) => pyvalue()}
          | {:tuple, [pyvalue()]}
          | {:set, MapSet.t(pyvalue())}
          | {:range, integer(), integer(), integer()}
          | {:function, String.t(), [Parser.param()], [Parser.ast_node()], Env.t()}
          | {:builtin, ([pyvalue()] -> pyvalue())}
          | {:builtin_type, String.t(), ([pyvalue()] -> pyvalue())}
          | {:builtin_kw, ([pyvalue()], %{optional(String.t()) => pyvalue()} -> pyvalue())}
          | {:file_handle, non_neg_integer()}
          | {:class, String.t(), [pyvalue()], %{optional(String.t()) => pyvalue()}}
          | {:instance, pyvalue(), %{optional(String.t()) => pyvalue()}}
          | {:bound_method, pyvalue(), pyvalue()}
          | {:bound_method, pyvalue(), pyvalue(), pyvalue()}
          | {:generator, [pyvalue()]}
          | {:generator_error, [pyvalue()], String.t()}
          | {:iterator, non_neg_integer()}
          | {:super_proxy, pyvalue(), [pyvalue()]}

  @typep signal ::
           {:returned, pyvalue()}
           | {:break}
           | {:continue}
           | {:suspended}
           | {:exception, String.t()}
           | {:yielded, pyvalue(), [cont_frame()]}

  @type builtin_signal ::
          {:print_call, [pyvalue()]}
          | {:io_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})}
          | {:ctx_call, (Env.t(), Ctx.t() -> term())}
          | {:mutate, pyvalue(), pyvalue()}
          | {:dunder_call, pyvalue(), String.t(), [pyvalue()]}
          | {:map_call, pyvalue(), [pyvalue()]}
          | {:filter_call, pyvalue(), [pyvalue()]}
          | {:min_call, [pyvalue()], pyvalue()}
          | {:max_call, [pyvalue()], pyvalue()}
          | {:sort_call, [pyvalue()], pyvalue() | nil, boolean()}
          | {:iter_sorted, pyvalue(), pyvalue() | nil, boolean()}
          | {:iter_sum, pyvalue()}
          | {:iter_to_list, pyvalue()}
          | {:iter_to_tuple, pyvalue()}
          | {:iter_to_set, pyvalue()}
          | {:iter_instance, pyvalue()}
          | {:make_iter, [pyvalue()]}
          | {:iter_next, non_neg_integer()}
          | {:iter_next_default, non_neg_integer(), pyvalue()}
          | {:next_instance_iter, non_neg_integer(), :no_default | {:default, pyvalue()}}
          | {:next_with_default, pyvalue(), pyvalue()}
          | {:starmap_call, pyvalue(), [pyvalue()]}
          | {:takewhile_call, pyvalue(), [pyvalue()]}
          | {:dropwhile_call, pyvalue(), [pyvalue()]}
          | {:filterfalse_call, pyvalue(), [pyvalue()]}
          | {:accumulate_call, [pyvalue()], pyvalue()}
          | {:groupby_call, [pyvalue()], pyvalue()}
          | {:unittest_main}
          | {:assert_raises, String.t()}
          | {:register_route, String.t(), String.t(), pyvalue()}
          | {:super_call}
          | {:suspended}

  @typep eval_result :: {pyvalue() | signal(), Env.t(), Ctx.t()}

  @doc """
  Evaluates an AST and returns the final value.

  The environment is pre-populated with Python builtins
  (`len`, `range`, `print`, etc.). A fresh `Ctx` is used
  for event recording.
  """
  @spec run(Parser.ast_node()) :: {:ok, pyvalue()} | {:error, String.t()}
  def run(ast) do
    case eval(ast, Builtins.env(), %Ctx{mode: :noop}) do
      {{:exception, msg}, _env, ctx} -> {:error, Helpers.format_error(msg, ctx)}
      {result, _env, _ctx} -> {:ok, Helpers.unwrap(result)}
    end
  end

  @doc """
  Evaluates an AST with a provided context, returning
  the value, final environment, and context (with full
  event log).

  Returns `{:suspended, env, ctx}` if the program called
  `suspend()`, allowing the caller to serialize and resume
  later.
  """
  @spec run_with_ctx(Parser.ast_node(), Env.t(), Ctx.t()) ::
          {:ok, pyvalue(), Env.t(), Ctx.t()}
          | {:suspended, Env.t(), Ctx.t()}
          | {:error, String.t()}
  def run_with_ctx(ast, env, ctx) do
    ctx = init_profile(ctx)

    case eval(ast, env, ctx) do
      {{:suspended}, env, ctx} -> {:suspended, env, ctx}
      {{:exception, msg}, _env, ctx} -> {:error, Helpers.format_error(msg, ctx)}
      {result, env, ctx} -> {:ok, Helpers.unwrap(result), env, ctx}
    end
  end

  defmacrop is_py_exception(val) do
    quote do: is_tuple(unquote(val)) and elem(unquote(val), 0) == :exception
  end

  @doc """
  Evaluates a single AST node within the given environment
  and context.

  Returns `{value, env, ctx}` where value may be a raw value
  or a signal (`{:returned, value}`, `{:break}`, `{:continue}`,
  `{:suspended}`, `{:exception, msg}`, `{:yielded, value, cont}`)
  that propagates up through statement evaluation.
  """
  @spec eval(Parser.ast_node(), Env.t(), Ctx.t()) :: eval_result()
  def eval({:module, _, statements}, env, ctx) do
    eval_statements(statements, env, ctx)
  end

  def eval({:def, _, [name, params, body]}, env, ctx) do
    func = {:function, name, params, body, env}
    ctx = Ctx.record(ctx, :assign, {name, :function})
    {nil, Env.smart_put(env, name, func), ctx}
  end

  def eval({:decorated_def, _, [decorator_expr, def_node]}, env, ctx) do
    {nil, env, ctx} = eval(def_node, env, ctx)

    name =
      case Helpers.unwrap_def(def_node) do
        {:def, _, [n, _, _]} -> n
        {:class, _, [n, _, _]} -> n
      end

    {:ok, func} = Env.get(env, name)

    case eval(decorator_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {decorator, env, ctx} ->
        case call_function(decorator, [func], %{}, env, ctx) do
          {:mutate, _new_object, return_value, ctx} ->
            ctx = Ctx.record(ctx, :assign, {name, :decorated})
            {nil, Env.smart_put(env, name, return_value), ctx}

          {{:register_route, method, path, handler}, env, ctx} ->
            env = register_route(decorator_expr, method, path, handler, env)
            ctx = Ctx.record(ctx, :assign, {name, :decorated})
            ctx = Ctx.record(ctx, :side_effect, {:register_route, method, path})
            {nil, Env.smart_put(env, name, handler), ctx}

          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {result, env, ctx, _updated_func} ->
            ctx = Ctx.record(ctx, :assign, {name, :decorated})
            {nil, Env.smart_put(env, name, result), ctx}

          {result, env, ctx} ->
            ctx = Ctx.record(ctx, :assign, {name, :decorated})
            {nil, Env.smart_put(env, name, result), ctx}
        end
    end
  end

  def eval({:with, _, [expr, as_name, body]}, env, ctx) do
    cm_var = with_context_var(expr)

    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {context_val, env, ctx} ->
        {enter_val, context_val, env, ctx} =
          case call_dunder_mut(context_val, "__enter__", [], env, ctx) do
            {:ok, new_obj, val, env, ctx} ->
              env = with_update_cm(env, cm_var, new_obj)
              {val, new_obj, env, ctx}

            :not_found ->
              {context_val, context_val, env, ctx}
          end

        env =
          if as_name do
            Env.smart_put(env, as_name, enter_val)
          else
            env
          end

        {result, env, ctx} = eval_statements(body, env, ctx)

        case result do
          {:exception, msg} ->
            exc_type = extract_exception_type_name(msg)

            case call_dunder_mut(context_val, "__exit__", [exc_type, msg, nil], env, ctx) do
              {:ok, new_obj, suppress, env, ctx} ->
                env = with_update_cm(env, cm_var, new_obj)

                if suppress do
                  {nil, env, ctx}
                else
                  {{:exception, msg}, env, ctx}
                end

              :not_found ->
                {{:exception, msg}, env, ctx}
            end

          _ ->
            case call_dunder_mut(context_val, "__exit__", [nil, nil, nil], env, ctx) do
              {:ok, new_obj, _, env, ctx} ->
                env = with_update_cm(env, cm_var, new_obj)
                {result, env, ctx}

              :not_found ->
                {result, env, ctx}
            end
        end
    end
  end

  def eval({:match, _, [subject_expr, cases]}, env, ctx) do
    case eval(subject_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {subject, env, ctx} ->
        Match.eval_match_cases(subject, cases, env, ctx)
    end
  end

  def eval({:class, _, [name, base_names, body]}, env, ctx) do
    bases =
      Enum.map(base_names, fn
        {:dotted, mod_name, attr_name} ->
          case Env.get(env, mod_name) do
            {:ok, %{^attr_name => {:class, _, _, _} = base}} -> base
            _ -> nil
          end

        base_name ->
          case Env.get(env, base_name) do
            {:ok, {:class, _, _, _} = base} -> base
            _ -> nil
          end
      end)
      |> Enum.reject(&is_nil/1)

    class_env = Env.push_scope(env)

    {class_env, ctx} =
      Enum.reduce(body, {class_env, ctx}, fn stmt, {ce, c} ->
        case eval(stmt, ce, c) do
          {{:exception, _} = _signal, ce, c} -> {ce, c}
          {_val, ce, c} -> {ce, c}
        end
      end)

    class_scope = Env.current_scope(class_env)

    class_attrs =
      Enum.reduce(class_scope, %{}, fn {k, v}, acc ->
        Map.put(acc, k, v)
      end)

    class_val = {:class, name, bases, class_attrs}
    ctx = Ctx.record(ctx, :assign, {name, :class})
    {nil, Env.smart_put(env, name, class_val), ctx}
  end

  def eval({:attr_assign, _, [target, expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        setattr(target, value, env, ctx)
    end
  end

  def eval({:aug_attr_assign, _, [target, op, expr]}, env, ctx) do
    case eval(target, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {old_value, env, ctx} ->
        case eval(expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {rhs, env, ctx} ->
            new_value = safe_binop(op, old_value, rhs)

            case new_value do
              {:exception, _} = signal -> {signal, env, ctx}
              _ -> setattr(target, new_value, env, ctx)
            end
        end
    end
  end

  def eval({:global, _, [names]}, env, ctx) do
    env = Enum.reduce(names, env, &Env.declare_global(&2, &1))
    {nil, env, ctx}
  end

  def eval({:nonlocal, _, [names]}, env, ctx) do
    env = Enum.reduce(names, env, &Env.declare_nonlocal(&2, &1))
    {nil, env, ctx}
  end

  def eval({:assign, _, [name, expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        ctx = Ctx.record(ctx, :assign, {name, value})
        {value, Env.smart_put(env, name, value), ctx}
    end
  end

  def eval({:annotated_assign, _, [name, type_str, nil]}, env, ctx) do
    annotations =
      case Env.get(env, "__annotations__") do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    resolved = resolve_annotation(type_str, env)
    env = Env.smart_put(env, "__annotations__", Map.put(annotations, name, resolved))
    {nil, env, ctx}
  end

  def eval({:annotated_assign, _, [name, type_str, expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        annotations =
          case Env.get(env, "__annotations__") do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        resolved = resolve_annotation(type_str, env)
        env = Env.smart_put(env, "__annotations__", Map.put(annotations, name, resolved))
        ctx = Ctx.record(ctx, :assign, {name, value})
        {value, Env.smart_put(env, name, value), ctx}
    end
  end

  def eval({:walrus, _, [name, expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        {value, Env.smart_put(env, name, value), ctx}
    end
  end

  def eval({:chained_assign, _, [names, expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        {env, ctx} =
          Enum.reduce(names, {env, ctx}, fn name, {env, ctx} ->
            ctx = Ctx.record(ctx, :assign, {name, value})
            {Env.smart_put(env, name, value), ctx}
          end)

        {value, env, ctx}
    end
  end

  def eval({:multi_assign, _, [names, exprs]}, env, ctx) do
    case eval_list(exprs, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {values, env, ctx} ->
        case unpack_iterable_safe(values, names) do
          {:ok, pairs} ->
            {env, ctx} =
              Enum.reduce(pairs, {env, ctx}, fn {name, val}, {env, ctx} ->
                ctx = Ctx.record(ctx, :assign, {name, val})
                {Env.smart_put(env, name, val), ctx}
              end)

            {_, last_val} = List.last(pairs)
            {last_val, env, ctx}

          {:exception, msg} ->
            {{:exception, msg}, env, ctx}
        end
    end
  end

  def eval(
        {:subscript_assign, _,
         [{:subscript, _, [container_expr, outer_key_expr]}, inner_key_expr, val_expr]},
        env,
        ctx
      ) do
    with {container, env, ctx} when not is_tuple(container) or elem(container, 0) != :exception <-
           eval(container_expr, env, ctx),
         {outer_key, env, ctx} when not is_tuple(outer_key) or elem(outer_key, 0) != :exception <-
           eval(outer_key_expr, env, ctx),
         {inner_key, env, ctx} when not is_tuple(inner_key) or elem(inner_key, 0) != :exception <-
           eval(inner_key_expr, env, ctx),
         {val, env, ctx} when not is_tuple(val) or elem(val, 0) != :exception <-
           eval(val_expr, env, ctx) do
      inner_container = get_subscript_value(container, outer_key)

      case inner_container do
        {:exception, msg} ->
          {{:exception, msg}, env, ctx}

        _ ->
          updated_inner = set_subscript_value(inner_container, inner_key, val)
          updated_outer = set_subscript_value(container, outer_key, updated_inner)
          write_back_subscript(container_expr, updated_outer, env, ctx)
      end
    else
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  def eval({:subscript_assign, _, [{:getattr, _, _} = target_expr, key_expr, val_expr]}, env, ctx) do
    with {container, env, ctx} when not is_tuple(container) or elem(container, 0) != :exception <-
           eval(target_expr, env, ctx),
         {key, env, ctx} when not is_tuple(key) or elem(key, 0) != :exception <-
           eval(key_expr, env, ctx),
         {val, env, ctx} when not is_tuple(val) or elem(val, 0) != :exception <-
           eval(val_expr, env, ctx) do
      case container do
        %{} = map ->
          updated = Map.put(map, key, val)
          setattr_nested(target_expr, updated, env, ctx)

        list when is_list(list) and is_integer(key) ->
          updated = List.replace_at(list, key, val)
          setattr_nested(target_expr, updated, env, ctx)

        _ ->
          {{:exception, "TypeError: object does not support item assignment"}, env, ctx}
      end
    else
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  def eval(
        {:aug_subscript_assign, _,
         [
           {:subscript, _, [container_expr, outer_key_expr]} = _target_expr,
           inner_key_expr,
           op,
           val_expr
         ]},
        env,
        ctx
      ) do
    with {container, env, ctx} when not is_tuple(container) or elem(container, 0) != :exception <-
           eval(container_expr, env, ctx),
         {outer_key, env, ctx} when not is_tuple(outer_key) or elem(outer_key, 0) != :exception <-
           eval(outer_key_expr, env, ctx),
         {inner_key, env, ctx} when not is_tuple(inner_key) or elem(inner_key, 0) != :exception <-
           eval(inner_key_expr, env, ctx),
         {val, env, ctx} when not is_tuple(val) or elem(val, 0) != :exception <-
           eval(val_expr, env, ctx) do
      inner_container = get_subscript_value(container, outer_key)

      case inner_container do
        {:exception, msg} ->
          {{:exception, msg}, env, ctx}

        _ ->
          old_val = get_subscript_value(inner_container, inner_key)

          case old_val do
            {:exception, msg} ->
              {{:exception, msg}, env, ctx}

            _ ->
              case safe_binop(op, old_val, val) do
                {:exception, msg} ->
                  {{:exception, msg}, env, ctx}

                new_val ->
                  updated_inner = set_subscript_value(inner_container, inner_key, new_val)
                  updated_outer = set_subscript_value(container, outer_key, updated_inner)
                  write_back_subscript(container_expr, updated_outer, env, ctx)
              end
          end
      end
    else
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  def eval(
        {:aug_subscript_assign, _, [{:getattr, _, _} = target_expr, key_expr, op, val_expr]},
        env,
        ctx
      ) do
    with {container, env, ctx} when not is_tuple(container) or elem(container, 0) != :exception <-
           eval(target_expr, env, ctx),
         {key, env, ctx} when not is_tuple(key) or elem(key, 0) != :exception <-
           eval(key_expr, env, ctx),
         {val, env, ctx} when not is_tuple(val) or elem(val, 0) != :exception <-
           eval(val_expr, env, ctx) do
      case container do
        %{} = map ->
          old_val = Map.get(map, key, 0)
          new_val = safe_binop(op, old_val, val)
          updated = Map.put(map, key, new_val)
          setattr_nested(target_expr, updated, env, ctx)

        _ ->
          {{:exception, "TypeError: object does not support item assignment"}, env, ctx}
      end
    else
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  def eval({:subscript_assign, _, [name, key_expr, val_expr]}, env, ctx) do
    with {container, env, ctx} when not is_tuple(container) or elem(container, 0) != :exception <-
           eval({:var, [line: 1], [name]}, env, ctx),
         {key, env, ctx} when not is_tuple(key) or elem(key, 0) != :exception <-
           eval(key_expr, env, ctx),
         {val, env, ctx} when not is_tuple(val) or elem(val, 0) != :exception <-
           eval(val_expr, env, ctx) do
      case container do
        %{} = map ->
          updated = Map.put(map, key, val)
          ctx = Ctx.record(ctx, :assign, {name, :subscript})
          {val, Env.put_at_source(env, name, updated), ctx}

        list when is_list(list) and is_integer(key) ->
          updated = List.replace_at(list, key, val)
          ctx = Ctx.record(ctx, :assign, {name, :subscript})
          {val, Env.put_at_source(env, name, updated), ctx}

        {:instance, _, _} = inst ->
          case call_dunder_mut(inst, "__setitem__", [key, val], env, ctx) do
            {:ok, updated_inst, _return_val, env, ctx} ->
              {val, Env.put_at_source(env, name, updated_inst), ctx}

            :not_found ->
              {{:exception,
                "TypeError: '#{Helpers.py_type(inst)}' object does not support item assignment"},
               env, ctx}
          end

        _ ->
          {{:exception, "TypeError: object does not support item assignment"}, env, ctx}
      end
    else
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  def eval({:aug_assign, meta, [name, op, expr]}, env, ctx) do
    var_node = {:var, meta, [name]}
    binop_node = {:binop, meta, [op, var_node, expr]}
    eval({:assign, meta, [name, binop_node]}, env, ctx)
  end

  def eval({:return, _, [expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
      {value, env, ctx} -> {{:returned, value}, env, ctx}
    end
  end

  def eval({:yield, _, [expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        case ctx.generator_mode do
          mode when mode in [:defer, :defer_inner] ->
            {{:yielded, value, []}, env, ctx}

          :accumulate ->
            ctx = %{ctx | generator_acc: [value | ctx.generator_acc]}
            {nil, env, ctx}

          nil ->
            {{:exception, "SyntaxError: 'yield' outside function"}, env, ctx}
        end
    end
  end

  def eval({:yield_from, _, [expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {{:generator_error, items, exception_msg}, env, ctx} ->
        case ctx.generator_mode do
          :accumulate ->
            ctx = %{ctx | generator_acc: Enum.reverse(items) ++ ctx.generator_acc}
            {{:exception, exception_msg}, env, ctx}

          mode when mode in [:defer, :defer_inner] ->
            yield_from_deferred(items, env, ctx)

          nil ->
            {{:exception, "SyntaxError: 'yield from' outside function"}, env, ctx}
        end

      {iterable, env, ctx} ->
        case to_iterable(iterable, env, ctx) do
          {:ok, items, env, ctx} ->
            case ctx.generator_mode do
              mode when mode in [:defer, :defer_inner] ->
                yield_from_deferred(items, env, ctx)

              :accumulate ->
                ctx = %{ctx | generator_acc: Enum.reverse(items) ++ ctx.generator_acc}
                {nil, env, ctx}

              nil ->
                {{:exception, "SyntaxError: 'yield from' outside function"}, env, ctx}
            end

          {:exception, msg} ->
            {{:exception, msg}, env, ctx}
        end
    end
  end

  def eval({:if, _, clauses}, env, ctx) do
    eval_if_clauses(clauses, env, ctx)
  end

  def eval({:while, _, [condition, body, else_body]}, env, ctx) do
    eval_while(condition, body, else_body, env, ctx)
  end

  def eval({:for, _, [var_name, iterable_expr, body, else_body]}, env, ctx) do
    case eval(iterable_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {{:generator_error, items, exception_msg}, env, ctx} ->
        case eval_for(var_name, items, body, else_body, env, ctx) do
          {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
          {{:returned, _} = signal, env, ctx} -> {signal, env, ctx}
          {{:break}, env, ctx} -> {{:exception, exception_msg}, env, ctx}
          {_, env, ctx} -> {{:exception, exception_msg}, env, ctx}
        end

      {iterable, env, ctx} ->
        case to_iterable(iterable, env, ctx) do
          {:ok, items, env, ctx} -> eval_for(var_name, items, body, else_body, env, ctx)
          {:exception, msg} -> {{:exception, msg}, env, ctx}
        end
    end
  end

  def eval({:import, _, [module_name]}, env, ctx) do
    case Import.resolve_module(module_name, env, ctx) do
      {:ok, module_value, ctx} ->
        ctx = Ctx.record(ctx, :assign, {module_name, :module})
        {nil, Env.put(env, module_name, module_value), ctx}

      {:import_error, msg, ctx} ->
        {{:exception, msg}, env, ctx}

      {:unknown_module, ctx} ->
        {{:exception,
          "ImportError: no module named '#{module_name}'#{Import.import_hint(module_name)}"}, env,
         ctx}
    end
  end

  def eval({:import, _, [module_name, alias_name]}, env, ctx) do
    case Import.resolve_module(module_name, env, ctx) do
      {:ok, module_value, ctx} ->
        ctx = Ctx.record(ctx, :assign, {alias_name, :module})
        {nil, Env.put(env, alias_name, module_value), ctx}

      {:import_error, msg, ctx} ->
        {{:exception, msg}, env, ctx}

      {:unknown_module, ctx} ->
        {{:exception,
          "ImportError: no module named '#{module_name}'#{Import.import_hint(module_name)}"}, env,
         ctx}
    end
  end

  def eval({:from_import, _, [module_name, names]}, env, ctx) do
    case Import.resolve_module(module_name, env, ctx) do
      {:ok, module_value, ctx} when is_map(module_value) ->
        Enum.reduce_while(names, {nil, env, ctx}, fn {name, alias_name}, {_, env, ctx} ->
          bind_as = alias_name || name

          case Map.fetch(module_value, name) do
            {:ok, value} ->
              ctx = Ctx.record(ctx, :assign, {bind_as, :from_import})
              {:cont, {nil, Env.put(env, bind_as, value), ctx}}

            :error ->
              {:halt,
               {{:exception, "ImportError: cannot import name '#{name}' from '#{module_name}'"},
                env, ctx}}
          end
        end)

      {:import_error, msg, ctx} ->
        {{:exception, msg}, env, ctx}

      {:unknown_module, ctx} ->
        {{:exception,
          "ImportError: no module named '#{module_name}'#{Import.import_hint(module_name)}"}, env,
         ctx}
    end
  end

  def eval({:try, _, [body, handlers, else_body, finally_body]}, env, ctx) do
    eval_try(body, handlers, else_body, finally_body, env, ctx)
  end

  def eval({:raise, _meta, [nil]}, env, ctx) do
    case Env.get(env, "__current_exception__") do
      {:ok, msg} ->
        {{:exception, msg}, env, ctx}

      :undefined ->
        {{:exception, "RuntimeError: No active exception to re-raise"}, env, ctx}
    end
  end

  def eval({:raise, meta, [expr]}, env, ctx) do
    case expr do
      {:call, _, [{:var, _, [exc_name]}, args]} when is_list(args) ->
        eval_raise_exc_class(exc_name, args, meta, env, ctx)

      {:call, _, [{:var, _, [exc_name]}, args, _kwargs]} when is_list(args) ->
        eval_raise_exc_class(exc_name, args, meta, env, ctx)

      {:var, _, [exc_name]} ->
        {{:exception, exc_name}, env, ctx}

      _ ->
        case eval(expr, env, ctx) do
          {{:exception, _} = signal, _env, _ctx} ->
            {signal, env, ctx}

          {value, env, ctx} ->
            msg =
              case value do
                msg when is_binary(msg) -> "Exception: #{msg}"
                _ -> "Exception: #{inspect(value)}"
              end

            {{:exception, msg}, env, ctx}
        end
    end
  end

  def eval({:assert, _, [condition, msg_expr]}, env, ctx) do
    case eval(condition, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        {taken, env, ctx} = eval_truthy(value, env, ctx)

        if taken do
          {nil, env, ctx}
        else
          case msg_expr do
            nil ->
              {{:exception, "AssertionError"}, env, ctx}

            _ ->
              case eval(msg_expr, env, ctx) do
                {{:exception, _} = signal, env, ctx} ->
                  {signal, env, ctx}

                {msg_val, env, ctx} ->
                  {{:exception, "AssertionError: #{Helpers.py_str(msg_val)}"}, env, ctx}
              end
          end
        end
    end
  end

  def eval({:del, _, [:var, var_name]}, env, ctx) do
    {nil, Env.delete(env, var_name), ctx}
  end

  def eval({:del, _, [:subscript, var_name, key_expr]}, env, ctx) do
    case Env.get(env, var_name) do
      {:ok, obj} when is_map(obj) ->
        case eval(key_expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {key, env, ctx} ->
            {nil, Env.put(env, var_name, Map.delete(obj, key)), ctx}
        end

      {:ok, obj} when is_list(obj) ->
        case eval(key_expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {idx, env, ctx} when is_integer(idx) ->
            {nil, Env.put(env, var_name, List.delete_at(obj, idx)), ctx}

          {_, env, ctx} ->
            {{:exception, "TypeError: list indices must be integers"}, env, ctx}
        end

      {:ok, _} ->
        {{:exception, "TypeError: object does not support item deletion"}, env, ctx}

      :undefined ->
        {{:exception, "NameError: name '#{var_name}' is not defined"}, env, ctx}
    end
  end

  def eval({:aug_subscript_assign, _, [var_name, key_expr, op, val_expr]}, env, ctx) do
    case Env.get(env, var_name) do
      {:ok, obj} ->
        case eval(key_expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {key, env, ctx} ->
            case eval(val_expr, env, ctx) do
              {{:exception, _} = signal, env, ctx} ->
                {signal, env, ctx}

              {val, env, ctx} ->
                current = get_subscript_value(obj, key)

                case current do
                  {:exception, msg} ->
                    {{:exception, msg}, env, ctx}

                  current_val ->
                    case safe_binop(op, current_val, val) do
                      {:exception, msg} ->
                        {{:exception, msg}, env, ctx}

                      new_val ->
                        new_obj = set_subscript_value(obj, key, new_val)
                        {new_val, Env.put_at_source(env, var_name, new_obj), ctx}
                    end
                end
            end
        end

      :undefined ->
        {{:exception, "NameError: name '#{var_name}' is not defined"}, env, ctx}
    end
  end

  def eval({:pass, _, _}, env, ctx), do: {nil, env, ctx}
  def eval({:break, _, _}, env, ctx), do: {{:break}, env, ctx}
  def eval({:continue, _, _}, env, ctx), do: {{:continue}, env, ctx}

  def eval({:expr, _, [expr]}, env, ctx) do
    eval(expr, env, ctx)
  end

  def eval(
        {:call, _meta, [{:getattr, _, [{:var, _, [var_name]}, _attr]} = func_expr, arg_exprs]},
        env,
        ctx
      ) do
    case eval(func_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {func, env, ctx} ->
        case eval_call_args(arg_exprs, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {args, kwargs, env, ctx} ->
            case call_function(func, args, kwargs, env, ctx) do
              {:mutate, new_object, return_value, ctx} ->
                {return_value, Env.put_at_source(env, var_name, new_object), ctx}

              {{:exception, _} = signal, env, ctx} ->
                {signal, env, ctx}

              {result, env, ctx, _updated_func} ->
                env = maybe_update_instance_var(env, var_name)
                {result, env, ctx}

              {result, env, ctx} ->
                env = maybe_update_instance_var(env, var_name)
                {result, env, ctx}
            end
        end
    end
  end

  def eval({:call, _, [func_expr, arg_exprs]}, env, ctx) do
    case eval(func_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {func, env, ctx} ->
        case eval_call_args(arg_exprs, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {args, kwargs, env, ctx} ->
            case call_function(func, args, kwargs, env, ctx) do
              {:mutate, new_object, return_value, ctx} ->
                env = mutate_target(func_expr, new_object, env, ctx)
                {return_value, env, ctx}

              {{:exception, _} = signal, env, ctx} ->
                {signal, env, ctx}

              {result, env, ctx, updated_func} ->
                env = Helpers.rebind_var(env, func_expr, updated_func)
                {result, env, ctx}

              {result, env, ctx} ->
                {result, env, ctx}
            end
        end
    end
  end

  def eval({:getattr, _, [expr, attr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {object, env, ctx} ->
        case object do
          {:instance, {:class, _, _, _} = class, inst_attrs} ->
            case Map.fetch(inst_attrs, attr) do
              {:ok, value} ->
                {value, env, ctx}

              :error ->
                case resolve_class_attr_with_owner(class, attr) do
                  {:ok, {:function, _, _, _, _} = func, owner_class} ->
                    {{:bound_method, object, func, owner_class}, env, ctx}

                  {:ok, {:builtin_kw, _} = bkw, _owner} ->
                    {{:bound_method, object, bkw}, env, ctx}

                  {:ok, value, _owner} ->
                    {value, env, ctx}

                  :error ->
                    case Methods.resolve(object, attr) do
                      {:ok, method} ->
                        {method, env, ctx}

                      :error ->
                        {{:exception,
                          "AttributeError: '#{Helpers.py_type(object)}' object has no attribute '#{attr}'"},
                         env, ctx}
                    end
                end
            end

          {:super_proxy, instance, bases} ->
            result =
              Enum.find_value(bases, :error, fn base ->
                case resolve_class_attr_with_owner(base, attr) do
                  {:ok, _, _} = found -> found
                  :error -> nil
                end
              end)

            case result do
              {:ok, {:function, _, _, _, _} = func, owner_class} ->
                {{:bound_method, instance, func, owner_class}, env, ctx}

              {:ok, value, _owner} ->
                {value, env, ctx}

              :error ->
                {{:exception, "AttributeError: 'super' object has no attribute '#{attr}'"}, env,
                 ctx}
            end

          {:class, class_name, _, class_attrs} = class_val ->
            case Map.get(class_attrs, attr) do
              nil ->
                case resolve_class_attr_with_owner(class_val, attr) do
                  {:ok, {:function, _, _, _, _} = func, _owner} ->
                    {{:bound_method, class_val, func}, env, ctx}

                  {:ok, {:builtin_kw, _} = bkw, _owner} ->
                    {{:bound_method, class_val, bkw}, env, ctx}

                  {:ok, value, _owner} ->
                    {value, env, ctx}

                  :error ->
                    {{:exception,
                      "AttributeError: type object '#{class_name}' has no attribute '#{attr}'"},
                     env, ctx}
                end

              {:builtin_kw, _} = bkw ->
                {{:bound_method, class_val, bkw}, env, ctx}

              value ->
                {value, env, ctx}
            end

          %{^attr => value} ->
            {value, env, ctx}

          {:range, rs, re, rst} ->
            case attr do
              "start" ->
                {rs, env, ctx}

              "stop" ->
                {re, env, ctx}

              "step" ->
                {rst, env, ctx}

              _ ->
                {{:exception, "AttributeError: 'range' object has no attribute '#{attr}'"}, env,
                 ctx}
            end

          _ ->
            case Methods.resolve(object, attr) do
              {:ok, method} ->
                {method, env, ctx}

              :error ->
                {{:exception,
                  "AttributeError: '#{Helpers.py_type(object)}' object has no attribute '#{attr}'"},
                 env, ctx}
            end
        end
    end
  end

  def eval({:subscript, _, [expr, key_expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {object, env, ctx} ->
        case eval(key_expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {key, env, ctx} ->
            eval_subscript(object, key, env, ctx)
        end
    end
  end

  def eval({:slice, _, [expr, start_expr, stop_expr, step_expr]}, env, ctx) do
    with {object, env, ctx} when not is_py_exception(object) <- eval(expr, env, ctx),
         {start, env, ctx} when not is_py_exception(start) <- eval_optional(start_expr, env, ctx),
         {stop, env, ctx} when not is_py_exception(stop) <- eval_optional(stop_expr, env, ctx),
         {step, env, ctx} when not is_py_exception(step) <- eval_optional(step_expr, env, ctx) do
      eval_slice(object, start, stop, step, env, ctx)
    else
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  def eval({:lambda, _, [params, body_expr]}, env, ctx) do
    body = [{:return, [line: 1], [body_expr]}]
    func = {:function, "<lambda>", params, body, env}
    {func, env, ctx}
  end

  def eval({:tuple, _, [elements]}, env, ctx) do
    case eval_list(elements, env, ctx) do
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
      {values, env, ctx} -> {{:tuple, values}, env, ctx}
    end
  end

  def eval({:ternary, _, [condition, true_expr, false_expr]}, env, ctx) do
    case eval(condition, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {cond_val, env, ctx} ->
        {taken, env, ctx} = eval_truthy(cond_val, env, ctx)

        if taken do
          eval(true_expr, env, ctx)
        else
          eval(false_expr, env, ctx)
        end
    end
  end

  def eval({:list_comp, _, [expr, clauses]}, env, ctx) do
    case eval_comp_clauses(:list, expr, clauses, [], env, ctx) do
      {result, env, ctx} when is_list(result) -> {Enum.reverse(result), env, ctx}
      other -> other
    end
  end

  def eval({:gen_expr, _, [expr, clauses]}, env, ctx) do
    case eval_comp_clauses(:list, expr, clauses, [], env, ctx) do
      {result, env, ctx} when is_list(result) -> {{:generator, Enum.reverse(result)}, env, ctx}
      other -> other
    end
  end

  def eval({:dict_comp, _, [key_expr, val_expr, clauses]}, env, ctx) do
    eval_comp_clauses(:dict, {key_expr, val_expr}, clauses, %{}, env, ctx)
  end

  def eval({:set_comp, _, [expr, clauses]}, env, ctx) do
    case eval_comp_clauses(:set, expr, clauses, MapSet.new(), env, ctx) do
      {{:exception, _}, _, _} = result -> result
      {set, env, ctx} -> {{:set, set}, env, ctx}
    end
  end

  def eval({:list, _, [elements]}, env, ctx) do
    eval_list(elements, env, ctx)
  end

  def eval({:dict, _, [entries]}, env, ctx) do
    eval_dict(entries, env, ctx)
  end

  def eval({:set, _, [elements]}, env, ctx) do
    case eval_list(elements, env, ctx) do
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
      {values, env, ctx} -> {{:set, MapSet.new(values)}, env, ctx}
    end
  end

  def eval({:binop, _, [op, left, right]}, env, ctx) when op in [:and, :or] do
    case eval(left, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {l, env, ctx} ->
        {taken, env, ctx} = eval_truthy(l, env, ctx)

        case {op, taken} do
          {:and, false} ->
            {l, env, ctx}

          {:or, true} ->
            {l, env, ctx}

          _ ->
            case eval(right, env, ctx) do
              {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
              {r, env, ctx} -> {r, env, ctx}
            end
        end
    end
  end

  def eval({:binop, _, [op, left, right]}, env, ctx) do
    case eval(left, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {l, env, ctx} ->
        case eval(right, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {r, env, ctx} ->
            eval_binop(op, l, r, env, ctx)
        end
    end
  end

  def eval({:chained_compare, _, [ops, operands]}, env, ctx) do
    eval_chained_compare(ops, operands, nil, env, ctx)
  end

  def eval({:unaryop, _, [:neg, expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {val, env, ctx} when is_number(val) ->
        {-val, env, ctx}

      {{:instance, _, _} = inst, env, ctx} ->
        case call_dunder(inst, "__neg__", [], env, ctx) do
          {:ok, result, env, ctx} ->
            {result, env, ctx}

          :not_found ->
            {{:exception, "TypeError: bad operand type for unary -: '#{Helpers.py_type(inst)}'"},
             env, ctx}
        end

      {val, env, ctx} ->
        {{:exception, "TypeError: bad operand type for unary -: '#{Helpers.py_type(val)}'"}, env,
         ctx}
    end
  end

  def eval({:unaryop, _, [:pos, expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {val, env, ctx} when is_number(val) ->
        {val, env, ctx}

      {{:instance, _, _} = inst, env, ctx} ->
        case call_dunder(inst, "__pos__", [], env, ctx) do
          {:ok, result, env, ctx} ->
            {result, env, ctx}

          :not_found ->
            {{:exception, "TypeError: bad operand type for unary +: '#{Helpers.py_type(inst)}'"},
             env, ctx}
        end

      {val, env, ctx} ->
        {{:exception, "TypeError: bad operand type for unary +: '#{Helpers.py_type(val)}'"}, env,
         ctx}
    end
  end

  def eval({:unaryop, _, [:bitnot, expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {val, env, ctx} when is_integer(val) ->
        {bnot(val), env, ctx}

      {{:instance, _, _} = inst, env, ctx} ->
        case call_dunder(inst, "__invert__", [], env, ctx) do
          {:ok, result, env, ctx} ->
            {result, env, ctx}

          :not_found ->
            {{:exception, "TypeError: bad operand type for unary ~: '#{Helpers.py_type(inst)}'"},
             env, ctx}
        end

      {val, env, ctx} ->
        {{:exception, "TypeError: bad operand type for unary ~: '#{Helpers.py_type(val)}'"}, env,
         ctx}
    end
  end

  def eval({:unaryop, _, [:not, expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {{:instance, _, _} = inst, env, ctx} ->
        {result, env, ctx} = eval_truthy(inst, env, ctx)
        {!result, env, ctx}

      {val, env, ctx} ->
        {!Helpers.truthy?(val), env, ctx}
    end
  end

  def eval({:fstring, _, [parts]}, env, ctx) do
    eval_fstring(parts, <<>>, env, ctx)
  end

  def eval({:lit, _, [value]}, env, ctx), do: {value, env, ctx}

  def eval({:var, _, [name]}, env, ctx) do
    case Env.get(env, name) do
      {:ok, value} -> {value, env, ctx}
      :undefined -> {{:exception, "NameError: name '#{name}' is not defined"}, env, ctx}
    end
  end

  @doc false
  @spec eval_statements([Parser.ast_node()], Env.t(), Ctx.t()) :: eval_result()
  def eval_statements([], env, ctx), do: {nil, env, ctx}

  def eval_statements([stmt], env, ctx) do
    ctx = track_line(stmt, ctx)
    eval(stmt, env, ctx)
  end

  def eval_statements([stmt | rest], env, ctx) do
    case Ctx.check_deadline(ctx) do
      {:exceeded, _} ->
        {{:exception, "TimeoutError: execution exceeded time limit"}, env, ctx}

      :ok ->
        ctx = track_line(stmt, ctx)

        case eval(stmt, env, ctx) do
          {{:returned, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {{:break} = signal, env, ctx} ->
            {signal, env, ctx}

          {{:continue} = signal, env, ctx} ->
            {signal, env, ctx}

          {{:suspended} = signal, env, ctx} ->
            {signal, env, ctx}

          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {{:yielded, val, cont}, env, ctx} ->
            {{:yielded, val, cont ++ [{:cont_stmts, rest}]}, env, ctx}

          {_, env, ctx} ->
            eval_statements(rest, env, ctx)
        end
    end
  end

  @spec init_profile(Ctx.t()) :: Ctx.t()
  defp init_profile(%Ctx{profile: nil} = ctx), do: ctx

  defp init_profile(%Ctx{} = ctx) do
    %{ctx | profile: %{line_counts: %{}, call_counts: %{}, call_us: %{}}}
  end

  @spec profile_record_call(Ctx.t(), String.t(), non_neg_integer()) :: Ctx.t()
  defp profile_record_call(%Ctx{profile: nil} = ctx, _name, _elapsed_us), do: ctx

  defp profile_record_call(%Ctx{profile: profile} = ctx, name, elapsed_us) do
    call_counts = Map.update(profile.call_counts, name, 1, &(&1 + 1))
    call_us = Map.update(profile.call_us, name, elapsed_us, &(&1 + elapsed_us))
    %{ctx | profile: %{profile | call_counts: call_counts, call_us: call_us}}
  end

  @spec track_line(Parser.ast_node(), Ctx.t()) :: Ctx.t()
  defp track_line({_tag, meta, _children}, ctx) when is_list(meta) do
    case Keyword.get(meta, :line) do
      nil ->
        ctx

      line ->
        ctx = %{ctx | current_line: line}

        case ctx.profile do
          %{line_counts: counts} = profile ->
            %{ctx | profile: %{profile | line_counts: Map.update(counts, line, 1, &(&1 + 1))}}

          nil ->
            ctx
        end
    end
  end

  defp track_line(_, ctx), do: ctx

  @primitive_type_names ~w(str int float bool list dict tuple set)
  @spec resolve_annotation(String.t(), Env.t()) :: String.t() | pyvalue()
  defp resolve_annotation(type_str, env) do
    if type_str in @primitive_type_names or String.contains?(type_str, "[") do
      type_str
    else
      case Env.get(env, type_str) do
        {:ok, {:class, _, _, _} = class} -> class
        _ -> type_str
      end
    end
  end

  @type call_result ::
          {pyvalue(), Env.t(), Ctx.t()}
          | {pyvalue(), Env.t(), Ctx.t(), pyvalue()}
          | {:mutate, pyvalue(), pyvalue(), Ctx.t()}
          | {{:register_route, String.t(), String.t(), pyvalue()}, Env.t(), Ctx.t()}
          | {{:exception, String.t()}, Env.t(), Ctx.t()}

  @doc false
  @spec call_function(
          pyvalue(),
          [pyvalue()],
          %{optional(String.t()) => pyvalue()},
          Env.t(),
          Ctx.t()
        ) ::
          call_result()
  def call_function(func, args, kwargs, env, ctx)

  def call_function({:function, name, params, body, closure_env} = func, args, kwargs, env, ctx) do
    if ctx.call_depth >= ctx.max_call_depth do
      {{:exception, "RecursionError: maximum recursion depth exceeded"}, env, ctx}
    else
      ctx =
        %{
          Ctx.record(ctx, :call_enter, {length(args) + map_size(kwargs)})
          | call_depth: ctx.call_depth + 1
        }

      fresh_closure = Env.put_global_scope(closure_env, Env.global_scope(env))
      base_env = Env.push_scope(Env.put(fresh_closure, name, func))

      case bind_params(params, args, kwargs, base_env, ctx) do
        {:exception, msg, ctx} ->
          ctx = %{ctx | call_depth: ctx.call_depth - 1}
          {{:exception, msg}, env, ctx}

        {call_env, ctx} ->
          t0 = if ctx.profile, do: System.monotonic_time(:microsecond)

          result =
            if contains_yield?(body) do
              case ctx.generator_mode do
                :defer ->
                  gen_ctx = %{ctx | generator_mode: :defer_inner}

                  case eval_statements(body, call_env, gen_ctx) do
                    {{:yielded, val, cont}, gen_env, gen_ctx} ->
                      ctx =
                        Ctx.record(
                          %{
                            ctx
                            | compute_ns: gen_ctx.compute_ns,
                              compute_started_at: gen_ctx.compute_started_at
                          },
                          :call_exit,
                          {:generator}
                        )

                      {{:generator_suspended, val, cont, gen_env}, env, ctx}

                    {{:exception, _} = signal, _post_env, gen_ctx} ->
                      ctx = %{
                        ctx
                        | compute_ns: gen_ctx.compute_ns,
                          compute_started_at: gen_ctx.compute_started_at
                      }

                      {signal, env, ctx}

                    {_, _post_env, gen_ctx} ->
                      ctx =
                        Ctx.record(
                          %{
                            ctx
                            | compute_ns: gen_ctx.compute_ns,
                              compute_started_at: gen_ctx.compute_started_at
                          },
                          :call_exit,
                          {:generator}
                        )

                      {{:generator, []}, env, ctx}
                  end

                _ ->
                  prev_acc = ctx.generator_acc
                  gen_ctx = %{ctx | generator_mode: :accumulate, generator_acc: []}
                  {result, _post_call_env, gen_ctx} = eval_statements(body, call_env, gen_ctx)
                  yields = Enum.reverse(gen_ctx.generator_acc || [])

                  ctx =
                    Ctx.record(
                      %{
                        ctx
                        | compute_ns: gen_ctx.compute_ns,
                          compute_started_at: gen_ctx.compute_started_at,
                          generator_mode: ctx.generator_mode,
                          generator_acc: prev_acc
                      },
                      :call_exit,
                      {:generator}
                    )

                  case result do
                    {:exception, "TimeoutError:" <> _ = msg} ->
                      {{:exception, msg}, env, ctx}

                    {:exception, msg} ->
                      {{:generator_error, yields, msg}, env, ctx}

                    _ ->
                      {{:generator, yields}, env, ctx}
                  end
              end
            else
              {result, post_call_env, ctx} = eval_statements(body, call_env, ctx)
              env = Env.propagate_scopes(env, fresh_closure, post_call_env)
              return_val = Helpers.unwrap(result)
              ctx = Ctx.record(ctx, :call_exit, {return_val})

              if Helpers.has_scope_declarations?(post_call_env) do
                return_val = Helpers.refresh_closure(return_val, post_call_env)
                updated_func = Helpers.refresh_closure(func, post_call_env)
                {return_val, env, ctx, updated_func}
              else
                updated_func = Helpers.update_closure_env(func, post_call_env)
                {return_val, env, ctx, updated_func}
              end
            end

          result =
            if t0 do
              elapsed = System.monotonic_time(:microsecond) - t0
              update_profile_in_result(result, name, elapsed)
            else
              result
            end

          decrement_depth(result)
      end
    end
  end

  def call_function({:builtin, fun}, args, _kwargs, env, ctx) do
    result =
      try do
        fun.(args)
      rescue
        FunctionClauseError ->
          {:exception, "TypeError: invalid arguments"}

        e in [ArithmeticError, ArgumentError, Enum.EmptyError] ->
          {:exception, "TypeError: #{Exception.message(e)}"}
      end

    case result do
      {:suspended} ->
        if ctx.mode == :replay do
          {nil, env, ctx}
        else
          ctx = Ctx.record(ctx, :suspend, {})
          {{:suspended}, env, ctx}
        end

      {:ctx_call, ctx_fun} ->
        ctx_fun.(env, ctx)

      {:io_call, io_fun} ->
        ctx = Ctx.pause_compute(ctx)
        {result, env, ctx} = io_fun.(env, ctx)
        ctx = Ctx.resume_compute(ctx)
        {result, env, ctx}

      {:mutate, new_object, return_value} ->
        ctx = Ctx.record(ctx, :side_effect, {:mutate})
        {:mutate, new_object, return_value, ctx}

      {:method_call, instance, func, method_args} ->
        call_method(instance, func, method_args, %{}, env, ctx)

      {:dunder_call, instance, dunder_name, dunder_args} ->
        case call_dunder(instance, dunder_name, dunder_args, env, ctx) do
          {:ok, result, env, ctx} ->
            {result, env, ctx}

          :not_found ->
            case dunder_str_fallback(instance, dunder_name, env, ctx) do
              {:ok, result, env, ctx} -> {result, env, ctx}
              :error -> {{:exception, "TypeError: object has no #{dunder_name}"}, env, ctx}
            end
        end

      {:iter_to_list, val} ->
        case to_iterable(val, env, ctx) do
          {:ok, items, env, ctx} -> {items, env, ctx}
          {:exception, _} = signal -> {signal, env, ctx}
        end

      {:iter_to_tuple, val} ->
        case to_iterable(val, env, ctx) do
          {:ok, items, env, ctx} -> {{:tuple, items}, env, ctx}
          {:exception, _} = signal -> {signal, env, ctx}
        end

      {:iter_to_set, val} ->
        case to_iterable(val, env, ctx) do
          {:ok, items, env, ctx} -> {{:set, MapSet.new(items)}, env, ctx}
          {:exception, _} = signal -> {signal, env, ctx}
        end

      {:iter_instance, inst} ->
        case call_dunder(inst, "__iter__", [], env, ctx) do
          {:ok, {:instance, _, _} = iter_inst, env, ctx} ->
            {token, ctx} = Ctx.new_instance_iterator(ctx, iter_inst)
            {token, env, ctx}

          {:ok, {:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {:ok, other, env, ctx} ->
            case Builtins.materialize_iterable(other) do
              {:ok, items} ->
                {token, ctx} = Ctx.new_iterator(ctx, items)
                {token, env, ctx}

              {:pass, iter} ->
                {iter, env, ctx}

              :error ->
                {{:exception, "TypeError: iter() returned non-iterator"}, env, ctx}
            end

          :not_found ->
            {{:exception, "TypeError: '#{Helpers.py_type(inst)}' object is not iterable"}, env,
             ctx}
        end

      {:make_iter, items} ->
        {token, ctx} = Ctx.new_iterator(ctx, items)
        {token, env, ctx}

      {:iter_next, id} ->
        case Ctx.iter_next(ctx, id) do
          {:ok, item, ctx} -> {item, env, ctx}
          :exhausted -> {{:exception, "StopIteration"}, env, ctx}
          {:instance, inst} -> eval_instance_next(inst, id, :no_default, env, ctx)
        end

      {:iter_next_default, id, default} ->
        case Ctx.iter_next(ctx, id) do
          {:ok, item, ctx} -> {item, env, ctx}
          :exhausted -> {default, env, ctx}
          {:instance, inst} -> eval_instance_next(inst, id, {:default, default}, env, ctx)
        end

      {:next_instance_iter, id, default_opt} ->
        case Ctx.iter_next(ctx, id) do
          {:instance, inst} ->
            eval_instance_next(inst, id, default_opt, env, ctx)

          {:ok, item, ctx} ->
            {item, env, ctx}

          :exhausted ->
            case default_opt do
              {:default, default} -> {default, env, ctx}
              :no_default -> {{:exception, "StopIteration"}, env, ctx}
            end
        end

      {:next_with_default, inst, default} ->
        case call_dunder_mut(inst, "__next__", [], env, ctx) do
          {:ok, _new_inst, {:exception, "StopIteration" <> _}, env, ctx} ->
            {default, env, ctx}

          {:ok, _new_inst, {:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {:ok, _new_inst, value, env, ctx} ->
            {value, env, ctx}

          :not_found ->
            {{:exception, "TypeError: object has no __next__"}, env, ctx}
        end

      {:iter_sum, val} ->
        case to_iterable(val, env, ctx) do
          {:ok, items, env, ctx} -> {Enum.sum(items), env, ctx}
          {:exception, _} = signal -> {signal, env, ctx}
        end

      {:print_call, print_args} ->
        eval_print_call(print_args, env, ctx)

      {:map_call, func, list} ->
        Iteration.eval_map_call(func, list, env, ctx)

      {:filter_call, func, list} ->
        Iteration.eval_filter_call(func, list, env, ctx)

      {:super_call} ->
        eval_super(env, ctx)

      {:starmap_call, func, items} ->
        Iteration.eval_starmap(func, items, env, ctx)

      {:takewhile_call, predicate, items} ->
        Iteration.eval_takewhile(predicate, items, env, ctx)

      {:dropwhile_call, predicate, items} ->
        Iteration.eval_dropwhile(predicate, items, env, ctx)

      {:filterfalse_call, predicate, items} ->
        Iteration.eval_filterfalse(predicate, items, env, ctx)

      {:unittest_main} ->
        Unittest.eval_unittest_main(env, ctx)

      {:assert_raises, exc_type} ->
        {{:assert_raises, exc_type}, env, ctx}

      {:register_route, _method, _path, _handler} = signal ->
        {signal, env, ctx}

      {:exception, _msg} = signal ->
        {signal, env, ctx}

      value ->
        ctx = Ctx.record(ctx, :side_effect, {:builtin_call, value})
        {value, env, ctx}
    end
  end

  def call_function({:builtin_type, _name, fun}, args, kwargs, env, ctx) do
    call_function({:builtin, fun}, args, kwargs, env, ctx)
  end

  def call_function({:builtin_kw, fun}, args, kwargs, env, ctx) do
    result =
      try do
        fun.(args, kwargs)
      rescue
        FunctionClauseError ->
          {:exception, "TypeError: invalid arguments"}

        e in [ArithmeticError, ArgumentError, Enum.EmptyError] ->
          {:exception, "TypeError: #{Exception.message(e)}"}
      end

    case result do
      {:exception, _msg} = signal ->
        {signal, env, ctx}

      {:io_call, io_fun} ->
        ctx = Ctx.pause_compute(ctx)
        {result, env, ctx} = io_fun.(env, ctx)
        ctx = Ctx.resume_compute(ctx)
        {result, env, ctx}

      {:sort_call, items, key_fn, reverse} ->
        eval_sort(items, key_fn, reverse, env, ctx)

      {:iter_sorted, val, key_fn, reverse} ->
        case to_iterable(val, env, ctx) do
          {:ok, items, env, ctx} -> eval_sort(items, key_fn, reverse, env, ctx)
          {:exception, _} = signal -> {signal, env, ctx}
        end

      {:min_call, items, key_fn} ->
        eval_minmax(items, key_fn, :min, env, ctx)

      {:max_call, items, key_fn} ->
        eval_minmax(items, key_fn, :max, env, ctx)

      {:accumulate_call, items, func} ->
        Iteration.eval_accumulate(items, func, env, ctx)

      {:groupby_call, items, key_func} ->
        Iteration.eval_groupby(items, key_func, env, ctx)

      {:starmap_call, func, items} ->
        Iteration.eval_starmap(func, items, env, ctx)

      {:takewhile_call, predicate, items} ->
        Iteration.eval_takewhile(predicate, items, env, ctx)

      {:dropwhile_call, predicate, items} ->
        Iteration.eval_dropwhile(predicate, items, env, ctx)

      {:filterfalse_call, predicate, items} ->
        Iteration.eval_filterfalse(predicate, items, env, ctx)

      result ->
        ctx = Ctx.record(ctx, :side_effect, {:builtin_call, result})
        {result, env, ctx}
    end
  end

  def call_function(
        {:bound_method, instance, {:function, _, _, _, _} = func, defining_class},
        args,
        kwargs,
        env,
        ctx
      ) do
    call_bound_method(instance, func, defining_class, args, kwargs, env, ctx)
  end

  def call_function(
        {:bound_method, instance, {:function, _, _, _, _} = func},
        args,
        kwargs,
        env,
        ctx
      ) do
    call_bound_method(instance, func, nil, args, kwargs, env, ctx)
  end

  def call_function(
        {:bound_method, instance, {:builtin_kw, fun}},
        args,
        kwargs,
        env,
        ctx
      ) do
    case fun.([instance | args], kwargs) do
      {:exception, _} = signal ->
        {signal, env, ctx}

      {:mutate, new_obj, return_val, new_ctx} ->
        {:mutate, new_obj, return_val, new_ctx}

      result ->
        {result, env, ctx}
    end
  end

  def call_function(
        {:bound_method, instance, {:builtin, fun}},
        args,
        _kwargs,
        env,
        ctx
      ) do
    case fun.([instance | args]) do
      {:exception, _} = signal ->
        {signal, env, ctx}

      result ->
        {result, env, ctx}
    end
  end

  def call_function({:class, name, _bases, _class_attrs} = class, args, kwargs, env, ctx) do
    instance = {:instance, class, %{}}
    ctx = Ctx.record(ctx, :call_enter, {length(args)})

    case resolve_class_attr_with_owner(class, "__init__") do
      {:ok, {:function, init_name, params, body, closure_env}, defining_class} ->
        init_args = [instance | args]
        fresh_closure = Env.put_global_scope(closure_env, Env.global_scope(env))
        init_fn = {:function, init_name, params, body, closure_env}
        base_env = Env.push_scope(Env.put(fresh_closure, init_name, init_fn))
        base_env = Env.put(base_env, "__class__", defining_class)

        case bind_params(params, init_args, kwargs, base_env, ctx) do
          {:exception, msg, ctx} ->
            {{:exception, msg}, env, ctx}

          {call_env, ctx} ->
            {result, post_call_env, ctx} = eval_statements(body, call_env, ctx)
            env = Env.propagate_scopes(env, fresh_closure, post_call_env)

            case result do
              {:exception, _} = signal ->
                {signal, env, ctx}

              _ ->
                final_self =
                  case Env.get(post_call_env, "self") do
                    {:ok, {:instance, _, _} = updated} -> updated
                    _ -> instance
                  end

                ctx = Ctx.record(ctx, :call_exit, {final_self})
                {final_self, env, ctx}
            end
        end

      {:ok, {:builtin_kw, fun}, _defining_class} ->
        case fun.([instance | args], kwargs) do
          {:instance, _, _} = updated_instance ->
            ctx = Ctx.record(ctx, :call_exit, {updated_instance})
            {updated_instance, env, ctx}

          {:exception, _} = signal ->
            {signal, env, ctx}
        end

      :error ->
        if args == [] do
          ctx = Ctx.record(ctx, :call_exit, {instance})
          {instance, env, ctx}
        else
          {{:exception, "TypeError: #{name}() takes 0 arguments but #{length(args)} were given"},
           env, ctx}
        end
    end
  end

  def call_function({:instance, {:class, _, _, _} = class, _} = instance, args, kwargs, env, ctx) do
    case resolve_class_attr(class, "__call__") do
      {:ok, {:function, _, _, _, _} = func} ->
        call_function({:bound_method, instance, func}, args, kwargs, env, ctx)

      _ ->
        {{:exception, "TypeError: '#{Helpers.py_type(instance)}' object is not callable"}, env,
         ctx}
    end
  end

  def call_function(val, _args, _kwargs, env, ctx) do
    {{:exception, "TypeError: '#{Helpers.py_type(val)}' object is not callable"}, env, ctx}
  end

  @spec update_profile_in_result(call_result(), String.t(), non_neg_integer()) :: call_result()
  defp update_profile_in_result({val, env, ctx}, name, elapsed_us) do
    {val, env, profile_record_call(ctx, name, elapsed_us)}
  end

  defp update_profile_in_result({val, env, ctx, extra}, name, elapsed_us) do
    {val, env, profile_record_call(ctx, name, elapsed_us), extra}
  end

  @spec call_bound_method(
          pyvalue(),
          pyvalue(),
          pyvalue() | nil,
          [pyvalue()],
          %{optional(String.t()) => pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: call_result()
  defp call_bound_method(
         instance,
         {:function, fname, params, body, closure_env},
         defining_class,
         args,
         kwargs,
         env,
         ctx
       ) do
    method_args = [instance | args]
    fresh_closure = Env.put_global_scope(closure_env, Env.global_scope(env))
    func = {:function, fname, params, body, closure_env}
    base_env = Env.push_scope(Env.put(fresh_closure, fname, func))

    base_env =
      if defining_class, do: Env.put(base_env, "__class__", defining_class), else: base_env

    case bind_params(params, method_args, kwargs, base_env, ctx) do
      {:exception, msg, ctx} ->
        {{:exception, msg}, env, ctx}

      {call_env, ctx} ->
        ctx = Ctx.record(ctx, :call_enter, {length(method_args)})
        {result, post_call_env, ctx} = eval_statements(body, call_env, ctx)
        _propagated_env = Env.propagate_scopes(env, fresh_closure, post_call_env)
        return_val = Helpers.unwrap(result)

        updated_self =
          case Env.get(post_call_env, "self") do
            {:ok, {:instance, _, _} = updated} -> updated
            _ -> instance
          end

        ctx = Ctx.record(ctx, :call_exit, {return_val})
        {:mutate, updated_self, return_val, ctx}
    end
  end

  @spec bind_params(
          [Parser.param()],
          [pyvalue()],
          %{optional(String.t()) => pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: {Env.t(), Ctx.t()} | {:exception, String.t(), Ctx.t()}
  defp bind_params(params, args, kwargs, env, ctx) do
    {regular, star_param, dstar_param} = split_variadic_params(params)
    regular_names = Enum.map(regular, &elem(&1, 0))
    defaults = Enum.map(regular, &elem(&1, 1))
    n_regular = length(regular)
    n_args = length(args)

    has_star = star_param != nil
    has_dstar = dstar_param != nil

    if n_args > n_regular and not has_star do
      {:exception,
       "TypeError: function takes #{n_regular} positional arguments but #{n_args} were given",
       ctx}
    else
      positional = Enum.take(args, n_regular)
      extra_args = Enum.drop(args, n_regular)
      padded = positional ++ List.duplicate(:__unset__, max(n_regular - n_args, 0))

      consumed_kwargs =
        MapSet.new(regular_names)
        |> MapSet.intersection(MapSet.new(Map.keys(kwargs)))

      result =
        [regular_names, padded, defaults]
        |> Enum.zip()
        |> Enum.reduce_while({env, ctx}, fn {name, arg, default}, {env, ctx} ->
          cond do
            arg != :__unset__ ->
              {:cont, {Env.put(env, name, arg), ctx}}

            Map.has_key?(kwargs, name) ->
              {:cont, {Env.put(env, name, Map.fetch!(kwargs, name)), ctx}}

            default != nil ->
              {val, _env, ctx} = eval(default, env, ctx)
              {:cont, {Env.put(env, name, val), ctx}}

            true ->
              {:halt, {:exception, "TypeError: missing required argument: '#{name}'", ctx}}
          end
        end)

      case result do
        {:exception, _, _} = err ->
          err

        {env, ctx} ->
          env = if has_star, do: Env.put(env, star_name(star_param), extra_args), else: env

          extra_kwargs = Map.drop(kwargs, MapSet.to_list(consumed_kwargs))

          env =
            if has_dstar, do: Env.put(env, dstar_name(dstar_param), extra_kwargs), else: env

          {env, ctx}
      end
    end
  end

  @spec split_variadic_params([Parser.param()]) ::
          {[Parser.param()], Parser.param() | nil, Parser.param() | nil}
  defp split_variadic_params(params) do
    {regular_rev, star, dstar} =
      Enum.reduce(params, {[], nil, nil}, fn param, {regular, star, dstar} ->
        name = elem(param, 0)

        cond do
          String.starts_with?(name, "**") -> {regular, star, param}
          String.starts_with?(name, "*") -> {regular, param, dstar}
          true -> {[param | regular], star, dstar}
        end
      end)

    {Enum.reverse(regular_rev), star, dstar}
  end

  @spec star_name(Parser.param()) :: String.t()
  defp star_name(param), do: String.trim_leading(elem(param, 0), "*")

  @spec dstar_name(Parser.param()) :: String.t()
  defp dstar_name(param), do: String.trim_leading(elem(param, 0), "*")

  @spec eval_call_args([Parser.ast_node()], Env.t(), Ctx.t()) ::
          {[pyvalue()], %{optional(String.t()) => pyvalue()}, Env.t(), Ctx.t()}
          | {{:exception, String.t()}, Env.t(), Ctx.t()}
  defp eval_call_args(arg_exprs, env, ctx) do
    Enum.reduce_while(arg_exprs, {[], %{}, env, ctx}, fn
      {:kwarg, _, [name, expr]}, {pos, kw, env, ctx} ->
        case eval(expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} -> {:halt, {signal, env, ctx}}
          {val, env, ctx} -> {:cont, {pos, Map.put(kw, name, val), env, ctx}}
        end

      {:star_arg, _, [expr]}, {pos, kw, env, ctx} ->
        case eval(expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {:halt, {signal, env, ctx}}

          {val, env, ctx} ->
            case to_iterable(val, env, ctx) do
              {:ok, items, env, ctx} ->
                {:cont, {Enum.reverse(items) ++ pos, kw, env, ctx}}

              {:exception, msg} ->
                {:halt, {{:exception, msg}, env, ctx}}
            end
        end

      {:double_star_arg, _, [expr]}, {pos, kw, env, ctx} ->
        case eval(expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {:halt, {signal, env, ctx}}

          {val, env, ctx} when is_map(val) ->
            merged =
              Enum.reduce(val, kw, fn {k, v}, acc ->
                Map.put(acc, to_string(k), v)
              end)

            {:cont, {pos, merged, env, ctx}}

          {val, env, ctx} ->
            {:halt,
             {{:exception,
               "TypeError: argument after ** must be a mapping, not '#{Helpers.py_type(val)}'"},
              env, ctx}}
        end

      expr, {pos, kw, env, ctx} ->
        case eval(expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} -> {:halt, {signal, env, ctx}}
          {val, env, ctx} -> {:cont, {[val | pos], kw, env, ctx}}
        end
    end)
    |> case do
      {pos, kw, env, ctx} when is_list(pos) -> {Enum.reverse(pos), kw, env, ctx}
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  @spec eval_list([Parser.ast_node()], Env.t(), Ctx.t()) ::
          {[pyvalue()], Env.t(), Ctx.t()} | {{:exception, String.t()}, Env.t(), Ctx.t()}
  defp eval_list(exprs, env, ctx) do
    Enum.reduce_while(exprs, {[], env, ctx}, fn expr, {acc, env, ctx} ->
      case eval(expr, env, ctx) do
        {{:exception, _} = signal, env, ctx} -> {:halt, {signal, env, ctx}}
        {val, env, ctx} -> {:cont, {[val | acc], env, ctx}}
      end
    end)
    |> case do
      {values, env, ctx} when is_list(values) -> {Enum.reverse(values), env, ctx}
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  @spec eval_if_clauses(
          [{Parser.ast_node(), [Parser.ast_node()]} | {:else, [Parser.ast_node()]}],
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp eval_if_clauses([], env, ctx), do: {nil, env, ctx}

  defp eval_if_clauses([{:else, body} | _], env, ctx) do
    ctx = Ctx.record(ctx, :branch, {:else})
    eval_statements(body, env, ctx)
  end

  defp eval_if_clauses([{condition, body} | rest], env, ctx) do
    case eval(condition, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        {taken, env, ctx} = eval_truthy(value, env, ctx)
        ctx = Ctx.record(ctx, :branch, {:if, taken})

        if taken do
          eval_statements(body, env, ctx)
        else
          eval_if_clauses(rest, env, ctx)
        end
    end
  end

  @spec eval_while(
          Parser.ast_node(),
          [Parser.ast_node()],
          [Parser.ast_node()] | nil,
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp eval_while(condition, body, else_body, env, ctx) do
    case Ctx.check_deadline(ctx) do
      {:exceeded, _} ->
        {{:exception, "TimeoutError: execution exceeded time limit"}, env, ctx}

      :ok ->
        eval_while_body(condition, body, else_body, env, ctx)
    end
  end

  defp eval_while_body(condition, body, else_body, env, ctx) do
    case eval(condition, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        {taken, env, ctx} = eval_truthy(value, env, ctx)
        ctx = Ctx.record(ctx, :loop_iter, {:while, taken})

        if taken do
          case eval_statements(body, env, ctx) do
            {{:returned, _} = signal, env, ctx} ->
              {signal, env, ctx}

            {{:break}, env, ctx} ->
              {nil, env, ctx}

            {{:suspended} = signal, env, ctx} ->
              {signal, env, ctx}

            {{:exception, _} = signal, env, ctx} ->
              {signal, env, ctx}

            {{:yielded, val, cont}, env, ctx} ->
              {{:yielded, val, cont ++ [{:cont_while, condition, body, else_body}]}, env, ctx}

            {{:continue}, env, ctx} ->
              eval_while(condition, body, else_body, env, ctx)

            {_, env, ctx} ->
              eval_while(condition, body, else_body, env, ctx)
          end
        else
          eval_loop_else(else_body, env, ctx)
        end
    end
  end

  @spec eval_for(
          String.t() | [String.t()],
          [pyvalue()],
          [Parser.ast_node()],
          [Parser.ast_node()] | nil,
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp eval_for(_var_name, [], _body, else_body, env, ctx) do
    eval_loop_else(else_body, env, ctx)
  end

  defp eval_for(var_names, [item | rest], body, else_body, env, ctx)
       when is_list(var_names) do
    case Ctx.check_deadline(ctx) do
      {:exceeded, _} ->
        {{:exception, "TimeoutError: execution exceeded time limit"}, env, ctx}

      :ok ->
        case unpack_for_item(var_names, item) do
          {:ok, bindings} ->
            env =
              Enum.reduce(bindings, env, fn {name, val}, env -> Env.smart_put(env, name, val) end)

            ctx = Ctx.record(ctx, :loop_iter, {:for, var_names, item})

            case eval_statements(body, env, ctx) do
              {{:returned, _} = signal, env, ctx} ->
                {signal, env, ctx}

              {{:break}, env, ctx} ->
                {nil, env, ctx}

              {{:suspended} = signal, env, ctx} ->
                {signal, env, ctx}

              {{:exception, _} = signal, env, ctx} ->
                {signal, env, ctx}

              {{:yielded, val, cont}, env, ctx} ->
                {{:yielded, val, cont ++ [{:cont_for, var_names, rest, body, else_body}]}, env,
                 ctx}

              {{:continue}, env, ctx} ->
                eval_for(var_names, rest, body, else_body, env, ctx)

              {_, env, ctx} ->
                eval_for(var_names, rest, body, else_body, env, ctx)
            end

          {:exception, msg} ->
            {{:exception, msg}, env, ctx}
        end
    end
  end

  defp eval_for(var_name, [item | rest], body, else_body, env, ctx) do
    case Ctx.check_deadline(ctx) do
      {:exceeded, _} ->
        {{:exception, "TimeoutError: execution exceeded time limit"}, env, ctx}

      :ok ->
        env = Env.smart_put(env, var_name, item)
        ctx = Ctx.record(ctx, :loop_iter, {:for, var_name, item})

        case eval_statements(body, env, ctx) do
          {{:returned, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {{:break}, env, ctx} ->
            {nil, env, ctx}

          {{:suspended} = signal, env, ctx} ->
            {signal, env, ctx}

          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {{:yielded, val, cont}, env, ctx} ->
            {{:yielded, val, cont ++ [{:cont_for, var_name, rest, body, else_body}]}, env, ctx}

          {{:continue}, env, ctx} ->
            eval_for(var_name, rest, body, else_body, env, ctx)

          {_, env, ctx} ->
            eval_for(var_name, rest, body, else_body, env, ctx)
        end
    end
  end

  @spec eval_loop_else([Parser.ast_node()] | nil, Env.t(), Ctx.t()) :: eval_result()
  defp eval_loop_else(nil, env, ctx), do: {nil, env, ctx}
  defp eval_loop_else(else_body, env, ctx), do: eval_statements(else_body, env, ctx)

  @spec bind_loop_var(String.t() | [String.t()], pyvalue(), Env.t()) ::
          Env.t() | {:exception, String.t()}
  defp bind_loop_var(var_name, item, env) when is_binary(var_name) do
    Env.smart_put(env, var_name, item)
  end

  defp bind_loop_var(var_names, item, env) when is_list(var_names) do
    case unpack_for_item(var_names, item) do
      {:ok, bindings} ->
        Enum.reduce(bindings, env, fn {name, val}, env -> Env.smart_put(env, name, val) end)

      {:exception, _} = error ->
        error
    end
  end

  @spec unpack_for_item([String.t()], pyvalue()) ::
          {:ok, [{String.t(), pyvalue()}]} | {:exception, String.t()}
  defp unpack_for_item(names, {:tuple, items}), do: unpack_for_list(names, items)
  defp unpack_for_item(names, items) when is_list(items), do: unpack_for_list(names, items)

  defp unpack_for_item(_names, val),
    do: {:exception, "TypeError: cannot unpack non-iterable #{Helpers.py_type(val)} object"}

  @spec unpack_for_list([String.t()], [pyvalue()]) ::
          {:ok, [{String.t(), pyvalue()}]} | {:exception, String.t()}
  defp unpack_for_list(names, items) do
    if length(names) == length(items) do
      {:ok, Enum.zip(names, items)}
    else
      {:exception,
       "ValueError: not enough values to unpack (expected #{length(names)}, got #{length(items)})"}
    end
  end

  @spec eval_try(
          [Parser.ast_node()],
          [{String.t() | nil, String.t() | nil, [Parser.ast_node()]}],
          [Parser.ast_node()] | nil,
          [Parser.ast_node()] | nil,
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp eval_try(body, handlers, else_body, finally_body, env, ctx) do
    result =
      case eval_statements(body, env, ctx) do
        {{:exception, msg}, body_env, ctx} ->
          ctx = Ctx.record(ctx, :exception, {msg})
          match_handler(handlers, msg, body_env, ctx)

        {val, env, ctx} ->
          if else_body do
            eval_statements(else_body, env, ctx)
          else
            {val, env, ctx}
          end
      end

    run_finally(result, finally_body)
  end

  @spec run_finally(eval_result(), [Parser.ast_node()] | nil) :: eval_result()
  defp run_finally(result, nil), do: result

  defp run_finally({original_signal, env, ctx}, finally_body) do
    case eval_statements(finally_body, env, ctx) do
      {{:exception, _} = new_signal, env, ctx} ->
        {new_signal, env, ctx}

      {{:returned, _} = new_signal, env, ctx} ->
        {new_signal, env, ctx}

      {_val, env, ctx} ->
        {original_signal, env, ctx}
    end
  end

  @spec match_handler(
          [{String.t() | [String.t()] | nil, String.t() | nil, [Parser.ast_node()]}],
          String.t(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp match_handler([], message, env, ctx) do
    {{:exception, message}, env, ctx}
  end

  defp match_handler([{nil, nil, handler_body} | _], message, env, ctx) do
    env = Env.put(env, "__current_exception__", message)
    ctx = %{ctx | exception_instance: nil}
    eval_statements(handler_body, env, ctx)
  end

  defp match_handler([{exc_names, var_name, handler_body} | rest], message, env, ctx) do
    matches =
      case exc_names do
        names when is_list(names) -> Enum.any?(names, &exception_matches?(&1, message))
        name -> exception_matches?(name, message)
      end

    if matches do
      env = Env.put(env, "__current_exception__", message)

      env =
        if var_name do
          exc_value =
            case ctx.exception_instance do
              {:instance, _, _} = inst -> inst
              _ -> synthesize_exception_instance(message)
            end

          Env.put(env, var_name, exc_value)
        else
          env
        end

      ctx = %{ctx | exception_instance: nil}
      eval_statements(handler_body, env, ctx)
    else
      match_handler(rest, message, env, ctx)
    end
  end

  @spec eval_subscript(pyvalue(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp eval_subscript(object, key, env, ctx) do
    case object do
      %{^key => value} ->
        {value, env, ctx}

      list when is_list(list) and is_integer(key) ->
        len = length(list)
        index = if key < 0, do: len + key, else: key

        if index < 0 or index >= len do
          {{:exception, "IndexError: list index out of range"}, env, ctx}
        else
          {Enum.at(list, index), env, ctx}
        end

      {:tuple, items} when is_integer(key) ->
        len = length(items)
        index = if key < 0, do: len + key, else: key

        if index < 0 or index >= len do
          {{:exception, "IndexError: tuple index out of range"}, env, ctx}
        else
          {Enum.at(items, index), env, ctx}
        end

      str when is_binary(str) and is_integer(key) ->
        codepoints = String.codepoints(str)
        len = length(codepoints)
        index = if key < 0, do: len + key, else: key

        if index < 0 or index >= len do
          {{:exception, "IndexError: string index out of range"}, env, ctx}
        else
          {Enum.at(codepoints, index), env, ctx}
        end

      {:range, start, stop, step} when is_integer(key) ->
        len = Builtins.range_length({:range, start, stop, step})
        index = if key < 0, do: len + key, else: key

        if index < 0 or index >= len do
          {{:exception, "IndexError: range object index out of range"}, env, ctx}
        else
          {start + index * step, env, ctx}
        end

      {:instance, _, _} = inst ->
        case call_dunder(inst, "__getitem__", [key], env, ctx) do
          {:ok, result, env, ctx} ->
            {result, env, ctx}

          :not_found ->
            {{:exception, "TypeError: '#{Helpers.py_type(inst)}' object is not subscriptable"},
             env, ctx}
        end

      %{"__defaultdict_factory__" => factory} = dict when is_map(dict) ->
        case call_function(factory, [], %{}, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {default_val, env, ctx, _updated_func} ->
            {default_val, env, ctx}

          {default_val, env, ctx} ->
            {default_val, env, ctx}
        end

      val when is_integer(val) or is_float(val) or is_boolean(val) or val == nil ->
        {{:exception, "TypeError: '#{Helpers.py_type(val)}' object is not subscriptable"}, env,
         ctx}

      {:function, _, _, _, _} ->
        {{:exception, "TypeError: 'function' object is not subscriptable"}, env, ctx}

      _ ->
        {{:exception, "KeyError: #{inspect(key)}"}, env, ctx}
    end
  end

  @spec get_subscript_value(pyvalue(), pyvalue()) :: pyvalue() | {:exception, String.t()}
  defp get_subscript_value(obj, key) when is_map(obj) do
    case Map.fetch(obj, key) do
      {:ok, val} ->
        val

      :error ->
        case Map.fetch(obj, "__defaultdict_factory__") do
          {:ok, {:builtin_type, _, func}} -> func.([])
          {:ok, {:builtin, func}} -> func.([])
          _ -> {:exception, "KeyError: #{inspect(key)}"}
        end
    end
  end

  defp get_subscript_value(obj, key) when is_list(obj) and is_integer(key) do
    len = length(obj)
    idx = if key < 0, do: len + key, else: key

    if idx < 0 or idx >= len do
      {:exception, "IndexError: list index out of range"}
    else
      Enum.at(obj, idx)
    end
  end

  defp get_subscript_value(_, _), do: {:exception, "TypeError: object is not subscriptable"}

  @spec set_subscript_value(pyvalue(), pyvalue(), pyvalue()) :: pyvalue()
  defp set_subscript_value(obj, key, val) when is_map(obj), do: Map.put(obj, key, val)

  defp set_subscript_value(obj, key, val) when is_list(obj) and is_integer(key) do
    idx = if key < 0, do: length(obj) + key, else: key
    List.replace_at(obj, idx, val)
  end

  @spec eval_slice(pyvalue(), pyvalue(), pyvalue(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp eval_slice(object, start, stop, step, env, ctx) do
    case object do
      list when is_list(list) ->
        case py_slice(list, start, stop, step) do
          {:exception, msg} -> {{:exception, msg}, env, ctx}
          result -> {result, env, ctx}
        end

      str when is_binary(str) ->
        codepoints = String.codepoints(str)

        case py_slice(codepoints, start, stop, step) do
          {:exception, msg} -> {{:exception, msg}, env, ctx}
          result -> {Enum.join(result), env, ctx}
        end

      {:range, _, _, _} = r ->
        items = Builtins.range_to_list(r)

        case py_slice(items, start, stop, step) do
          {:exception, msg} -> {{:exception, msg}, env, ctx}
          result -> {result, env, ctx}
        end

      _ ->
        {{:exception, "TypeError: '#{Helpers.py_type(object)}' object is not subscriptable"}, env,
         ctx}
    end
  end

  @spec eval_comp_clauses(
          :list | :dict | :set,
          Parser.ast_node() | {Parser.ast_node(), Parser.ast_node()},
          [
            {:comp_for, String.t() | [String.t()], Parser.ast_node()}
            | {:comp_if, Parser.ast_node()}
          ],
          [pyvalue()] | map() | MapSet.t(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  @dialyzer {:nowarn_function, eval_comp_clauses: 6}
  defp eval_comp_clauses(:list, expr, [], acc, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
      {val, env, ctx} -> {[val | acc], env, ctx}
    end
  end

  defp eval_comp_clauses(:dict, {key_expr, val_expr}, [], acc, env, ctx) do
    case eval(key_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {key, env, ctx} ->
        case eval(val_expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
          {val, env, ctx} -> {Map.put(acc, key, val), env, ctx}
        end
    end
  end

  defp eval_comp_clauses(:set, expr, [], acc, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
      {val, env, ctx} -> {MapSet.put(acc, val), env, ctx}
    end
  end

  defp eval_comp_clauses(kind, expr, [{:comp_if, condition} | rest_clauses], acc, env, ctx) do
    case eval(condition, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {cond_val, env, ctx} ->
        {taken, env, ctx} = eval_truthy(cond_val, env, ctx)

        if taken do
          eval_comp_clauses(kind, expr, rest_clauses, acc, env, ctx)
        else
          {acc, env, ctx}
        end
    end
  end

  defp eval_comp_clauses(
         kind,
         expr,
         [{:comp_for, var_name, iterable_expr} | rest_clauses],
         acc,
         env,
         ctx
       ) do
    case eval(iterable_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {iterable, env, ctx} ->
        case to_iterable(iterable, env, ctx) do
          {:ok, items, env, ctx} ->
            eval_comp_for_loop(kind, expr, var_name, items, rest_clauses, acc, env, ctx)

          {:exception, msg} ->
            {{:exception, msg}, env, ctx}
        end
    end
  end

  @spec eval_comp_for_loop(
          :list | :dict | :set,
          Parser.ast_node() | {Parser.ast_node(), Parser.ast_node()},
          String.t() | [String.t()],
          [pyvalue()],
          [
            {:comp_for, String.t() | [String.t()], Parser.ast_node()}
            | {:comp_if, Parser.ast_node()}
          ],
          [pyvalue()] | map() | MapSet.t(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp eval_comp_for_loop(_kind, _expr, _var_name, [], _rest_clauses, acc, env, ctx) do
    {acc, env, ctx}
  end

  defp eval_comp_for_loop(kind, expr, var_name, [item | rest_items], rest_clauses, acc, env, ctx) do
    case bind_loop_var(var_name, item, env) do
      {:exception, msg} ->
        {{:exception, msg}, env, ctx}

      bound_env ->
        case eval_comp_clauses(kind, expr, rest_clauses, acc, bound_env, ctx) do
          {{:exception, _}, _, _} = error ->
            error

          {new_acc, _inner_env, ctx} ->
            eval_comp_for_loop(kind, expr, var_name, rest_items, rest_clauses, new_acc, env, ctx)
        end
    end
  end

  @spec eval_dict(
          [{Parser.ast_node(), Parser.ast_node()}],
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp eval_dict(entries, env, ctx) do
    Enum.reduce_while(entries, {%{}, env, ctx}, fn {key_expr, val_expr}, {map, env, ctx} ->
      case eval(key_expr, env, ctx) do
        {{:exception, _} = signal, env, ctx} ->
          {:halt, {signal, env, ctx}}

        {key, env, ctx} ->
          if unhashable?(key) do
            {:halt,
             {{:exception, "TypeError: unhashable type: '#{Helpers.py_type(key)}'"}, env, ctx}}
          else
            case eval(val_expr, env, ctx) do
              {{:exception, _} = signal, env, ctx} -> {:halt, {signal, env, ctx}}
              {val, env, ctx} -> {:cont, {Map.put(map, key, val), env, ctx}}
            end
          end
      end
    end)
  end

  @spec unhashable?(pyvalue()) :: boolean()
  defp unhashable?(val) when is_list(val), do: true
  defp unhashable?({:set, _}), do: true
  defp unhashable?(_), do: false

  @spec eval_fstring(
          [{:lit, String.t()} | {:expr, Parser.ast_node()}],
          binary(),
          Env.t(),
          Ctx.t()
        ) ::
          eval_result()
  defp eval_fstring([], acc, env, ctx), do: {acc, env, ctx}

  defp eval_fstring([{:lit, str} | rest], acc, env, ctx) do
    eval_fstring(rest, <<acc::binary, str::binary>>, env, ctx)
  end

  defp eval_fstring([{:expr, expr} | rest], acc, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {val, env, ctx} ->
        {str, env, ctx} = eval_py_str(val, env, ctx)
        eval_fstring(rest, <<acc::binary, str::binary>>, env, ctx)
    end
  end

  @spec eval_raise_exc_class(String.t(), [Parser.ast_node()], Parser.meta(), Env.t(), Ctx.t()) ::
          eval_result()
  defp eval_raise_exc_class(exc_name, args, _meta, env, ctx) do
    case Env.get(env, exc_name) do
      {:ok, {:class, _, _, _} = class} ->
        case eval_list(args, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {values, env, ctx} ->
            msg = format_exc_msg(exc_name, values)

            case call_function(class, values, %{}, env, ctx) do
              {{:exception, _}, env, ctx} ->
                instance = {:instance, class, %{"args" => {:tuple, values}}}
                ctx = %{ctx | exception_instance: instance}
                {{:exception, msg}, env, ctx}

              {instance, env, ctx} ->
                ctx = %{ctx | exception_instance: instance}
                {{:exception, msg}, env, ctx}
            end
        end

      _ ->
        case eval_list(args, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {values, env, ctx} ->
            msg = format_exc_msg(exc_name, values)
            {{:exception, msg}, env, ctx}
        end
    end
  end

  @spec format_exc_msg(String.t(), [pyvalue()]) :: String.t()
  defp format_exc_msg(exc_name, values) do
    case values do
      [] -> exc_name
      [m] when is_binary(m) -> "#{exc_name}: #{m}"
      [m] -> "#{exc_name}: #{Helpers.py_str(m)}"
      _ -> "#{exc_name}: #{values |> Enum.map(&Helpers.py_str/1) |> Enum.join(", ")}"
    end
  end

  @spec synthesize_exception_instance(String.t()) :: pyvalue()
  defp synthesize_exception_instance(message) do
    {class_name, msg} =
      case String.split(message, ": ", parts: 2) do
        [name, m] -> {name, m}
        [name] -> {name, ""}
      end

    {:instance, {:class, class_name, [], %{}}, %{"args" => {:tuple, [msg]}}}
  end

  @spec exception_matches?(String.t(), String.t()) :: boolean()
  defp exception_matches?("Exception", _message), do: true

  defp exception_matches?(exc_name, message) do
    message == exc_name or String.starts_with?(message, exc_name <> ":")
  end

  @spec eval_py_str(pyvalue(), Env.t(), Ctx.t()) :: {String.t(), Env.t(), Ctx.t()}
  defp eval_py_str({:instance, _, _} = inst, env, ctx) do
    case call_dunder(inst, "__str__", [], env, ctx) do
      {:ok, str, env, ctx} when is_binary(str) ->
        {str, env, ctx}

      _ ->
        case call_dunder(inst, "__repr__", [], env, ctx) do
          {:ok, str, env, ctx} when is_binary(str) -> {str, env, ctx}
          _ -> {Helpers.py_str(inst), env, ctx}
        end
    end
  end

  defp eval_py_str(val, env, ctx), do: {Helpers.py_str(val), env, ctx}

  @spec dunder_str_fallback(pyvalue(), String.t(), Env.t(), Ctx.t()) ::
          {:ok, String.t(), Env.t(), Ctx.t()} | :error
  defp dunder_str_fallback({:instance, _, attrs} = inst, "__str__", env, ctx) do
    case call_dunder(inst, "__repr__", [], env, ctx) do
      {:ok, str, env, ctx} when is_binary(str) ->
        {:ok, str, env, ctx}

      _ ->
        case Map.get(attrs, "args") do
          {:tuple, [single]} when is_binary(single) ->
            {:ok, single, env, ctx}

          {:tuple, items} when is_list(items) and items != [] ->
            {:ok, items |> Enum.map(&Helpers.py_str/1) |> Enum.join(", "), env, ctx}

          _ ->
            {:ok, Helpers.py_str(inst), env, ctx}
        end
    end
  end

  defp dunder_str_fallback({:instance, _, _} = inst, "__repr__", env, ctx) do
    {:ok, Helpers.py_str(inst), env, ctx}
  end

  defp dunder_str_fallback(inst, "__bool__", env, ctx) do
    case call_dunder(inst, "__len__", [], env, ctx) do
      {:ok, len, env, ctx} when is_integer(len) ->
        {:ok, len > 0, env, ctx}

      _ ->
        {:ok, true, env, ctx}
    end
  end

  defp dunder_str_fallback(_, _, _, _), do: :error

  @spec to_iterable(pyvalue(), Env.t(), Ctx.t()) ::
          {:ok, [pyvalue()], Env.t(), Ctx.t()} | {:exception, String.t()}
  defp to_iterable(list, env, ctx) when is_list(list), do: {:ok, list, env, ctx}
  defp to_iterable(str, env, ctx) when is_binary(str), do: {:ok, String.codepoints(str), env, ctx}

  defp to_iterable(map, env, ctx) when is_map(map),
    do: {:ok, map |> Builtins.visible_dict() |> Map.keys(), env, ctx}

  defp to_iterable({:tuple, elements}, env, ctx), do: {:ok, elements, env, ctx}
  defp to_iterable({:set, s}, env, ctx), do: {:ok, MapSet.to_list(s), env, ctx}

  defp to_iterable({:range, _, _, _} = r, env, ctx),
    do: {:ok, Builtins.range_to_list(r), env, ctx}

  defp to_iterable({:generator, items}, env, ctx), do: {:ok, items, env, ctx}
  defp to_iterable({:generator_error, items, _msg}, env, ctx), do: {:ok, items, env, ctx}

  defp to_iterable({:iterator, id}, env, ctx) do
    {:ok, Ctx.iter_items(ctx, id), env, ctx}
  end

  defp to_iterable({:instance, _, _} = inst, env, ctx) do
    case call_dunder(inst, "__iter__", [], env, ctx) do
      {:ok, result, env, ctx} ->
        case result do
          {:exception, _} = signal ->
            signal

          {:instance, _, _} = iter ->
            drain_iterator(iter, [], env, ctx)

          other ->
            to_iterable(other, env, ctx)
        end

      :not_found ->
        {:exception, "TypeError: '#{Helpers.py_type(inst)}' object is not iterable"}
    end
  end

  defp to_iterable(val, _env, _ctx) do
    {:exception, "TypeError: '#{Helpers.py_type(val)}' object is not iterable"}
  end

  @spec drain_iterator(pyvalue(), [pyvalue()], Env.t(), Ctx.t()) ::
          {:ok, [pyvalue()], Env.t(), Ctx.t()} | {:exception, String.t()}
  defp drain_iterator(iter, acc, env, ctx) do
    case call_dunder_mut(iter, "__next__", [], env, ctx) do
      {:ok, new_iter, {:exception, "StopIteration" <> _}, env, ctx} ->
        _ = new_iter
        {:ok, Enum.reverse(acc), env, ctx}

      {:ok, _new_iter, {:exception, _} = signal, _env, _ctx} ->
        signal

      {:ok, new_iter, value, env, ctx} ->
        drain_iterator(new_iter, [value | acc], env, ctx)

      :not_found ->
        {:exception, "TypeError: '#{Helpers.py_type(iter)}' object is not an iterator"}
    end
  end

  @spec unpack_iterable_safe([pyvalue()], [String.t() | {:starred, String.t()}]) ::
          {:ok, [{String.t(), pyvalue()}]} | {:exception, String.t()}
  defp unpack_iterable_safe([single], names) do
    case single do
      list when is_list(list) -> check_unpack_length(list, names)
      {:tuple, items} -> check_unpack_length(items, names)
      {:range, _, _, _} = r -> check_unpack_length(Builtins.range_to_list(r), names)
      str when is_binary(str) -> check_unpack_length(String.codepoints(str), names)
      val -> {:exception, "TypeError: cannot unpack non-iterable #{Helpers.py_type(val)} object"}
    end
  end

  defp unpack_iterable_safe(values, names) do
    check_unpack_length(values, names)
  end

  @spec check_unpack_length([pyvalue()], [String.t() | {:starred, String.t()}]) ::
          {:ok, [{String.t(), pyvalue()}]} | {:exception, String.t()}
  defp check_unpack_length(items, names) do
    has_star = Enum.any?(names, &match?({:starred, _}, &1))

    if has_star do
      unpack_starred(items, names)
    else
      if length(items) == length(names) do
        {:ok, Enum.zip(names, items)}
      else
        {:exception,
         "ValueError: not enough values to unpack (expected #{length(names)}, got #{length(items)})"}
      end
    end
  end

  @spec unpack_starred([pyvalue()], [String.t() | {:starred, String.t()}]) ::
          {:ok, [{String.t(), pyvalue()}]} | {:exception, String.t()}
  defp unpack_starred(items, names) do
    star_idx = Enum.find_index(names, &match?({:starred, _}, &1))
    fixed_count = length(names) - 1
    item_count = length(items)

    if item_count < fixed_count do
      {:exception,
       "ValueError: not enough values to unpack (expected at least #{fixed_count}, got #{item_count})"}
    else
      before_names = Enum.take(names, star_idx)
      {:starred, star_name} = Enum.at(names, star_idx)
      after_names = Enum.drop(names, star_idx + 1)
      after_count = length(after_names)

      before_items = Enum.take(items, star_idx)
      after_items = if after_count > 0, do: Enum.take(items, -after_count), else: []

      star_items =
        items
        |> Enum.drop(star_idx)
        |> Enum.take(item_count - star_idx - after_count)

      pairs =
        Enum.zip(before_names, before_items) ++
          [{star_name, star_items}] ++
          Enum.zip(after_names, after_items)

      {:ok, pairs}
    end
  end

  @spec register_route(Parser.ast_node(), String.t(), String.t(), pyvalue(), Env.t()) :: Env.t()
  defp register_route(decorator_expr, method, path, handler, env) do
    case Helpers.root_var_name(decorator_expr) do
      {:ok, var_name} ->
        case Env.get(env, var_name) do
          {:ok, %{"__routes__" => routes} = app} ->
            new_app = Map.put(app, "__routes__", routes ++ [{{method, path}, handler}])
            Env.put(env, var_name, new_app)

          _ ->
            env
        end

      :error ->
        env
    end
  end

  @doc false
  @spec eval_truthy(pyvalue(), Env.t(), Ctx.t()) :: {boolean(), Env.t(), Ctx.t()}
  def eval_truthy({:instance, _, _} = inst, env, ctx) do
    case call_dunder(inst, "__bool__", [], env, ctx) do
      {:ok, result, env, ctx} ->
        {Helpers.truthy?(result), env, ctx}

      :not_found ->
        case call_dunder(inst, "__len__", [], env, ctx) do
          {:ok, result, env, ctx} when is_integer(result) -> {result != 0, env, ctx}
          {:ok, _, env, ctx} -> {true, env, ctx}
          :not_found -> {true, env, ctx}
        end
    end
  end

  def eval_truthy(val, env, ctx), do: {Helpers.truthy?(val), env, ctx}

  @spec eval_binop(atom(), pyvalue(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp eval_binop(op, {:instance, _, _} = l, r, env, ctx) do
    case dunder_for_op(op) do
      nil ->
        binop_result(safe_binop(op, l, r), env, ctx)

      dunder ->
        case call_dunder(l, dunder, [r], env, ctx) do
          {:ok, result, env, ctx} ->
            {result, env, ctx}

          :not_found ->
            binop_result(safe_binop(op, l, r), env, ctx)
        end
    end
  end

  defp eval_binop(:in, l, {:instance, _, _} = r, env, ctx) do
    case call_dunder(r, "__contains__", [l], env, ctx) do
      {:ok, result, env, ctx} -> {Helpers.truthy?(result), env, ctx}
      :not_found -> binop_result(safe_binop(:in, l, r), env, ctx)
    end
  end

  defp eval_binop(:not_in, l, {:instance, _, _} = r, env, ctx) do
    case call_dunder(r, "__contains__", [l], env, ctx) do
      {:ok, result, env, ctx} -> {!Helpers.truthy?(result), env, ctx}
      :not_found -> binop_result(safe_binop(:not_in, l, r), env, ctx)
    end
  end

  defp eval_binop(op, l, {:instance, _, _} = r, env, ctx) do
    case rdunder_for_op(op) do
      nil ->
        binop_result(safe_binop(op, l, r), env, ctx)

      rdunder ->
        case call_dunder(r, rdunder, [l], env, ctx) do
          {:ok, result, env, ctx} ->
            {result, env, ctx}

          :not_found ->
            binop_result(safe_binop(op, l, r), env, ctx)
        end
    end
  end

  defp eval_binop(op, l, r, env, ctx) do
    binop_result(safe_binop(op, l, r), env, ctx)
  end

  @spec binop_result(pyvalue() | {:exception, String.t()}, Env.t(), Ctx.t()) :: eval_result()
  defp binop_result({:exception, msg}, env, ctx), do: {{:exception, msg}, env, ctx}
  defp binop_result(value, env, ctx), do: {value, env, ctx}

  @spec dunder_for_op(atom()) :: String.t() | nil
  defp dunder_for_op(:plus), do: "__add__"
  defp dunder_for_op(:minus), do: "__sub__"
  defp dunder_for_op(:star), do: "__mul__"
  defp dunder_for_op(:slash), do: "__truediv__"
  defp dunder_for_op(:floor_div), do: "__floordiv__"
  defp dunder_for_op(:percent), do: "__mod__"
  defp dunder_for_op(:double_star), do: "__pow__"
  defp dunder_for_op(:eq), do: "__eq__"
  defp dunder_for_op(:neq), do: "__ne__"
  defp dunder_for_op(:lt), do: "__lt__"
  defp dunder_for_op(:gt), do: "__gt__"
  defp dunder_for_op(:lte), do: "__le__"
  defp dunder_for_op(:gte), do: "__ge__"
  defp dunder_for_op(:amp), do: "__and__"
  defp dunder_for_op(:pipe), do: "__or__"
  defp dunder_for_op(:caret), do: "__xor__"
  defp dunder_for_op(:lshift), do: "__lshift__"
  defp dunder_for_op(:rshift), do: "__rshift__"
  defp dunder_for_op(:in), do: nil
  defp dunder_for_op(:not_in), do: nil
  defp dunder_for_op(:is), do: nil
  defp dunder_for_op(:is_not), do: nil
  defp dunder_for_op(:and), do: nil
  defp dunder_for_op(:or), do: nil
  defp dunder_for_op(_), do: nil

  @spec rdunder_for_op(atom()) :: String.t() | nil
  defp rdunder_for_op(:plus), do: "__radd__"
  defp rdunder_for_op(:minus), do: "__rsub__"
  defp rdunder_for_op(:star), do: "__rmul__"
  defp rdunder_for_op(:slash), do: "__rtruediv__"
  defp rdunder_for_op(:floor_div), do: "__rfloordiv__"
  defp rdunder_for_op(:percent), do: "__rmod__"
  defp rdunder_for_op(:double_star), do: "__rpow__"
  defp rdunder_for_op(:eq), do: "__eq__"
  defp rdunder_for_op(:neq), do: "__ne__"
  defp rdunder_for_op(:lt), do: "__gt__"
  defp rdunder_for_op(:gt), do: "__lt__"
  defp rdunder_for_op(:lte), do: "__ge__"
  defp rdunder_for_op(:gte), do: "__le__"
  defp rdunder_for_op(_), do: nil

  @spec safe_binop(atom(), pyvalue(), pyvalue()) :: pyvalue() | {:exception, String.t()}
  defp safe_binop(op, l, r) when is_boolean(l) or is_boolean(r) do
    case op do
      op
      when op in [
             :plus,
             :minus,
             :star,
             :slash,
             :floor_div,
             :percent,
             :double_star,
             :amp,
             :pipe,
             :caret,
             :lshift,
             :rshift,
             :eq,
             :neq,
             :lt,
             :gt,
             :lte,
             :gte
           ] ->
        safe_binop(op, Helpers.bool_to_int(l), Helpers.bool_to_int(r))

      _ ->
        safe_binop_dispatch(op, l, r)
    end
  end

  defp safe_binop(op, l, r), do: safe_binop_dispatch(op, l, r)

  defp safe_binop_dispatch(:plus, l, r) when is_binary(l) and is_binary(r), do: l <> r
  defp safe_binop_dispatch(:plus, l, r) when is_list(l) and is_list(r), do: l ++ r
  defp safe_binop_dispatch(:plus, {:tuple, l}, {:tuple, r}), do: {:tuple, l ++ r}
  defp safe_binop_dispatch(:plus, l, r) when is_number(l) and is_number(r), do: l + r

  defp safe_binop_dispatch(:plus, l, r),
    do:
      {:exception,
       "TypeError: unsupported operand type(s) for +: '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}

  defp safe_binop_dispatch(:minus, l, r) when is_number(l) and is_number(r), do: l - r

  defp safe_binop_dispatch(:minus, {:set, a}, {:set, b}),
    do: {:set, MapSet.difference(a, b)}

  defp safe_binop_dispatch(:minus, l, r),
    do:
      {:exception,
       "TypeError: unsupported operand type(s) for -: '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}

  defp safe_binop_dispatch(:star, l, r) when is_binary(l) and is_integer(r),
    do: String.duplicate(l, max(r, 0))

  defp safe_binop_dispatch(:star, l, r) when is_integer(l) and is_binary(r),
    do: String.duplicate(r, max(l, 0))

  defp safe_binop_dispatch(:star, l, r) when is_integer(l) and is_list(r),
    do: Helpers.repeat_list(r, l)

  defp safe_binop_dispatch(:star, l, r) when is_list(l) and is_integer(r),
    do: Helpers.repeat_list(l, r)

  defp safe_binop_dispatch(:star, {:tuple, items}, r) when is_integer(r),
    do: {:tuple, Helpers.repeat_list(items, r)}

  defp safe_binop_dispatch(:star, l, {:tuple, items}) when is_integer(l),
    do: {:tuple, Helpers.repeat_list(items, l)}

  defp safe_binop_dispatch(:star, l, r) when is_number(l) and is_number(r), do: l * r

  defp safe_binop_dispatch(:star, l, r),
    do:
      {:exception,
       "TypeError: unsupported operand type(s) for *: '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}

  defp safe_binop_dispatch(:slash, _l, r) when r == 0 or r == 0.0,
    do: {:exception, "ZeroDivisionError: division by zero"}

  defp safe_binop_dispatch(:slash, l, r) when is_number(l) and is_number(r), do: l / r

  defp safe_binop_dispatch(:slash, l, r),
    do:
      {:exception,
       "TypeError: unsupported operand type(s) for /: '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}

  defp safe_binop_dispatch(:floor_div, _l, r) when r == 0 or r == 0.0,
    do: {:exception, "ZeroDivisionError: integer division or modulo by zero"}

  defp safe_binop_dispatch(:floor_div, l, r) when is_integer(l) and is_integer(r),
    do: Integer.floor_div(l, r)

  defp safe_binop_dispatch(:floor_div, l, r) when is_number(l) and is_number(r),
    do: Float.floor(l / r)

  defp safe_binop_dispatch(:floor_div, l, r),
    do:
      {:exception,
       "TypeError: unsupported operand type(s) for //: '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}

  defp safe_binop_dispatch(:percent, l, r) when is_binary(l), do: Format.string_format(l, r)

  defp safe_binop_dispatch(:percent, _l, r) when r == 0 or r == 0.0,
    do: {:exception, "ZeroDivisionError: integer division or modulo by zero"}

  defp safe_binop_dispatch(:percent, l, r) when is_integer(l) and is_integer(r),
    do: Integer.mod(l, r)

  defp safe_binop_dispatch(:percent, l, r) when is_number(l) and is_number(r),
    do: l - Float.floor(l / r) * r

  defp safe_binop_dispatch(:percent, l, r),
    do:
      {:exception,
       "TypeError: unsupported operand type(s) for %: '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}

  defp safe_binop_dispatch(:double_star, l, r) when is_number(l) and is_number(r) do
    cond do
      l == 0 and r < 0 ->
        {:exception, "ZeroDivisionError: 0 cannot be raised to a negative power"}

      is_integer(l) and is_integer(r) and r >= 0 ->
        Helpers.int_pow(l, r)

      is_float(l) or is_float(r) ->
        try do
          :math.pow(l, r)
        rescue
          ArithmeticError ->
            {:exception, "ValueError: math domain error"}
        end

      true ->
        try do
          :math.pow(l, r) |> Helpers.maybe_intify()
        rescue
          ArithmeticError ->
            {:exception, "ValueError: math domain error"}
        end
    end
  end

  defp safe_binop_dispatch(:double_star, l, r),
    do:
      {:exception,
       "TypeError: unsupported operand type(s) for **: '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}

  defp safe_binop_dispatch(:eq, l, r), do: l == r
  defp safe_binop_dispatch(:neq, l, r), do: l != r
  defp safe_binop_dispatch(:lt, l, r), do: ordering_compare(:lt, l, r)
  defp safe_binop_dispatch(:gt, l, r), do: ordering_compare(:gt, l, r)
  defp safe_binop_dispatch(:lte, l, r), do: ordering_compare(:lte, l, r)
  defp safe_binop_dispatch(:gte, l, r), do: ordering_compare(:gte, l, r)
  defp safe_binop_dispatch(:in, l, {:tuple, items}), do: l in items
  defp safe_binop_dispatch(:in, l, r) when is_list(r), do: l in r

  defp safe_binop_dispatch(:in, l, r) when is_binary(l) and is_binary(r),
    do: String.contains?(r, l)

  defp safe_binop_dispatch(:in, l, r) when is_map(r),
    do: Map.has_key?(Builtins.visible_dict(r), l)

  defp safe_binop_dispatch(:in, l, {:set, s}), do: MapSet.member?(s, l)

  defp safe_binop_dispatch(:in, l, {:range, start, stop, step}) when is_integer(l) do
    cond do
      step > 0 and l >= start and l < stop -> rem(l - start, step) == 0
      step < 0 and l <= start and l > stop -> rem(start - l, -step) == 0
      true -> false
    end
  end

  defp safe_binop_dispatch(:in, _l, {:range, _, _, _}), do: false

  defp safe_binop_dispatch(:in, _l, r),
    do: {:exception, "TypeError: argument of type '#{Helpers.py_type(r)}' is not iterable"}

  defp safe_binop_dispatch(:is, l, r), do: l === r
  defp safe_binop_dispatch(:is_not, l, r), do: l !== r

  defp safe_binop_dispatch(:not_in, l, r) do
    case safe_binop(:in, l, r) do
      {:exception, _} = exc -> exc
      val -> not val
    end
  end

  defp safe_binop_dispatch(:amp, {:set, a}, {:set, b}), do: {:set, MapSet.intersection(a, b)}

  defp safe_binop_dispatch(:amp, l, r) when is_integer(l) and is_integer(r), do: band(l, r)

  defp safe_binop_dispatch(:amp, l, r),
    do:
      {:exception,
       "TypeError: unsupported operand type(s) for &: '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}

  defp safe_binop_dispatch(:pipe, {:set, a}, {:set, b}), do: {:set, MapSet.union(a, b)}

  defp safe_binop_dispatch(:pipe, l, r) when is_integer(l) and is_integer(r), do: bor(l, r)

  defp safe_binop_dispatch(:pipe, l, r),
    do:
      {:exception,
       "TypeError: unsupported operand type(s) for |: '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}

  defp safe_binop_dispatch(:caret, {:set, a}, {:set, b}),
    do: {:set, MapSet.symmetric_difference(a, b)}

  defp safe_binop_dispatch(:caret, l, r) when is_integer(l) and is_integer(r), do: bxor(l, r)

  defp safe_binop_dispatch(:caret, l, r),
    do:
      {:exception,
       "TypeError: unsupported operand type(s) for ^: '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}

  defp safe_binop_dispatch(:lshift, l, r) when is_integer(l) and is_integer(r), do: bsl(l, r)

  defp safe_binop_dispatch(:lshift, l, r),
    do:
      {:exception,
       "TypeError: unsupported operand type(s) for <<: '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}

  defp safe_binop_dispatch(:rshift, l, r) when is_integer(l) and is_integer(r), do: bsr(l, r)

  defp safe_binop_dispatch(:rshift, l, r),
    do:
      {:exception,
       "TypeError: unsupported operand type(s) for >>: '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}

  @spec ordering_compare(atom(), pyvalue(), pyvalue()) :: boolean() | {:exception, String.t()}
  defp ordering_compare(op, l, r) when is_number(l) and is_number(r), do: ord_cmp(op, l, r)
  defp ordering_compare(op, l, r) when is_binary(l) and is_binary(r), do: ord_cmp(op, l, r)
  defp ordering_compare(op, l, r) when is_list(l) and is_list(r), do: ord_cmp(op, l, r)
  defp ordering_compare(op, {:tuple, a}, {:tuple, b}), do: ord_cmp(op, a, b)

  defp ordering_compare(op, l, r) when is_boolean(l) and is_number(r),
    do: ordering_compare(op, bool_to_int(l), r)

  defp ordering_compare(op, l, r) when is_number(l) and is_boolean(r),
    do: ordering_compare(op, l, bool_to_int(r))

  defp ordering_compare(_op, l, r) do
    {:exception,
     "TypeError: '<' not supported between instances of '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}
  end

  @spec ord_cmp(atom(), term(), term()) :: boolean()
  defp ord_cmp(:lt, l, r), do: l < r
  defp ord_cmp(:gt, l, r), do: l > r
  defp ord_cmp(:lte, l, r), do: l <= r
  defp ord_cmp(:gte, l, r), do: l >= r

  @spec bool_to_int(boolean()) :: 0 | 1
  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  @spec eval_chained_compare([atom()], [Parser.ast_node()], pyvalue() | nil, Env.t(), Ctx.t()) ::
          {pyvalue(), Env.t(), Ctx.t()}
  defp eval_chained_compare([], _, _prev_val, env, ctx) do
    {true, env, ctx}
  end

  defp eval_chained_compare([op | rest_ops], [operand | rest_operands], prev_val, env, ctx) do
    {left_val, env, ctx} =
      case prev_val do
        nil -> eval(operand, env, ctx)
        val -> {val, env, ctx}
      end

    case left_val do
      {:exception, _} = signal ->
        {signal, env, ctx}

      _ ->
        [right_node | _] = rest_operands

        case eval(right_node, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {right_val, env, ctx} ->
            case eval_binop(op, left_val, right_val, env, ctx) do
              {{:exception, _} = signal, env, ctx} ->
                {signal, env, ctx}

              {false, env, ctx} ->
                {false, env, ctx}

              {_, env, ctx} ->
                eval_chained_compare(rest_ops, rest_operands, right_val, env, ctx)
            end
        end
    end
  end

  @spec eval_optional(Parser.ast_node() | nil, Env.t(), Ctx.t()) ::
          {pyvalue(), Env.t(), Ctx.t()}
  defp eval_optional(nil, env, ctx), do: {nil, env, ctx}
  defp eval_optional(expr, env, ctx), do: eval(expr, env, ctx)

  @spec py_slice(list(), integer() | nil, integer() | nil, integer() | nil) ::
          list() | {:exception, String.t()}
  defp py_slice(_list, _start, _stop, 0),
    do: {:exception, "ValueError: slice step cannot be zero"}

  defp py_slice(list, start, stop, step) do
    len = length(list)
    step = step || 1

    {start, stop} = normalize_slice_bounds(start, stop, step, len)

    cond do
      step == 1 and start >= 0 and stop >= start ->
        Enum.slice(list, start, stop - start)

      step > 0 ->
        list
        |> Enum.with_index()
        |> Enum.filter(fn {_, i} -> i >= start and i < stop and rem(i - start, step) == 0 end)
        |> Enum.map(&elem(&1, 0))

      true ->
        list
        |> Enum.with_index()
        |> Enum.filter(fn {_, i} -> i <= start and i > stop and rem(start - i, -step) == 0 end)
        |> Enum.sort_by(fn {_, i} -> -i end)
        |> Enum.map(&elem(&1, 0))
    end
  end

  @spec normalize_slice_bounds(integer() | nil, integer() | nil, integer(), non_neg_integer()) ::
          {integer(), integer()}
  defp normalize_slice_bounds(start, stop, step, len) do
    start =
      cond do
        start == nil and step > 0 -> 0
        start == nil -> len - 1
        start < 0 -> max(start + len, 0)
        true -> min(start, len)
      end

    stop =
      cond do
        stop == nil and step > 0 -> len
        stop == nil -> -1
        stop < 0 -> max(stop + len, 0)
        true -> min(stop, len)
      end

    {start, stop}
  end

  @spec setattr(Parser.ast_node(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp setattr({:getattr, _, [{:var, _, [var_name]}, attr]}, value, env, ctx) do
    case Env.get(env, var_name) do
      {:ok, {:instance, class, attrs}} ->
        updated = {:instance, class, Map.put(attrs, attr, value)}
        {nil, Env.put_at_source(env, var_name, updated), ctx}

      {:ok, {:class, name, bases, class_attrs}} ->
        updated = {:class, name, bases, Map.put(class_attrs, attr, value)}
        {nil, Env.put_at_source(env, var_name, updated), ctx}

      {:ok, other} when is_map(other) ->
        updated = Map.put(other, attr, value)
        {nil, Env.put_at_source(env, var_name, updated), ctx}

      _ ->
        {{:exception, "AttributeError: cannot set attribute '#{attr}'"}, env, ctx}
    end
  end

  defp setattr({:getattr, _, [inner_target, attr]}, value, env, ctx) do
    case eval(inner_target, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {{:instance, class, attrs}, env, ctx} ->
        updated = {:instance, class, Map.put(attrs, attr, value)}
        write_back_target(inner_target, updated, env, ctx)

      _ ->
        {{:exception, "AttributeError: cannot set attribute '#{attr}'"}, env, ctx}
    end
  end

  defp setattr(_target, _value, env, ctx) do
    {{:exception, "SyntaxError: cannot assign to attribute"}, env, ctx}
  end

  @spec setattr_nested(Parser.ast_node(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp setattr_nested({:getattr, meta, [obj_expr, attr]}, value, env, ctx) do
    setattr({:getattr, meta, [obj_expr, attr]}, value, env, ctx)
  end

  @spec eval_sort([pyvalue()], pyvalue() | nil, boolean(), Env.t(), Ctx.t()) :: call_result()
  defp eval_sort(items, key_fn, reverse, env, ctx) do
    has_instances? = Enum.any?(items, &match?({:instance, _, _}, &1))

    sorted =
      case key_fn do
        nil when has_instances? ->
          sort_with_lt(items, env, ctx)

        nil ->
          {:ok, Enum.sort(items), env, ctx}

        _ ->
          sort_with_key(items, key_fn, env, ctx)
      end

    case sorted do
      {:ok, sorted_items, env, ctx} ->
        result = if reverse, do: Enum.reverse(sorted_items), else: sorted_items
        {result, env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}
    end
  end

  @spec eval_minmax([pyvalue()], pyvalue(), :min | :max, Env.t(), Ctx.t()) ::
          {pyvalue(), Env.t(), Ctx.t()}
  defp eval_minmax(items, key_fn, op, env, ctx) do
    keys_result =
      Enum.reduce_while(items, {:ok, [], env, ctx}, fn item, {:ok, acc, env, ctx} ->
        case call_function(key_fn, [item], %{}, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {:halt, {signal, env, ctx}}

          {key_val, env, ctx, _updated_func} ->
            {:cont, {:ok, [{item, key_val} | acc], env, ctx}}

          {key_val, env, ctx} ->
            {:cont, {:ok, [{item, key_val} | acc], env, ctx}}
        end
      end)

    case keys_result do
      {:ok, pairs, env, ctx} ->
        selector = if op == :min, do: &Enum.min_by/2, else: &Enum.max_by/2
        {winner, _key} = selector.(Enum.reverse(pairs), &elem(&1, 1))
        {winner, env, ctx}

      {signal, env, ctx} ->
        {signal, env, ctx}
    end
  end

  @spec sort_with_lt([pyvalue()], Env.t(), Ctx.t()) :: {atom(), [pyvalue()], Env.t(), Ctx.t()}
  defp sort_with_lt(items, env, ctx) do
    indexed = Enum.with_index(items)

    comparisons =
      for {a, i} <- indexed, {b, j} <- indexed, i < j, reduce: %{} do
        acc ->
          {result, _env, _ctx} = eval_binop(:lt, a, b, env, ctx)

          cond do
            result == true -> Map.put(acc, {i, j}, :lt)
            result == false -> Map.put(acc, {i, j}, :gte)
            true -> acc
          end
      end

    sorted_indexed =
      Enum.sort(indexed, fn {_a, i}, {_b, j} ->
        if i < j do
          Map.get(comparisons, {i, j}) == :lt
        else
          Map.get(comparisons, {j, i}) != :lt
        end
      end)

    {:ok, Enum.map(sorted_indexed, &elem(&1, 0)), env, ctx}
  end

  @spec sort_with_key([pyvalue()], pyvalue(), Env.t(), Ctx.t()) ::
          {:ok, [pyvalue()], Env.t(), Ctx.t()} | eval_result()
  defp sort_with_key(items, key_fn, env, ctx) do
    keys_result =
      Enum.reduce_while(items, {:ok, [], env, ctx}, fn item, {:ok, acc, env, ctx} ->
        case call_function(key_fn, [item], %{}, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {:halt, {signal, env, ctx}}

          {key_val, env, ctx, _updated_func} ->
            {:cont, {:ok, [{item, key_val} | acc], env, ctx}}

          {key_val, env, ctx} ->
            {:cont, {:ok, [{item, key_val} | acc], env, ctx}}
        end
      end)

    case keys_result do
      {:ok, pairs, env, ctx} ->
        sorted = pairs |> Enum.reverse() |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
        {:ok, sorted, env, ctx}

      {signal, env, ctx} ->
        {signal, env, ctx}
    end
  end

  @spec mutate_target(Parser.ast_node(), pyvalue(), Env.t(), Ctx.t()) :: Env.t()
  defp mutate_target({:getattr, _, [{:var, _, [var_name]}, _method]}, new_object, env, _ctx) do
    Env.smart_put(env, var_name, new_object)
  end

  defp mutate_target(
         {:getattr, _, [{:getattr, _, _} = inner_target, _method]},
         new_object,
         env,
         ctx
       ) do
    case setattr(inner_target, new_object, env, ctx) do
      {_, env, _} -> env
    end
  end

  defp mutate_target({:getattr, _, [{:call, _, _}, _method]}, new_object, env, _ctx) do
    Env.smart_put(env, "self", new_object)
  end

  defp mutate_target(
         {:getattr, _, [{:subscript, _, [container_expr, key_expr]}, _method]},
         new_object,
         env,
         ctx
       ) do
    {container, env, ctx} = eval(container_expr, env, ctx)
    {key, env, _ctx} = eval(key_expr, env, ctx)
    new_container = set_subscript_value(container, key, new_object)
    mutate_target(container_expr, new_container, env, ctx)
  end

  defp mutate_target({:var, _, [var_name]}, new_object, env, _ctx) do
    Env.smart_put(env, var_name, new_object)
  end

  defp mutate_target({:subscript, _, [expr, _index]}, new_object, env, ctx) do
    mutate_target(expr, new_object, env, ctx)
  end

  defp mutate_target(_, _new_object, env, _ctx), do: env

  @spec write_back_target(Parser.ast_node(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp write_back_target({:var, _, [name]}, value, env, ctx) do
    {nil, Env.smart_put(env, name, value), ctx}
  end

  defp write_back_target({:getattr, _, [{:var, _, [var_name]}, attr]}, value, env, ctx) do
    case Env.get(env, var_name) do
      {:ok, {:instance, class, attrs}} ->
        updated = {:instance, class, Map.put(attrs, attr, value)}
        {nil, Env.smart_put(env, var_name, updated), ctx}

      _ ->
        {{:exception, "AttributeError: cannot write back to nested attribute"}, env, ctx}
    end
  end

  defp write_back_target(_, _, env, ctx) do
    {{:exception, "SyntaxError: cannot assign to nested attribute"}, env, ctx}
  end

  @spec get_mutated_instance(Env.t(), pyvalue()) :: pyvalue()
  defp get_mutated_instance(env, {:instance, _, _} = original) do
    case Env.get(env, "self") do
      {:ok, {:instance, _, _} = updated} -> updated
      _ -> original
    end
  end

  @spec call_method(
          pyvalue(),
          pyvalue(),
          [pyvalue()],
          %{optional(String.t()) => pyvalue()},
          Env.t(),
          Ctx.t()
        ) ::
          call_result()
  defp call_method(instance, {:function, _, _, _, _} = func, args, kwargs, env, ctx) do
    method_args = [instance | args]

    case call_function(func, method_args, kwargs, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {result, env, ctx, _updated} ->
        updated_instance = get_mutated_instance(env, instance)
        env = rebind_instance(env, instance, updated_instance)
        {result, env, ctx}

      {result, env, ctx} ->
        updated_instance = get_mutated_instance(env, instance)
        env = rebind_instance(env, instance, updated_instance)
        {result, env, ctx}
    end
  end

  @spec rebind_instance(Env.t(), pyvalue(), pyvalue()) :: Env.t()
  defp rebind_instance(env, _old, new) do
    case Env.get(env, "self") do
      {:ok, {:instance, _, _}} -> Env.smart_put(env, "self", new)
      _ -> env
    end
  end

  @spec maybe_update_instance_var(Env.t(), String.t()) :: Env.t()
  defp maybe_update_instance_var(env, var_name) do
    case Env.get(env, var_name) do
      {:ok, {:instance, _, _}} ->
        case Env.get(env, "self") do
          {:ok, {:instance, _, _} = updated_self} ->
            Env.smart_put(env, var_name, updated_self)

          _ ->
            env
        end

      _ ->
        env
    end
  end

  @spec eval_instance_next(
          pyvalue(),
          non_neg_integer(),
          :no_default | {:default, pyvalue()},
          Env.t(),
          Ctx.t()
        ) ::
          eval_result()
  defp eval_instance_next(inst, id, default_opt, env, ctx) do
    case call_dunder_mut(inst, "__next__", [], env, ctx) do
      {:ok, _new_inst, {:exception, "StopIteration" <> _}, env, ctx} ->
        ctx = Ctx.delete_iterator(ctx, id)

        case default_opt do
          {:default, default} -> {default, env, ctx}
          :no_default -> {{:exception, "StopIteration"}, env, ctx}
        end

      {:ok, _new_inst, {:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {:ok, new_inst, value, env, ctx} ->
        ctx = Ctx.update_instance_iterator(ctx, id, new_inst)
        {value, env, ctx}

      :not_found ->
        {{:exception, "TypeError: object has no __next__"}, env, ctx}
    end
  end

  @spec eval_print_call([pyvalue()], Env.t(), Ctx.t()) :: eval_result()
  defp eval_print_call(args, env, ctx) do
    {strs, env, ctx} =
      Enum.reduce(args, {[], env, ctx}, fn arg, {acc, env, ctx} ->
        {str, env, ctx} = eval_py_str(arg, env, ctx)
        {[str | acc], env, ctx}
      end)

    output = strs |> Enum.reverse() |> Enum.join(" ")
    ctx = Ctx.record(ctx, :output, output)
    {nil, env, ctx}
  end

  @spec eval_super(Env.t(), Ctx.t()) :: eval_result()
  defp eval_super(env, ctx) do
    case Env.get(env, "self") do
      {:ok, {:instance, _, _} = instance} ->
        case Env.get(env, "__class__") do
          {:ok, {:class, _, bases, _}} when bases != [] ->
            {{:super_proxy, instance, bases}, env, ctx}

          {:ok, {:class, _, _, _}} ->
            {{:exception, "TypeError: super(): no parent class"}, env, ctx}

          _ ->
            {{:exception, "RuntimeError: super(): __class__ is not set"}, env, ctx}
        end

      _ ->
        {{:exception, "RuntimeError: super(): self is not bound"}, env, ctx}
    end
  end

  @spec call_dunder(pyvalue(), String.t(), [pyvalue()], Env.t(), Ctx.t()) ::
          {:ok, pyvalue(), Env.t(), Ctx.t()} | :not_found
  defp call_dunder(instance, method, args, env, ctx) do
    case call_dunder_mut(instance, method, args, env, ctx) do
      {:ok, _new_obj, return_val, env, ctx} -> {:ok, return_val, env, ctx}
      :not_found -> :not_found
    end
  end

  @spec call_dunder_mut(pyvalue(), String.t(), [pyvalue()], Env.t(), Ctx.t()) ::
          {:ok, pyvalue(), pyvalue(), Env.t(), Ctx.t()} | :not_found
  defp call_dunder_mut(
         {:instance, {:class, _, _, _} = class, _} = instance,
         method,
         args,
         env,
         ctx
       ) do
    case resolve_class_attr(class, method) do
      {:ok, {:function, _, _, _, _} = func} ->
        case call_function({:bound_method, instance, func}, args, %{}, env, ctx) do
          {:mutate, new_obj, return_val, ctx} ->
            {:ok, new_obj, return_val, env, ctx}

          {{:exception, _} = signal, env, ctx} ->
            {:ok, instance, signal, env, ctx}

          {return_val, env, ctx} ->
            {:ok, instance, return_val, env, ctx}

          {return_val, env, ctx, _} ->
            {:ok, instance, return_val, env, ctx}
        end

      {:ok, {:builtin, fun}} ->
        case call_function({:builtin, fun}, [instance | args], %{}, env, ctx) do
          {:mutate, new_obj, return_val, ctx} ->
            {:ok, new_obj, return_val, env, ctx}

          {{:exception, _} = signal, env, ctx} ->
            {:ok, instance, signal, env, ctx}

          {return_val, env, ctx} ->
            {:ok, instance, return_val, env, ctx}
        end

      _ ->
        :not_found
    end
  end

  defp call_dunder_mut(_, _, _, _, _), do: :not_found

  @spec resolve_class_attr(pyvalue(), String.t()) :: {:ok, pyvalue()} | :error
  defp resolve_class_attr(class, attr) do
    mro = c3_linearize(class)

    Enum.find_value(mro, :error, fn {:class, _, _, class_attrs} ->
      case Map.get(class_attrs, attr) do
        nil -> nil
        value -> {:ok, value}
      end
    end)
  end

  @spec resolve_class_attr_with_owner(pyvalue(), String.t()) ::
          {:ok, pyvalue(), pyvalue()} | :error
  defp resolve_class_attr_with_owner(class, attr) do
    mro = c3_linearize(class)

    Enum.find_value(mro, :error, fn {:class, _, _, class_attrs} = c ->
      case Map.get(class_attrs, attr) do
        nil -> nil
        value -> {:ok, value, c}
      end
    end)
  end

  @spec c3_linearize(pyvalue()) :: [pyvalue()]
  defp c3_linearize({:class, _, [], _} = class), do: [class]

  defp c3_linearize({:class, _, bases, _} = class) do
    parent_mros = Enum.map(bases, &c3_linearize/1)
    [class | c3_merge(parent_mros ++ [bases])]
  end

  @spec c3_merge([[pyvalue()]]) :: [pyvalue()]
  defp c3_merge(lists) do
    lists = Enum.reject(lists, &(&1 == []))

    case lists do
      [] ->
        []

      _ ->
        case find_c3_head(lists) do
          {:ok, head} ->
            remaining =
              lists
              |> Enum.map(fn list ->
                case list do
                  [^head | rest] -> rest
                  _ -> Enum.reject(list, &(&1 == head))
                end
              end)

            [head | c3_merge(remaining)]

          :error ->
            Enum.flat_map(lists, & &1) |> Enum.uniq()
        end
    end
  end

  @spec find_c3_head([[pyvalue()]]) :: {:ok, pyvalue()} | :error
  defp find_c3_head(lists) do
    tails = lists |> Enum.flat_map(&tl_safe/1) |> MapSet.new()

    Enum.find_value(lists, :error, fn
      [head | _] ->
        if MapSet.member?(tails, head), do: nil, else: {:ok, head}

      [] ->
        nil
    end)
  end

  @spec tl_safe([pyvalue()]) :: [pyvalue()]
  defp tl_safe([]), do: []
  defp tl_safe([_ | rest]), do: rest

  @spec yield_from_deferred([pyvalue()], Env.t(), Ctx.t()) :: eval_result()
  defp yield_from_deferred([], env, ctx), do: {nil, env, ctx}

  defp yield_from_deferred([item | rest], env, ctx) do
    {{:yielded, item, [{:cont_yield_from, rest}]}, env, ctx}
  end

  @type cont_frame ::
          {:cont_stmts, [Parser.ast_node()]}
          | {:cont_for, String.t() | [String.t()], [pyvalue()], [Parser.ast_node()],
             [Parser.ast_node()] | nil}
          | {:cont_while, Parser.ast_node(), [Parser.ast_node()], [Parser.ast_node()] | nil}
          | {:cont_yield_from, [pyvalue()]}

  @doc """
  Resumes a suspended generator from a continuation.

  Processes continuation frames from inside out. Each frame
  represents a point where execution was interrupted by a
  `yield`. Returns `{:yielded, value, new_cont}` if another
  yield is reached, or `{:done, env, ctx}` when the generator
  body completes.
  """
  @spec resume_generator([cont_frame()], Env.t(), Ctx.t()) ::
          {{:yielded, pyvalue(), [cont_frame()]}, Env.t(), Ctx.t()}
          | {:done, Env.t(), Ctx.t()}
          | {{:exception, String.t()}, Env.t(), Ctx.t()}
  def resume_generator([], env, ctx), do: {:done, env, ctx}

  def resume_generator([{:cont_stmts, stmts} | rest], env, ctx) do
    case eval_statements(stmts, env, ctx) do
      {{:yielded, val, inner_cont}, env, ctx} ->
        {{:yielded, val, inner_cont ++ rest}, env, ctx}

      {{:returned, _}, env, ctx} ->
        {:done, env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {_, env, ctx} ->
        resume_generator(rest, env, ctx)
    end
  end

  def resume_generator([{:cont_for, var, items, body, else_body} | rest], env, ctx) do
    case eval_for(var, items, body, else_body, env, ctx) do
      {{:yielded, val, inner_cont}, env, ctx} ->
        {{:yielded, val, inner_cont ++ rest}, env, ctx}

      {{:returned, _}, env, ctx} ->
        {:done, env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {_, env, ctx} ->
        resume_generator(rest, env, ctx)
    end
  end

  def resume_generator([{:cont_while, condition, body, else_body} | rest], env, ctx) do
    case eval_while(condition, body, else_body, env, ctx) do
      {{:yielded, val, inner_cont}, env, ctx} ->
        {{:yielded, val, inner_cont ++ rest}, env, ctx}

      {{:returned, _}, env, ctx} ->
        {:done, env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {_, env, ctx} ->
        resume_generator(rest, env, ctx)
    end
  end

  def resume_generator([{:cont_yield_from, items} | rest], env, ctx) do
    case yield_from_deferred(items, env, ctx) do
      {{:yielded, val, inner_cont}, env, ctx} ->
        {{:yielded, val, inner_cont ++ rest}, env, ctx}

      {_, env, ctx} ->
        resume_generator(rest, env, ctx)
    end
  end

  @spec contains_yield?([Parser.ast_node()]) :: boolean()
  defp contains_yield?([]), do: false

  defp contains_yield?([{:yield, _, _} | _]), do: true
  defp contains_yield?([{:yield_from, _, _} | _]), do: true

  defp contains_yield?([{:def, _, _} | rest]) do
    contains_yield?(rest)
  end

  defp contains_yield?([{:class, _, _} | rest]) do
    contains_yield?(rest)
  end

  defp contains_yield?([{:lambda, _, _} | rest]) do
    contains_yield?(rest)
  end

  defp contains_yield?([{_, _, children} | rest]) when is_list(children) do
    Enum.any?(children, fn
      child when is_list(child) ->
        contains_yield?(child)

      {_, _, _} = node ->
        contains_yield?([node])

      {cond_or_key, body} when is_list(body) ->
        contains_yield?(body) or contains_yield?([cond_or_key])

      _ ->
        false
    end) or contains_yield?(rest)
  end

  defp contains_yield?([_ | rest]), do: contains_yield?(rest)

  @spec write_back_subscript(Parser.ast_node(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp write_back_subscript({:var, _, [name]}, updated, env, ctx) do
    {updated, Env.put_at_source(env, name, updated), ctx}
  end

  defp write_back_subscript({:subscript, _, [parent_expr, key_expr]}, updated, env, ctx) do
    {parent, env, ctx} = eval(parent_expr, env, ctx)
    {key, env, ctx} = eval(key_expr, env, ctx)
    updated_parent = set_subscript_value(parent, key, updated)
    write_back_subscript(parent_expr, updated_parent, env, ctx)
  end

  defp write_back_subscript({:getattr, _, _} = target, updated, env, ctx) do
    setattr_nested(target, updated, env, ctx)
  end

  defp write_back_subscript(_, updated, env, ctx) do
    {updated, env, ctx}
  end

  @spec decrement_depth(call_result()) :: call_result()
  defp decrement_depth({{:exception, _} = signal, env, ctx}),
    do: {signal, env, %{ctx | call_depth: ctx.call_depth - 1}}

  defp decrement_depth({val, env, ctx, updated_func}),
    do: {val, env, %{ctx | call_depth: ctx.call_depth - 1}, updated_func}

  defp decrement_depth({val, env, ctx}),
    do: {val, env, %{ctx | call_depth: ctx.call_depth - 1}}

  @spec extract_exception_type_name(String.t()) :: String.t() | nil
  defp extract_exception_type_name(msg) do
    case Regex.run(~r/^(\w+(?:Error|Exception|Warning|Interrupt)):/, msg) do
      [_, type] -> type
      _ -> nil
    end
  end

  @spec with_context_var(node()) :: String.t() | nil
  defp with_context_var({:var, _, [name]}), do: name
  defp with_context_var(_), do: nil

  @spec with_update_cm(Env.t(), String.t() | nil, pyvalue()) :: Env.t()
  defp with_update_cm(env, nil, _new_obj), do: env
  defp with_update_cm(env, var_name, new_obj), do: Env.put_at_source(env, var_name, new_obj)
end
