defmodule Pyex.Interpreter.Statements do
  @moduledoc """
  Simple statement evaluation helpers for `Pyex.Interpreter`.

  Keeps small statement families together so the main interpreter can focus
  on dispatch while preserving the public `eval/3` entrypoint.
  """

  alias Pyex.{Ctx, Env, Interpreter, Parser}
  alias Pyex.Interpreter.Helpers

  @typep eval_result :: {Interpreter.pyvalue() | tuple(), Env.t(), Ctx.t()}

  @doc """
  Evaluates an `assert` statement.
  """
  @spec eval_assert(Parser.ast_node(), Parser.ast_node() | nil, Env.t(), Ctx.t()) :: eval_result()
  def eval_assert(condition, msg_expr, env, ctx) do
    case Interpreter.eval(condition, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        {taken, env, ctx} = Interpreter.eval_truthy(value, env, ctx)

        if taken do
          {nil, env, ctx}
        else
          eval_assert_message(msg_expr, env, ctx)
        end
    end
  end

  @doc """
  Evaluates `del name`.
  """
  @spec eval_del_var(String.t(), Env.t(), Ctx.t()) :: eval_result()
  def eval_del_var(var_name, env, ctx) do
    {nil, Env.delete(env, var_name), ctx}
  end

  @doc """
  Evaluates `del obj[key]` for name-backed containers.
  """
  @spec eval_del_subscript(String.t(), Parser.ast_node(), Env.t(), Ctx.t()) :: eval_result()
  def eval_del_subscript(var_name, key_expr, env, ctx) do
    case Env.get(env, var_name) do
      {:ok, obj} when is_map(obj) ->
        case Interpreter.eval(key_expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {key, env, ctx} ->
            {nil, Env.put(env, var_name, Map.delete(obj, key)), ctx}
        end

      {:ok, {:py_list, reversed, len}} ->
        case Interpreter.eval(key_expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {idx, env, ctx} when is_integer(idx) ->
            real_idx = if idx < 0, do: len + idx, else: idx
            new_reversed = List.delete_at(reversed, len - 1 - real_idx)
            {nil, Env.put(env, var_name, {:py_list, new_reversed, len - 1}), ctx}

          {_, env, ctx} ->
            {{:exception, "TypeError: list indices must be integers"}, env, ctx}
        end

      {:ok, obj} when is_list(obj) ->
        case Interpreter.eval(key_expr, env, ctx) do
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

  @doc """
  Evaluates `pass`.
  """
  @spec eval_pass(Env.t(), Ctx.t()) :: eval_result()
  def eval_pass(env, ctx), do: {nil, env, ctx}

  @doc """
  Evaluates `break`.
  """
  @spec eval_break(Env.t(), Ctx.t()) :: eval_result()
  def eval_break(env, ctx), do: {{:break}, env, ctx}

  @doc """
  Evaluates `continue`.
  """
  @spec eval_continue(Env.t(), Ctx.t()) :: eval_result()
  def eval_continue(env, ctx), do: {{:continue}, env, ctx}

  @spec eval_assert_message(Parser.ast_node() | nil, Env.t(), Ctx.t()) :: eval_result()
  defp eval_assert_message(nil, env, ctx) do
    {{:exception, "AssertionError"}, env, ctx}
  end

  defp eval_assert_message(msg_expr, env, ctx) do
    case Interpreter.eval(msg_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {msg_val, env, ctx} ->
        {{:exception, "AssertionError: #{Helpers.py_str(msg_val)}"}, env, ctx}
    end
  end
end
