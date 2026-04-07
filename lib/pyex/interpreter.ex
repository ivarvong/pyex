defmodule Pyex.Interpreter do
  @moduledoc """
  Tree-walking evaluator for the Pyex AST.

  Functions are first-class values stored in the environment.
  Control flow (return, break, continue) is handled via tagged
  tuples that unwind naturally through the call stack. Python
  exceptions are `{:exception, message}` tuples that propagate
  identically -- no Elixir raise/rescue for Python error semantics.

  Every execution is instrumented via `Pyex.Ctx`. The context tracks
  output plus lightweight counters for events, file operations, and
  compute time so callers can inspect execution without a separate
  runtime process.
  """

  import Bitwise, only: [bnot: 1]

  alias Pyex.{Builtins, Ctx, Env, Methods, Parser, PyDict}

  alias Pyex.Interpreter.{
    Assignments,
    BinaryOps,
    Bindings,
    ClassLookup,
    Calls,
    Collections,
    ControlFlow,
    Dunder,
    Exceptions,
    Format,
    Helpers,
    Import,
    Invocation,
    Iterables,
    Match,
    Protocols,
    Statements
  }

  @type pyvalue ::
          integer()
          | float()
          | :infinity
          | :neg_infinity
          | :nan
          | :ellipsis
          | String.t()
          | boolean()
          | nil
          | [pyvalue()]
          | {:py_list, [pyvalue()], non_neg_integer()}
          | %{optional(pyvalue()) => pyvalue()}
          | {:tuple, [pyvalue()]}
          | {:set, MapSet.t(pyvalue())}
          | {:frozenset, MapSet.t(pyvalue())}
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
          | {:pandas_series, Explorer.Series.t()}
          | {:pandas_rolling, Explorer.Series.t(), pos_integer()}
          | {:pandas_dataframe, Explorer.DataFrame.t()}
          | {:py_dict, %{optional(pyvalue()) => pyvalue()}, [pyvalue()]}
          | {:pyex_decimal, Decimal.t()}
          | {:object, integer()}
          | {:property, pyvalue() | nil, pyvalue() | nil, pyvalue() | nil}
          | {:staticmethod, pyvalue()}
          | {:classmethod, pyvalue()}
          | {:deque, [pyvalue()], integer() | nil}
          | {:stringio, String.t()}
          | {:partial, pyvalue(), [pyvalue()], %{optional(String.t()) => pyvalue()}}
          | {:lru_cached_function, pyvalue(), non_neg_integer()}
          | {:cached_property, pyvalue()}
          | {:ref, non_neg_integer()}

  @typep signal ::
           {:returned, pyvalue()}
           | {:break}
           | {:continue}
           | {:exception, String.t()}
           | {:yielded, pyvalue(), [cont_frame()]}

  @type builtin_signal ::
          {:print_call, [pyvalue()], String.t(), String.t()}
          | {:io_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})}
          | {:ctx_call, (Env.t(), Ctx.t() -> term())}
          | {:mutate, pyvalue(), pyvalue()}
          | {:mutate_arg, non_neg_integer(), pyvalue(), pyvalue()}
          | {:dunder_call, pyvalue(), String.t(), [pyvalue()]}
          | {:map_call, pyvalue(), [pyvalue()]}
          | {:filter_call, pyvalue(), [pyvalue()]}
          | {:reduce_call, pyvalue(), pyvalue(), pyvalue() | :no_initial}
          | {:min_call, [pyvalue()], pyvalue()}
          | {:max_call, [pyvalue()], pyvalue()}
          | {:sort_call, [pyvalue()], pyvalue() | nil, boolean()}
          | {:list_sort_call, [pyvalue()], pyvalue() | nil, boolean()}
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

  @typep eval_result :: {pyvalue() | signal(), Env.t(), Ctx.t()}

  @doc """
  Evaluates an AST and returns the final value.

  The environment is pre-populated with Python builtins
  (`len`, `range`, `print`, etc.). A fresh `Ctx` is used
  for event recording.
  """
  @spec run(Parser.ast_node()) :: {:ok, pyvalue()} | {:error, String.t()}
  def run(ast) do
    case eval(ast, Builtins.env(), %Ctx{}) do
      {{:exception, msg}, _env, ctx} -> {:error, Helpers.format_error(msg, ctx)}
      {result, _env, _ctx} -> {:ok, Helpers.unwrap(result)}
    end
  end

  @doc """
  Evaluates an AST with a provided context, returning
  the value, final environment, and updated context.
  """
  @spec run_with_ctx(Parser.ast_node(), Env.t(), Ctx.t()) ::
          {:ok, pyvalue(), Env.t(), Ctx.t()}
          | {:error, String.t()}
  def run_with_ctx(ast, env, ctx) do
    case run_with_ctx_result(ast, env, ctx) do
      {:ok, value, env, ctx} -> {:ok, value, env, ctx}
      {:error, msg, _ctx} -> {:error, msg}
    end
  end

  @doc """
  Evaluates an AST with a provided context, preserving the
  final context even when execution ends with an exception.
  """
  @spec run_with_ctx_result(Parser.ast_node(), Env.t(), Ctx.t()) ::
          {:ok, pyvalue(), Env.t(), Ctx.t()}
          | {:error, String.t(), Ctx.t()}
  def run_with_ctx_result(ast, env, ctx) do
    ctx = init_profile(ctx)

    case eval(ast, env, ctx) do
      {{:exception, msg}, env, ctx} ->
        if system_exit_zero?(msg) do
          {:ok, nil, env, ctx}
        else
          {:error, Helpers.format_error(msg, ctx), ctx}
        end

      {result, env, ctx} ->
        value = Helpers.unwrap(result)
        {:ok, Ctx.deep_deref(ctx, value), env, ctx}
    end
  end

  @spec system_exit_zero?(String.t()) :: boolean()
  defp system_exit_zero?("SystemExit"), do: true
  defp system_exit_zero?("SystemExit: 0"), do: true
  defp system_exit_zero?("SystemExit: None"), do: true
  defp system_exit_zero?(_), do: false

  defmacrop is_py_exception(val) do
    quote do: is_tuple(unquote(val)) and elem(unquote(val), 0) == :exception
  end

  @doc """
  Evaluates a single AST node within the given environment
  and context.

  Returns `{value, env, ctx}` where value may be a raw value
  or a signal (`{:returned, value}`, `{:break}`, `{:continue}`,
  `{:exception, msg}`, `{:yielded, value, cont}`) that
  propagates up through statement evaluation.
  """
  @spec eval(Parser.ast_node(), Env.t(), Ctx.t()) :: eval_result()
  def eval({:__evaluated__, val}, env, ctx), do: {val, env, ctx}

  def eval({:module, _, statements}, env, ctx) do
    eval_statements(statements, env, ctx)
  end

  def eval({:block, _, [statements]}, env, ctx) do
    eval_statements(statements, env, ctx)
  end

  def eval({:def, _, [name, params, body]}, env, ctx) do
    {evaluated_params, ctx} = eval_param_defaults(params, env, ctx)
    func = {:function, name, evaluated_params, body, env}
    {nil, Env.smart_put(env, name, func), ctx}
  end

  def eval({:decorated_def, _, [decorator_expr, def_node]}, env, ctx) do
    # Evaluate the decorator expression BEFORE the def so that references to
    # the name (e.g. @x.setter referencing the existing @property x) capture
    # the current binding, not the one created by the def below.
    case eval(decorator_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {decorator, env, ctx} ->
        {nil, env, ctx} = eval(def_node, env, ctx)

        name =
          case Helpers.unwrap_def(def_node) do
            {:def, _, [n, _, _]} -> n
            {:class, _, [n, _, _]} -> n
          end

        {:ok, func} = Env.get(env, name)

        eval_apply_decorator(decorator, func, name, decorator_expr, env, ctx)
    end
  end

  def eval({:with, _, [expr, as_name, body]}, env, ctx) do
    cm_var = with_context_var(expr)

    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {context_val, env, ctx} ->
        {enter_val, context_val, env, ctx} =
          case Dunder.call_dunder_mut(context_val, "__enter__", [], env, ctx) do
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
            exc_type_name = extract_exception_type_name(msg)

            exc_type =
              case ctx.exception_instance do
                {:instance, {:class, name, bases, attrs}, _} ->
                  {:class, name, bases, Map.put_new(attrs, "__name__", name)}

                _ when is_binary(exc_type_name) ->
                  {:class, exc_type_name, [], %{"__name__" => exc_type_name}}

                _ ->
                  nil
              end

            exc_val =
              case ctx.exception_instance do
                nil -> msg
                inst -> inst
              end

            case Dunder.call_dunder_mut(
                   context_val,
                   "__exit__",
                   [exc_type, exc_val, nil],
                   env,
                   ctx
                 ) do
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
            case Dunder.call_dunder_mut(context_val, "__exit__", [nil, nil, nil], env, ctx) do
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
            {:ok, {:class, _, _, _} = base} ->
              base

            _ ->
              # Builtin exception types (Exception, ValueError, ...) are
              # not bound as real classes in the env -- they're handled as
              # tagged strings at raise/except time. To make
              # `class MyError(Exception): super().__init__(...)` work,
              # synthesize a stub class for any recognized exception base
              # name. Other unknown base names still fall through to nil
              # so we don't silently mask typos.
              builtin_exception_base_stub(base_name)
          end
      end)
      |> Enum.reject(&is_nil/1)

    class_env = Env.push_scope(env)

    {class_env, ctx, error} =
      Enum.reduce_while(body, {class_env, ctx, nil}, fn stmt, {ce, c, _err} ->
        case eval(stmt, ce, c) do
          {{:exception, _} = signal, ce, c} -> {:halt, {ce, c, signal}}
          {_val, ce, c} -> {:cont, {ce, c, nil}}
        end
      end)

    if error do
      {error, env, ctx}
    else
      class_scope = Env.current_scope(class_env)

      class_attrs =
        Enum.reduce(class_scope, %{}, fn {k, v}, acc ->
          Map.put(acc, k, v)
        end)
        |> Map.put("__name__", name)

      class_val = {:class, name, bases, class_attrs}
      {nil, Env.smart_put(env, name, class_val), ctx}
    end
  end

  def eval({:attr_assign, _, [target, expr]}, env, ctx) do
    Assignments.eval_attr_assign(target, expr, env, ctx)
  end

  def eval({:aug_attr_assign, _, [target, op, expr]}, env, ctx) do
    Assignments.eval_aug_attr_assign(target, op, expr, env, ctx)
  end

  def eval({:global, _, [names]}, env, ctx) do
    Bindings.eval_global(names, env, ctx)
  end

  def eval({:nonlocal, _, [names]}, env, ctx) do
    Bindings.eval_nonlocal(names, env, ctx)
  end

  def eval({:assign, _, [name, expr]}, env, ctx) do
    Bindings.eval_assign(name, expr, env, ctx)
  end

  def eval({:annotated_assign, _, [name, type_str, nil]}, env, ctx) do
    Bindings.eval_annotated_declaration(name, type_str, env, ctx)
  end

  def eval({:annotated_assign, _, [name, type_str, expr]}, env, ctx) do
    Bindings.eval_annotated_assign(name, type_str, expr, env, ctx)
  end

  def eval({:walrus, _, [name, expr]}, env, ctx) do
    Bindings.eval_walrus(name, expr, env, ctx)
  end

  def eval({:chained_assign, _, [names, expr]}, env, ctx) do
    Bindings.eval_chained_assign(names, expr, env, ctx)
  end

  def eval({:multi_assign, _, [names, exprs]}, env, ctx) do
    Bindings.eval_multi_assign(names, exprs, env, ctx)
  end

  def eval(
        {:subscript_assign, _,
         [{:subscript, _, [container_expr, outer_key_expr]}, inner_key_expr, val_expr]},
        env,
        ctx
      ) do
    Assignments.eval_nested_subscript_assign(
      container_expr,
      outer_key_expr,
      inner_key_expr,
      val_expr,
      env,
      ctx
    )
  end

  def eval({:subscript_assign, _, [{:getattr, _, _} = target_expr, key_expr, val_expr]}, env, ctx) do
    Assignments.eval_attr_subscript_assign(target_expr, key_expr, val_expr, env, ctx)
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
    Assignments.eval_nested_aug_subscript_assign(
      container_expr,
      outer_key_expr,
      inner_key_expr,
      op,
      val_expr,
      env,
      ctx
    )
  end

  def eval(
        {:aug_subscript_assign, _, [{:getattr, _, _} = target_expr, key_expr, op, val_expr]},
        env,
        ctx
      ) do
    Assignments.eval_attr_aug_subscript_assign(target_expr, key_expr, op, val_expr, env, ctx)
  end

  def eval({:subscript_assign, _, [name, key_expr, val_expr]}, env, ctx) do
    Assignments.eval_name_subscript_assign(name, key_expr, val_expr, env, ctx)
  end

  def eval({:aug_assign, meta, [name, op, expr]}, env, ctx) do
    Bindings.eval_aug_assign(meta, name, op, expr, env, ctx)
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
    ControlFlow.eval_if(clauses, env, ctx)
  end

  def eval({:while, _, [condition, body, else_body]}, env, ctx) do
    ControlFlow.eval_while(condition, body, else_body, env, ctx)
  end

  def eval({:for, _, [var_name, iterable_expr, body, else_body]}, env, ctx) do
    ControlFlow.eval_for(var_name, iterable_expr, body, else_body, env, ctx)
  end

  def eval({:import, _, imports}, env, ctx) when is_list(imports) do
    Import.eval_import(imports, env, ctx)
  end

  def eval({:from_import, _, [module_name, names]}, env, ctx) do
    Import.eval_from_import(module_name, names, env, ctx)
  end

  def eval({:try, _, [body, handlers, else_body, finally_body]}, env, ctx) do
    ControlFlow.eval_try(body, handlers, else_body, finally_body, env, ctx)
  end

  def eval({:raise, meta, [nil]}, env, ctx) do
    Exceptions.eval_raise(nil, meta, env, ctx)
  end

  def eval({:raise, meta, [expr]}, env, ctx) do
    Exceptions.eval_raise(expr, meta, env, ctx)
  end

  def eval({:assert, _, [condition, msg_expr]}, env, ctx) do
    Statements.eval_assert(condition, msg_expr, env, ctx)
  end

  def eval({:del, _, [:var, var_name]}, env, ctx) do
    Statements.eval_del_var(var_name, env, ctx)
  end

  def eval({:del, _, [:subscript, target_expr, key_expr]}, env, ctx) do
    Statements.eval_del_subscript(target_expr, key_expr, env, ctx)
  end

  def eval({:del, _, [:attr, obj_expr, attr]}, env, ctx) do
    case eval(obj_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {obj, env, ctx} ->
        obj = Ctx.deref(ctx, obj)

        case obj do
          {:instance, _, attrs} = inst ->
            if Map.has_key?(attrs, attr) do
              new_inst = put_elem(inst, 2, Map.delete(attrs, attr))

              case obj_expr do
                {:var, _, [var_name]} ->
                  case Env.get(env, var_name) do
                    {:ok, {:ref, id}} -> {nil, env, Ctx.heap_put(ctx, id, new_inst)}
                    _ -> {nil, Env.put_at_source(env, var_name, new_inst), ctx}
                  end

                _ ->
                  {nil, env, ctx}
              end
            else
              {{:exception,
                "AttributeError: #{Helpers.py_type(obj)} object has no attribute '#{attr}'"}, env,
               ctx}
            end

          _ ->
            {{:exception,
              "AttributeError: '#{Helpers.py_type(obj)}' object has no attribute '#{attr}'"}, env,
             ctx}
        end
    end
  end

  def eval({:aug_subscript_assign, _, [var_name, key_expr, op, val_expr]}, env, ctx) do
    Assignments.eval_name_aug_subscript_assign(var_name, key_expr, op, val_expr, env, ctx)
  end

  def eval({:pass, _, _}, env, ctx), do: Statements.eval_pass(env, ctx)
  def eval({:break, _, _}, env, ctx), do: Statements.eval_break(env, ctx)
  def eval({:continue, _, _}, env, ctx), do: Statements.eval_continue(env, ctx)

  def eval({:expr, _, [expr]}, env, ctx) do
    eval(expr, env, ctx)
  end

  def eval(
        {:call, _meta, [{:getattr, _, [{:var, _, [var_name]}, _attr]} = func_expr, arg_exprs]},
        env,
        ctx
      ) do
    Calls.eval_var_attr_call(func_expr, arg_exprs, var_name, env, ctx)
  end

  def eval({:call, _, [func_expr, arg_exprs]}, env, ctx) do
    Calls.eval_call_expr(func_expr, arg_exprs, env, ctx)
  end

  def eval({:getattr, _, [{:var, _, [name]}, attr]}, env, ctx) do
    case Env.get(env, name) do
      {:ok, raw} ->
        case Ctx.deref(ctx, raw) do
          {:instance, {:class, _, _, _} = class, inst_attrs} = instance ->
            case attr do
              "__class__" ->
                {class, env, ctx}

              _ ->
                case Map.fetch(inst_attrs, attr) do
                  {:ok, value} ->
                    {value, env, ctx}

                  :error ->
                    case ClassLookup.resolve_class_attr_with_owner(class, attr) do
                      {:ok, {:function, _, _, _, _} = func, owner_class} ->
                        {{:bound_method, raw, func, owner_class}, env, ctx}

                      {:ok, {:builtin_kw, _} = bkw, _owner} ->
                        {{:bound_method, raw, bkw}, env, ctx}

                      {:ok, {:property, fget, _, _}, _owner} when fget != nil ->
                        case call_function(fget, [instance], %{}, env, ctx) do
                          {val, env, ctx, _} -> {val, env, ctx}
                          other -> other
                        end

                      {:ok, {:staticmethod, func}, _owner} ->
                        {func, env, ctx}

                      {:ok, {:classmethod, func}, _owner} ->
                        {{:bound_method, class, func}, env, ctx}

                      {:ok, value, _owner} ->
                        {value, env, ctx}

                      :error ->
                        case Methods.resolve(instance, attr) do
                          {:ok, method} ->
                            {method, env, ctx}

                          :error ->
                            case Dunder.call_dunder(instance, "__getattr__", [attr], env, ctx) do
                              {:ok, val, env, ctx} ->
                                {val, env, ctx}

                              :not_found ->
                                {{:exception,
                                  "AttributeError: '#{Helpers.py_type(instance)}' object has no attribute '#{attr}'"},
                                 env, ctx}
                            end
                        end
                    end
                end
            end

          other ->
            eval_getattr_on_value(other, attr, env, ctx)
        end

      :undefined ->
        {{:exception, "NameError: name '#{name}' is not defined"}, env, ctx}
    end
  end

  def eval({:getattr, _, [expr, attr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {raw_object, env, ctx} ->
        object = Ctx.deref(ctx, raw_object)

        case object do
          {:instance, {:class, _, _, _} = class, inst_attrs} ->
            case attr do
              "__class__" ->
                {class, env, ctx}

              _ ->
                case Map.fetch(inst_attrs, attr) do
                  {:ok, value} ->
                    {value, env, ctx}

                  :error ->
                    case ClassLookup.resolve_class_attr_with_owner(class, attr) do
                      {:ok, {:function, _, _, _, _} = func, owner_class} ->
                        {{:bound_method, raw_object, func, owner_class}, env, ctx}

                      {:ok, {:builtin_kw, _} = bkw, _owner} ->
                        {{:bound_method, raw_object, bkw}, env, ctx}

                      {:ok, value, _owner} ->
                        {value, env, ctx}

                      :error ->
                        case Methods.resolve(object, attr) do
                          {:ok, method} ->
                            {method, env, ctx}

                          :error ->
                            case Dunder.call_dunder(object, "__getattr__", [attr], env, ctx) do
                              {:ok, val, env, ctx} ->
                                {val, env, ctx}

                              :not_found ->
                                {{:exception,
                                  "AttributeError: '#{Helpers.py_type(object)}' object has no attribute '#{attr}'"},
                                 env, ctx}
                            end
                        end
                    end
                end
            end

          {:class, class_name, _, class_attrs} = class_val ->
            case attr do
              "__class__" ->
                {{:class, "type", [], %{"__name__" => "type"}}, env, ctx}

              _ ->
                case Map.get(class_attrs, attr) do
                  nil ->
                    case ClassLookup.resolve_class_attr_with_owner(class_val, attr) do
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
            end

          {:property, fget, fset, fdel} ->
            case attr do
              "setter" ->
                prop = {:property, fget, fset, fdel}

                fun = fn
                  [fsetter] -> {:property, fget, fsetter, fdel}
                  _ -> prop
                end

                {{:builtin, fun}, env, ctx}

              "deleter" ->
                prop = {:property, fget, fset, fdel}

                fun = fn
                  [fdeleter] -> {:property, fget, fset, fdeleter}
                  _ -> prop
                end

                {{:builtin, fun}, env, ctx}

              "getter" ->
                prop = {:property, fget, fset, fdel}

                fun = fn
                  [fg] -> {:property, fg, fset, fdel}
                  _ -> prop
                end

                {{:builtin, fun}, env, ctx}

              "__doc__" ->
                {nil, env, ctx}

              _ ->
                {{:exception, "AttributeError: 'property' object has no attribute '#{attr}'"},
                 env, ctx}
            end

          {:staticmethod, _} ->
            {{:exception, "AttributeError: 'staticmethod' object has no attribute '#{attr}'"},
             env, ctx}

          {:classmethod, _} ->
            {{:exception, "AttributeError: 'classmethod' object has no attribute '#{attr}'"}, env,
             ctx}

          {:super_proxy, instance, bases} ->
            result =
              Enum.find_value(bases, :error, fn base ->
                case ClassLookup.resolve_class_attr_with_owner(base, attr) do
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

          {:py_dict, _, _} = dict ->
            resolve_dict_attr(dict, attr, env, ctx)

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

  def eval(
        {:subscript, _, [{:getattr, _, [{:var, _, [name]}, attr]} = ga_expr, key_expr]},
        env,
        ctx
      ) do
    with {:ok, raw} <- Env.get(env, name),
         {:instance, _class, inst_attrs} <- Ctx.deref(ctx, raw),
         {:ok, container} <- Map.fetch(inst_attrs, attr) do
      container = Ctx.deref(ctx, container)

      case eval(key_expr, env, ctx) do
        {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
        {key, env, ctx} -> eval_subscript(container, key, env, ctx)
      end
    else
      _ ->
        case eval(ga_expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {container, env, ctx} ->
            case eval(key_expr, env, ctx) do
              {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
              {key, env, ctx} -> eval_subscript(container, key, env, ctx)
            end
        end
    end
  end

  def eval({:subscript, _, [{:var, _, [var_name]} = expr, key_expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {object, env, ctx} ->
        case eval(key_expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {key, env, ctx} ->
            case eval_subscript(object, key, env, ctx) do
              {:defaultdict_auto_insert, default_val, new_obj, env, ctx} ->
                env = Env.put_at_source(env, var_name, new_obj)
                {default_val, env, ctx}

              other ->
                other
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
            case eval_subscript(object, key, env, ctx) do
              {:defaultdict_auto_insert, default_val, _new_obj, env, ctx} ->
                {default_val, env, ctx}

              other ->
                other
            end
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
    {evaluated_params, ctx} = eval_param_defaults(params, env, ctx)
    func = {:function, "<lambda>", evaluated_params, body, env}
    {func, env, ctx}
  end

  def eval({:tuple, _, [elements]}, env, ctx) do
    Collections.eval_tuple(elements, env, ctx)
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
    Collections.eval_list_comp(expr, clauses, env, ctx)
  end

  def eval({:gen_expr, _, [expr, clauses]}, env, ctx) do
    Collections.eval_gen_expr(expr, clauses, env, ctx)
  end

  def eval({:dict_comp, _, [key_expr, val_expr, clauses]}, env, ctx) do
    Collections.eval_dict_comp(key_expr, val_expr, clauses, env, ctx)
  end

  def eval({:set_comp, _, [expr, clauses]}, env, ctx) do
    Collections.eval_set_comp(expr, clauses, env, ctx)
  end

  def eval({:list, _, [elements]}, env, ctx) do
    Collections.eval_list_literal(elements, env, ctx)
  end

  def eval({:dict, _, [entries]}, env, ctx) do
    Collections.eval_dict_literal(entries, env, ctx)
  end

  def eval({:set, _, [elements]}, env, ctx) do
    Collections.eval_set_literal(elements, env, ctx)
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

      {raw, env, ctx} ->
        val = Ctx.deref(ctx, raw)

        cond do
          is_number(val) ->
            {-val, env, ctx}

          match?({:instance, _, _}, val) ->
            case Dunder.call_dunder(val, "__neg__", [], env, ctx) do
              {:ok, result, env, ctx} ->
                {result, env, ctx}

              :not_found ->
                {{:exception,
                  "TypeError: bad operand type for unary -: '#{Helpers.py_type(val)}'"}, env, ctx}
            end

          true ->
            {{:exception, "TypeError: bad operand type for unary -: '#{Helpers.py_type(val)}'"},
             env, ctx}
        end
    end
  end

  def eval({:unaryop, _, [:pos, expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {raw, env, ctx} ->
        val = Ctx.deref(ctx, raw)

        cond do
          is_number(val) ->
            {val, env, ctx}

          match?({:instance, _, _}, val) ->
            case Dunder.call_dunder(val, "__pos__", [], env, ctx) do
              {:ok, result, env, ctx} ->
                {result, env, ctx}

              :not_found ->
                {{:exception,
                  "TypeError: bad operand type for unary +: '#{Helpers.py_type(val)}'"}, env, ctx}
            end

          true ->
            {{:exception, "TypeError: bad operand type for unary +: '#{Helpers.py_type(val)}'"},
             env, ctx}
        end
    end
  end

  def eval({:unaryop, _, [:bitnot, expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {raw, env, ctx} ->
        val = Ctx.deref(ctx, raw)

        cond do
          is_integer(val) ->
            {bnot(val), env, ctx}

          match?({:instance, _, _}, val) ->
            case Dunder.call_dunder(val, "__invert__", [], env, ctx) do
              {:ok, result, env, ctx} ->
                {result, env, ctx}

              :not_found ->
                {{:exception,
                  "TypeError: bad operand type for unary ~: '#{Helpers.py_type(val)}'"}, env, ctx}
            end

          true ->
            {{:exception, "TypeError: bad operand type for unary ~: '#{Helpers.py_type(val)}'"},
             env, ctx}
        end
    end
  end

  def eval({:unaryop, _, [:not, expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {raw, env, ctx} ->
        val = Ctx.deref(ctx, raw)

        case val do
          {:instance, _, _} = inst ->
            {result, env, ctx} = eval_truthy(inst, env, ctx)
            {!result, env, ctx}

          _ ->
            {!Helpers.truthy?(val), env, ctx}
        end
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

  # Resolve `dict.attr`. Python dicts have no attribute access for keys —
  # `d.items` is always the method, never `d["items"]`. Pyex relaxes this for
  # internal namespace-as-dict patterns (e.g. `requests.Session()`), so prefer
  # a stored callable when present, otherwise fall back to the dict method.
  @spec resolve_dict_attr(pyvalue(), String.t(), Env.t(), Ctx.t()) :: eval_result()
  defp resolve_dict_attr(dict, attr, env, ctx) do
    stored =
      case PyDict.fetch(dict, attr) do
        {:ok, value} -> {:ok, value}
        :error -> :error
      end

    method =
      case Methods.resolve(dict, attr) do
        {:ok, m} -> {:ok, m}
        :error -> :error
      end

    case {stored, method} do
      {{:ok, value}, {:ok, _}} ->
        if callable?(value), do: {value, env, ctx}, else: {elem(method, 1), env, ctx}

      {{:ok, value}, :error} ->
        {value, env, ctx}

      {:error, {:ok, m}} ->
        {m, env, ctx}

      {:error, :error} ->
        {{:exception, "AttributeError: 'dict' object has no attribute '#{attr}'"}, env, ctx}
    end
  end

  @spec callable?(pyvalue()) :: boolean()
  defp callable?({:builtin, _}), do: true
  defp callable?({:builtin_kw, _}), do: true
  defp callable?({:builtin_raw, _}), do: true
  defp callable?({:function, _, _, _, _}), do: true
  defp callable?({:lambda, _, _, _}), do: true
  defp callable?({:bound_method, _, _}), do: true
  defp callable?({:bound_method, _, _, _}), do: true
  defp callable?({:class, _, _, _}), do: true
  defp callable?({:ctx_call, _}), do: true
  defp callable?({:io_call, _}), do: true
  defp callable?(_), do: false

  @spec eval_getattr_on_value(pyvalue(), String.t(), Env.t(), Ctx.t()) :: eval_result()
  defp eval_getattr_on_value(object, attr, env, ctx) do
    object = Ctx.deref(ctx, object)

    case object do
      {:func_with_attrs, _func, attrs} ->
        case Map.fetch(attrs, attr) do
          {:ok, value} ->
            {value, env, ctx}

          :error ->
            {{:exception, "AttributeError: function has no attribute '#{attr}'"}, env, ctx}
        end

      {:instance, {:class, _, _, _} = class, inst_attrs} ->
        case attr do
          "__class__" ->
            {class, env, ctx}

          _ ->
            case Map.fetch(inst_attrs, attr) do
              {:ok, value} ->
                {value, env, ctx}

              :error ->
                case ClassLookup.resolve_class_attr_with_owner(class, attr) do
                  {:ok, {:function, _, _, _, _} = func, owner_class} ->
                    {{:bound_method, object, func, owner_class}, env, ctx}

                  {:ok, {:builtin_kw, _} = bkw, _owner} ->
                    {{:bound_method, object, bkw}, env, ctx}

                  {:ok, {:property, fget, _, _}, _owner} when fget != nil ->
                    case call_function(fget, [object], %{}, env, ctx) do
                      {val, env, ctx, _} -> {val, env, ctx}
                      other -> other
                    end

                  {:ok, {:staticmethod, func}, _owner} ->
                    {func, env, ctx}

                  {:ok, {:classmethod, func}, _owner} ->
                    {{:bound_method, class, func}, env, ctx}

                  {:ok, value, _owner} ->
                    {value, env, ctx}

                  :error ->
                    case Methods.resolve(object, attr) do
                      {:ok, method} ->
                        {method, env, ctx}

                      :error ->
                        case Dunder.call_dunder(object, "__getattr__", [attr], env, ctx) do
                          {:ok, val, env, ctx} ->
                            {val, env, ctx}

                          :not_found ->
                            {{:exception,
                              "AttributeError: '#{Helpers.py_type(object)}' object has no attribute '#{attr}'"},
                             env, ctx}
                        end
                    end
                end
            end
        end

      {:class, class_name, _, class_attrs} = class_val ->
        case attr do
          "__class__" ->
            {{:class, "type", [], %{"__name__" => "type"}}, env, ctx}

          _ ->
            case Map.get(class_attrs, attr) do
              nil ->
                case ClassLookup.resolve_class_attr_with_owner(class_val, attr) do
                  {:ok, {:function, _, _, _, _} = func, _owner} ->
                    {{:bound_method, class_val, func}, env, ctx}

                  {:ok, {:builtin_kw, _} = bkw, _owner} ->
                    {{:bound_method, class_val, bkw}, env, ctx}

                  {:ok, {:staticmethod, func}, _owner} ->
                    {func, env, ctx}

                  {:ok, {:classmethod, func}, _owner} ->
                    {{:bound_method, class_val, func}, env, ctx}

                  {:ok, value, _owner} ->
                    {value, env, ctx}

                  :error ->
                    {{:exception,
                      "AttributeError: type object '#{class_name}' has no attribute '#{attr}'"},
                     env, ctx}
                end

              {:staticmethod, func} ->
                {func, env, ctx}

              {:classmethod, func} ->
                {{:bound_method, class_val, func}, env, ctx}

              {:builtin_kw, _} = bkw ->
                {{:bound_method, class_val, bkw}, env, ctx}

              value ->
                {value, env, ctx}
            end
        end

      {:builtin_type, "dict", _} ->
        case attr do
          "fromkeys" ->
            fun = fn
              [keys], _kw ->
                Builtins.dict_fromkeys(keys, nil)

              [keys, default], _kw ->
                Builtins.dict_fromkeys(keys, default)

              _, _kw ->
                {:exception, "TypeError: dict.fromkeys() takes 1 or 2 arguments"}
            end

            {{:builtin_kw, fun}, env, ctx}

          _ ->
            {{:exception, "AttributeError: type object 'dict' has no attribute '#{attr}'"}, env,
             ctx}
        end

      {:builtin_type, name, _} ->
        {{:exception, "AttributeError: type object '#{name}' has no attribute '#{attr}'"}, env,
         ctx}

      {:py_dict, _, _} = dict ->
        resolve_dict_attr(dict, attr, env, ctx)

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
            {{:exception, "AttributeError: 'range' object has no attribute '#{attr}'"}, env, ctx}
        end

      {:property, fget, fset, fdel} ->
        case attr do
          "setter" ->
            fun = fn
              [fsetter] -> {:property, fget, fsetter, fdel}
              _ -> {:property, fget, fset, fdel}
            end

            {{:builtin, fun}, env, ctx}

          "deleter" ->
            fun = fn
              [fdeleter] -> {:property, fget, fset, fdeleter}
              _ -> {:property, fget, fset, fdel}
            end

            {{:builtin, fun}, env, ctx}

          "getter" ->
            fun = fn
              [fg] -> {:property, fg, fset, fdel}
              _ -> {:property, fget, fset, fdel}
            end

            {{:builtin, fun}, env, ctx}

          "__doc__" ->
            {nil, env, ctx}

          _ ->
            {{:exception, "AttributeError: 'property' object has no attribute '#{attr}'"}, env,
             ctx}
        end

      {:staticmethod, _} ->
        {{:exception, "AttributeError: 'staticmethod' object has no attribute '#{attr}'"}, env,
         ctx}

      {:classmethod, _} ->
        {{:exception, "AttributeError: 'classmethod' object has no attribute '#{attr}'"}, env,
         ctx}

      {:super_proxy, instance, bases} ->
        result =
          Enum.find_value(bases, :error, fn base ->
            case ClassLookup.resolve_class_attr_with_owner(base, attr) do
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
            {{:exception, "AttributeError: 'super' object has no attribute '#{attr}'"}, env, ctx}
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

  @doc false
  @spec eval_statements([Parser.ast_node()], Env.t(), Ctx.t()) :: eval_result()
  def eval_statements([], env, ctx), do: {nil, env, ctx}

  def eval_statements([stmt], env, ctx) do
    ctx = track_line(stmt, ctx)
    eval(stmt, env, ctx)
  end

  def eval_statements([stmt | rest], env, ctx) do
    case Ctx.check_step(ctx) do
      {:exceeded, msg} ->
        {{:exception, msg}, env, ctx}

      {:ok, ctx} ->
        ctx = track_line(stmt, ctx)

        case eval(stmt, env, ctx) do
          {{:returned, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {{:break} = signal, env, ctx} ->
            {signal, env, ctx}

          {{:continue} = signal, env, ctx} ->
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
    %{ctx | profile: %{line_counts: %{}, call_counts: %{}, call: %{}}}
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
  @doc false
  @spec resolve_annotation(String.t(), Env.t()) :: String.t() | pyvalue()
  def resolve_annotation(type_str, env) do
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
          | {:mutate, pyvalue(), pyvalue(), Env.t(), Ctx.t()}
          | {:mutate_arg, non_neg_integer(), pyvalue(), pyvalue(), Ctx.t()}
          | {:mutate_arg, non_neg_integer(), pyvalue(), pyvalue(), Env.t(), Ctx.t()}
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
    Invocation.call_user_function(func, name, params, body, closure_env, args, kwargs, env, ctx)
  end

  def call_function({:func_with_attrs, func, _attrs}, args, kwargs, env, ctx) do
    call_function(func, args, kwargs, env, ctx)
  end

  def call_function({:partial, func, partial_args, partial_kwargs}, args, kwargs, env, ctx) do
    full_args = partial_args ++ args
    full_kwargs = Map.merge(partial_kwargs, kwargs)
    call_function(func, full_args, full_kwargs, env, ctx)
  end

  def call_function({:lru_cached_function, func, cache_id}, args, kwargs, env, ctx) do
    cache = Map.get(ctx.heap, cache_id, %{})
    cache_args = {args, kwargs}

    case Map.fetch(cache, cache_args) do
      {:ok, cached_result} ->
        {cached_result, env, ctx}

      :error ->
        case call_function(func, args, kwargs, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {result, env, ctx, _} ->
            ctx = Ctx.heap_put(ctx, cache_id, Map.put(cache, cache_args, result))
            {result, env, ctx}

          {result, env, ctx} ->
            ctx = Ctx.heap_put(ctx, cache_id, Map.put(cache, cache_args, result))
            {result, env, ctx}
        end
    end
  end

  def call_function({:builtin, fun}, args, _kwargs, env, ctx) do
    Invocation.call_builtin(fun, args, env, ctx)
  end

  def call_function({:builtin_raw, fun}, args, _kwargs, env, ctx) do
    Invocation.call_builtin_raw(fun, args, env, ctx)
  end

  def call_function({:builtin_type, "dict", _fun}, args, kwargs, env, ctx) do
    Invocation.call_builtin_kw(&Builtins.builtin_dict/2, args, kwargs, env, ctx)
  end

  def call_function({:builtin_type, _name, fun}, args, kwargs, env, ctx) do
    call_function({:builtin, fun}, args, kwargs, env, ctx)
  end

  def call_function({:builtin_kw, fun}, args, kwargs, env, ctx) do
    Invocation.call_builtin_kw(fun, args, kwargs, env, ctx)
  end

  def call_function({:builtin_kw_raw, fun}, args, kwargs, env, ctx) do
    Invocation.call_builtin_kw_raw(fun, args, kwargs, env, ctx)
  end

  def call_function(
        {:bound_method, instance, {:function, _, _, _, _} = func, defining_class},
        args,
        kwargs,
        env,
        ctx
      ) do
    Invocation.call_bound_method(instance, func, defining_class, args, kwargs, env, ctx)
  end

  def call_function(
        {:bound_method, instance, {:function, _, _, _, _} = func},
        args,
        kwargs,
        env,
        ctx
      ) do
    Invocation.call_bound_method(instance, func, nil, args, kwargs, env, ctx)
  end

  def call_function(
        {:bound_method, instance, {:builtin_kw, fun}},
        args,
        kwargs,
        env,
        ctx
      ) do
    Invocation.call_bound_builtin_kw(instance, fun, args, kwargs, env, ctx)
  end

  def call_function(
        {:bound_method, instance, {:builtin, fun}},
        args,
        _kwargs,
        env,
        ctx
      ) do
    Invocation.call_bound_builtin(instance, fun, args, env, ctx)
  end

  def call_function(
        {:class, _name, _bases, %{"__constructor__" => {:builtin, ctor}} = _class_attrs},
        args,
        _kwargs,
        env,
        ctx
      ) do
    Invocation.call_builtin(ctor, args, env, ctx)
    |> case do
      {{:exception, _} = exc, env, ctx} ->
        {exc, env, ctx}

      {inst, env, ctx} when elem(inst, 0) == :instance ->
        {inst, env, ctx}

      {val, env, ctx} ->
        {val, env, ctx}
    end
  end

  def call_function({:class, name, _bases, _class_attrs} = class, args, kwargs, env, ctx) do
    Invocation.call_class(class, name, args, kwargs, env, ctx)
  end

  def call_function({:instance, {:class, _, _, _} = class, _} = instance, args, kwargs, env, ctx) do
    Invocation.call_callable_instance(instance, class, args, kwargs, env, ctx)
  end

  def call_function({:ref, _} = ref, args, kwargs, env, ctx) do
    case Ctx.deref(ctx, ref) do
      {:instance, {:class, _, _, _} = class, _} = instance ->
        Invocation.call_callable_instance(instance, class, args, kwargs, env, ctx)

      other ->
        call_function(other, args, kwargs, env, ctx)
    end
  end

  def call_function(val, _args, _kwargs, env, ctx) do
    {{:exception, "TypeError: '#{Helpers.py_type(val)}' object is not callable"}, env, ctx}
  end

  @doc false
  @spec eval_call_args([Parser.ast_node()], Env.t(), Ctx.t()) ::
          {[pyvalue()], %{optional(String.t()) => pyvalue()}, Env.t(), Ctx.t()}
          | {{:exception, String.t()}, Env.t(), Ctx.t()}
  def eval_call_args([], env, ctx), do: {[], %{}, env, ctx}

  def eval_call_args(arg_exprs, env, ctx) do
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

          {raw_val, env, ctx} ->
            val = Ctx.deref(ctx, raw_val)

            case val do
              {:py_dict, _, _} = dict ->
                merged =
                  Enum.reduce(PyDict.items(dict), kw, fn {k, v}, acc ->
                    Map.put(acc, to_string(k), v)
                  end)

                {:cont, {pos, merged, env, ctx}}

              map when is_map(map) ->
                merged =
                  Enum.reduce(map, kw, fn {k, v}, acc ->
                    Map.put(acc, to_string(k), v)
                  end)

                {:cont, {pos, merged, env, ctx}}

              _ ->
                {:halt,
                 {{:exception,
                   "TypeError: argument after ** must be a mapping, not '#{Helpers.py_type(val)}'"},
                  env, ctx}}
            end
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

  @doc false
  @spec eval_list([Parser.ast_node()], Env.t(), Ctx.t()) ::
          {[pyvalue()], Env.t(), Ctx.t()} | {{:exception, String.t()}, Env.t(), Ctx.t()}
  def eval_list(exprs, env, ctx) do
    Enum.reduce_while(exprs, {[], env, ctx}, fn expr, {acc, env, ctx} ->
      case eval(expr, env, ctx) do
        {{:exception, _} = signal, env, ctx} -> {:halt, {signal, env, ctx}}
        {val, env, ctx} -> {:cont, {[val | acc], env, ctx}}
      end
    end)
    |> case do
      # Return reversed list (stored in reverse order for O(1) append)
      {values, env, ctx} when is_list(values) -> {values, env, ctx}
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  @spec eval_subscript(pyvalue(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp eval_subscript(object, key, env, ctx) do
    object = Ctx.deref(ctx, object)

    case object do
      {:py_dict, %{^key => _}, _} ->
        {:ok, value} = PyDict.fetch(object, key)
        {value, env, ctx}

      %{^key => value} ->
        {value, env, ctx}

      {:py_list, reversed, len} when is_integer(key) ->
        # Transform Python index to storage index
        # Python index i = storage index (len-1-i)
        # Python index -1 (last) = storage index 0 (first in reversed)
        index =
          if key < 0 do
            # Python negative: -1 → 0, -2 → 1, etc.
            -key - 1
          else
            len - 1 - key
          end

        if key < -len or key >= len do
          {{:exception, "IndexError: list index out of range"}, env, ctx}
        else
          {Enum.at(reversed, index), env, ctx}
        end

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
        case Dunder.call_dunder(inst, "__getitem__", [key], env, ctx) do
          {:ok, result, env, ctx} ->
            {result, env, ctx}

          :not_found ->
            {{:exception, "TypeError: '#{Helpers.py_type(inst)}' object is not subscriptable"},
             env, ctx}
        end

      {:pandas_dataframe, df} when is_binary(key) ->
        col = Explorer.DataFrame.pull(df, key)
        {{:pandas_series, col}, env, ctx}

      {:pandas_series, s} ->
        case key do
          {:pandas_series, mask} ->
            {{:pandas_series, Explorer.Series.mask(s, mask)}, env, ctx}

          i when is_integer(i) ->
            len = Explorer.Series.count(s)
            index = if i < 0, do: len + i, else: i

            if index < 0 or index >= len do
              {{:exception, "IndexError: Series index out of range"}, env, ctx}
            else
              {Explorer.Series.at(s, index), env, ctx}
            end

          _ ->
            {{:exception, "TypeError: invalid Series index type"}, env, ctx}
        end

      {:py_dict, %{"__defaultdict_factory__" => factory}, _} = dict ->
        case call_function(factory, [], %{}, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {default_val, env, ctx, _updated_func} ->
            new_dict = PyDict.put(dict, key, default_val)
            {:defaultdict_auto_insert, default_val, new_dict, env, ctx}

          {default_val, env, ctx} ->
            new_dict = PyDict.put(dict, key, default_val)
            {:defaultdict_auto_insert, default_val, new_dict, env, ctx}
        end

      %{"__defaultdict_factory__" => factory} = dict when is_map(dict) ->
        case call_function(factory, [], %{}, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {default_val, env, ctx, _updated_func} ->
            new_dict = Map.put(dict, key, default_val)
            {:defaultdict_auto_insert, default_val, new_dict, env, ctx}

          {default_val, env, ctx} ->
            new_dict = Map.put(dict, key, default_val)
            {:defaultdict_auto_insert, default_val, new_dict, env, ctx}
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

  @spec eval_slice(pyvalue(), pyvalue(), pyvalue(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp eval_slice(object, start, stop, step, env, ctx) do
    object = Ctx.deref(ctx, object)

    case object do
      {:py_list, reversed, _} ->
        case py_slice(Enum.reverse(reversed), start, stop, step) do
          {:exception, msg} ->
            {{:exception, msg}, env, ctx}

          result ->
            {ref, ctx} = Ctx.heap_alloc(ctx, {:py_list, Enum.reverse(result), length(result)})
            {ref, env, ctx}
        end

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

      {:tuple, items} ->
        case py_slice(items, start, stop, step) do
          {:exception, msg} -> {{:exception, msg}, env, ctx}
          result -> {{:tuple, result}, env, ctx}
        end

      {:range, _, _, _} = r ->
        case Builtins.range_to_list(r) do
          {:exception, msg} ->
            {{:exception, msg}, env, ctx}

          items ->
            case py_slice(items, start, stop, step) do
              {:exception, msg} -> {{:exception, msg}, env, ctx}
              result -> {result, env, ctx}
            end
        end

      _ ->
        {{:exception, "TypeError: '#{Helpers.py_type(object)}' object is not subscriptable"}, env,
         ctx}
    end
  end

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

      {raw, env, ctx} ->
        val = Ctx.deref(ctx, raw)
        {str, env, ctx} = eval_py_str(val, env, ctx)
        eval_fstring(rest, <<acc::binary, str::binary>>, env, ctx)
    end
  end

  defp eval_fstring([{:expr, expr, format_spec} | rest], acc, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {raw, env, ctx} ->
        val = Ctx.deref(ctx, raw)

        case Pyex.Interpreter.FstringFormat.apply_format_spec(val, format_spec) do
          {:exception, _} = signal ->
            {signal, env, ctx}

          formatted ->
            eval_fstring(rest, <<acc::binary, formatted::binary>>, env, ctx)
        end
    end
  end

  @spec eval_py_str(pyvalue(), Env.t(), Ctx.t()) :: {String.t(), Env.t(), Ctx.t()}
  defp eval_py_str(val, env, ctx), do: Protocols.eval_py_str(Ctx.deref(ctx, val), env, ctx)

  @spec dunder_str_fallback(pyvalue(), String.t(), Env.t(), Ctx.t()) ::
          {:ok, String.t(), Env.t(), Ctx.t()} | :error
  @doc false
  def dunder_str_fallback(val, dunder_name, env, ctx),
    do: Protocols.dunder_str_fallback(val, dunder_name, env, ctx)

  @doc false
  @spec to_iterable(pyvalue(), Env.t(), Ctx.t()) ::
          {:ok, [pyvalue()], Env.t(), Ctx.t()} | {:exception, String.t()}
  def to_iterable(val, env, ctx), do: Iterables.to_iterable(Ctx.deref(ctx, val), env, ctx)

  @doc false
  @spec unpack_iterable_safe([pyvalue()], [Parser.unpack_target()]) ::
          {:ok, [{String.t(), pyvalue()}]} | {:exception, String.t()}
  def unpack_iterable_safe([single], names) do
    case single do
      {:py_list, reversed, _} ->
        check_unpack_length(Enum.reverse(reversed), names)

      list when is_list(list) ->
        check_unpack_length(list, names)

      {:tuple, items} ->
        check_unpack_length(items, names)

      {:range, _, _, _} = r ->
        case Builtins.range_to_list(r) do
          {:exception, _} = err -> err
          list -> check_unpack_length(list, names)
        end

      str when is_binary(str) ->
        check_unpack_length(String.codepoints(str), names)

      val ->
        {:exception, "TypeError: cannot unpack non-iterable #{Helpers.py_type(val)} object"}
    end
  end

  def unpack_iterable_safe(values, names) do
    check_unpack_length(values, names)
  end

  @spec check_unpack_length([pyvalue()], [Parser.unpack_target()]) ::
          {:ok, [{String.t(), pyvalue()}]} | {:exception, String.t()}
  defp check_unpack_length(items, names) do
    has_star = Enum.any?(names, &match?({:starred, _}, &1))

    if has_star do
      unpack_starred(items, names)
    else
      if length(items) == length(names) do
        bind_pairs(names, items, [])
      else
        {:exception,
         "ValueError: not enough values to unpack (expected #{length(names)}, got #{length(items)})"}
      end
    end
  end

  @spec bind_pairs([Parser.unpack_target()], [pyvalue()], [{String.t(), pyvalue()}]) ::
          {:ok, [{String.t(), pyvalue()}]} | {:exception, String.t()}
  defp bind_pairs([], [], acc), do: {:ok, Enum.reverse(acc)}

  defp bind_pairs([name | names], [val | vals], acc) when is_binary(name) do
    bind_pairs(names, vals, [{name, val} | acc])
  end

  defp bind_pairs([{:starred, _} = s | names], [val | vals], acc) do
    bind_pairs(names, vals, [{s, val} | acc])
  end

  defp bind_pairs([nested_names | names], [val | vals], acc) when is_list(nested_names) do
    case unpack_nested(val, nested_names) do
      {:ok, pairs} -> bind_pairs(names, vals, Enum.reverse(pairs) ++ acc)
      {:exception, _} = err -> err
    end
  end

  @spec unpack_nested(pyvalue(), [Parser.unpack_target()]) ::
          {:ok, [{String.t(), pyvalue()}]} | {:exception, String.t()}
  defp unpack_nested({:tuple, items}, names), do: check_unpack_length(items, names)
  defp unpack_nested({:py_list, rev, _}, names), do: check_unpack_length(Enum.reverse(rev), names)
  defp unpack_nested(list, names) when is_list(list), do: check_unpack_length(list, names)

  defp unpack_nested(str, names) when is_binary(str),
    do: check_unpack_length(String.codepoints(str), names)

  defp unpack_nested({:range, _, _, _} = r, names) do
    case Builtins.range_to_list(r) do
      {:exception, _} = err -> err
      list -> check_unpack_length(list, names)
    end
  end

  defp unpack_nested(val, _names) do
    {:exception, "TypeError: cannot unpack non-iterable #{Helpers.py_type(val)} object"}
  end

  @spec unpack_starred([pyvalue()], [Parser.unpack_target()]) ::
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

      with {:ok, before_pairs} <- bind_pairs(before_names, before_items, []),
           {:ok, after_pairs} <- bind_pairs(after_names, after_items, []) do
        {:ok, before_pairs ++ [{star_name, star_items}] ++ after_pairs}
      end
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
  def eval_truthy(val, env, ctx), do: Protocols.eval_truthy(Ctx.deref(ctx, val), env, ctx)

  @spec eval_binop(atom(), pyvalue(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp eval_binop(op, l, r, env, ctx) when op in [:is, :is_not] do
    BinaryOps.binop_result(safe_binop(op, l, r), env, ctx)
  end

  defp eval_binop(op, l, r, env, ctx) when op in [:eq, :neq] do
    l = if Ctx.ref?(l), do: Ctx.deep_deref(ctx, l), else: l
    r = if Ctx.ref?(r), do: Ctx.deep_deref(ctx, r), else: r
    do_eval_binop(op, l, r, env, ctx)
  end

  defp eval_binop(op, l, r, env, ctx) do
    l = Ctx.deref(ctx, l)
    r = Ctx.deref(ctx, r)
    do_eval_binop(op, l, r, env, ctx)
  end

  @spec do_eval_binop(atom(), pyvalue(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp do_eval_binop(op, {:instance, _, _} = l, r, env, ctx) do
    case BinaryOps.dunder_for_op(op) do
      nil ->
        BinaryOps.binop_result(safe_binop(op, l, r), env, ctx)

      dunder ->
        case Dunder.call_dunder(l, dunder, [r], env, ctx) do
          {:ok, result, env, ctx} ->
            {result, env, ctx}

          :not_found ->
            BinaryOps.binop_result(safe_binop(op, l, r), env, ctx)
        end
    end
  end

  defp do_eval_binop(:in, l, {:instance, _, _} = r, env, ctx) do
    case Dunder.call_dunder(r, "__contains__", [l], env, ctx) do
      {:ok, result, env, ctx} -> {Helpers.truthy?(result), env, ctx}
      :not_found -> BinaryOps.binop_result(safe_binop(:in, l, r), env, ctx)
    end
  end

  defp do_eval_binop(:not_in, l, {:instance, _, _} = r, env, ctx) do
    case Dunder.call_dunder(r, "__contains__", [l], env, ctx) do
      {:ok, result, env, ctx} -> {!Helpers.truthy?(result), env, ctx}
      :not_found -> BinaryOps.binop_result(safe_binop(:not_in, l, r), env, ctx)
    end
  end

  defp do_eval_binop(:percent, l, r, env, ctx) when is_binary(l) do
    {result, env, ctx} = Format.string_format(l, r, env, ctx)
    BinaryOps.binop_result(result, env, ctx)
  end

  defp do_eval_binop(op, l, {:instance, _, _} = r, env, ctx) do
    case BinaryOps.rdunder_for_op(op) do
      nil ->
        BinaryOps.binop_result(safe_binop(op, l, r), env, ctx)

      rdunder ->
        case Dunder.call_dunder(r, rdunder, [l], env, ctx) do
          {:ok, result, env, ctx} ->
            {result, env, ctx}

          :not_found ->
            BinaryOps.binop_result(safe_binop(op, l, r), env, ctx)
        end
    end
  end

  defp do_eval_binop(op, {:tuple, la}, {:tuple, ra}, env, ctx)
       when op in [:eq, :neq] and length(la) == length(ra) do
    result =
      Enum.zip(la, ra)
      |> Enum.reduce_while({true, env, ctx}, fn {a, b}, {_, env, ctx} ->
        case eval_binop(:eq, a, b, env, ctx) do
          {{:exception, _} = signal, env, ctx} -> {:halt, {signal, env, ctx}}
          {false, env, ctx} -> {:halt, {false, env, ctx}}
          {_, env, ctx} -> {:cont, {true, env, ctx}}
        end
      end)

    case result do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {eq_result, env, ctx} when is_boolean(eq_result) ->
        final = if op == :neq, do: not eq_result, else: eq_result
        {final, env, ctx}
    end
  end

  defp do_eval_binop(op, {:tuple, la}, {:tuple, ra}, env, ctx)
       when op in [:eq, :neq] and length(la) != length(ra) do
    {op == :neq, env, ctx}
  end

  defp do_eval_binop(op, {:pandas_series, _} = l, r, env, ctx) do
    BinaryOps.binop_result(BinaryOps.series_binop(op, l, r), env, ctx)
  end

  defp do_eval_binop(op, l, {:pandas_series, _} = r, env, ctx) do
    BinaryOps.binop_result(BinaryOps.series_binop(op, l, r), env, ctx)
  end

  defp do_eval_binop(op, l, r, env, ctx) do
    BinaryOps.binop_result(safe_binop(op, l, r), env, ctx)
  end

  @doc false
  @spec safe_binop(atom(), pyvalue(), pyvalue()) :: pyvalue() | {:exception, String.t()}
  defdelegate safe_binop(op, l, r), to: BinaryOps

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

  @doc false
  @spec eval_sort([pyvalue()], pyvalue() | nil, boolean(), Env.t(), Ctx.t()) :: call_result()
  def eval_sort(items, key_fn, reverse, env, ctx) do
    has_instances? = Enum.any?(items, &match?({:instance, _, _}, &1))

    sorted =
      case key_fn do
        nil when has_instances? ->
          case sort_with_lt(items, env, ctx) do
            {:ok, sorted, env, ctx} when reverse -> {:ok, Enum.reverse(sorted), env, ctx}
            other -> other
          end

        nil ->
          order = if reverse, do: :desc, else: :asc
          {:ok, Enum.sort(items, order), env, ctx}

        _ ->
          sort_with_key(items, key_fn, reverse, env, ctx)
      end

    case sorted do
      {:ok, sorted_items, env, ctx} ->
        {sorted_items, env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}
    end
  end

  @doc false
  @spec eval_minmax([pyvalue()], pyvalue(), :min | :max, Env.t(), Ctx.t()) ::
          {pyvalue(), Env.t(), Ctx.t()}
  def eval_minmax(items, key_fn, op, env, ctx) do
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

  @spec sort_with_key([pyvalue()], pyvalue(), boolean(), Env.t(), Ctx.t()) ::
          {:ok, [pyvalue()], Env.t(), Ctx.t()} | eval_result()
  defp sort_with_key(items, key_fn, reverse, env, ctx) do
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
        comparator = if reverse, do: &pyvalue_gte/2, else: &pyvalue_lte/2

        sorted =
          pairs
          |> Enum.reverse()
          |> Enum.sort_by(fn {_item, key} -> key end, comparator)
          |> Enum.map(&elem(&1, 0))

        {:ok, sorted, env, ctx}

      {signal, env, ctx} ->
        {signal, env, ctx}
    end
  end

  @spec pyvalue_lte(pyvalue(), pyvalue()) :: boolean()
  defp pyvalue_lte(
         {:instance, _, %{"__dt__" => %DateTime{} = a}},
         {:instance, _, %{"__dt__" => %DateTime{} = b}}
       ),
       do: DateTime.compare(a, b) != :gt

  defp pyvalue_lte(
         {:instance, _, %{"__date__" => %Date{} = a}},
         {:instance, _, %{"__date__" => %Date{} = b}}
       ),
       do: Date.compare(a, b) != :gt

  defp pyvalue_lte(a, b), do: a <= b

  @spec pyvalue_gte(pyvalue(), pyvalue()) :: boolean()
  defp pyvalue_gte(
         {:instance, _, %{"__dt__" => %DateTime{} = a}},
         {:instance, _, %{"__dt__" => %DateTime{} = b}}
       ),
       do: DateTime.compare(a, b) != :lt

  defp pyvalue_gte(
         {:instance, _, %{"__date__" => %Date{} = a}},
         {:instance, _, %{"__date__" => %Date{} = b}}
       ),
       do: Date.compare(a, b) != :lt

  defp pyvalue_gte(a, b), do: a >= b

  @doc false
  @spec eval_instance_next(
          pyvalue(),
          non_neg_integer(),
          :no_default | {:default, pyvalue()},
          Env.t(),
          Ctx.t()
        ) ::
          eval_result()
  def eval_instance_next(inst, id, default_opt, env, ctx),
    do: Iterables.eval_instance_next(inst, id, default_opt, env, ctx)

  @doc false
  @spec eval_print_call([pyvalue()], String.t(), String.t(), Env.t(), Ctx.t()) :: eval_result()
  def eval_print_call(args, sep, end_str, env, ctx) do
    {strs, env, ctx} =
      Enum.reduce(args, {[], env, ctx}, fn arg, {acc, env, ctx} ->
        val = Ctx.deref(ctx, arg)
        {str, env, ctx} = eval_py_str(val, env, ctx)
        {[str | acc], env, ctx}
      end)

    output = strs |> Enum.reverse() |> Enum.join(sep)
    output = output <> end_str
    ctx = Ctx.record(ctx, :output, output)

    limits = ctx.limits

    if limits.max_output_bytes != :infinity and ctx.output_bytes >= limits.max_output_bytes do
      {{:exception, "LimitError: output limit exceeded (#{limits.max_output_bytes} bytes)"}, env,
       ctx}
    else
      {nil, env, ctx}
    end
  end

  # Builtin exception type names that subclass __init__ may legitimately
  # call `super().__init__(...)` against. Stubs accept any args/kwargs
  # and do nothing, matching Python's permissive Exception.__init__.
  @builtin_exception_names ~w(
    BaseException Exception
    ArithmeticError AssertionError AttributeError BufferError EOFError
    FloatingPointError GeneratorExit ImportError IndexError KeyError
    KeyboardInterrupt LookupError MemoryError NameError NotImplementedError
    OSError IOError FileNotFoundError FileExistsError PermissionError
    OverflowError RecursionError ReferenceError RuntimeError StopIteration
    StopAsyncIteration SyntaxError IndentationError SystemError SystemExit
    TabError TimeoutError TypeError UnboundLocalError UnicodeError
    UnicodeDecodeError UnicodeEncodeError UnicodeTranslateError ValueError
    ZeroDivisionError ConnectionError BrokenPipeError ConnectionAbortedError
    ConnectionRefusedError ConnectionResetError ChildProcessError
  )

  @spec builtin_exception_base_stub(term()) :: pyvalue() | nil
  defp builtin_exception_base_stub(name) when is_binary(name) do
    if name in @builtin_exception_names do
      noop = fn _args, _kwargs -> nil end

      {:class, name, [],
       %{
         "__name__" => name,
         "__init__" => {:builtin_kw, noop}
       }}
    else
      nil
    end
  end

  defp builtin_exception_base_stub(_), do: nil

  @doc false
  @spec eval_super(Env.t(), Ctx.t()) :: eval_result()
  def eval_super(env, ctx) do
    case Env.get(env, "self") do
      {:ok, raw_self} ->
        case Ctx.deref(ctx, raw_self) do
          {:instance, inst_class, _} = instance ->
            case Env.get(env, "__class__") do
              {:ok, {:class, _, _, _} = current_class} ->
                # Use the MRO of the instance's actual class, then drop everything
                # up to and including current_class. This is how Python's super()
                # enables cooperative multiple inheritance.
                mro = ClassLookup.c3_linearize(inst_class)
                mro_tail = Enum.drop_while(mro, &(&1 != current_class)) |> Enum.drop(1)

                if mro_tail == [] do
                  {{:exception, "TypeError: super(): no parent class"}, env, ctx}
                else
                  {{:super_proxy, instance, mro_tail}, env, ctx}
                end

              _ ->
                {{:exception, "RuntimeError: super(): __class__ is not set"}, env, ctx}
            end

          _ ->
            {{:exception, "RuntimeError: super(): self is not bound"}, env, ctx}
        end

      _ ->
        {{:exception, "RuntimeError: super(): self is not bound"}, env, ctx}
    end
  end

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
    case ControlFlow.eval_for_items(var, items, body, else_body, env, ctx) do
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
    case ControlFlow.eval_while(condition, body, else_body, env, ctx) do
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

  @doc false
  @spec contains_yield?([Parser.ast_node()]) :: boolean()
  def contains_yield?([]), do: false

  def contains_yield?([{:yield, _, _} | _]), do: true
  def contains_yield?([{:yield_from, _, _} | _]), do: true

  def contains_yield?([{:def, _, _} | rest]) do
    contains_yield?(rest)
  end

  def contains_yield?([{:class, _, _} | rest]) do
    contains_yield?(rest)
  end

  def contains_yield?([{:lambda, _, _} | rest]) do
    contains_yield?(rest)
  end

  def contains_yield?([{_, _, children} | rest]) when is_list(children) do
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

  def contains_yield?([_ | rest]), do: contains_yield?(rest)

  @spec extract_exception_type_name(String.t()) :: String.t() | nil
  defp extract_exception_type_name(msg) do
    case Regex.run(~r/^(\w+(?:Error|Exception|Warning|Interrupt)):/, msg) do
      [_, type] -> type
      _ -> nil
    end
  end

  @spec eval_apply_decorator(
          pyvalue(),
          pyvalue(),
          String.t(),
          Parser.ast_node(),
          Env.t(),
          Ctx.t()
        ) ::
          eval_result()
  defp eval_apply_decorator(decorator, func, name, decorator_expr, env, ctx) do
    case call_function(decorator, [func], %{}, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {:mutate, _new_object, return_value, new_env, ctx} ->
        {nil, Env.smart_put(new_env, name, return_value), ctx}

      {:mutate, _new_object, return_value, ctx} ->
        {nil, Env.smart_put(env, name, return_value), ctx}

      {{:register_route, method, path, handler}, env, ctx} ->
        env = register_route(decorator_expr, method, path, handler, env)
        {nil, Env.smart_put(env, name, handler), ctx}

      {result, env, ctx, _updated_func} ->
        {nil, Env.smart_put(env, name, result), ctx}

      {result, env, ctx} ->
        {nil, Env.smart_put(env, name, result), ctx}
    end
  end

  @spec with_context_var(node()) :: String.t() | nil
  defp with_context_var({:var, _, [name]}), do: name
  defp with_context_var(_), do: nil

  @spec with_update_cm(Env.t(), String.t() | nil, pyvalue()) :: Env.t()
  defp with_update_cm(env, nil, _new_obj), do: env
  defp with_update_cm(env, var_name, new_obj), do: Env.put_at_source(env, var_name, new_obj)

  @spec eval_param_defaults([Parser.param()], Env.t(), Ctx.t()) :: {[Parser.param()], Ctx.t()}
  defp eval_param_defaults(params, env, ctx) do
    Enum.map_reduce(params, ctx, fn param, ctx ->
      case param do
        {name, nil} ->
          {{name, nil}, ctx}

        {name, :kwonly_sep} ->
          {{name, :kwonly_sep}, ctx}

        {name, nil, type} ->
          {{name, nil, type}, ctx}

        {name, {:__evaluated__, _} = already} ->
          {{name, already}, ctx}

        {name, default_expr} ->
          case eval(default_expr, env, ctx) do
            {{:exception, _}, _env, ctx} -> {{name, nil}, ctx}
            {val, _env, ctx} -> {{name, {:__evaluated__, val}}, ctx}
          end

        {name, {:__evaluated__, _} = already, type} ->
          {{name, already, type}, ctx}

        {name, default_expr, type} ->
          case eval(default_expr, env, ctx) do
            {{:exception, _}, _env, ctx} -> {{name, nil, type}, ctx}
            {val, _env, ctx} -> {{name, {:__evaluated__, val}, type}, ctx}
          end
      end
    end)
  end
end
