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

  @doc """
  Returns the module value map.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "Counter" => {:builtin, &counter/1},
      "defaultdict" => {:builtin, &defaultdict/1},
      "OrderedDict" => {:builtin, &ordered_dict/1}
    }
  end

  @spec counter([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp counter([]) do
    counter_with_methods(%{})
  end

  defp counter([list]) when is_list(list) do
    counts =
      Enum.reduce(list, %{}, fn item, acc ->
        Map.update(acc, item, 1, &(&1 + 1))
      end)

    counter_with_methods(counts)
  end

  defp counter([str]) when is_binary(str) do
    counts =
      str
      |> String.codepoints()
      |> Enum.reduce(%{}, fn ch, acc ->
        Map.update(acc, ch, 1, &(&1 + 1))
      end)

    counter_with_methods(counts)
  end

  defp counter([%{} = dict]) do
    counter_with_methods(dict)
  end

  @spec counter_with_methods(%{optional(Pyex.Interpreter.pyvalue()) => integer()}) ::
          %{optional(Pyex.Interpreter.pyvalue()) => Pyex.Interpreter.pyvalue()}
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

    Map.merge(counts, %{
      "most_common" => {:builtin, most_common_fn},
      "elements" =>
        {:builtin,
         fn [] ->
           Enum.flat_map(counts, fn {k, v} ->
             List.duplicate(k, max(v, 0))
           end)
         end}
    })
  end

  @spec defaultdict([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp defaultdict([]) do
    %{}
  end

  defp defaultdict([factory]) do
    %{"__defaultdict_factory__" => factory}
  end

  @spec ordered_dict([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp ordered_dict([]) do
    %{}
  end

  defp ordered_dict([list]) when is_list(list) do
    Enum.reduce(list, %{}, fn
      {:tuple, [k, v]}, acc -> Map.put(acc, k, v)
      [k, v], acc -> Map.put(acc, k, v)
      _, acc -> acc
    end)
  end
end
