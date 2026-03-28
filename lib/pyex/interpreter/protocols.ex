defmodule Pyex.Interpreter.Protocols do
  @moduledoc """
  Python protocol helpers for string conversion and truthiness.

  Keeps `__str__`, `__repr__`, `__bool__`, and `__len__` fallback rules together
  so protocol semantics stay separate from the main evaluator.
  """

  alias Pyex.{Ctx, Env, Interpreter, PyDict}
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
        {:ok, str, env, ctx} = dunder_str_fallback(inst, "__str__", env, ctx)
        {str, env, ctx}
    end
  end

  def eval_py_str({:py_list, reversed, _}, env, ctx) do
    {items_str, env, ctx} =
      reversed
      |> Enum.reverse()
      |> eval_reprs(env, ctx)

    {"[" <> Enum.join(items_str, ", ") <> "]", env, ctx}
  end

  def eval_py_str(list, env, ctx) when is_list(list) do
    {items_str, env, ctx} = eval_reprs(list, env, ctx)
    {"[" <> Enum.join(items_str, ", ") <> "]", env, ctx}
  end

  def eval_py_str({:tuple, items}, env, ctx) do
    {items_str, env, ctx} = eval_reprs(items, env, ctx)

    formatted =
      case items_str do
        [single] -> "(" <> single <> ",)"
        many -> "(" <> Enum.join(many, ", ") <> ")"
      end

    {formatted, env, ctx}
  end

  def eval_py_str(val, env, ctx), do: {Helpers.py_str(val), env, ctx}

  @doc false
  @spec eval_py_repr(Interpreter.pyvalue(), Env.t(), Ctx.t()) :: {String.t(), Env.t(), Ctx.t()}
  def eval_py_repr({:ref, _} = ref, env, ctx) do
    eval_py_repr(Ctx.deref(ctx, ref), env, ctx)
  end

  def eval_py_repr({:instance, _, _} = inst, env, ctx) do
    case Dunder.call_dunder(inst, "__repr__", [], env, ctx) do
      {:ok, str, env, ctx} when is_binary(str) ->
        {str, env, ctx}

      _ ->
        {Helpers.py_str(inst), env, ctx}
    end
  end

  def eval_py_repr({:py_list, reversed, _}, env, ctx) do
    {items_str, env, ctx} =
      reversed
      |> Enum.reverse()
      |> eval_reprs(env, ctx)

    {"[" <> Enum.join(items_str, ", ") <> "]", env, ctx}
  end

  def eval_py_repr(list, env, ctx) when is_list(list) do
    {items_str, env, ctx} = eval_reprs(list, env, ctx)
    {"[" <> Enum.join(items_str, ", ") <> "]", env, ctx}
  end

  def eval_py_repr({:tuple, items}, env, ctx) do
    {items_str, env, ctx} = eval_reprs(items, env, ctx)

    formatted =
      case items_str do
        [single] -> "(" <> single <> ",)"
        many -> "(" <> Enum.join(many, ", ") <> ")"
      end

    {formatted, env, ctx}
  end

  def eval_py_repr({:py_dict, _, _} = dict, env, ctx) do
    visible = Pyex.Builtins.visible_dict(dict)

    {inner, env, ctx} =
      Enum.reduce(PyDict.items(visible), {[], env, ctx}, fn {k, v}, {acc, env, ctx} ->
        {k_str, env, ctx} = eval_py_repr(k, env, ctx)
        {v_str, env, ctx} = eval_py_repr(v, env, ctx)
        {["#{k_str}: #{v_str}" | acc], env, ctx}
      end)

    {"{" <> Enum.join(Enum.reverse(inner), ", ") <> "}", env, ctx}
  end

  def eval_py_repr(val, env, ctx), do: {Helpers.py_repr_fmt(val), env, ctx}

  @spec eval_reprs([Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          {[String.t()], Env.t(), Ctx.t()}
  defp eval_reprs(items, env, ctx) do
    {strs_rev, env, ctx} =
      Enum.reduce(items, {[], env, ctx}, fn item, {acc, env, ctx} ->
        {str, env, ctx} = eval_py_repr(item, env, ctx)
        {[str | acc], env, ctx}
      end)

    {Enum.reverse(strs_rev), env, ctx}
  end

  @doc false
  @spec dunder_str_fallback(Interpreter.pyvalue(), String.t(), Env.t(), Ctx.t()) ::
          {:ok, String.t(), Env.t(), Ctx.t()} | :error
  def dunder_str_fallback({:instance, {:class, "KeyError", _, _}, attrs}, "__str__", env, ctx) do
    # CPython's KeyError.__str__ calls repr() on the single argument
    case Map.get(attrs, "args") do
      {:tuple, [single]} ->
        {repr_str, env, ctx} = eval_py_repr(single, env, ctx)
        {:ok, repr_str, env, ctx}

      {:tuple, items} when is_list(items) and items != [] ->
        {:ok, items |> Enum.map(&Helpers.py_repr_fmt/1) |> Enum.join(", "), env, ctx}

      _ ->
        {:ok, "KeyError", env, ctx}
    end
  end

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
