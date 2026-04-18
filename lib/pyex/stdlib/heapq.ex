defmodule Pyex.Stdlib.Heapq do
  @moduledoc """
  Minimal `heapq` support for interview-style min-heap workflows.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Interpreter

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "heapify" => {:builtin, &heapify/1},
      "heappush" => {:builtin, &heappush/1},
      "heappop" => {:builtin, &heappop/1},
      "heapreplace" => {:builtin, &heapreplace/1},
      "heappushpop" => {:builtin, &heappushpop/1},
      "nlargest" => {:builtin_kw, &nlargest/2},
      "nsmallest" => {:builtin_kw, &nsmallest/2},
      "merge" => {:builtin_kw, &merge/2}
    }
  end

  @spec heappushpop([Interpreter.pyvalue()]) :: term()
  defp heappushpop([heap, item]) do
    with {:ok, items, wrap} <- heap_parts(heap) do
      cond do
        items == [] ->
          {item, nil}

        hd(items) < item ->
          [root | rest] = items
          new_heap = sift_down([item | rest], 0)
          {:mutate_arg, 0, wrap.(new_heap), root}

        true ->
          # item is smaller than root — no change, return item
          {:mutate_arg, 0, wrap.(items), item}
      end
    end
  end

  defp heappushpop(_),
    do: {:exception, "TypeError: heappushpop() takes exactly 2 arguments"}

  @spec nlargest([Interpreter.pyvalue()], map()) :: [Interpreter.pyvalue()]
  defp nlargest([n, iterable], kwargs) when is_integer(n) do
    do_n(n, iterable, kwargs, :desc)
  end

  defp nlargest(_, _), do: {:exception, "TypeError: nlargest() requires (n, iterable)"}

  @spec nsmallest([Interpreter.pyvalue()], map()) :: [Interpreter.pyvalue()]
  defp nsmallest([n, iterable], kwargs) when is_integer(n) do
    do_n(n, iterable, kwargs, :asc)
  end

  defp nsmallest(_, _), do: {:exception, "TypeError: nsmallest() requires (n, iterable)"}

  @spec do_n(integer(), Interpreter.pyvalue(), map(), :asc | :desc) :: term()
  defp do_n(n, _iterable, _kwargs, _order) when n <= 0, do: []

  defp do_n(n, iterable, kwargs, order) do
    items = materialize(iterable)

    case Map.get(kwargs, "key") do
      nil ->
        items
        |> Enum.sort(if order == :asc, do: :asc, else: :desc)
        |> Enum.take(n)

      func ->
        # Use the interpreter's :sort_call machinery to evaluate the key
        # function for each item, then slice to n elements.
        {:ctx_call,
         fn env, ctx ->
           case Pyex.Interpreter.eval_sort(items, func, order == :desc, env, ctx) do
             {{:exception, _} = signal, env, ctx} ->
               {signal, env, ctx}

             {sorted, env, ctx} ->
               {Enum.take(sorted, n), env, ctx}
           end
         end}
    end
  end

  @spec merge([Interpreter.pyvalue()], map()) :: [Interpreter.pyvalue()]
  defp merge(iterables, _kwargs) do
    iterables
    |> Enum.flat_map(&materialize/1)
    |> Enum.sort()
  end

  @spec materialize(Interpreter.pyvalue()) :: [Interpreter.pyvalue()]
  defp materialize({:py_list, reversed, _}), do: Enum.reverse(reversed)
  defp materialize({:tuple, items}), do: items
  defp materialize({:set, s}), do: MapSet.to_list(s)
  defp materialize(list) when is_list(list), do: list
  defp materialize(_), do: []

  @spec heapify([Interpreter.pyvalue()]) :: term()
  defp heapify([heap]) do
    with {:ok, items, wrap} <- heap_parts(heap) do
      {:mutate_arg, 0, wrap.(build_heap(items)), nil}
    end
  end

  defp heapify(_args), do: {:exception, "TypeError: heapify() takes exactly 1 argument"}

  @spec heappush([Interpreter.pyvalue()]) :: term()
  defp heappush([heap, item]) do
    with {:ok, items, wrap} <- heap_parts(heap) do
      {:mutate_arg, 0, wrap.(sift_up(items ++ [item])), nil}
    end
  end

  defp heappush(_args), do: {:exception, "TypeError: heappush() takes exactly 2 arguments"}

  @spec heappop([Interpreter.pyvalue()]) :: term()
  defp heappop([heap]) do
    with {:ok, items, wrap} <- heap_parts(heap) do
      case items do
        [] ->
          {:exception, "IndexError: index out of range"}

        [item] ->
          {:mutate_arg, 0, wrap.([]), item}

        _ ->
          [root | rest] = items
          last = List.last(rest)
          rest = List.delete_at(rest, length(rest) - 1)
          new_heap = sift_down([last | rest], 0)
          {:mutate_arg, 0, wrap.(new_heap), root}
      end
    end
  end

  defp heappop(_args), do: {:exception, "TypeError: heappop() takes exactly 1 argument"}

  @spec heapreplace([Interpreter.pyvalue()]) :: term()
  defp heapreplace([heap, item]) do
    with {:ok, items, wrap} <- heap_parts(heap) do
      case items do
        [] ->
          {:exception, "IndexError: index out of range"}

        [_root | rest] ->
          root = hd(items)
          new_heap = sift_down([item | rest], 0)
          {:mutate_arg, 0, wrap.(new_heap), root}
      end
    end
  end

  defp heapreplace(_args), do: {:exception, "TypeError: heapreplace() takes exactly 2 arguments"}

  @spec heap_parts(Interpreter.pyvalue()) ::
          {:ok, [Interpreter.pyvalue()], ([Interpreter.pyvalue()] -> Interpreter.pyvalue())}
          | {:exception, String.t()}
  defp heap_parts({:py_list, reversed, _len}) do
    {:ok, Enum.reverse(reversed), fn items -> {:py_list, Enum.reverse(items), len_for(items)} end}
  end

  defp heap_parts(list) when is_list(list) do
    {:ok, list, &Function.identity/1}
  end

  defp heap_parts(_other), do: {:exception, "TypeError: heap argument must be list"}

  @spec len_for([Interpreter.pyvalue()]) :: non_neg_integer()
  defp len_for(items), do: length(items)

  @spec build_heap([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp build_heap([]), do: []
  defp build_heap([item]), do: [item]

  defp build_heap(items) do
    start = div(length(items), 2) - 1
    Enum.reduce(start..0//-1, items, fn idx, acc -> sift_down(acc, idx) end)
  end

  @spec sift_up([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp sift_up(items) do
    do_sift_up(items, length(items) - 1)
  end

  @spec do_sift_up([Interpreter.pyvalue()], integer()) :: [Interpreter.pyvalue()]
  defp do_sift_up(items, idx) when idx <= 0, do: items

  defp do_sift_up(items, idx) do
    parent = div(idx - 1, 2)

    if Enum.at(items, idx) < Enum.at(items, parent) do
      items
      |> swap(idx, parent)
      |> do_sift_up(parent)
    else
      items
    end
  end

  @spec sift_down([Interpreter.pyvalue()], non_neg_integer()) :: [Interpreter.pyvalue()]
  defp sift_down(items, idx) do
    left = idx * 2 + 1
    right = idx * 2 + 2
    len = length(items)

    smallest =
      idx
      |> smaller_child(items, left, len)
      |> smaller_child(items, right, len)

    if smallest != idx do
      items
      |> swap(idx, smallest)
      |> sift_down(smallest)
    else
      items
    end
  end

  @spec smaller_child(
          non_neg_integer(),
          [Interpreter.pyvalue()],
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp smaller_child(current, items, child, len) when child < len do
    if Enum.at(items, child) < Enum.at(items, current), do: child, else: current
  end

  defp smaller_child(current, _items, _child, _len), do: current

  @spec swap([Interpreter.pyvalue()], non_neg_integer(), non_neg_integer()) :: [
          Interpreter.pyvalue()
        ]
  defp swap(items, a, b) do
    va = Enum.at(items, a)
    vb = Enum.at(items, b)

    items
    |> List.replace_at(a, vb)
    |> List.replace_at(b, va)
  end
end
