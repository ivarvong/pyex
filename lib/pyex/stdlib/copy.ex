defmodule Pyex.Stdlib.Copy do
  @moduledoc """
  Python `copy` module providing shallow and deep copy operations.

  Implements `copy.copy()` for shallow copies and `copy.deepcopy()`
  for deep copies. Mutable objects (lists, dicts, sets) are allocated
  as new heap objects. Immutable types (int, str, float, bool, None,
  tuples) are returned as-is.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.{Ctx, PyDict}

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "copy" => {:builtin_raw, &do_copy/1},
      "deepcopy" => {:builtin_raw, &do_deepcopy/1}
    }
  end

  defp do_copy([obj]) do
    {:ctx_call,
     fn env, ctx ->
       {result, ctx} = shallow_copy(obj, ctx)
       {result, env, ctx}
     end}
  end

  defp do_copy(_), do: {:exception, "TypeError: copy() takes exactly 1 argument"}

  defp do_deepcopy([obj]) do
    {:ctx_call,
     fn env, ctx ->
       {result, ctx} = deep_copy(obj, ctx, %{})
       {result, env, ctx}
     end}
  end

  defp do_deepcopy(_), do: {:exception, "TypeError: deepcopy() takes exactly 1 argument"}

  @spec shallow_copy(term(), Ctx.t()) :: {term(), Ctx.t()}
  defp shallow_copy({:ref, id} = _ref, ctx) do
    case Ctx.deref(ctx, {:ref, id}) do
      {:py_list, _, _} = list ->
        Ctx.heap_alloc(ctx, list)

      {:py_dict, _, _} = dict ->
        Ctx.heap_alloc(ctx, dict)

      {:set, _} = set ->
        Ctx.heap_alloc(ctx, set)

      {:instance, class, attrs} ->
        Ctx.heap_alloc(ctx, {:instance, class, attrs})

      _other ->
        {{:ref, id}, ctx}
    end
  end

  defp shallow_copy(value, ctx), do: {value, ctx}

  @spec deep_copy(term(), Ctx.t(), %{optional(non_neg_integer()) => {:ref, non_neg_integer()}}) ::
          {term(), Ctx.t()}
  defp deep_copy({:ref, id}, ctx, memo) do
    case Map.fetch(memo, id) do
      {:ok, new_ref} ->
        {new_ref, ctx}

      :error ->
        case Ctx.deref(ctx, {:ref, id}) do
          {:py_list, reversed, len} ->
            # Allocate a placeholder first, then fill in to handle cycles
            {new_ref, ctx} = Ctx.heap_alloc(ctx, {:py_list, [], 0})
            {:ref, new_id} = new_ref
            memo = Map.put(memo, id, new_ref)

            {new_reversed, ctx} =
              Enum.reduce(reversed, {[], ctx}, fn elem, {acc, ctx} ->
                {copied, ctx} = deep_copy(elem, ctx, memo)
                {[copied | acc], ctx}
              end)

            ctx = Ctx.heap_put(ctx, new_id, {:py_list, Enum.reverse(new_reversed), len})
            {new_ref, ctx}

          {:py_dict, _, _} = dict ->
            {new_ref, ctx} = Ctx.heap_alloc(ctx, PyDict.new())
            {:ref, new_id} = new_ref
            memo = Map.put(memo, id, new_ref)

            pairs = PyDict.items(dict)

            {new_dict, ctx} =
              Enum.reduce(pairs, {PyDict.new(), ctx}, fn {k, v}, {acc, ctx} ->
                {new_k, ctx} = deep_copy(k, ctx, memo)
                {new_v, ctx} = deep_copy(v, ctx, memo)
                {PyDict.put(acc, new_k, new_v), ctx}
              end)

            ctx = Ctx.heap_put(ctx, new_id, new_dict)
            {new_ref, ctx}

          {:set, mapset} ->
            {new_ref, ctx} = Ctx.heap_alloc(ctx, {:set, MapSet.new()})
            {:ref, new_id} = new_ref
            memo = Map.put(memo, id, new_ref)

            {new_set, ctx} =
              Enum.reduce(mapset, {MapSet.new(), ctx}, fn elem, {acc, ctx} ->
                {copied, ctx} = deep_copy(elem, ctx, memo)
                {MapSet.put(acc, copied), ctx}
              end)

            ctx = Ctx.heap_put(ctx, new_id, {:set, new_set})
            {new_ref, ctx}

          {:instance, class, attrs} ->
            {new_ref, ctx} = Ctx.heap_alloc(ctx, {:instance, class, %{}})
            {:ref, new_id} = new_ref
            memo = Map.put(memo, id, new_ref)

            {new_attrs, ctx} =
              Enum.reduce(attrs, {%{}, ctx}, fn {k, v}, {acc, ctx} ->
                {new_v, ctx} = deep_copy(v, ctx, memo)
                {Map.put(acc, k, new_v), ctx}
              end)

            ctx = Ctx.heap_put(ctx, new_id, {:instance, class, new_attrs})
            {new_ref, ctx}

          _other ->
            {{:ref, id}, ctx}
        end
    end
  end

  defp deep_copy({:tuple, items}, ctx, memo) do
    {new_items, ctx} =
      Enum.reduce(items, {[], ctx}, fn elem, {acc, ctx} ->
        {copied, ctx} = deep_copy(elem, ctx, memo)
        {[copied | acc], ctx}
      end)

    {{:tuple, Enum.reverse(new_items)}, ctx}
  end

  defp deep_copy(value, ctx, _memo), do: {value, ctx}
end
