defmodule Pyex.Stdlib.Collections do
  @moduledoc """
  Python `collections` module.

  Provides `Counter`, `defaultdict`, and `OrderedDict`.

  `Counter` is represented as a plain dict mapping elements to counts.
  `defaultdict` is represented as a plain dict (the factory is applied
  at construction time via initial values).
  `OrderedDict` is a plain dict (Elixir maps preserve insertion order
  in practice for small sizes, and Python dicts are ordered since 3.7).
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.PyDict

  @doc """
  Returns the module value map.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "Counter" => {:builtin_kw, &counter/2},
      "defaultdict" => {:builtin, &defaultdict/1},
      "OrderedDict" => {:builtin, &ordered_dict/1}
    }
  end

  @spec counter([Pyex.Interpreter.pyvalue()], map()) :: Pyex.Interpreter.pyvalue()
  defp counter([], kwargs) when map_size(kwargs) > 0 do
    counter_with_methods(kwargs)
  end

  defp counter([], _kwargs) do
    counter_with_methods(%{})
  end

  defp counter([{:py_list, reversed, _}], _kwargs) do
    counts =
      Enum.reduce(reversed, %{}, fn item, acc ->
        Map.update(acc, item, 1, &(&1 + 1))
      end)

    counter_with_methods(counts)
  end

  defp counter([list], _kwargs) when is_list(list) do
    counts =
      Enum.reduce(list, %{}, fn item, acc ->
        Map.update(acc, item, 1, &(&1 + 1))
      end)

    counter_with_methods(counts)
  end

  defp counter([str], _kwargs) when is_binary(str) do
    counts =
      str
      |> String.codepoints()
      |> Enum.reduce(%{}, fn ch, acc ->
        Map.update(acc, ch, 1, &(&1 + 1))
      end)

    counter_with_methods(counts)
  end

  defp counter([{:py_dict, _, _} = dict], _kwargs) do
    counter_with_methods(PyDict.to_map(dict))
  end

  defp counter([%{} = dict], _kwargs) do
    counter_with_methods(dict)
  end

  @doc "Add two Counters, keeping only positive counts (CPython semantics)."
  @spec counter_add(PyDict.t() | map(), PyDict.t() | map()) :: PyDict.t()
  def counter_add(a, b) do
    va = Pyex.Builtins.visible_dict(a)
    vb = Pyex.Builtins.visible_dict(b)

    va_map = if match?({:py_dict, _, _}, va), do: PyDict.to_map(va), else: va
    vb_map = if match?({:py_dict, _, _}, vb), do: PyDict.to_map(vb), else: vb

    keys =
      (Map.keys(va_map) ++ Map.keys(vb_map))
      |> Enum.uniq()

    counts =
      Enum.reduce(keys, %{}, fn k, acc ->
        sum = Map.get(va_map, k, 0) + Map.get(vb_map, k, 0)
        if sum > 0, do: Map.put(acc, k, sum), else: acc
      end)

    counter_with_methods(counts)
  end

  @spec counter_with_methods(%{optional(Pyex.Interpreter.pyvalue()) => integer()}) ::
          PyDict.t()
  defp counter_with_methods(counts) do
    most_common_fn = fn
      [] ->
        counts
        |> Enum.sort_by(fn {_k, v} -> -v end)
        |> Enum.map(fn {k, v} -> {:tuple, [k, v]} end)

      [n] when is_integer(n) ->
        counts
        |> Enum.sort_by(fn {_k, v} -> -v end)
        |> Enum.take(n)
        |> Enum.map(fn {k, v} -> {:tuple, [k, v]} end)
    end

    base = PyDict.from_map(counts)

    base
    |> PyDict.put("__counter__", true)
    |> PyDict.put("most_common", {:builtin, most_common_fn})
    |> PyDict.put(
      "elements",
      {:builtin,
       fn [] ->
         Enum.flat_map(counts, fn {k, v} ->
           List.duplicate(k, max(v, 0))
         end)
       end}
    )
  end

  @spec defaultdict([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp defaultdict([]) do
    PyDict.new()
  end

  defp defaultdict([factory]) do
    PyDict.from_pairs([{"__defaultdict_factory__", factory}])
  end

  @spec ordered_dict([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp ordered_dict([]) do
    PyDict.new()
  end

  defp ordered_dict([{:py_list, reversed, _}]) do
    reversed
    |> Enum.reverse()
    |> Enum.reduce(PyDict.new(), fn
      {:tuple, [k, v]}, acc ->
        PyDict.put(acc, k, v)

      {:py_list, r, _}, acc ->
        case Enum.reverse(r) do
          [k, v] -> PyDict.put(acc, k, v)
          _ -> acc
        end

      [k, v], acc ->
        PyDict.put(acc, k, v)

      _, acc ->
        acc
    end)
  end

  defp ordered_dict([list]) when is_list(list) do
    Enum.reduce(list, PyDict.new(), fn
      {:tuple, [k, v]}, acc -> PyDict.put(acc, k, v)
      [k, v], acc -> PyDict.put(acc, k, v)
      _, acc -> acc
    end)
  end
end
