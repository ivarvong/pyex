defmodule Pyex.Interpreter.Bindings do
  @moduledoc """
  Variable binding and annotation evaluation helpers for `Pyex.Interpreter`.

  Keeps plain-name assignment semantics together so the main interpreter can
  focus on dispatch while preserving the existing public API.
  """

  alias Pyex.{Ctx, Env, Interpreter, Parser}

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
            env =
              Enum.reduce(pairs, env, fn {name, val}, acc -> Env.smart_put(acc, name, val) end)

            {_, last_val} = List.last(pairs)
            {last_val, env, ctx}

          {:exception, msg} ->
            {{:exception, msg}, env, ctx}
        end
    end
  end

  @doc """
  Evaluates an augmented assignment by lowering it to assignment plus binop.
  """
  @spec eval_aug_assign(Parser.meta(), String.t(), atom(), Parser.ast_node(), Env.t(), Ctx.t()) ::
          eval_result()
  def eval_aug_assign(meta, name, op, expr, env, ctx) do
    var_node = {:var, meta, [name]}
    binop_node = {:binop, meta, [op, var_node, expr]}
    Interpreter.eval({:assign, meta, [name, binop_node]}, env, ctx)
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
    if name in order, do: order, else: order ++ [name]
  end
end
