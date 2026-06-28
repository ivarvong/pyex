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
          | {:function, String.t(), [Parser.param()], [Parser.ast_node()], Env.t(), boolean(),
             :sync | :async}
          | {:coroutine, String.t(), {:iterator, non_neg_integer()}}
          | {:asyncio_task, pyvalue()}
          | {:asyncio_task_pending, pyvalue()}
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
          | {:deque, [pyvalue()], [pyvalue()], non_neg_integer(), integer() | nil}
          | {:stringio, String.t()}
          | {:partial, pyvalue(), [pyvalue()], %{optional(String.t()) => pyvalue()}}
          | {:lru_cached_function, pyvalue(), non_neg_integer()}
          | {:cached_property, pyvalue()}
          | {:ref, non_neg_integer()}
          | {:exception_class, String.t()}
          | {:bytes, binary()}
          | {:bytearray, binary()}
          | {:complex, float(), float()}
          | {:module, String.t(), %{optional(String.t()) => pyvalue()}}
          | {:func_with_attrs, pyvalue(), %{optional(String.t()) => pyvalue()}}

  @typedoc """
  Control-flow tokens that flow through the same yield channel as user
  `pyvalue()`s but represent internal coroutine machinery, not Python values.

  - `{:asyncio_sleep, ms}` — emitted by `asyncio.sleep(t)`; the trampoline
    `Process.sleep`s for `ms` and resumes.
  - `{:asyncio_capability_call, cap_id, fun, args}` — emitted by a call to
    an `{:awaitable, fn}` capability; the trampoline dispatches `fun` (in
    parallel under `asyncio.gather`) and resumes the cap iter `cap_id` with
    the result via `Invocation.resume_capability/4`.

  Kept distinct from `pyvalue()` so Dialyzer can verify trampoline branches
  that pattern-match on these shapes (which would otherwise be unreachable
  if the yield channel were typed as `pyvalue()` alone).
  """
  @type coroutine_signal ::
          {:asyncio_sleep, non_neg_integer()}
          | {:asyncio_capability_call, non_neg_integer(), ([term()] -> term()), [pyvalue()]}

  @typep signal ::
           {:returned, pyvalue()}
           | {:break}
           | {:continue}
           | {:exception, String.t()}
           | {:yielded, pyvalue() | coroutine_signal(), [cont_frame()]}

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

  def eval({:def, meta, [name, params, body]}, env, ctx) do
    {evaluated_params, ctx} = eval_param_defaults(params, env, ctx)
    has_yield = contains_yield?(body)

    # `async def` + yield is an async generator in CPython.  Phase 1
    # models it as a regular sync generator so the existing lazy_iter
    # machinery (and FastAPI streaming) consume it without changes.
    # Plain `async def` (no yield) becomes a coroutine producer.
    kind =
      cond do
        Keyword.get(meta, :async, false) and not has_yield -> :async
        true -> :sync
      end

    func = {:function, name, evaluated_params, body, env, has_yield, kind}
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
            {:ok, {:module, _, %{^attr_name => {:class, _, _, _} = base}}} -> base
            {:ok, %{^attr_name => {:class, _, _, _} = base}} -> base
            _ -> nil
          end

        base_name ->
          case Env.get(env, base_name) do
            {:ok, {:class, _, _, _} = base} ->
              base

            {:ok, {:exception_class, _} = exc} ->
              # Reify to a real {:class, name, bases, attrs} so the MRO
              # and super() paths find the builtin __init__ etc.
              exception_instance_class(exc)

            {:ok, {:builtin_type, _, _} = btype} ->
              # Reify `list`, `dict`, `set`, `str`, `int`, `tuple`, ... so
              # `class MyList(list)` works.  Subclass instances carry their
              # wrapped value under `__wrapped__`.
              builtin_type_base_class(btype)

            _ ->
              # Fallback: legacy stub for bases that aren't in env but
              # happen to be registered exception names (for very old
              # callsites that may predate the exception_class builtins).
              builtin_exception_base_stub(base_name)
          end
      end)
      |> Enum.reject(&is_nil/1)

    class_env =
      Env.push_scope_with(env, %{"__annotations__" => %{}, "__annotations_order__" => []})

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

      docstring =
        case body do
          [{:expr, _, [{:lit, _, [s]}]} | _] when is_binary(s) -> s
          [{:lit, _, [s]} | _] when is_binary(s) -> s
          _ -> nil
        end

      module_name =
        case Env.get(env, "__name__") do
          {:ok, n} when is_binary(n) -> n
          _ -> "__main__"
        end

      raw_attrs =
        Enum.reduce(class_scope, %{}, fn {k, v}, acc ->
          Map.put(acc, k, v)
        end)
        |> Map.put("__name__", name)
        |> Map.put("__qualname__", name)
        |> Map.put("__module__", module_name)
        |> Map.put("__doc__", docstring)

      class_val = {:class, name, bases, raw_attrs}

      # Enum subclasses transform plain value assignments into enum
      # member instances with `.name` and `.value` attributes.
      class_val =
        if enum_base?(bases) do
          # Preserve the definition order of member names by walking
          # the class body AST.
          body_order = body_assignment_order(body)
          transform_enum_class(class_val, body_order)
        else
          class_val
        end

      class_val = ClassLookup.with_mro_cache(class_val)
      ctx = Ctx.register_class(ctx, class_val)

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

  def eval({:subscript_assign, _, [expr_target, key_expr, val_expr]}, env, ctx)
      when is_tuple(expr_target) do
    Assignments.eval_expr_subscript_assign(expr_target, key_expr, val_expr, env, ctx)
  end

  def eval({:subscript_assign, _, [name, key_expr, val_expr]}, env, ctx) do
    Assignments.eval_name_subscript_assign(name, key_expr, val_expr, env, ctx)
  end

  def eval({:aug_assign, meta, [name, op, expr]}, env, ctx) do
    Bindings.eval_aug_assign(meta, name, op, expr, env, ctx)
  end

  def eval({:return, _, [expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {{:yielded, val, cont}, env, ctx} ->
        # `return await coro` (or any return-of-suspending-expr): the
        # awaited expression yielded part-way through evaluation.
        # Propagate the yield up; on resume, the resumed value becomes
        # the function's return.  Mirrors how `eval_assign` handles
        # `x = yield expr` via `:cont_bind_sent`.
        {{:yielded, val, cont ++ [{:cont_return_value}]}, env, ctx}

      {value, env, ctx} ->
        {{:returned, value}, env, ctx}
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

          _ ->
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

      {{:iterator, id} = iter, env, ctx} ->
        case Pyex.Ctx.iter_entry(ctx, id) do
          {:gen_sync, _started?, _, _} when ctx.generator_mode in [:defer, :defer_inner] ->
            yield_from_gen_iter(id, env, ctx)

          {:gen_pending, _, _, _} when ctx.generator_mode in [:defer, :defer_inner] ->
            yield_from_gen_iter(id, env, ctx)

          :gen_done when ctx.generator_mode in [:defer, :defer_inner] ->
            {nil, env, ctx}

          {:gen_done, _value} when ctx.generator_mode in [:defer, :defer_inner] ->
            {nil, env, ctx}

          _ ->
            yield_from_general(iter, env, ctx)
        end

      {iterable, env, ctx} ->
        yield_from_general(iterable, env, ctx)
    end
  end

  # `await EXPR`: evaluate EXPR (must be a coroutine or Task), then
  # advance it one step.  If the awaited iterator yields, propagate
  # the yield UP to the surrounding trampoline (with a
  # `:cont_await_iter` frame so resumption continues the same
  # await).  When the iterator exhausts, surface its captured return
  # value as the await expression's result.  Strict on shape —
  # non-awaitables raise CPython-shaped TypeError.
  def eval({:await, _, [expr]}, env, ctx) do
    case eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
      {value, env, ctx} -> Invocation.initiate_await(value, env, ctx)
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
    Exceptions.eval_raise(expr, meta, env, ctx) |> Exceptions.chain_context()
  end

  def eval({:raise, meta, [expr, cause_expr]}, env, ctx) do
    Exceptions.eval_raise_from(expr, cause_expr, meta, env, ctx) |> Exceptions.chain_context()
  end

  def eval({:assert, _, [condition, msg_expr]}, env, ctx) do
    Statements.eval_assert(condition, msg_expr, env, ctx)
  end

  def eval({:del, meta, [:multi, targets]}, env, ctx) do
    # `del a, b, c` — delete each target left-to-right; stop at the first error.
    Enum.reduce_while(targets, {nil, env, ctx}, fn target_args, {_, env, ctx} ->
      case eval({:del, meta, target_args}, env, ctx) do
        {{:exception, _}, _, _} = err -> {:halt, err}
        {_, env, ctx} -> {:cont, {nil, env, ctx}}
      end
    end)
  end

  def eval({:del, _, [:var, var_name]}, env, ctx) do
    Statements.eval_del_var(var_name, env, ctx)
  end

  def eval({:del, _, [:subscript, target_expr, key_expr]}, env, ctx) do
    Statements.eval_del_subscript(target_expr, key_expr, env, ctx)
  end

  def eval({:del, _, [:slice, target_expr, start_expr, stop_expr, step_expr]}, env, ctx) do
    Statements.eval_del_slice(target_expr, start_expr, stop_expr, step_expr, env, ctx)
  end

  def eval({:del, _, [:attr, obj_expr, attr]}, env, ctx) do
    case eval(obj_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {raw_obj, env, ctx} ->
        obj = Ctx.deref(ctx, raw_obj)

        case obj do
          {:instance, class, attrs} = inst ->
            cond do
              Map.has_key?(attrs, attr) ->
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

              # `del obj.attr` where attr is a property with a deleter calls it.
              match?(
                {:ok, {:property, _, _, fdel}, _} when fdel != nil,
                ClassLookup.resolve_class_attr_with_owner(class, attr)
              ) ->
                {:ok, {:property, _fget, _fset, fdel}, _owner} =
                  ClassLookup.resolve_class_attr_with_owner(class, attr)

                self_arg = if match?({:ref, _}, raw_obj), do: raw_obj, else: inst

                case call_function(fdel, [self_arg], %{}, env, ctx) do
                  {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
                  {{:exception, _} = signal, env, ctx, _} -> {signal, env, ctx}
                  {_, env, ctx, _} -> {nil, env, ctx}
                  {_, env, ctx} -> {nil, env, ctx}
                end

              true ->
                {{:exception,
                  "AttributeError: #{Helpers.py_type(obj)} object has no attribute '#{attr}'"},
                 env, ctx}
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
          {:instance, {:class, _, _, _} = snapshot_class, inst_attrs} = instance ->
            # Resolve to the live class so class-attribute mutations made after
            # this instance was created are visible (class identity).
            class = Ctx.live_class(ctx, snapshot_class)

            case attr do
              "__class__" ->
                {class, env, ctx}

              _ ->
                override = subclass_method_override(class, attr)

                case {override, Map.fetch(inst_attrs, attr)} do
                  {{:ok, func, owner_class}, _} ->
                    {{:bound_method, raw, func, owner_class}, env, ctx}

                  {_, {:ok, value}} ->
                    {value, env, ctx}

                  {_, :error} ->
                    case ClassLookup.resolve_class_attr_with_owner(class, attr) do
                      {:ok, {:function, _, _, _, _, _, _} = func, owner_class} ->
                        {{:bound_method, raw, func, owner_class}, env, ctx}

                      {:ok, {:builtin_kw, _} = bkw, _owner} ->
                        {{:bound_method, raw, bkw}, env, ctx}

                      {:ok, {:builtin, _} = b, _owner} ->
                        {{:bound_method, raw, b}, env, ctx}

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
                        invoke_descriptor_get(value, instance, class, env, ctx)

                      :error ->
                        cond do
                          # StopIteration(value).value — the carried value, the
                          # first arg, or None. Used by the generator/coroutine
                          # return protocol (PEP 380/479).
                          attr == "value" and
                              Helpers.py_type(instance) in ["StopIteration", "StopAsyncIteration"] ->
                            {stop_iteration_value(inst_attrs), env, ctx}

                          true ->
                            case forward_method_to_wrapped(inst_attrs, attr) do
                              {:ok, bound} ->
                                {bound, env, ctx}

                              :not_found ->
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
          {:instance, {:class, _, _, _} = snapshot_class, inst_attrs} ->
            # Resolve to the live class so class-attribute mutations made after
            # this instance was created are visible (class identity).
            class = Ctx.live_class(ctx, snapshot_class)

            case attr do
              "__class__" ->
                {class, env, ctx}

              _ ->
                override = subclass_method_override(class, attr)

                case {override, Map.fetch(inst_attrs, attr)} do
                  {{:ok, func, owner_class}, _} ->
                    {{:bound_method, raw_object, func, owner_class}, env, ctx}

                  {_, {:ok, value}} ->
                    {value, env, ctx}

                  {_, :error} ->
                    case ClassLookup.resolve_class_attr_with_owner(class, attr) do
                      {:ok, {:function, _, _, _, _, _, _} = func, owner_class} ->
                        {{:bound_method, raw_object, func, owner_class}, env, ctx}

                      {:ok, {:builtin_kw, _} = bkw, _owner} ->
                        {{:bound_method, raw_object, bkw}, env, ctx}

                      {:ok, {:builtin, _} = b, _owner} ->
                        {{:bound_method, raw_object, b}, env, ctx}

                      {:ok, value, _owner} ->
                        invoke_descriptor_get(value, object, class, env, ctx)

                      :error ->
                        case Methods.resolve(object, attr) do
                          {:ok, method} ->
                            {method, env, ctx}

                          :error ->
                            case forward_method_to_wrapped(elem(object, 2), attr) do
                              {:ok, bound} ->
                                {bound, env, ctx}

                              :not_found ->
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
            end

          {:class, class_name, _, _} = class_val ->
            case ClassLookup.class_attribute(class_val, attr) do
              {:ok, value} ->
                {value, env, ctx}

              :error ->
                {{:exception,
                  "AttributeError: type object '#{class_name}' has no attribute '#{attr}'"}, env,
                 ctx}
            end

          {:complex, r, i} ->
            case attr do
              "real" ->
                {r, env, ctx}

              "imag" ->
                {i, env, ctx}

              "conjugate" ->
                {{:builtin, fn _ -> {:complex, r, -i} end}, env, ctx}

              _ ->
                {{:exception, "AttributeError: 'complex' object has no attribute '#{attr}'"}, env,
                 ctx}
            end

          {:fraction, n, d} ->
            case attr do
              "numerator" ->
                {n, env, ctx}

              "denominator" ->
                {d, env, ctx}

              _ ->
                {{:exception, "AttributeError: 'Fraction' object has no attribute '#{attr}'"},
                 env, ctx}
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
              {:ok, {:function, _, _, _, _, _, _} = func, owner_class} ->
                {{:bound_method, instance, func, owner_class}, env, ctx}

              # Builtin attrs on a parent class should still receive
              # `self` as first arg (matches Python's bound-method call
              # semantics).
              {:ok, {:builtin, _} = builtin, _owner} ->
                {{:bound_method, instance, builtin}, env, ctx}

              {:ok, {:builtin_kw, _} = builtin, _owner} ->
                {{:bound_method, instance, builtin}, env, ctx}

              {:ok, value, _owner} ->
                {value, env, ctx}

              :error ->
                # Fallback for stdlib parents that bake methods into
                # instance attrs (e.g. datetime): if the instance has
                # the method attr inst-level, prefer it over raising.
                derefed = Ctx.deref(ctx, instance)

                case derefed do
                  {:instance, _, inst_attrs} ->
                    case Map.fetch(inst_attrs, attr) do
                      {:ok, value} ->
                        {value, env, ctx}

                      :error ->
                        {{:exception,
                          "AttributeError: 'super' object has no attribute '#{attr}'"}, env, ctx}
                    end

                  _ ->
                    {{:exception, "AttributeError: 'super' object has no attribute '#{attr}'"},
                     env, ctx}
                end
            end

          {:py_dict, _, _} = dict ->
            resolve_dict_attr(dict, attr, env, ctx)

          {:module, name, attrs} ->
            case module_attr(name, attrs, attr) do
              {:ok, value} ->
                {value, env, ctx}

              :error ->
                {{:exception, "AttributeError: module '#{name}' has no attribute '#{attr}'"}, env,
                 ctx}
            end

          {:exception_class, exc_name} ->
            case attr do
              "__name__" ->
                {exc_name, env, ctx}

              "__qualname__" ->
                {exc_name, env, ctx}

              "__class__" ->
                {Builtins.type_class(), env, ctx}

              "__mro__" ->
                {{:tuple, exception_class_mro(exc_name)}, env, ctx}

              "__bases__" ->
                {{:tuple, exception_class_bases(exc_name)}, env, ctx}

              "__module__" ->
                {"builtins", env, ctx}

              "__doc__" ->
                {nil, env, ctx}

              _ ->
                {{:exception,
                  "AttributeError: type object '#{exc_name}' has no attribute '#{attr}'"}, env,
                 ctx}
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

          {:function, _, _, _, _, _, _} = func ->
            case Helpers.function_attr(func, attr) do
              {:ok, value} ->
                {value, env, ctx}

              :error ->
                {{:exception, "AttributeError: function has no attribute '#{attr}'"}, env, ctx}
            end

          {:func_with_attrs, func, attrs} ->
            case Map.fetch(attrs, attr) do
              {:ok, value} ->
                {value, env, ctx}

              :error ->
                case Helpers.function_attr(func, attr) do
                  {:ok, value} ->
                    {value, env, ctx}

                  :error ->
                    {{:exception, "AttributeError: function has no attribute '#{attr}'"}, env,
                     ctx}
                end
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
    func = {:function, "<lambda>", evaluated_params, body, env, false, :sync}
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

          is_boolean(val) ->
            {-Helpers.bool_to_int(val), env, ctx}

          match?({:complex, _, _}, val) ->
            {:complex, r, i} = val
            {{:complex, -r, -i}, env, ctx}

          match?({:pyex_decimal, _}, val) ->
            {:pyex_decimal, d} = val
            {{:pyex_decimal, decimal_unary_neg(d)}, env, ctx}

          match?({:fraction, _, _}, val) ->
            {:fraction, n, d} = val
            {{:fraction, -n, d}, env, ctx}

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

          is_boolean(val) ->
            {Helpers.bool_to_int(val), env, ctx}

          match?({:complex, _, _}, val) ->
            {val, env, ctx}

          match?({:pyex_decimal, _}, val) ->
            {:pyex_decimal, d} = val
            {{:pyex_decimal, decimal_unary_pos(d)}, env, ctx}

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

          is_boolean(val) ->
            {bnot(Helpers.bool_to_int(val)), env, ctx}

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

  # Fast path: parse-time scope resolution (see `Pyex.Parser.ScopeResolve`).
  # `:scope, :global` means the analyzer proved the name is read from
  # a non-local scope (module-level or builtin).  We still walk
  # `env.scopes` because functions defined in imported modules see
  # their *own* module scope as a non-top entry — but we skip the
  # topmost scope (the function's own locals), which is a guaranteed
  # miss.  Net: 1 hash lookup instead of 2 for the common
  # `[function_locals, module_scope]` chain.
  def eval({:var, [{:scope, :global} | _], [name]}, %Env{scopes: [_top | rest]} = env, ctx) do
    case scope_find(rest, name) do
      {:ok, value} -> {value, env, ctx}
      # Misannotated reads fall back so behaviour stays correct.
      :error -> eval_var_slow(name, env, ctx)
    end
  end

  # `:scope, :local` means the analyzer proved the name is bound in
  # the topmost scope.  One hash lookup.  On miss, fall back to the
  # full walk (a wrong annotation must remain correct).
  def eval({:var, [{:scope, :local} | _], [name]}, %Env{scopes: [top | _]} = env, ctx) do
    case Map.fetch(top, name) do
      {:ok, value} ->
        {value, env, ctx}

      :error ->
        eval_var_slow(name, env, ctx)
    end
  end

  # Unannotated reads (module-level code, closure reads the analyzer
  # couldn't classify, or pre-existing AST built without the resolve
  # pass).  Inlined directly so the common case doesn't pay an
  # extra function call.
  def eval({:var, _, [name]}, env, ctx) do
    case Env.get(env, name) do
      {:ok, value} -> {value, env, ctx}
      :undefined -> {{:exception, "NameError: name '#{name}' is not defined"}, env, ctx}
    end
  end

  defp eval_var_slow(name, env, ctx) do
    case Env.get(env, name) do
      {:ok, value} -> {value, env, ctx}
      :undefined -> {{:exception, "NameError: name '#{name}' is not defined"}, env, ctx}
    end
  end

  defp scope_find([], _name), do: :error

  defp scope_find([scope | rest], name) do
    case Map.fetch(scope, name) do
      {:ok, _} = found -> found
      :error -> scope_find(rest, name)
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
  defp callable?({:function, _, _, _, _, _, _}), do: true
  defp callable?({:lambda, _, _, _}), do: true
  defp callable?({:bound_method, _, _}), do: true
  defp callable?({:bound_method, _, _, _}), do: true
  defp callable?({:class, _, _, _}), do: true
  defp callable?({:ctx_call, _}), do: true
  defp callable?({:io_call, _}), do: true
  defp callable?(_), do: false

  @doc false
  @spec eval_value_attr(pyvalue(), String.t(), Env.t(), Ctx.t()) :: eval_result()
  def eval_value_attr(object, attr, env, ctx), do: eval_getattr_on_value(object, attr, env, ctx)

  @spec eval_getattr_on_value(pyvalue(), String.t(), Env.t(), Ctx.t()) :: eval_result()
  defp eval_getattr_on_value(object, attr, env, ctx) do
    object = Ctx.deref(ctx, object)

    case object do
      {:func_with_attrs, func, attrs} ->
        case Map.fetch(attrs, attr) do
          {:ok, value} ->
            {value, env, ctx}

          :error ->
            case Helpers.function_attr(func, attr) do
              {:ok, value} ->
                {value, env, ctx}

              :error ->
                {{:exception, "AttributeError: function has no attribute '#{attr}'"}, env, ctx}
            end
        end

      {:function, _, _, _, _, _, _} = func ->
        case Helpers.function_attr(func, attr) do
          {:ok, value} ->
            {value, env, ctx}

          :error ->
            {{:exception, "AttributeError: function has no attribute '#{attr}'"}, env, ctx}
        end

      {:complex, r, i} ->
        case attr do
          "real" ->
            {r, env, ctx}

          "imag" ->
            {i, env, ctx}

          "conjugate" ->
            {{:builtin, fn _ -> {:complex, r, -i} end}, env, ctx}

          _ ->
            {{:exception, "AttributeError: 'complex' object has no attribute '#{attr}'"}, env,
             ctx}
        end

      {:fraction, n, d} ->
        case attr do
          "numerator" ->
            {n, env, ctx}

          "denominator" ->
            {d, env, ctx}

          _ ->
            {{:exception, "AttributeError: 'Fraction' object has no attribute '#{attr}'"}, env,
             ctx}
        end

      {:instance, {:class, _, _, _} = class, inst_attrs} ->
        case attr do
          "__class__" ->
            {class, env, ctx}

          _ ->
            # If the instance's MRO contains a user-defined subclass override
            # for this attr, prefer it over baked-in parent methods in
            # inst_attrs.  This makes stdlib subclass methods (e.g.
            # overriding datetime.isoformat) work as expected.
            override = subclass_method_override(class, attr)

            case {override, Map.fetch(inst_attrs, attr)} do
              {{:ok, {:function, _, _, _, _, _, _} = func, owner_class}, _} ->
                {{:bound_method, object, func, owner_class}, env, ctx}

              {_, {:ok, value}} ->
                {value, env, ctx}

              {_, :error} ->
                case ClassLookup.resolve_class_attr_with_owner(class, attr) do
                  {:ok, {:function, _, _, _, _, _, _} = func, owner_class} ->
                    {{:bound_method, object, func, owner_class}, env, ctx}

                  {:ok, {:builtin_kw, _} = bkw, _owner} ->
                    {{:bound_method, object, bkw}, env, ctx}

                  {:ok, {:builtin, _} = b, _owner} ->
                    {{:bound_method, object, b}, env, ctx}

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
                    invoke_descriptor_get(value, object, class, env, ctx)

                  :error ->
                    case Methods.resolve(object, attr) do
                      {:ok, method} ->
                        {method, env, ctx}

                      :error ->
                        case forward_method_to_wrapped(elem(object, 2), attr) do
                          {:ok, bound} ->
                            {bound, env, ctx}

                          :not_found ->
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
        end

      {:class, class_name, _, _} = class_val ->
        case ClassLookup.class_attribute(class_val, attr) do
          {:ok, value} ->
            {value, env, ctx}

          :error ->
            {{:exception,
              "AttributeError: type object '#{class_name}' has no attribute '#{attr}'"}, env, ctx}
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

      {:builtin_type, "str", _} when attr == "maketrans" ->
        {{:builtin, fn args -> Pyex.Methods.make_translation_table(args) end}, env, ctx}

      {:builtin_type, name, _} ->
        case builtin_type_attr(name, attr) do
          {:ok, value} ->
            {value, env, ctx}

          :error ->
            {{:exception, "AttributeError: type object '#{name}' has no attribute '#{attr}'"},
             env, ctx}
        end

      {:py_dict, _, _} = dict ->
        resolve_dict_attr(dict, attr, env, ctx)

      {:exception_class, name} ->
        case attr do
          "__name__" ->
            {name, env, ctx}

          "__qualname__" ->
            {name, env, ctx}

          "__class__" ->
            {Builtins.type_class(), env, ctx}

          "__mro__" ->
            {{:tuple, exception_class_mro(name)}, env, ctx}

          "__bases__" ->
            {{:tuple, exception_class_bases(name)}, env, ctx}

          "__module__" ->
            {"builtins", env, ctx}

          "__doc__" ->
            {nil, env, ctx}

          _ ->
            {{:exception, "AttributeError: type object '#{name}' has no attribute '#{attr}'"},
             env, ctx}
        end

      {:module, name, attrs} ->
        case module_attr(name, attrs, attr) do
          {:ok, value} ->
            {value, env, ctx}

          :error ->
            {{:exception, "AttributeError: module '#{name}' has no attribute '#{attr}'"}, env,
             ctx}
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
          {:ok, {:function, _, _, _, _, _, _} = func, owner_class} ->
            {{:bound_method, instance, func, owner_class}, env, ctx}

          {:ok, {:builtin, _} = b, _owner} ->
            {{:bound_method, instance, b}, env, ctx}

          {:ok, {:builtin_kw, _} = bkw, _owner} ->
            {{:bound_method, instance, bkw}, env, ctx}

          {:ok, value, _owner} ->
            {value, env, ctx}

          :error when attr == "__new__" ->
            # `super().__new__(cls)` with no base overriding it resolves to
            # `object.__new__`, which allocates a blank instance of `cls`.
            {{:builtin, &object_new/1}, env, ctx}

          :error when attr == "__init__" ->
            # `object.__init__` is a no-op accepting any arguments.
            {{:builtin, fn _ -> nil end}, env, ctx}

          :error ->
            # Fall back to instance attrs or forwarded stdlib methods.
            # Stdlib subclasses (e.g. class MyDT(datetime.datetime)) bake
            # the parent's builtin methods directly into inst_attrs at
            # construction time, so super().isoformat() must find them there.
            obj = Ctx.deref(ctx, instance)
            inst_attrs = if is_tuple(obj) and tuple_size(obj) == 3, do: elem(obj, 2), else: %{}

            # Stdlib subclass instances (e.g. datetime subclasses) store
            # parent methods as pre-bound closures in inst_attrs. Return them
            # directly without re-binding, since the closure already captures
            # the concrete value (e.g. `fn [] -> "2024-01-15T00:00:00" end`).
            cond do
              match?({:ok, {:builtin, _}}, Map.fetch(inst_attrs, attr)) ->
                {:ok, val} = Map.fetch(inst_attrs, attr)
                {val, env, ctx}

              match?({:ok, {:builtin_kw, _}}, Map.fetch(inst_attrs, attr)) ->
                {:ok, val} = Map.fetch(inst_attrs, attr)
                {val, env, ctx}

              true ->
                case forward_method_to_wrapped(inst_attrs, attr) do
                  {:ok, method} ->
                    {method, env, ctx}

                  :not_found ->
                    {{:exception, "AttributeError: 'super' object has no attribute '#{attr}'"},
                     env, ctx}
                end
            end
        end

      {:iterator, id} ->
        iter_attr_for_generator(id, attr, env, ctx)

      {:file_handle, id} when attr in ["closed", "mode", "name"] ->
        file_handle_attr(id, attr, env, ctx)

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

  # File data attributes (read without a call): `closed` reflects whether the
  # handle is still open, `mode`/`name` echo how it was opened. CPython exposes
  # these on the stream object itself, so they resolve here, not via Methods.
  @spec file_handle_attr(non_neg_integer(), String.t(), Env.t(), Ctx.t()) :: eval_result()
  defp file_handle_attr(id, attr, env, ctx) do
    case {attr, Ctx.handle_meta(ctx, id)} do
      {"closed", :error} -> {true, env, ctx}
      {"closed", {:ok, _}} -> {false, env, ctx}
      {_, :error} -> {{:exception, "ValueError: I/O operation on closed file"}, env, ctx}
      {"mode", {:ok, %{mode: mode}}} -> {file_mode_string(mode), env, ctx}
      {"name", {:ok, %{name: name}}} -> {name, env, ctx}
    end
  end

  @spec file_mode_string(:read | :write | :append) :: String.t()
  defp file_mode_string(:read), do: "r"
  defp file_mode_string(:write), do: "w"
  defp file_mode_string(:append), do: "a"

  @spec iter_attr_for_generator(non_neg_integer(), String.t(), Env.t(), Ctx.t()) :: eval_result()
  defp iter_attr_for_generator(id, attr, env, ctx) do
    iter_token = {:iterator, id}

    case attr do
      a when a in ["__iter__", "__next__"] ->
        {{:builtin,
          fn
            [] -> {:iter_next, id}
            [_self] -> {:iter_next, id}
          end}, env, ctx}

      "send" ->
        {{:builtin,
          fn
            [sent_value] ->
              {:ctx_call,
               fn env, ctx ->
                 case Ctx.iter_entry(ctx, id) do
                   {:gen_sync, false, _cont, _gen_env} when sent_value != nil ->
                     # send(non-None) to a just-created generator is a TypeError:
                     # there is no `yield` expression waiting to receive the value.
                     {{:exception,
                       "TypeError: can't send non-None value to a just-started generator"}, env,
                      ctx}

                   {:gen_sync, _started?, cont, gen_env} ->
                     Pyex.Interpreter.BuiltinResults.advance_gen_sync(
                       id,
                       cont,
                       gen_env,
                       {:send, sent_value},
                       env,
                       ctx
                     )

                   {:gen_awaiting_send, _val, cont, gen_env} ->
                     # Generator is waiting for a sent value to advance.
                     Pyex.Interpreter.BuiltinResults.send_to_awaiting_generator(
                       id,
                       cont,
                       gen_env,
                       sent_value,
                       env,
                       ctx
                     )

                   {:gen_pending, _val, _cont, _gen_env} when sent_value == nil ->
                     # send(None) on a just-started generator primes it, like next().
                     Pyex.Interpreter.BuiltinResults.prime_generator(id, env, ctx)

                   {:gen_pending, _val, _cont, _gen_env} ->
                     {{:exception,
                       "TypeError: can't send non-None value to a just-started generator"}, env,
                      ctx}

                   :gen_done ->
                     Pyex.Interpreter.BuiltinResults.stop_iteration(:no_value, env, ctx)

                   {:gen_done, _value} ->
                     Pyex.Interpreter.BuiltinResults.stop_iteration(:no_value, env, ctx)

                   _ ->
                     {{:exception, "TypeError: can only send to a generator"}, env, ctx}
                 end
               end}

            _ ->
              {:exception, "TypeError: send() takes exactly one argument"}
          end}, env, ctx}

      "close" ->
        {{:builtin,
          fn _ ->
            {:ctx_call,
             fn env, ctx ->
               # close() throws GeneratorExit at the suspension point so finally
               # blocks run; the exit then propagates and the generator is done.
               case Ctx.iter_entry(ctx, id) do
                 {:gen_sync, _started?, cont, gen_env} ->
                   exit_inst =
                     {:instance, exception_instance_class({:exception_class, "GeneratorExit"}),
                      %{"args" => {:tuple, []}}}

                   ctx = %{ctx | exception_instance: exit_inst}

                   {_result, _genv, ctx} =
                     Pyex.Interpreter.BuiltinResults.advance_gen_sync(
                       id,
                       cont,
                       gen_env,
                       {:throw, "GeneratorExit"},
                       env,
                       ctx
                     )

                   {nil, env, Ctx.mark_iter_exhausted(ctx, id)}

                 {state, _val, cont, gen_env} when state in [:gen_pending, :gen_awaiting_send] ->
                   exit_inst =
                     {:instance, exception_instance_class({:exception_class, "GeneratorExit"}),
                      %{"args" => {:tuple, []}}}

                   ctx = %{ctx | exception_instance: exit_inst}

                   {_result, _genv, ctx} =
                     Pyex.Interpreter.BuiltinResults.throw_into_generator(
                       id,
                       cont,
                       gen_env,
                       "GeneratorExit",
                       env,
                       ctx
                     )

                   {nil, env, Ctx.mark_iter_exhausted(ctx, id)}

                 _ ->
                   {nil, env, ctx}
               end
             end}
          end}, env, ctx}

      "throw" ->
        {{:builtin,
          fn
            [exc_type | _rest] ->
              {:ctx_call,
               fn env, ctx ->
                 # Build the exception signal exactly as `raise exc_type` would
                 # (sets ctx.exception_instance for `except ... as e` binding).
                 {{:exception, exc_msg}, env, ctx} =
                   Pyex.Interpreter.Exceptions.raise_value_signal(exc_type, env, ctx)

                 case Ctx.iter_entry(ctx, id) do
                   {:gen_sync, _started?, cont, gen_env} ->
                     Pyex.Interpreter.BuiltinResults.advance_gen_sync(
                       id,
                       cont,
                       gen_env,
                       {:throw, exc_msg},
                       env,
                       ctx
                     )

                   {state, _val, cont, gen_env}
                   when state in [:gen_pending, :gen_awaiting_send] ->
                     Pyex.Interpreter.BuiltinResults.throw_into_generator(
                       id,
                       cont,
                       gen_env,
                       exc_msg,
                       env,
                       ctx
                     )

                   _ ->
                     {{:exception, exc_msg}, env, ctx}
                 end
               end}

            _ ->
              {:exception, "TypeError: throw() requires an exception type"}
          end}, env, ctx}

      _ ->
        _ = iter_token
        {{:exception, "AttributeError: 'generator' object has no attribute '#{attr}'"}, env, ctx}
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
          | {{:yielded, pyvalue() | coroutine_signal(), [cont_frame()]}, Env.t(), Ctx.t()}

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

  def call_function(
        {:function, name, params, body, closure_env, is_generator, :sync} = func,
        args,
        kwargs,
        env,
        ctx
      ) do
    Invocation.call_user_function(
      func,
      name,
      params,
      body,
      closure_env,
      is_generator,
      args,
      kwargs,
      env,
      ctx
    )
  end

  # Calling an `async def` (kind=:async) defers body execution and
  # returns a coroutine value.  The body is driven later by `await`
  # / `asyncio.run` / `asyncio.gather` via the trampoline.
  def call_function(
        {:function, name, params, body, closure_env, _is_generator, :async},
        args,
        kwargs,
        env,
        ctx
      ) do
    Invocation.build_coroutine(name, params, body, closure_env, args, kwargs, env, ctx)
  end

  def call_function({:func_with_attrs, func, _attrs}, args, kwargs, env, ctx) do
    call_function(func, args, kwargs, env, ctx)
  end

  def call_function({:partial, func, partial_args, partial_kwargs}, args, kwargs, env, ctx) do
    full_args = partial_args ++ args
    full_kwargs = Map.merge(partial_kwargs, kwargs)

    case call_function(func, full_args, full_kwargs, env, ctx) do
      # Preserve the partial wrapper when the inner function returns
      # an updated closure: without this, callers that reuse the
      # partial across iterations (e.g. `map(partial(...), ...)`)
      # would lose the pre-bound arguments on the second call.
      {val, env, ctx, updated_inner} ->
        {val, env, ctx, {:partial, updated_inner, partial_args, partial_kwargs}}

      other ->
        other
    end
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

  # `{:awaitable, fn}` is a host-registered capability the trampoline
  # is allowed to dispatch concurrently.  Calling one from Python
  # returns a coroutine that yields a `:asyncio_capability_call`
  # sentinel and waits for the trampoline to resume it with the
  # call's result.  See `Pyex.Stdlib.Asyncio` for how
  # `asyncio.gather` batches a set of these into parallel BEAM
  # Tasks via `Task.async_stream/3`.
  def call_function({:awaitable, fun}, args, _kwargs, env, ctx) do
    {iter_token, ctx} =
      Ctx.new_awaiting_capability_iterator(
        ctx,
        fn cap_id -> {:asyncio_capability_call, cap_id, fun, args} end,
        [{:cont_capability_resume}],
        Env.new()
      )

    {{:coroutine, "<capability>", iter_token}, env, ctx}
  end

  def call_function({:builtin_raw, fun}, args, _kwargs, env, ctx) do
    Invocation.call_builtin_raw(fun, args, env, ctx)
  end

  def call_function({:builtin_type, "dict", _fun}, args, kwargs, env, ctx) do
    Invocation.call_builtin_kw(&Builtins.builtin_dict/2, args, kwargs, env, ctx)
  end

  def call_function({:builtin_type, "int", _fun}, args, kwargs, env, ctx) do
    Invocation.call_builtin_kw(&Builtins.builtin_int/2, args, kwargs, env, ctx)
  end

  def call_function({:builtin_type, _name, fun}, args, kwargs, env, ctx) do
    call_function({:builtin, fun}, args, kwargs, env, ctx)
  end

  # Calling a built-in exception class constructs an instance whose `args`
  # tuple holds the positional arguments, matching CPython semantics.
  def call_function({:exception_class, _name} = cls, args, _kwargs, env, ctx) do
    instance = {:instance, exception_instance_class(cls), %{"args" => {:tuple, args}}}
    {instance, env, ctx}
  end

  def call_function({:builtin_kw, fun}, args, kwargs, env, ctx) do
    Invocation.call_builtin_kw(fun, args, kwargs, env, ctx)
  end

  def call_function(
        {:bound_method, instance, {:function, _, _, _, _, _, _} = func, defining_class},
        args,
        kwargs,
        env,
        ctx
      ) do
    Invocation.call_bound_method(instance, func, defining_class, args, kwargs, env, ctx)
  end

  def call_function(
        {:bound_method, instance, {:function, _, _, _, _, _, _} = func},
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

  def call_function({:class, name, _bases, class_attrs} = class, args, kwargs, env, ctx) do
    case Map.get(class_attrs, "__enum_members__") do
      members when is_list(members) ->
        call_enum_lookup(members, name, args, env, ctx)

      _ ->
        Invocation.call_class(class, name, args, kwargs, env, ctx)
    end
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
  @spec exception_instance_class(pyvalue()) :: pyvalue()
  def exception_instance_class({:exception_class, name}) do
    # Represent a built-in exception class as {:class, name, bases, attrs}
    # so the rest of the interpreter (attribute access, method dispatch,
    # isinstance on user-defined subclasses) can treat it uniformly.
    # The only method we expose is __init__, which replaces self.args
    # with its positional arguments (matches CPython's BaseException).
    bases =
      case Pyex.ExceptionsHierarchy.parent(name) do
        nil -> []
        parent -> [{:exception_class, parent}]
      end

    attrs = %{
      "__name__" => name,
      "__qualname__" => name,
      "__module__" => "builtins",
      "__init__" =>
        {:builtin,
         fn
           [{:instance, cls, inst_attrs} | rest] ->
             # Replaces self.args with the positional args, matching
             # BaseException.__init__.  Returned via {:mutate, ...} so
             # the caller updates the heap cell backing `self`.
             new_instance = {:instance, cls, Map.put(inst_attrs, "args", {:tuple, rest})}
             {:mutate, new_instance, nil}

           _ ->
             nil
         end}
    }

    {:class, name, bases, attrs}
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

  @doc false
  @spec invoke_descriptor_get(pyvalue(), pyvalue(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  # `object.__new__(cls)` — a fresh instance of `cls` with no attributes.
  @spec object_new([pyvalue()]) :: pyvalue()
  defp object_new([{:class, _, _, _} = cls | _]), do: {:instance, cls, %{}}
  defp object_new(_), do: {:exception, "TypeError: object.__new__(X): X is not a type object"}

  def invoke_descriptor_get(value, instance, owner_class, env, ctx) do
    derefed = Ctx.deref(ctx, value)

    case derefed do
      {:property, fget, _, _} when fget != nil ->
        case call_function(fget, [instance], %{}, env, ctx) do
          {val, env, ctx, _} -> {val, env, ctx}
          other -> other
        end

      {:property, nil, _, _} ->
        {{:exception, "AttributeError: unreadable attribute"}, env, ctx}

      {:staticmethod, func} ->
        {func, env, ctx}

      {:classmethod, func} ->
        {{:bound_method, owner_class, func}, env, ctx}

      {:instance, {:class, _, _, _} = desc_class, _} ->
        case ClassLookup.resolve_class_attr(desc_class, "__get__") do
          {:ok, {:function, _, _, _, _, _, _} = func} ->
            result =
              call_function(
                {:bound_method, value, func},
                [instance, owner_class],
                %{},
                env,
                ctx
              )

            normalize_call_result(result)

          _ ->
            {value, env, ctx}
        end

      _ ->
        {value, env, ctx}
    end
  end

  @spec invoke_descriptor_set(pyvalue(), pyvalue(), pyvalue(), Env.t(), Ctx.t()) ::
          {:ok, Env.t(), Ctx.t()} | :no_descriptor
  def invoke_descriptor_set(value, instance, new_value, env, ctx) do
    derefed = Ctx.deref(ctx, value)

    case derefed do
      {:instance, {:class, _, _, _} = desc_class, _} ->
        case ClassLookup.resolve_class_attr(desc_class, "__set__") do
          {:ok, {:function, _, _, _, _, _, _} = func} ->
            result =
              call_function(
                {:bound_method, value, func},
                [instance, new_value],
                %{},
                env,
                ctx
              )

            case normalize_call_result(result) do
              {_val, env, ctx} -> {:ok, env, ctx}
            end

          _ ->
            :no_descriptor
        end

      _ ->
        :no_descriptor
    end
  end

  @spec normalize_call_result(term()) :: eval_result()
  defp normalize_call_result(result) do
    case result do
      {val, env, ctx, _updated} -> {val, env, ctx}
      {val, env, ctx} -> {val, env, ctx}
    end
  end

  @doc false
  @spec builtin_type_attr(String.t(), String.t()) :: {:ok, pyvalue()} | :error
  def builtin_type_attr(name, "__name__"), do: {:ok, name}
  def builtin_type_attr(name, "__qualname__"), do: {:ok, name}
  def builtin_type_attr(_, "__module__"), do: {:ok, "builtins"}
  def builtin_type_attr(_, "__class__"), do: {:ok, Builtins.type_class()}
  def builtin_type_attr(_, "__doc__"), do: {:ok, nil}

  def builtin_type_attr(name, "__mro__") do
    mro = builtin_type_mro_classes(name)
    {:ok, {:tuple, mro}}
  end

  def builtin_type_attr(name, "__bases__") do
    bases = builtin_type_bases_classes(name)
    {:ok, {:tuple, bases}}
  end

  def builtin_type_attr(_, _), do: :error

  @spec builtin_type_mro_classes(String.t()) :: [pyvalue()]
  defp builtin_type_mro_classes(name) do
    object_class = {:class, "object", [], %{"__name__" => "object"}}

    case name do
      "bool" ->
        [
          {:class, "bool", [], %{"__name__" => "bool"}},
          {:class, "int", [], %{"__name__" => "int"}},
          object_class
        ]

      n
      when n in [
             "int",
             "float",
             "str",
             "list",
             "dict",
             "set",
             "frozenset",
             "tuple",
             "bytes",
             "bytearray",
             "complex",
             "range"
           ] ->
        [{:class, n, [], %{"__name__" => n}}, object_class]

      n ->
        [{:class, n, [], %{"__name__" => n}}, object_class]
    end
  end

  @spec builtin_type_bases_classes(String.t()) :: [pyvalue()]
  defp builtin_type_bases_classes("bool"), do: [{:class, "int", [], %{"__name__" => "int"}}]

  defp builtin_type_bases_classes(_),
    do: [{:class, "object", [], %{"__name__" => "object"}}]

  @doc false
  @spec module_attr(String.t(), map(), String.t()) :: {:ok, pyvalue()} | :error
  def module_attr(name, attrs, attr) do
    cond do
      attr == "__name__" ->
        {:ok, Map.get(attrs, "__name__", name)}

      attr == "__class__" ->
        {:ok, {:class, "module", [], %{"__name__" => "module"}}}

      attr == "__dict__" ->
        pairs = Enum.map(attrs, fn {k, v} -> {k, v} end)
        {:ok, PyDict.from_pairs(pairs)}

      attr == "__doc__" ->
        {:ok, Map.get(attrs, "__doc__", nil)}

      true ->
        Map.fetch(attrs, attr)
    end
  end

  @doc false
  @spec forward_method_to_wrapped(map(), String.t()) :: {:ok, pyvalue()} | :not_found
  def forward_method_to_wrapped(inst_attrs, attr) when is_map(inst_attrs) do
    case Map.fetch(inst_attrs, "__wrapped__") do
      {:ok, wrapped} ->
        case Methods.resolve(wrapped, attr) do
          {:ok, method} -> {:ok, method}
          :error -> :not_found
        end

      :error ->
        :not_found
    end
  end

  def forward_method_to_wrapped(_, _), do: :not_found

  # StopIteration.value: the first constructor arg, or None when absent.
  @spec stop_iteration_value(%{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp stop_iteration_value(attrs) do
    case Map.get(attrs, "args") do
      {:tuple, [value | _]} -> value
      _ -> nil
    end
  end

  @spec builtin_type_base_class(pyvalue()) :: pyvalue()
  defp builtin_type_base_class({:builtin_type, name, factory}) do
    # `dict` alone among builtin types accepts kwargs; its factory has a
    # 2-arity signature.  Route it through `builtin_dict/2`.
    init_fn =
      case name do
        "dict" ->
          {:builtin_kw,
           fn
             [{:instance, cls, attrs} | rest], kwargs ->
               case Builtins.builtin_dict(rest, kwargs) do
                 {:exception, _} = exc ->
                   exc

                 wrapped ->
                   {:mutate, {:instance, cls, Map.put(attrs, "__wrapped__", wrapped)}, nil}
               end
           end}

        _ ->
          {:builtin,
           fn
             [{:instance, cls, attrs}] ->
               wrapped = factory.([])
               {:mutate, {:instance, cls, Map.put(attrs, "__wrapped__", wrapped)}, nil}

             [{:instance, cls, attrs} | rest] ->
               case factory.(rest) do
                 {:exception, _} = exc ->
                   exc

                 wrapped ->
                   {:mutate, {:instance, cls, Map.put(attrs, "__wrapped__", wrapped)}, nil}
               end
           end}
      end

    {:class, name, [],
     %{
       "__name__" => name,
       "__qualname__" => name,
       "__module__" => "builtins",
       "__init__" => init_fn
     }}
  end

  @spec subclass_method_override(pyvalue(), String.t()) ::
          {:ok, pyvalue(), pyvalue()} | :not_found
  defp subclass_method_override({:class, _, _, _} = class, attr) do
    # Walk the class in C3-linearization order so diamond inheritance
    # resolves to the correct override.  We only return user-defined
    # Python functions (`{:function, ...}`); stdlib-baked methods live
    # in inst_attrs and are found separately.
    class
    |> ClassLookup.c3_linearize()
    |> Enum.find_value(:not_found, fn
      {:class, _, _, attrs} = cls ->
        case Map.fetch(attrs, attr) do
          {:ok, {:function, _, _, _, _, _, _} = func} -> {:ok, func, cls}
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  @spec exception_class_mro(String.t()) :: [pyvalue()]
  defp exception_class_mro(name) do
    walk = fn n, walk_ref ->
      case Pyex.ExceptionsHierarchy.parent(n) do
        nil -> [{:exception_class, n}]
        parent -> [{:exception_class, n} | walk_ref.(parent, walk_ref)]
      end
    end

    mro = walk.(name, walk)

    # Append `object` to match CPython.
    mro ++ [{:class, "object", [], %{"__name__" => "object"}}]
  end

  @spec exception_class_bases(String.t()) :: [pyvalue()]
  defp exception_class_bases(name) do
    case Pyex.ExceptionsHierarchy.parent(name) do
      nil -> [{:class, "object", [], %{"__name__" => "object"}}]
      parent -> [{:exception_class, parent}]
    end
  end

  @spec canonicalize_map_key(Ctx.t(), pyvalue(), pyvalue()) :: pyvalue()
  defp canonicalize_map_key(ctx, key, {:py_dict, _, _}),
    do: ctx |> Ctx.deep_deref(key) |> PyDict.canonical_key()

  defp canonicalize_map_key(ctx, key, obj) when is_map(obj),
    do: ctx |> Ctx.deep_deref(key) |> PyDict.canonical_key()

  defp canonicalize_map_key(_ctx, key, _obj), do: key

  @spec eval_subscript(pyvalue(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  # Lists shorter than this skip the tuple-cache fast path and stay
  # on the original reverse-cons walk.  Below ~32 elements the walk
  # is cheaper than the cache lookup + bookkeeping, and short-list
  # indexing is rarely a hot path anyway.
  @list_cache_min_len 32

  defp eval_subscript(object, {:slice_obj, start, stop, step}, env, ctx) do
    eval_slice(object, start, stop, step, env, ctx)
  end

  defp eval_subscript(object, key, env, ctx) do
    # Fast path: a heap-stored Python list indexed by an integer key.
    # Storage is reverse-cons (`Enum.at` is O(j) per index), but
    # lists indexed repeatedly promote to a tuple form on the second
    # access (see `Ctx.list_index_lookup/5`), giving O(1) subscript
    # for inner-loop numerical code (SMA windows, z-scores, etc.).
    # Heap-mutating ops invalidate the cache centrally in `heap_put/3`.
    case object do
      {:ref, id} when is_integer(key) ->
        case Map.fetch!(ctx.heap, id) do
          {:py_list, reversed, len} when len >= @list_cache_min_len ->
            cond do
              key < -len or key >= len ->
                {{:exception, "IndexError: list index out of range"}, env, ctx}

              true ->
                forward_idx = if key < 0, do: len + key, else: key
                storage_idx = len - 1 - forward_idx
                {value, ctx} = Ctx.list_index_lookup(ctx, id, forward_idx, reversed, storage_idx)
                {value, env, ctx}
            end

          # Already paid the heap fetch — hand the deref'd value
          # to the slow path so it doesn't fetch a second time.
          derefed_value ->
            eval_subscript_slow(derefed_value, key, env, ctx)
        end

      _ ->
        eval_subscript_slow(object, key, env, ctx)
    end
  end

  # The slow path accepts either a heap ref or an already-deref'd
  # value.  `Ctx.deref/2` is identity for non-refs, so the fast
  # path can pre-deref and the slow path stays correct.
  @spec eval_subscript_slow(pyvalue(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp eval_subscript_slow(object, key, env, ctx) do
    object = Ctx.deref(ctx, object)
    # Canonicalize keys for hash-based lookup so heap-backed instances with
    # matching `__eq__`/`__hash__` resolve to the correct dict/map entry.
    key = canonicalize_map_key(ctx, key, object)

    case object do
      {:py_dict, %{^key => _}, _} ->
        {:ok, value} = PyDict.fetch(object, key)
        {value, env, ctx}

      %{^key => value} ->
        {value, env, ctx}

      {:py_list, reversed, len} when is_integer(key) ->
        # Non-heap py_list — no caching available.  Falls back to the
        # storage-index walk.  Hit rarely in practice; most py_lists
        # live behind a heap ref and take the fast path above.
        index =
          if key < 0 do
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

      {tag, bin} when tag in [:bytes, :bytearray] and is_integer(key) ->
        # Indexing bytes/bytearray yields the integer byte value.
        bytes = :binary.bin_to_list(bin)
        len = length(bytes)
        index = if key < 0, do: len + key, else: key

        if index < 0 or index >= len do
          {{:exception, "IndexError: index out of range"}, env, ctx}
        else
          {Enum.at(bytes, index), env, ctx}
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

      {:py_dict, %{"__counter__" => true}, _} ->
        # Counter.__missing__ returns 0 for any missing key.
        {0, env, ctx}

      val when is_integer(val) or is_float(val) or is_boolean(val) or val == nil ->
        {{:exception, "TypeError: '#{Helpers.py_type(val)}' object is not subscriptable"}, env,
         ctx}

      {:function, _, _, _, _, _, _} ->
        {{:exception, "TypeError: 'function' object is not subscriptable"}, env, ctx}

      _ ->
        {{:exception, "KeyError: #{Builtins.py_repr_quoted(Ctx.deep_deref(ctx, key))}"}, env, ctx}
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

      {tag, bin} when tag in [:bytes, :bytearray] ->
        case py_slice(:binary.bin_to_list(bin), start, stop, step) do
          {:exception, msg} -> {{:exception, msg}, env, ctx}
          result -> {{tag, :binary.list_to_bin(result)}, env, ctx}
        end

      {:range, rs, _, rstep} = r ->
        # Slicing a range yields a range (lazily), as in CPython.
        sstep = step || 1

        if sstep == 0 do
          {{:exception, "ValueError: slice step cannot be zero"}, env, ctx}
        else
          len = Builtins.range_length(r)
          {nstart, nstop} = normalize_slice_bounds(start, stop, sstep, len)
          {{:range, rs + nstart * rstep, rs + nstop * rstep, rstep * sstep}, env, ctx}
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

        # Resolve nested expressions within the spec, e.g. `{w}d` -> `8d`.
        case interpolate_format_spec(format_spec, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {resolved_spec, env, ctx} ->
            case Pyex.Interpreter.FstringFormat.apply_format_spec(val, resolved_spec) do
              {:exception, _} = signal ->
                {signal, env, ctx}

              formatted ->
                eval_fstring(rest, <<acc::binary, formatted::binary>>, env, ctx)
            end
        end
    end
  end

  # Expands `{expr}` inside a format spec by evaluating and stringifying
  # each expression.  Matches CPython's nested f-string spec semantics.
  # Literal `{{` / `}}` still escape to single braces.
  @spec interpolate_format_spec(String.t(), Env.t(), Ctx.t()) ::
          {String.t(), Env.t(), Ctx.t()} | {{:exception, String.t()}, Env.t(), Ctx.t()}
  defp interpolate_format_spec(spec, env, ctx) do
    if String.contains?(spec, "{") do
      case Parser.parse_fstring_template(spec) do
        {:ok, parts} ->
          eval_fstring(parts, <<>>, env, ctx)

        {:error, msg} ->
          {{:exception, "ValueError: invalid format spec: #{msg}"}, env, ctx}
      end
    else
      {spec, env, ctx}
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
          {:ok, [{Parser.unpack_target(), pyvalue()}]} | {:exception, String.t()}
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
          {:ok, [{Parser.unpack_target(), pyvalue()}]} | {:exception, String.t()}
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

  @spec bind_pairs([Parser.unpack_target()], [pyvalue()], [{Parser.unpack_target(), pyvalue()}]) ::
          {:ok, [{Parser.unpack_target(), pyvalue()}]} | {:exception, String.t()}
  defp bind_pairs([], [], acc), do: {:ok, Enum.reverse(acc)}

  defp bind_pairs([name | names], [val | vals], acc) when is_binary(name) do
    bind_pairs(names, vals, [{name, val} | acc])
  end

  defp bind_pairs([{:starred, _} = s | names], [val | vals], acc) do
    bind_pairs(names, vals, [{s, val} | acc])
  end

  defp bind_pairs([{:target, _} = target | names], [val | vals], acc) do
    bind_pairs(names, vals, [{target, val} | acc])
  end

  defp bind_pairs([nested_names | names], [val | vals], acc) when is_list(nested_names) do
    case unpack_nested(val, nested_names) do
      {:ok, pairs} -> bind_pairs(names, vals, Enum.reverse(pairs) ++ acc)
      {:exception, _} = err -> err
    end
  end

  @spec unpack_nested(pyvalue(), [Parser.unpack_target()]) ::
          {:ok, [{Parser.unpack_target(), pyvalue()}]} | {:exception, String.t()}
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
          {:ok, [{Parser.unpack_target(), pyvalue()}]} | {:exception, String.t()}
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
          # `return NotImplemented` from the left dunder defers to the
          # right operand's reflected dunder (CPython's binop protocol).
          {:ok, :not_implemented, env, ctx} ->
            binop_reflected_fallback(op, l, r, env, ctx)

          {:ok, result, env, ctx} ->
            {result, env, ctx}

          :not_found ->
            binop_reflected_fallback(op, l, r, env, ctx)
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
          # A reflected dunder that returns NotImplemented declines too;
          # fall through to the built-in coercion / TypeError path.
          {:ok, :not_implemented, env, ctx} ->
            BinaryOps.binop_result(safe_binop(op, l, r), env, ctx)

          {:ok, result, env, ctx} ->
            {result, env, ctx}

          :not_found ->
            BinaryOps.binop_result(safe_binop(op, l, r), env, ctx)
        end
    end
  end

  defp do_eval_binop(op, {:py_list, la, _}, {:py_list, ra, _}, env, ctx)
       when op in [:eq, :neq] do
    compare_sequence_equality(op, Enum.reverse(la), Enum.reverse(ra), env, ctx)
  end

  defp do_eval_binop(op, {:py_list, la, _}, ra, env, ctx)
       when op in [:eq, :neq] and is_list(ra) do
    compare_sequence_equality(op, Enum.reverse(la), ra, env, ctx)
  end

  defp do_eval_binop(op, la, {:py_list, ra, _}, env, ctx)
       when op in [:eq, :neq] and is_list(la) do
    compare_sequence_equality(op, la, Enum.reverse(ra), env, ctx)
  end

  defp do_eval_binop(op, la, ra, env, ctx)
       when op in [:eq, :neq] and is_list(la) and is_list(ra) do
    compare_sequence_equality(op, la, ra, env, ctx)
  end

  defp do_eval_binop(op, {:tuple, la}, {:tuple, ra}, env, ctx)
       when op in [:eq, :neq] do
    compare_sequence_equality(op, la, ra, env, ctx)
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

  # Left dunder declined (NotImplemented / absent): try the right operand's
  # reflected dunder, then fall back to built-in coercion. Mirrors CPython:
  # `a + b` -> `a.__add__(b)` then `b.__radd__(a)` then TypeError.
  defp binop_reflected_fallback(op, l, r, env, ctx) do
    rdunder = match?({:instance, _, _}, r) && BinaryOps.rdunder_for_op(op)

    if is_binary(rdunder) do
      case Dunder.call_dunder(r, rdunder, [l], env, ctx) do
        {:ok, :not_implemented, env, ctx} ->
          BinaryOps.binop_result(safe_binop(op, l, r), env, ctx)

        {:ok, result, env, ctx} ->
          {result, env, ctx}

        :not_found ->
          BinaryOps.binop_result(safe_binop(op, l, r), env, ctx)
      end
    else
      BinaryOps.binop_result(safe_binop(op, l, r), env, ctx)
    end
  end

  @spec compare_sequence_equality(atom(), [pyvalue()], [pyvalue()], Env.t(), Ctx.t()) ::
          eval_result()
  defp compare_sequence_equality(op, la, ra, env, ctx) when length(la) == length(ra) do
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

  defp compare_sequence_equality(op, la, ra, env, ctx) when length(la) != length(ra) do
    {op == :neq, env, ctx}
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
    # Elements may be heap refs (identity-preserving materializers pass
    # them shallow). Detect instances and order by the dereferenced value,
    # but keep the original elements in the result so identity survives.
    has_instances? = Enum.any?(items, &match?({:instance, _, _}, Ctx.deref(ctx, &1)))

    sorted =
      case key_fn do
        nil when has_instances? ->
          case sort_with_lt(items, env, ctx) do
            {:ok, sorted, env, ctx} when reverse -> {:ok, Enum.reverse(sorted), env, ctx}
            other -> other
          end

        nil ->
          order = if reverse, do: :desc, else: :asc
          {:ok, Enum.sort_by(items, &Ctx.deep_deref(ctx, &1), order), env, ctx}

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

  @spec builtin_exception_base_stub(String.t()) :: pyvalue() | nil
  defp builtin_exception_base_stub(name) do
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

  @doc false
  @spec eval_super(Env.t(), Ctx.t()) :: eval_result()
  def eval_super(env, ctx) do
    case Env.get(env, "self") do
      {:ok, raw_self} ->
        case Ctx.deref(ctx, raw_self) do
          {:instance, inst_class, _} = instance ->
            super_proxy_for(instance, inst_class, env, ctx)

          _ ->
            super_from_class_arg(env, ctx)
        end

      _ ->
        super_from_class_arg(env, ctx)
    end
  end

  # `super()` inside `__new__`/classmethods: there is no `self`, but the first
  # positional arg is the class (conventionally `cls`). Bind the proxy to it.
  @spec super_from_class_arg(Env.t(), Ctx.t()) :: eval_result()
  defp super_from_class_arg(env, ctx) do
    case Env.get(env, "cls") do
      {:ok, {:class, _, _, _} = cls} ->
        super_proxy_for(cls, cls, env, ctx)

      _ ->
        {{:exception, "RuntimeError: super(): self is not bound"}, env, ctx}
    end
  end

  # Build a super proxy bound to `bound` (an instance or class) whose method
  # lookup walks `derived`'s MRO starting just past the enclosing `__class__`.
  @spec super_proxy_for(pyvalue(), pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp super_proxy_for(bound, derived, env, ctx) do
    case Env.get(env, "__class__") do
      {:ok, {:class, _, _, _} = current_class} ->
        # Use the MRO of the actual class, then drop everything up to and
        # including current_class. This is how Python's super() enables
        # cooperative multiple inheritance.
        mro = ClassLookup.c3_linearize(derived)
        mro_tail = Enum.drop_while(mro, &(&1 != current_class)) |> Enum.drop(1)

        # An empty tail means the only ancestor left is the implicit `object`
        # (which c3_linearize does not list). Keep the proxy so `object`'s
        # `__new__`/`__init__` still resolve through the fallback below.
        {{:super_proxy, bound, mro_tail}, env, ctx}

      _ ->
        {{:exception, "RuntimeError: super(): __class__ is not set"}, env, ctx}
    end
  end

  @spec yield_from_deferred([pyvalue()], Env.t(), Ctx.t()) :: eval_result()
  defp yield_from_deferred([], env, ctx), do: {nil, env, ctx}

  defp yield_from_deferred([item | rest], env, ctx) do
    {{:yielded, item, [{:cont_yield_from, rest}]}, env, ctx}
  end

  @spec yield_from_general(pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp yield_from_general(iterable, env, ctx) do
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

  @doc """
  Finalize every still-suspended generator at turn end — CPython's
  interpreter-shutdown behavior, where a generator left paused has
  `GeneratorExit` thrown into it so its `finally`/`with` cleanup runs.

  Ordering matches CPython shutdown: ascending iterator id (creation order).
  `yield from` delegation falls out for free — finalizing the (lower-id) outer
  generator propagates `GeneratorExit` into the inner one, so the inner
  `finally` runs first and the inner is already done when its own (higher) id
  comes up. A cleanup block that raises is swallowed (CPython prints "Exception
  ignored" and continues finalizing the rest); the turn result is unaffected.

  NOTE: this is the *shutdown* timing only. CPython also finalizes a generator
  the instant its last reference drops (refcount GC) — observable as cleanup
  running mid-script. That timing is a CPython implementation detail (not a
  language guarantee, and not shared by e.g. PyPy) and is not reproducible in
  Pyex's reference-free value model, so it is intentionally not emulated.
  """
  @spec finalize_suspended_generators(Ctx.t()) :: Ctx.t()
  def finalize_suspended_generators(%Ctx{} = ctx) do
    suspended_ids =
      ctx.iterators
      |> Enum.filter(fn {_id, entry} -> match?({:gen_sync, _, _, _}, entry) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case suspended_ids do
      [] ->
        ctx

      ids ->
        env = Builtins.runtime_env(ctx)
        Enum.reduce(ids, ctx, fn id, ctx -> finalize_one_generator(id, env, ctx) end)
    end
  end

  @spec finalize_one_generator(non_neg_integer(), Env.t(), Ctx.t()) :: Ctx.t()
  defp finalize_one_generator(id, env, ctx) do
    case Ctx.iter_entry(ctx, id) do
      {:gen_sync, _started?, cont, gen_env} ->
        exit_inst =
          {:instance, exception_instance_class({:exception_class, "GeneratorExit"}),
           %{"args" => {:tuple, []}}}

        ctx = %{ctx | exception_instance: exit_inst}

        # Run the cleanup. The result (a propagated GeneratorExit, a different
        # exception raised by the cleanup, or even a re-yield) is discarded —
        # the generator is done either way.
        {_result, _env, ctx} =
          Pyex.Interpreter.BuiltinResults.advance_gen_sync(
            id,
            cont,
            gen_env,
            {:throw, "GeneratorExit"},
            env,
            ctx
          )

        Ctx.mark_iter_exhausted(ctx, id)

      _ ->
        # Already finalized (e.g. an inner `yield from` target closed while
        # finalizing its outer generator).
        ctx
    end
  end

  @doc """
  Lazy `yield from` over a generator iterator. Yields the first
  pending value, then attaches a `:cont_yield_from_iter` frame so the
  generator advances one step at a time on resumption — preserving
  side-effect ordering and partial-yield-then-error semantics.
  """
  @spec yield_from_gen_iter(non_neg_integer(), Env.t(), Ctx.t()) :: eval_result()
  def yield_from_gen_iter(id, env, ctx) do
    case Pyex.Ctx.iter_entry(ctx, id) do
      {:gen_sync, _started?, cont, gen_env} ->
        # Lazy delegation: advance the sub-generator to its first yield. If it
        # yields, propagate the value out of the outer generator and attach a
        # `:cont_yield_from_iter` frame so subsequent next()/send()/throw()
        # route through the sub-generator (PEP 380). If it finishes
        # immediately, `yield from` evaluates to the sub's return value.
        case Pyex.Interpreter.BuiltinResults.advance_gen_sync_raw(id, cont, gen_env, :next, ctx) do
          {:yield, val, _c, _e, ctx} ->
            {{:yielded, val, [{:cont_yield_from_iter, id}]}, env, ctx}

          {:return, return_value, ctx} ->
            {return_value, env, ctx}

          {:exhausted, ctx} ->
            {nil, env, ctx}

          {:raise, msg, ctx} ->
            {{:exception, msg}, env, ctx}
        end

      {:gen_pending, val, _cont, _gen_env} ->
        {{:yielded, val, [{:cont_yield_from_iter, id}]}, env, ctx}

      :gen_done ->
        {nil, env, ctx}

      _ ->
        {nil, env, ctx}
    end
  end

  # Thread one resumed step of a delegated `yield from` sub-generator into the
  # outer continuation `rest`. Used by the `:cont_yield_from_iter` resume
  # clauses (next/send/throw).
  @spec yield_from_step(
          non_neg_integer(),
          {:yield, pyvalue(), [cont_frame()], Env.t(), Ctx.t()}
          | {:return, pyvalue(), Ctx.t()}
          | {:exhausted, Ctx.t()}
          | {:raise, String.t(), Ctx.t()},
          [cont_frame()],
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp yield_from_step(id, step, rest, env, _ctx) do
    case step do
      {:yield, val, _new_cont, _new_gen_env, ctx} ->
        {{:yielded, val, [{:cont_yield_from_iter, id}] ++ rest}, env, ctx}

      {:return, return_value, ctx} ->
        # PEP 380: `x = yield from sub()` evaluates to the sub's return value.
        resume_generator_with_send(rest, env, ctx, return_value)

      {:exhausted, ctx} ->
        resume_generator(rest, env, ctx)

      {:raise, msg, ctx} ->
        # Exception escaped the sub-generator: re-raise it at the delegation
        # point inside the outer generator (caught by its enclosing try, if any).
        resume_generator_with_throw(rest, env, ctx, msg)
    end
  end

  @type cont_frame ::
          {:cont_stmts, [Parser.ast_node()]}
          | {:cont_for, String.t() | [String.t()], [pyvalue()], [Parser.ast_node()],
             [Parser.ast_node()] | nil}
          | {:cont_while, Parser.ast_node(), [Parser.ast_node()], [Parser.ast_node()] | nil}
          | {:cont_yield_from, [pyvalue()]}
          | {:cont_yield_from_iter, non_neg_integer()}
          | {:cont_try, [cont_frame()],
             [{String.t() | nil, String.t() | nil, [Parser.ast_node()]}],
             [Parser.ast_node()] | nil, [Parser.ast_node()] | nil}
          | {:cont_for_gen_iter, String.t(), non_neg_integer(), [Parser.ast_node()],
             [Parser.ast_node()] | nil}
          | {:cont_bind_sent, String.t()}
          | {:cont_await_iter, non_neg_integer()}
          | {:cont_return_value}
          | {:cont_capability_resume}
          | {:cont_call_resume, pyvalue(), term(), [Parser.ast_node()], [pyvalue()],
             [Parser.ast_node()], map(), Calls.arg_slot()}

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
          | {{:done_with_value, pyvalue()}, Env.t(), Ctx.t()}
          | {{:exception, String.t()}, Env.t(), Ctx.t()}
  def resume_generator([], env, ctx), do: {:done, env, ctx}

  def resume_generator([{:cont_bind_sent, name} | rest], env, ctx) do
    # next() resumes with sent_value = nil (Python semantics)
    env = Env.smart_put(env, name, nil)
    resume_generator(rest, env, ctx)
  end

  def resume_generator([{:cont_call_resume, _, _, _, _, _, _, _} | _] = cont, env, ctx) do
    # A `yield` suspended inside a function call's arguments (e.g.
    # `f((yield x))`). `next()` == `send(None)`: resume the call with nil.
    resume_generator_with_send(cont, env, ctx, nil)
  end

  def resume_generator([{:cont_return_value} | _rest], env, ctx) do
    # `return await coro` resumed with no sent value (e.g. via
    # plain next()): treat as the function returning None.
    {{:done_with_value, nil}, env, ctx}
  end

  def resume_generator([{:cont_capability_resume} | _rest], env, ctx) do
    # Capability iter resumed without a sent value — terminate the
    # cap iter with nil as its return value.  (Shouldn't happen in
    # normal use; the trampoline always supplies a result via
    # `resume_generator_with_send`.)
    {{:done_with_value, nil}, env, ctx}
  end

  def resume_generator([{:cont_stmts, stmts} | rest], env, ctx) do
    case eval_statements(stmts, env, ctx) do
      {{:yielded, val, inner_cont}, env, ctx} ->
        {{:yielded, val, inner_cont ++ rest}, env, ctx}

      {{:returned, value}, env, ctx} ->
        # PEP 380: a generator's `return value` becomes the value of
        # `yield from` — and PEP 492 inherits this for `await`.
        # Surfaced via `{:done_with_value, value}`; legacy callers
        # that match `:done` keep working (value defaults to nil).
        {{:done_with_value, value}, env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {_, env, ctx} ->
        resume_generator(rest, env, ctx)
    end
  end

  # Resume a generator suspended at a `yield` inside a try. Run the rest of the
  # try body; if it yields again, stay inside the try; otherwise apply the
  # except/else/finally and continue the outer continuation. This is what makes
  # try/finally generators lazy (finally at exit, not at the yield).
  def resume_generator(
        [{:cont_try, body_cont, handlers, else_body, finally_body} | rest],
        env,
        ctx
      ) do
    case resume_generator(body_cont, env, ctx) do
      {{:yielded, val, inner_cont}, env, ctx} ->
        {{:yielded, val, [{:cont_try, inner_cont, handlers, else_body, finally_body}] ++ rest},
         env, ctx}

      body_result ->
        ControlFlow.finish_try(body_result, handlers, else_body, finally_body)
        |> continue_after_try(rest)
    end
  end

  def resume_generator([{:cont_for, var, items, body, else_body} | rest], env, ctx) do
    case ControlFlow.eval_for_items(var, items, body, else_body, env, ctx) do
      {{:yielded, val, inner_cont}, env, ctx} ->
        {{:yielded, val, inner_cont ++ rest}, env, ctx}

      {{:returned, value}, env, ctx} ->
        {{:done_with_value, value}, env, ctx}

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

      {{:returned, value}, env, ctx} ->
        {{:done_with_value, value}, env, ctx}

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

  def resume_generator(
        [{:cont_for_gen_iter, var_name, id, body, else_body} | rest],
        env,
        ctx
      ) do
    case ControlFlow.resume_for_gen_iter(var_name, id, body, else_body, env, ctx) do
      {{:yielded, val, inner_cont}, env, ctx} ->
        {{:yielded, val, inner_cont ++ rest}, env, ctx}

      {{:returned, value}, env, ctx} ->
        {{:done_with_value, value}, env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {_, env, ctx} ->
        resume_generator(rest, env, ctx)
    end
  end

  # Resume an in-progress `await`: advance the awaited iterator one
  # more step.  If it yields again, propagate the yield up with this
  # frame reattached.  If it completes, surface the StopIteration
  # value as the "sent value" to the rest of the continuation — that
  # way `r = await coro` lands the return value in `r` via the
  # existing `:cont_bind_sent` machinery.
  def resume_generator([{:cont_await_iter, id} | rest], env, ctx) do
    case Invocation.continue_await(id, env, ctx) do
      {{:yielded, val, inner_cont}, env, ctx} ->
        {{:yielded, val, inner_cont ++ rest}, env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {return_value, env, ctx} ->
        # Send the return value back into the surrounding context
        # (cont_bind_sent will pick it up if there's an assign).
        resume_generator_with_send(rest, env, ctx, return_value)
    end
  end

  def resume_generator([{:cont_yield_from_iter, id} | rest], env, ctx) do
    # Advance the source generator one step (next == send nil). On yield,
    # propagate and stay delegating. On done, feed the return value into the
    # rest of the outer continuation (PEP 380). On exception, re-raise it at
    # the delegation point.
    saved_mode = ctx.generator_mode
    inner_ctx = %{ctx | generator_mode: :defer_inner}

    case Pyex.Ctx.iter_entry(ctx, id) do
      {:gen_sync, _started?, cont, gen_env} ->
        step = Pyex.Interpreter.BuiltinResults.advance_gen_sync_raw(id, cont, gen_env, :next, ctx)
        yield_from_step(id, step, rest, env, ctx)

      {:gen_pending, _val, cont, gen_env} ->
        case resume_generator(cont, gen_env, inner_ctx) do
          {{:yielded, val, next_cont}, next_gen_env, ctx} ->
            ctx = %{ctx | generator_mode: saved_mode}
            ctx = Pyex.Ctx.set_gen_pending(ctx, id, val, next_cont, next_gen_env)
            {{:yielded, val, [{:cont_yield_from_iter, id}] ++ rest}, env, ctx}

          {{:done_with_value, return_value}, _gen_env, ctx} ->
            ctx = %{ctx | generator_mode: saved_mode}
            ctx = Pyex.Ctx.mark_iter_done_with_value(ctx, id, return_value)
            # PEP 380: `r = yield from sub()` evaluates to the sub-generator's
            # return value, so feed it into the outer continuation as the value
            # of the yield-from expression (a bare `yield from` ignores it).
            resume_generator_with_send(rest, env, ctx, return_value)

          {:done, _gen_env, ctx} ->
            ctx = %{ctx | generator_mode: saved_mode}
            ctx = Pyex.Ctx.mark_iter_exhausted(ctx, id)
            resume_generator(rest, env, ctx)

          {{:exception, _} = signal, _gen_env, ctx} ->
            ctx = %{ctx | generator_mode: saved_mode}
            ctx = Pyex.Ctx.mark_iter_exhausted(ctx, id)
            {signal, env, ctx}
        end

      :gen_done ->
        resume_generator(rest, env, ctx)

      _ ->
        resume_generator(rest, env, ctx)
    end
  end

  # Thread a try's resolved result into the outer continuation: re-yield (from a
  # handler/finally), propagate a return, keep throwing an uncaught exception
  # through outer trys, or continue normally.
  @spec continue_after_try(eval_result(), [cont_frame()]) :: eval_result()
  defp continue_after_try({{:yielded, val, c}, env, ctx}, rest),
    do: {{:yielded, val, c ++ rest}, env, ctx}

  defp continue_after_try({{:exception, msg}, env, ctx}, rest),
    do: resume_generator_with_throw(rest, env, ctx, msg)

  defp continue_after_try({{:done_with_value, _} = d, env, ctx}, _rest), do: {d, env, ctx}

  defp continue_after_try({{:returned, v}, env, ctx}, _rest),
    do: {{:done_with_value, v}, env, ctx}

  defp continue_after_try({_, env, ctx}, rest), do: resume_generator(rest, env, ctx)

  @doc false
  # Resume a generator by raising an exception at its current suspension point
  # (the `throw()`/`close()` path). The exception propagates through the
  # continuation, caught by the first enclosing try whose handler matches.
  @spec resume_generator_with_throw([cont_frame()], Env.t(), Ctx.t(), String.t()) ::
          {{:yielded, pyvalue(), [cont_frame()]}, Env.t(), Ctx.t()}
          | {:done, Env.t(), Ctx.t()}
          | {{:done_with_value, pyvalue()}, Env.t(), Ctx.t()}
          | {{:exception, String.t()}, Env.t(), Ctx.t()}
  def resume_generator_with_throw([], env, ctx, exc_msg), do: {{:exception, exc_msg}, env, ctx}

  def resume_generator_with_throw(
        [{:cont_try, body_cont, handlers, else_body, finally_body} | rest],
        env,
        ctx,
        exc_msg
      ) do
    # The suspension may be nested *inside* this try (e.g. an inner try, whose
    # finally must run first). Throw into the body continuation first; whatever
    # it produces then passes through this try's except/finally. (Throwing into
    # an empty body_cont yields `{:exception, exc_msg}`, so a flat try still
    # runs its own handler/finally — same as the old throw_into_try path.)
    case resume_generator_with_throw(body_cont, env, ctx, exc_msg) do
      {{:yielded, val, inner_cont}, env, ctx} ->
        {{:yielded, val, [{:cont_try, inner_cont, handlers, else_body, finally_body}] ++ rest},
         env, ctx}

      body_result ->
        ControlFlow.finish_try(body_result, handlers, else_body, finally_body)
        |> continue_after_try(rest)
    end
  end

  def resume_generator_with_throw([{:cont_yield_from_iter, id} | rest], env, ctx, exc_msg) do
    # throw() into a generator suspended at `yield from sub`: per PEP 380, the
    # exception is thrown into the sub-generator first.
    case Pyex.Ctx.iter_entry(ctx, id) do
      {:gen_sync, _started?, cont, gen_env} ->
        step =
          Pyex.Interpreter.BuiltinResults.advance_gen_sync_raw(
            id,
            cont,
            gen_env,
            {:throw, exc_msg},
            ctx
          )

        yield_from_step(id, step, rest, env, ctx)

      _ ->
        resume_generator_with_throw(rest, env, ctx, exc_msg)
    end
  end

  def resume_generator_with_throw([_frame | rest], env, ctx, exc_msg),
    do: resume_generator_with_throw(rest, env, ctx, exc_msg)

  @doc false
  @spec resume_generator_with_send([cont_frame()], Env.t(), Ctx.t(), pyvalue()) ::
          {{:yielded, pyvalue(), [cont_frame()]}, Env.t(), Ctx.t()}
          | {:done, Env.t(), Ctx.t()}
          | {{:done_with_value, pyvalue()}, Env.t(), Ctx.t()}
          | {{:exception, String.t()}, Env.t(), Ctx.t()}
  def resume_generator_with_send([{:cont_bind_sent, name} | rest], env, ctx, sent_value) do
    env = Env.smart_put(env, name, sent_value)
    resume_generator(rest, env, ctx)
  end

  def resume_generator_with_send(
        [{:cont_try, body_cont, handlers, else_body, finally_body} | rest],
        env,
        ctx,
        sent_value
      ) do
    # A generator suspended at a `yield` *inside* a try has `:cont_try` as its
    # outermost frame. Thread the sent value into the try body's continuation
    # (where the `:cont_bind_sent` lives) rather than dropping it; re-apply the
    # except/else/finally when the body resumes past the yield.
    case resume_generator_with_send(body_cont, env, ctx, sent_value) do
      {{:yielded, val, inner_cont}, env, ctx} ->
        {{:yielded, val, [{:cont_try, inner_cont, handlers, else_body, finally_body}] ++ rest},
         env, ctx}

      body_result ->
        ControlFlow.finish_try(body_result, handlers, else_body, finally_body)
        |> continue_after_try(rest)
    end
  end

  def resume_generator_with_send([{:cont_return_value} | _rest], env, ctx, sent_value) do
    # `return await coro` resumed with the awaited value via
    # `:cont_await_iter` -> `resume_generator_with_send`.  The sent
    # value IS what the function returns.
    {{:done_with_value, sent_value}, env, ctx}
  end

  def resume_generator_with_send([{:cont_capability_resume} | _rest], env, ctx, sent_value) do
    # Capability resolved to `sent_value`.  Terminate the cap
    # coroutine with `sent_value` as its return — the await on the
    # cap coroutine will then surface that as the await
    # expression's result via the standard `:cont_await_iter` ->
    # `resume_generator_with_send` path on the outer cont.
    {{:done_with_value, sent_value}, env, ctx}
  end

  def resume_generator_with_send(
        [{:cont_call_resume, func, meta, orig_args, rev_pos, remaining, kwargs, slot} | rest],
        env,
        ctx,
        sent_value
      ) do
    case Calls.incorporate_value(slot, sent_value, rev_pos, kwargs, env, ctx) do
      {:ok, new_rev_pos, new_kwargs, env, ctx} ->
        case Calls.eval_remaining_and_call(
               func,
               meta,
               orig_args,
               remaining,
               new_rev_pos,
               new_kwargs,
               env,
               ctx
             ) do
          {{:yielded, val, inner_cont}, env, ctx} ->
            {{:yielded, val, inner_cont ++ rest}, env, ctx}

          {{:exception, _} = sig, env, ctx} ->
            {sig, env, ctx}

          {val, env, ctx} ->
            resume_generator_with_send(rest, env, ctx, val)
        end

      {:error, signal, env, ctx} ->
        {signal, env, ctx}
    end
  end

  def resume_generator_with_send([{:cont_yield_from_iter, id} | rest], env, ctx, sent_value) do
    # send() into a generator suspended at `yield from sub`: PEP 380 routes the
    # value into the sub-generator's own suspended `yield`.
    case Pyex.Ctx.iter_entry(ctx, id) do
      {:gen_sync, _started?, cont, gen_env} ->
        step =
          Pyex.Interpreter.BuiltinResults.advance_gen_sync_raw(
            id,
            cont,
            gen_env,
            {:send, sent_value},
            ctx
          )

        yield_from_step(id, step, rest, env, ctx)

      _ ->
        resume_generator([{:cont_yield_from_iter, id} | rest], env, ctx)
    end
  end

  def resume_generator_with_send(cont, env, ctx, _sent_value) do
    resume_generator(cont, env, ctx)
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
        # A decorator that transforms a class produces a new class value (same
        # __id__); re-register so instances resolve to the decorated version.
        ctx = Ctx.register_class(ctx, return_value)
        {nil, smart_put_decorated(new_env, name, return_value), ctx}

      {:mutate, _new_object, return_value, ctx} ->
        ctx = Ctx.register_class(ctx, return_value)
        {nil, smart_put_decorated(env, name, return_value), ctx}

      {{:register_route, method, path, handler}, env, ctx} ->
        env = register_route(decorator_expr, method, path, handler, env)
        {nil, smart_put_decorated(env, name, handler), ctx}

      {result, env, ctx, _updated_func} ->
        ctx = Ctx.register_class(ctx, result)
        {nil, smart_put_decorated(env, name, result), ctx}

      {result, env, ctx} ->
        ctx = Ctx.register_class(ctx, result)
        {nil, smart_put_decorated(env, name, result), ctx}
    end
  end

  # Writes the decorated value to `name` AND rewrites any recursive
  # self-reference inside the wrapped function's closure to point to the
  # decorated form.  Without this, calling the decorated function
  # propagates the stale (undecorated) reference from the function's
  # closure back to the caller's global scope, defeating lru_cache and
  # other stateful wrappers.
  @spec smart_put_decorated(Env.t(), String.t(), pyvalue()) :: Env.t()
  defp smart_put_decorated(env, name, decorated) do
    patched = rewrite_self_reference(decorated, name, decorated)
    Env.smart_put(env, name, patched)
  end

  @spec rewrite_self_reference(pyvalue(), String.t(), pyvalue()) :: pyvalue()
  defp rewrite_self_reference(
         {:lru_cached_function, {:function, fname, params, body, closure_env, is_generator, kind},
          cache_id},
         name,
         decorated
       ) do
    {:lru_cached_function,
     {:function, fname, params, body, Env.put_global(closure_env, name, decorated), is_generator,
      kind}, cache_id}
  end

  defp rewrite_self_reference(
         {:function, fname, params, body, closure_env, is_generator, kind},
         name,
         decorated
       ) do
    {:function, fname, params, body, Env.put_global(closure_env, name, decorated), is_generator,
     kind}
  end

  defp rewrite_self_reference({:partial, inner, args, kwargs}, name, decorated) do
    {:partial, rewrite_self_reference(inner, name, decorated), args, kwargs}
  end

  defp rewrite_self_reference(other, _name, _decorated), do: other

  @spec with_context_var(Parser.ast_node()) :: String.t() | nil
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

        {name, :pos_only_sep} ->
          {{name, :pos_only_sep}, ctx}

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

  @spec enum_base?([pyvalue()]) :: boolean()
  defp enum_base?(bases) do
    Enum.any?(bases, fn
      {:class, "Enum", _, _} -> true
      {:class, "IntEnum", _, _} -> true
      {:class, _, inner_bases, _} -> enum_base?(inner_bases)
      _ -> false
    end)
  end

  # Transforms an `enum.Enum` subclass: each class-level value assignment
  # becomes a singleton instance with `.name` and `.value`.  The class
  # also gains `__enum_members__` (ordered list) and a callable form
  # `Color(1) -> Color.RED` for value lookup.
  @spec transform_enum_class(pyvalue(), [String.t()]) :: pyvalue()
  defp transform_enum_class({:class, name, bases, attrs}, body_order) do
    {members_map, rest} =
      Enum.split_with(attrs, fn {k, v} -> enum_member_value?(k, v) end)

    members_map = Map.new(members_map)

    # Order members by the sequence they appeared in the class body.
    members =
      body_order
      |> Enum.filter(&Map.has_key?(members_map, &1))
      |> Enum.map(fn n -> {n, Map.fetch!(members_map, n)} end)

    class_skeleton = {:class, name, bases, Map.new(rest)}

    member_instances =
      Enum.map(members, fn {member_name, value} ->
        instance = {:instance, class_skeleton, enum_member_attrs(member_name, value)}
        {member_name, instance}
      end)

    finalize_enum_class(name, bases, rest, member_instances)
  end

  # Extracts the order of top-level name assignments in a class body,
  # preserving the source-code sequence needed for enum iteration.
  @spec body_assignment_order([Parser.ast_node()]) :: [String.t()]
  defp body_assignment_order(body) do
    Enum.flat_map(body, fn
      {:assign, _, [name, _]} when is_binary(name) -> [name]
      {:assign, _, [{:var, _, [name]}, _]} -> [name]
      {:ann_assign, _, [name, _, _]} when is_binary(name) -> [name]
      {:ann_assign, _, [{:var, _, [name]}, _, _]} -> [name]
      {:def, _, [name, _, _]} -> [name]
      {:class, _, [name, _, _]} -> [name]
      {:decorated_def, _, [_, inner]} -> body_assignment_order([inner])
      _ -> []
    end)
  end

  @spec finalize_enum_class(
          String.t(),
          [pyvalue()],
          list(),
          [{String.t(), pyvalue()}]
        ) :: pyvalue()
  defp finalize_enum_class(name, bases, rest_attrs, member_instances) do
    attrs_map =
      rest_attrs
      |> Map.new()
      |> Map.put("__enum_members__", member_instances)

    # Add members as attributes once so lookups work before we rewrite
    # their class pointer below.
    attrs_map =
      Enum.reduce(member_instances, attrs_map, fn {n, inst}, acc -> Map.put(acc, n, inst) end)

    final_class = {:class, name, bases, attrs_map}

    final_members =
      Enum.map(member_instances, fn {n, {:instance, _, inst_attrs}} ->
        {n, {:instance, final_class, inst_attrs}}
      end)

    final_attrs =
      Enum.reduce(final_members, attrs_map, fn {n, inst}, acc -> Map.put(acc, n, inst) end)
      |> Map.put("__enum_members__", final_members)

    {:class, name, bases, final_attrs}
  end

  @spec enum_member_value?(String.t(), pyvalue()) :: boolean()
  defp enum_member_value?("__" <> _, _), do: false

  defp enum_member_value?(_name, v) do
    case v do
      v when is_number(v) -> true
      v when is_binary(v) -> true
      true -> true
      false -> true
      nil -> false
      {:tuple, _} -> true
      {:py_list, _, _} -> true
      _ -> false
    end
  end

  @spec enum_member_attrs(String.t(), pyvalue()) :: map()
  defp enum_member_attrs(name, value) do
    %{
      "name" => name,
      "value" => value,
      "_name_" => name,
      "_value_" => value
    }
  end

  @spec call_enum_lookup([{String.t(), pyvalue()}], String.t(), [pyvalue()], Env.t(), Ctx.t()) ::
          call_result()
  defp call_enum_lookup(members, class_name, [value], env, ctx) do
    case Enum.find(members, fn {_n, {:instance, _, attrs}} -> Map.get(attrs, "value") == value end) do
      nil ->
        {{:exception, "ValueError: #{inspect(value)} is not a valid #{class_name}"}, env, ctx}

      {_n, inst} ->
        {inst, env, ctx}
    end
  end

  defp call_enum_lookup(_members, class_name, _args, env, ctx) do
    {{:exception, "TypeError: #{class_name}() takes exactly 1 argument"}, env, ctx}
  end

  # CPython's unary `-` and `+` on Decimal go through the context, which
  # strips the sign from a zero result (per IEEE). So `-Decimal('0.00')`
  # and `+Decimal('-0.00')` both return Decimal('0.00') under the default
  # context. `copy_negate` is the sign-preserving alternative.
  defp decimal_unary_neg(%Decimal{coef: :NaN} = d), do: %{d | sign: -d.sign}

  defp decimal_unary_neg(%Decimal{coef: 0} = d),
    do: %{d | sign: 1} |> Decimal.apply_context()

  defp decimal_unary_neg(%Decimal{} = d), do: Decimal.negate(d) |> Decimal.apply_context()

  defp decimal_unary_pos(%Decimal{coef: :NaN} = d), do: d

  defp decimal_unary_pos(%Decimal{coef: 0} = d),
    do: %{d | sign: 1} |> Decimal.apply_context()

  defp decimal_unary_pos(%Decimal{} = d), do: Decimal.apply_context(d)
end
