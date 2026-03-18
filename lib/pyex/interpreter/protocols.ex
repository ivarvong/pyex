defmodule Pyex.Interpreter.Protocols do
  @moduledoc """
  Python protocol helpers for string conversion and truthiness.

  Keeps `__str__`, `__repr__`, `__bool__`, and `__len__` fallback rules together
  so protocol semantics stay separate from the main evaluator.
  """

  alias Pyex.{Ctx, Env, Interpreter}
  alias Pyex.Interpreter.{Dunder, Helpers}

  @doc false
  @spec eval_py_str(Interpreter.pyvalue(), Env.t(), Ctx.t()) :: {String.t(), Env.t(), Ctx.t()}
  def eval_py_str({:ref, _} = ref, env, ctx) do
    eval_py_str(Ctx.deref(ctx, ref), env, ctx)
  end

  def eval_py_str({:instance, _, _} = inst, env, ctx) do
    case Dunder.call_dunder(inst, "__str__", [], env, ctx) do
      {:ok, str, env, ctx} when is_binary(str) ->
        {str, env, ctx}

      _ ->
        case Dunder.call_dunder(inst, "__repr__", [], env, ctx) do
          {:ok, str, env, ctx} when is_binary(str) -> {str, env, ctx}
          _ -> {Helpers.py_str(inst), env, ctx}
        end
    end
  end

  def eval_py_str(val, env, ctx), do: {Helpers.py_str(val), env, ctx}

  @doc false
  @spec dunder_str_fallback(Interpreter.pyvalue(), String.t(), Env.t(), Ctx.t()) ::
          {:ok, String.t(), Env.t(), Ctx.t()} | :error
  def dunder_str_fallback({:instance, _, attrs} = inst, "__str__", env, ctx) do
    case Dunder.call_dunder(inst, "__repr__", [], env, ctx) do
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

  def dunder_str_fallback({:instance, _, _} = inst, "__repr__", env, ctx) do
    {:ok, Helpers.py_str(inst), env, ctx}
  end

  def dunder_str_fallback(inst, "__bool__", env, ctx) do
    case Dunder.call_dunder(inst, "__len__", [], env, ctx) do
      {:ok, len, env, ctx} when is_integer(len) ->
        {:ok, len > 0, env, ctx}

      _ ->
        {:ok, true, env, ctx}
    end
  end

  def dunder_str_fallback(_, _, _, _), do: :error

  @doc false
  @spec eval_truthy(Interpreter.pyvalue(), Env.t(), Ctx.t()) :: {boolean(), Env.t(), Ctx.t()}
  def eval_truthy({:ref, _} = ref, env, ctx) do
    eval_truthy(Ctx.deref(ctx, ref), env, ctx)
  end

  def eval_truthy({:instance, _, _} = inst, env, ctx) do
    case Dunder.call_dunder(inst, "__bool__", [], env, ctx) do
      {:ok, result, env, ctx} ->
        {Helpers.truthy?(result), env, ctx}

      :not_found ->
        case Dunder.call_dunder(inst, "__len__", [], env, ctx) do
          {:ok, result, env, ctx} when is_integer(result) -> {result != 0, env, ctx}
          {:ok, _, env, ctx} -> {true, env, ctx}
          :not_found -> {true, env, ctx}
        end
    end
  end

  def eval_truthy(val, env, ctx), do: {Helpers.truthy?(val), env, ctx}
end
