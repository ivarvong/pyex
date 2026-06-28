defmodule Pyex.Interpreter.Bindings do
  @moduledoc """
  Variable binding and annotation evaluation helpers for `Pyex.Interpreter`.

  Keeps plain-name assignment semantics together so the main interpreter can
  focus on dispatch while preserving the existing public API.
  """

  alias Pyex.{Ctx, Env, Interpreter, Parser}
  alias Pyex.Interpreter.Assignments

  @typep eval_result :: {Interpreter.pyvalue() | tuple(), Env.t(), Ctx.t()}

  @doc """
  Evaluates `global` declarations.
  """
  @spec eval_global([String.t()], Env.t(), Ctx.t()) :: eval_result()
  def eval_global(names, env, ctx) do
    env = Enum.reduce(names, env, &Env.declare_global(&2, &1))
    {nil, env, ctx}
  end

  @doc """
  Evaluates `nonlocal` declarations.
  """
  @spec eval_nonlocal([String.t()], Env.t(), Ctx.t()) :: eval_result()
  def eval_nonlocal(names, env, ctx) do
    env = Enum.reduce(names, env, &Env.declare_nonlocal(&2, &1))
    {nil, env, ctx}
  end

  @doc """
  Evaluates a simple variable assignment.
  """
  @spec eval_assign(String.t(), Parser.ast_node(), Env.t(), Ctx.t()) :: eval_result()
  def eval_assign(name, expr, env, ctx) do
    case Interpreter.eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {{:yielded, val, cont}, env, ctx} ->
        # A yielding expression on the RHS of an assignment.  Two
        # shapes:
        #
        #   `x = yield val`  — `cont` is empty.  On resume via .send,
        #     the sent value is the result of the yield expression and
        #     is bound to `name`.
        #
        #   `x = await coro` — `cont` already has `:cont_await_iter`
        #     (and maybe nested frames) that drive the coroutine to
        #     completion before any value is available to bind.
        #
        # The bind frame must run AFTER the existing cont — append,
        # don't prepend.  When `:cont_await_iter` finishes, it routes
        # its `:done_with_value` through `resume_generator_with_send`
        # with the awaited value as the sent value, which is exactly
        # what `:cont_bind_sent` consumes.
        {{:yielded, val, cont ++ [{:cont_bind_sent, name}]}, env, ctx}

      {value, env, ctx} ->
        {value, Env.smart_put(env, name, value), ctx}
    end
  end

  @doc """
  Evaluates an annotated assignment without an initial value.
  """
  @spec eval_annotated_declaration(String.t(), String.t(), Env.t(), Ctx.t()) :: eval_result()
  def eval_annotated_declaration(name, type_str, env, ctx) do
    annotations = current_annotations(env)
    resolved = Interpreter.resolve_annotation(type_str, env)
    env = Env.smart_put(env, "__annotations__", Map.put(annotations, name, resolved))
    env = Env.smart_put(env, "__annotations_order__", update_annotation_order(env, name))
    {nil, env, ctx}
  end

  @doc """
  Evaluates an annotated assignment with a value.
  """
  @spec eval_annotated_assign(String.t(), String.t(), Parser.ast_node(), Env.t(), Ctx.t()) ::
          eval_result()
  def eval_annotated_assign(name, type_str, expr, env, ctx) do
    case Interpreter.eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        annotations = current_annotations(env)
        resolved = Interpreter.resolve_annotation(type_str, env)
        env = Env.smart_put(env, "__annotations__", Map.put(annotations, name, resolved))
        env = Env.smart_put(env, "__annotations_order__", update_annotation_order(env, name))
        {value, Env.smart_put(env, name, value), ctx}
    end
  end

  @doc """
  Evaluates a walrus assignment.
  """
  @spec eval_walrus(String.t(), Parser.ast_node(), Env.t(), Ctx.t()) :: eval_result()
  def eval_walrus(name, expr, env, ctx) do
    case Interpreter.eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        {value, Env.smart_put(env, name, value), ctx}
    end
  end

  @doc """
  Evaluates a chained assignment.
  """
  @spec eval_chained_assign([String.t()], Parser.ast_node(), Env.t(), Ctx.t()) :: eval_result()
  def eval_chained_assign(names, expr, env, ctx) do
    case Interpreter.eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        env = Enum.reduce(names, env, &Env.smart_put(&2, &1, value))
        {value, env, ctx}
    end
  end

  @doc """
  Evaluates tuple or iterable unpacking assignment.
  """
  @spec eval_multi_assign(
          [Parser.unpack_target()],
          [Parser.ast_node()],
          Env.t(),
          Ctx.t()
        ) ::
          eval_result()
  def eval_multi_assign(names, exprs, env, ctx) do
    case Interpreter.eval_list(exprs, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {values, env, ctx} ->
        derefed = Enum.map(Enum.reverse(values), &Ctx.deref(ctx, &1))

        case Interpreter.unpack_iterable_safe(derefed, names) do
          {:ok, pairs} ->
            case bind_assignment_pairs(pairs, env, ctx) do
              {:ok, env, ctx} ->
                {_, last_val} = List.last(pairs)
                {last_val, env, ctx}

              {{:exception, _} = signal, env, ctx} ->
                {signal, env, ctx}
            end

          {:exception, msg} ->
            {{:exception, msg}, env, ctx}
        end
    end
  end

  @spec bind_assignment_pairs([{Parser.unpack_target(), Interpreter.pyvalue()}], Env.t(), Ctx.t()) ::
          {:ok, Env.t(), Ctx.t()} | {{:exception, String.t()}, Env.t(), Ctx.t()}
  defp bind_assignment_pairs(pairs, env, ctx) do
    Enum.reduce_while(pairs, {:ok, env, ctx}, fn
      {name, val}, {:ok, env, ctx} when is_binary(name) ->
        {:cont, {:ok, Env.smart_put(env, name, val), ctx}}

      {{:target, {:subscript, _, [target_expr, key_expr]}}, val}, {:ok, env, ctx} ->
        case Assignments.eval_expr_subscript_assign(
               target_expr,
               key_expr,
               {:__evaluated__, val},
               env,
               ctx
             ) do
          {{:exception, _} = signal, env, ctx} -> {:halt, {signal, env, ctx}}
          {_val, env, ctx} -> {:cont, {:ok, env, ctx}}
        end

      # Attribute target in an unpack, e.g. `self.a, self.b = 1, 2`.
      {{:target, {:getattr, _, _} = target}, val}, {:ok, env, ctx} ->
        case Assignments.setattr(target, val, env, ctx) do
          {{:exception, _} = signal, env, ctx} -> {:halt, {signal, env, ctx}}
          {_val, env, ctx} -> {:cont, {:ok, env, ctx}}
        end
    end)
  end

  @doc """
  Evaluates an augmented assignment by lowering it to assignment plus binop.
  """
  @spec eval_aug_assign(Parser.meta(), String.t(), atom(), Parser.ast_node(), Env.t(), Ctx.t()) ::
          eval_result()
  def eval_aug_assign(meta, name, op, expr, env, ctx) do
    current =
      case Env.get(env, name) do
        {:ok, v} -> Ctx.deref(ctx, v)
        _ -> :__undefined__
      end

    cond do
      # `a += iterable` on a list is in-place extend (accepts any iterable),
      # not list+list — so `lst += "ab"` / `lst += (1, 2)` works like CPython.
      op == :plus and match?({:py_list, _, _}, current) ->
        extend_node =
          {:call, meta, [{:getattr, meta, [{:var, meta, [name]}, "extend"]}, [expr]]}

        case Interpreter.eval(extend_node, env, ctx) do
          {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
          {_none, env, ctx} -> Interpreter.eval({:var, meta, [name]}, env, ctx)
        end

      # An instance may define an in-place dunder (__iadd__ etc.); fall back to
      # the binary dunder (__add__) via normal lowering when it doesn't.
      match?({:instance, _, _}, current) ->
        eval_inplace_dunder(meta, name, op, expr, current, env, ctx)

      true ->
        var_node = {:var, meta, [name]}
        binop_node = {:binop, meta, [op, var_node, expr]}
        Interpreter.eval({:assign, meta, [name, binop_node]}, env, ctx)
    end
  end

  @inplace_dunders %{
    plus: "__iadd__",
    minus: "__isub__",
    star: "__imul__",
    slash: "__itruediv__",
    floor_div: "__ifloordiv__",
    percent: "__imod__",
    double_star: "__ipow__",
    amp: "__iand__",
    pipe: "__ior__",
    caret: "__ixor__",
    lshift: "__ilshift__",
    rshift: "__irshift__",
    at: "__imatmul__"
  }

  defp eval_inplace_dunder(meta, name, op, expr, instance, env, ctx) do
    binop_fallback = fn env, ctx ->
      binop_node = {:binop, meta, [op, {:var, meta, [name]}, expr]}
      Interpreter.eval({:assign, meta, [name, binop_node]}, env, ctx)
    end

    case Map.get(@inplace_dunders, op) do
      nil ->
        binop_fallback.(env, ctx)

      dunder ->
        case Interpreter.eval(expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {rhs, env, ctx} ->
            case Pyex.Interpreter.Dunder.call_dunder(instance, dunder, [rhs], env, ctx) do
              {:ok, result, env, ctx} ->
                Interpreter.eval({:assign, meta, [name, {:__evaluated__, result}]}, env, ctx)

              :not_found ->
                binop_fallback.(env, ctx)
            end
        end
    end
  end

  @spec current_annotations(Env.t()) :: map()
  defp current_annotations(env) do
    case Env.get(env, "__annotations__") do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @spec current_annotation_order(Env.t()) :: [String.t()]
  defp current_annotation_order(env) do
    case Env.get(env, "__annotations_order__") do
      {:ok, names} when is_list(names) -> names
      _ -> []
    end
  end

  @spec update_annotation_order(Env.t(), String.t()) :: [String.t()]
  defp update_annotation_order(env, name) do
    order = current_annotation_order(env)
    if name in order, do: order, else: [name | order]
  end
end
