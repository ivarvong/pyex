defmodule Pyex.Interpreter.Iterables do
  @moduledoc """
  Iterable and iterator protocol helpers for `Pyex.Interpreter`.

  Keeps iterable coercion, iterator draining, and instance-backed iterator state
  updates separate from the main evaluator.
  """

  alias Pyex.{Builtins, Ctx, Env, Interpreter, PyDict}
  alias Pyex.Interpreter.{Dunder, Helpers}

  @doc false
  @spec to_iterable(Interpreter.pyvalue(), Env.t(), Ctx.t()) ::
          {:ok, [Interpreter.pyvalue()], Env.t(), Ctx.t()} | {:exception, String.t()}
  def to_iterable({:ref, _} = ref, env, ctx) do
    to_iterable(Ctx.deref(ctx, ref), env, ctx)
  end

  def to_iterable({:py_list, reversed, _len}, env, ctx),
    do: {:ok, Enum.reverse(reversed), env, ctx}

  def to_iterable(list, env, ctx) when is_list(list), do: {:ok, list, env, ctx}
  def to_iterable(str, env, ctx) when is_binary(str), do: {:ok, String.codepoints(str), env, ctx}

  def to_iterable({:py_dict, _, _} = dict, env, ctx) do
    {:ok, PyDict.keys(Builtins.visible_dict(dict)), env, ctx}
  end

  def to_iterable(map, env, ctx) when is_map(map),
    do: {:ok, map |> Builtins.visible_dict() |> Map.keys(), env, ctx}

  def to_iterable({:tuple, elements}, env, ctx), do: {:ok, elements, env, ctx}
  def to_iterable({:set, set}, env, ctx), do: {:ok, MapSet.to_list(set), env, ctx}
  def to_iterable({:frozenset, set}, env, ctx), do: {:ok, MapSet.to_list(set), env, ctx}

  def to_iterable({:range, _, _, _} = range, env, ctx) do
    case Builtins.range_to_list(range) do
      {:exception, _} = err -> err
      list -> {:ok, list, env, ctx}
    end
  end

  def to_iterable({:generator, items}, env, ctx), do: {:ok, items, env, ctx}
  def to_iterable({:generator_error, items, _msg}, env, ctx), do: {:ok, items, env, ctx}
  def to_iterable({:iterator, id}, env, ctx), do: {:ok, Ctx.iter_items(ctx, id), env, ctx}

  def to_iterable({:instance, _, _} = inst, env, ctx) do
    case Dunder.call_dunder(inst, "__iter__", [], env, ctx) do
      {:ok, raw_result, env, ctx} ->
        result = Ctx.deref(ctx, raw_result)

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

  def to_iterable(val, _env, _ctx) do
    {:exception, "TypeError: '#{Helpers.py_type(val)}' object is not iterable"}
  end

  @doc false
  @spec eval_instance_next(
          Interpreter.pyvalue(),
          non_neg_integer(),
          :no_default | {:default, Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: {Interpreter.pyvalue() | tuple(), Env.t(), Ctx.t()}
  def eval_instance_next(inst, id, default_opt, env, ctx) do
    case Dunder.call_dunder_mut(inst, "__next__", [], env, ctx) do
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

  @spec drain_iterator(Interpreter.pyvalue(), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          {:ok, [Interpreter.pyvalue()], Env.t(), Ctx.t()} | {:exception, String.t()}
  defp drain_iterator(iter, acc, env, ctx) do
    case Dunder.call_dunder_mut(iter, "__next__", [], env, ctx) do
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
end
