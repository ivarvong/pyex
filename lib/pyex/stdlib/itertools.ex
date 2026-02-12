defmodule Pyex.Stdlib.Itertools do
  @moduledoc """
  Python `itertools` module.

  Provides combinatoric iterators, infinite iterators (capped for
  sandbox safety), and iterator building blocks.

  Since Pyex materializes iterables eagerly, all functions return
  plain lists or `{:generator, list}` tuples. Functions that take
  Python callables (starmap, takewhile, dropwhile, filterfalse,
  groupby, accumulate with func) return signal tuples that the
  interpreter evaluates.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.{Builtins, Interpreter}

  @doc """
  Returns the module value map with all itertools functions.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "chain" => {:builtin, &do_chain/1},
      "chain_from_iterable" => {:builtin, &do_chain_from_iterable/1},
      "islice" => {:builtin, &do_islice/1},
      "product" => {:builtin_kw, &do_product/2},
      "permutations" => {:builtin, &do_permutations/1},
      "combinations" => {:builtin, &do_combinations/1},
      "combinations_with_replacement" => {:builtin, &do_combinations_with_replacement/1},
      "repeat" => {:builtin, &do_repeat/1},
      "compress" => {:builtin, &do_compress/1},
      "pairwise" => {:builtin, &do_pairwise/1},
      "zip_longest" => {:builtin_kw, &do_zip_longest/2},
      "accumulate" => {:builtin_kw, &do_accumulate/2},
      "count" => {:builtin, &do_count/1},
      "cycle" => {:builtin, &do_cycle/1},
      "starmap" => {:builtin, &do_starmap/1},
      "takewhile" => {:builtin, &do_takewhile/1},
      "dropwhile" => {:builtin, &do_dropwhile/1},
      "filterfalse" => {:builtin, &do_filterfalse/1},
      "groupby" => {:builtin_kw, &do_groupby/2},
      "tee" => {:builtin, &do_tee/1}
    }
  end

  @spec materialize(Interpreter.pyvalue()) :: [Interpreter.pyvalue()]
  defp materialize(list) when is_list(list), do: list
  defp materialize({:tuple, items}), do: items
  defp materialize({:generator, items}), do: items
  defp materialize({:set, s}), do: MapSet.to_list(s)
  defp materialize({:frozenset, s}), do: MapSet.to_list(s)

  defp materialize({:range, _, _, _} = r) do
    case Builtins.range_to_list(r) do
      {:exception, _} -> []
      list -> list
    end
  end

  defp materialize(str) when is_binary(str), do: String.codepoints(str)
  defp materialize(map) when is_map(map), do: map |> Builtins.visible_dict() |> Map.keys()

  @spec do_chain([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp do_chain(iterables) do
    Enum.flat_map(iterables, &materialize/1)
  end

  @spec do_chain_from_iterable([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp do_chain_from_iterable([iterable]) do
    iterable
    |> materialize()
    |> Enum.flat_map(&materialize/1)
  end

  @spec do_islice([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp do_islice([iterable, stop]) when is_integer(stop) do
    iterable |> materialize() |> Enum.take(max(stop, 0))
  end

  defp do_islice([iterable, nil]) do
    materialize(iterable)
  end

  defp do_islice([iterable, start, stop]) when is_integer(start) and is_integer(stop) do
    iterable |> materialize() |> Enum.slice(start..(stop - 1)//1)
  end

  defp do_islice([iterable, start, nil]) when is_integer(start) do
    iterable |> materialize() |> Enum.drop(start)
  end

  defp do_islice([iterable, start, stop, step])
       when is_integer(start) and is_integer(stop) and is_integer(step) and step > 0 do
    iterable
    |> materialize()
    |> Enum.slice(start..(stop - 1)//1)
    |> Enum.take_every(step)
  end

  @spec do_product([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          [Interpreter.pyvalue()]
  defp do_product([], _kwargs) do
    [{:tuple, []}]
  end

  defp do_product(args, kwargs) do
    repeat_count = kwargs |> Map.get("repeat", 1) |> max(1)
    lists = Enum.map(args, &materialize/1)

    repeated =
      case repeat_count do
        1 -> lists
        n -> lists |> List.duplicate(n) |> Enum.concat()
      end

    cartesian_product(repeated)
    |> Enum.map(fn combo -> {:tuple, combo} end)
  end

  @spec cartesian_product([[Interpreter.pyvalue()]]) :: [[Interpreter.pyvalue()]]
  defp cartesian_product([]), do: [[]]

  defp cartesian_product([head | tail]) do
    rest = cartesian_product(tail)

    for x <- head, combo <- rest do
      [x | combo]
    end
  end

  @spec do_permutations([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp do_permutations([iterable]) do
    items = materialize(iterable)
    permute(items, length(items))
  end

  defp do_permutations([iterable, r]) when is_integer(r) do
    items = materialize(iterable)
    permute(items, r)
  end

  defp do_permutations([iterable, nil]) do
    items = materialize(iterable)
    permute(items, length(items))
  end

  @spec permute([Interpreter.pyvalue()], non_neg_integer()) :: [Interpreter.pyvalue()]
  defp permute(_items, 0), do: [{:tuple, []}]

  defp permute(items, r) when r > length(items), do: []

  defp permute(items, r) do
    do_permute(items, r)
    |> Enum.map(fn combo -> {:tuple, combo} end)
  end

  @spec do_permute([Interpreter.pyvalue()], non_neg_integer()) :: [[Interpreter.pyvalue()]]
  defp do_permute(_items, 0), do: [[]]

  defp do_permute(items, r) do
    for {x, i} <- Enum.with_index(items),
        rest <- do_permute(List.delete_at(items, i), r - 1) do
      [x | rest]
    end
  end

  @spec do_combinations([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp do_combinations([iterable, r]) when is_integer(r) do
    items = materialize(iterable)
    combine(items, r)
  end

  @spec combine([Interpreter.pyvalue()], non_neg_integer()) :: [Interpreter.pyvalue()]
  defp combine(_items, 0), do: [{:tuple, []}]
  defp combine([], _r), do: []

  defp combine(items, r) when r > length(items), do: []

  defp combine([head | tail], r) do
    with_head =
      combine(tail, r - 1)
      |> Enum.map(fn {:tuple, elems} -> {:tuple, [head | elems]} end)

    without_head = combine(tail, r)
    with_head ++ without_head
  end

  @spec do_combinations_with_replacement([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp do_combinations_with_replacement([iterable, r]) when is_integer(r) do
    items = materialize(iterable)
    combine_with_replacement(items, r)
  end

  @spec combine_with_replacement([Interpreter.pyvalue()], non_neg_integer()) ::
          [Interpreter.pyvalue()]
  defp combine_with_replacement(_items, 0), do: [{:tuple, []}]
  defp combine_with_replacement([], _r), do: []

  defp combine_with_replacement([head | tail] = items, r) do
    with_head =
      combine_with_replacement(items, r - 1)
      |> Enum.map(fn {:tuple, elems} -> {:tuple, [head | elems]} end)

    without_head = combine_with_replacement(tail, r)
    with_head ++ without_head
  end

  @spec do_repeat([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp do_repeat([elem]) do
    List.duplicate(elem, 1000)
  end

  defp do_repeat([elem, n]) when is_integer(n) do
    List.duplicate(elem, max(n, 0))
  end

  @spec do_compress([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp do_compress([data, selectors]) do
    data_list = materialize(data)
    selector_list = materialize(selectors)

    Enum.zip(data_list, selector_list)
    |> Enum.filter(fn {_d, s} -> Builtins.truthy?(s) end)
    |> Enum.map(fn {d, _s} -> d end)
  end

  @spec do_pairwise([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp do_pairwise([iterable]) do
    items = materialize(iterable)

    items
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> {:tuple, [a, b]} end)
  end

  @spec do_zip_longest(
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()}
        ) :: [Interpreter.pyvalue()]
  defp do_zip_longest(args, kwargs) do
    fillvalue = Map.get(kwargs, "fillvalue", nil)
    lists = Enum.map(args, &materialize/1)
    max_len = lists |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    padded =
      Enum.map(lists, fn list ->
        list ++ List.duplicate(fillvalue, max_len - length(list))
      end)

    Enum.zip(padded)
    |> Enum.map(fn tup -> {:tuple, Tuple.to_list(tup)} end)
  end

  @spec do_accumulate(
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()}
        ) :: Interpreter.pyvalue()
  defp do_accumulate([iterable], kwargs) do
    func = Map.get(kwargs, "func")
    initial = Map.get(kwargs, "initial")

    items =
      case initial do
        nil -> materialize(iterable)
        val -> [val | materialize(iterable)]
      end

    case func do
      nil -> accumulate_add(items)
      f -> {:accumulate_call, items, f}
    end
  end

  defp do_accumulate([iterable, func], kwargs) do
    initial = Map.get(kwargs, "initial")

    items =
      case initial do
        nil -> materialize(iterable)
        val -> [val | materialize(iterable)]
      end

    {:accumulate_call, items, func}
  end

  @spec accumulate_add([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp accumulate_add([]), do: []

  defp accumulate_add([first | rest]) do
    {result, _} =
      Enum.map_reduce(rest, first, fn item, acc ->
        new_acc = py_add(acc, item)
        {new_acc, new_acc}
      end)

    [first | result]
  end

  @spec py_add(Interpreter.pyvalue(), Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp py_add(a, b) when is_number(a) and is_number(b), do: a + b
  defp py_add(a, b) when is_binary(a) and is_binary(b), do: a <> b
  defp py_add(a, b) when is_list(a) and is_list(b), do: a ++ b

  defp py_add({:tuple, a}, {:tuple, b}), do: {:tuple, a ++ b}

  @spec do_count([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp do_count([]) do
    {:range, 0, 1_000_000, 1}
  end

  defp do_count([start]) when is_integer(start) do
    {:range, start, start + 1_000_000, 1}
  end

  defp do_count([start, step]) when is_integer(start) and is_integer(step) do
    stop =
      if step > 0 do
        start + step * 1_000_000
      else
        start + step * 1_000_000
      end

    {:range, start, stop, step}
  end

  @spec do_cycle([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp do_cycle([iterable]) do
    items = materialize(iterable)

    case items do
      [] -> []
      _ -> List.flatten(List.duplicate(items, 1000))
    end
  end

  @spec do_starmap([Interpreter.pyvalue()]) ::
          {:starmap_call, Interpreter.pyvalue(), [Interpreter.pyvalue()]}
  defp do_starmap([func, iterable]) do
    {:starmap_call, func, materialize(iterable)}
  end

  @spec do_takewhile([Interpreter.pyvalue()]) ::
          {:takewhile_call, Interpreter.pyvalue(), [Interpreter.pyvalue()]}
  defp do_takewhile([predicate, iterable]) do
    {:takewhile_call, predicate, materialize(iterable)}
  end

  @spec do_dropwhile([Interpreter.pyvalue()]) ::
          {:dropwhile_call, Interpreter.pyvalue(), [Interpreter.pyvalue()]}
  defp do_dropwhile([predicate, iterable]) do
    {:dropwhile_call, predicate, materialize(iterable)}
  end

  @spec do_filterfalse([Interpreter.pyvalue()]) ::
          {:filterfalse_call, Interpreter.pyvalue(), [Interpreter.pyvalue()]}
  defp do_filterfalse([predicate, iterable]) do
    {:filterfalse_call, predicate, materialize(iterable)}
  end

  @spec do_groupby(
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()}
        ) :: Interpreter.pyvalue()
  defp do_groupby([iterable], kwargs) do
    items = materialize(iterable)
    key_func = Map.get(kwargs, "key")

    case key_func do
      nil ->
        items
        |> Enum.chunk_by(& &1)
        |> Enum.map(fn group -> {:tuple, [hd(group), group]} end)

      func ->
        {:groupby_call, items, func}
    end
  end

  defp do_groupby([iterable, key_func], _kwargs) do
    {:groupby_call, materialize(iterable), key_func}
  end

  @spec do_tee([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp do_tee([iterable]) do
    items = materialize(iterable)
    {:tuple, [items, items]}
  end

  defp do_tee([iterable, n]) when is_integer(n) do
    items = materialize(iterable)
    {:tuple, List.duplicate(items, n)}
  end
end
