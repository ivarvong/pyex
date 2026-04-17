defmodule Pyex.Stdlib.Bisect do
  @moduledoc """
  Python `bisect` module for binary search on sorted sequences.

  Provides `bisect_left`, `bisect_right` (alias `bisect`), `insort_left`,
  and `insort_right` (alias `insort`).  Insertion variants return the
  mutated list via the `:mutate_arg` signal so Python's in-place
  semantics are preserved.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Interpreter

  @doc """
  Returns the module value map.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "bisect_left" => {:builtin_kw, &bisect_left/2},
      "bisect_right" => {:builtin_kw, &bisect_right/2},
      "bisect" => {:builtin_kw, &bisect_right/2},
      "insort_left" => {:builtin_kw, &insort_left/2},
      "insort_right" => {:builtin_kw, &insort_right/2},
      "insort" => {:builtin_kw, &insort_right/2}
    }
  end

  @doc false
  @spec bisect_left([Interpreter.pyvalue()], map()) :: non_neg_integer()
  def bisect_left(args, kwargs), do: do_bisect(args, kwargs, :left)

  @doc false
  @spec bisect_right([Interpreter.pyvalue()], map()) :: non_neg_integer()
  def bisect_right(args, kwargs), do: do_bisect(args, kwargs, :right)

  @doc false
  @spec insort_left([Interpreter.pyvalue()], map()) ::
          {:mutate_arg, non_neg_integer(), Interpreter.pyvalue(), nil}
  def insort_left(args, kwargs), do: do_insort(args, kwargs, :left)

  @doc false
  @spec insort_right([Interpreter.pyvalue()], map()) ::
          {:mutate_arg, non_neg_integer(), Interpreter.pyvalue(), nil}
  def insort_right(args, kwargs), do: do_insort(args, kwargs, :right)

  @spec do_bisect([Interpreter.pyvalue()], map(), :left | :right) :: non_neg_integer()
  defp do_bisect(args, kwargs, side) do
    {list, item, lo, hi} = unpack_args(args, kwargs)
    items = materialize(list)
    clamped_hi = if hi, do: min(hi, length(items)), else: length(items)
    find_position(items, item, max(lo, 0), clamped_hi, side)
  end

  defp do_insort(args, kwargs, side) do
    {list, item, lo, hi} = unpack_args(args, kwargs)
    items = materialize(list)
    clamped_hi = if hi, do: min(hi, length(items)), else: length(items)
    pos = find_position(items, item, max(lo, 0), clamped_hi, side)
    {before, after_} = Enum.split(items, pos)
    new_list = before ++ [item] ++ after_

    case list do
      {:py_list, _reversed, _len} ->
        new_py = {:py_list, Enum.reverse(new_list), length(new_list)}
        {:mutate_arg, 0, new_py, nil}

      _ ->
        {:mutate_arg, 0, new_list, nil}
    end
  end

  defp unpack_args([list, item], kwargs) do
    lo = Map.get(kwargs, "lo", 0)
    hi = Map.get(kwargs, "hi", nil)
    {list, item, lo, hi}
  end

  defp unpack_args([list, item, lo], kwargs) do
    hi = Map.get(kwargs, "hi", nil)
    {list, item, lo, hi}
  end

  defp unpack_args([list, item, lo, hi], _kwargs), do: {list, item, lo, hi}

  @spec find_position(
          [Interpreter.pyvalue()],
          Interpreter.pyvalue(),
          non_neg_integer(),
          non_neg_integer(),
          :left | :right
        ) ::
          non_neg_integer()
  defp find_position(items, item, lo, hi, side) do
    do_find(items, item, lo, hi, side)
  end

  defp do_find(_items, _item, lo, hi, _side) when lo >= hi, do: lo

  defp do_find(items, item, lo, hi, side) do
    mid = div(lo + hi, 2)
    mid_item = Enum.at(items, mid)

    cond do
      side == :left and cmp(mid_item, item) < 0 ->
        do_find(items, item, mid + 1, hi, side)

      side == :left ->
        do_find(items, item, lo, mid, side)

      side == :right and cmp(item, mid_item) < 0 ->
        do_find(items, item, lo, mid, side)

      side == :right ->
        do_find(items, item, mid + 1, hi, side)
    end
  end

  defp cmp(a, b) when a < b, do: -1
  defp cmp(a, b) when a > b, do: 1
  defp cmp(_, _), do: 0

  @spec materialize(Interpreter.pyvalue()) :: [Interpreter.pyvalue()]
  defp materialize({:py_list, reversed, _}), do: Enum.reverse(reversed)
  defp materialize(list) when is_list(list), do: list
  defp materialize({:tuple, items}), do: items
  defp materialize(_), do: []
end
