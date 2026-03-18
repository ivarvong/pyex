defmodule Pyex.PyDict do
  @moduledoc """
  Insertion-order-preserving Python dict representation.

  Python dicts (since 3.7) guarantee iteration in insertion order.
  Elixir maps do not.  This module provides a `{:py_dict, map, keys}`
  tuple where `map` gives O(log n) key lookup and `keys` preserves
  insertion order.

  All functions in this module are pure — they take and return the
  `{:py_dict, map, keys}` triple.  The interpreter, builtins, methods,
  and stdlib modules should use these helpers rather than operating on
  the tuple directly.
  """

  @type t ::
          {:py_dict, %{optional(Pyex.Interpreter.pyvalue()) => Pyex.Interpreter.pyvalue()},
           [Pyex.Interpreter.pyvalue()]}

  @doc """
  Creates an empty py_dict.
  """
  @spec new() :: t()
  def new, do: {:py_dict, %{}, []}

  @doc """
  Creates a py_dict from a list of `{key, value}` pairs, preserving order.
  """
  @spec from_pairs([{term(), term()}]) :: t()
  def from_pairs(pairs) do
    {map, keys} =
      Enum.reduce(pairs, {%{}, []}, fn {k, v}, {m, ks} ->
        if Map.has_key?(m, k) do
          {Map.put(m, k, v), ks}
        else
          {Map.put(m, k, v), ks ++ [k]}
        end
      end)

    {:py_dict, map, keys}
  end

  @doc """
  Converts a plain Elixir map to a py_dict.  Key order follows
  Elixir's map iteration order (arbitrary), so this is only
  suitable for maps where insertion order is already lost.
  """
  @spec from_map(%{optional(term()) => term()}) :: t()
  def from_map(map) when is_map(map) do
    {:py_dict, map, Map.keys(map)}
  end

  @doc """
  Returns the value for `key`, or `default` if not found.
  """
  @spec get(t(), term(), term()) :: term()
  def get({:py_dict, map, _keys}, key, default \\ nil) do
    Map.get(map, key, default)
  end

  @doc """
  Fetches the value for `key`.
  """
  @spec fetch(t(), term()) :: {:ok, term()} | :error
  def fetch({:py_dict, map, _keys}, key) do
    Map.fetch(map, key)
  end

  @doc """
  Returns true if `key` is present.
  """
  @spec has_key?(t(), term()) :: boolean()
  def has_key?({:py_dict, map, _keys}, key) do
    Map.has_key?(map, key)
  end

  @doc """
  Inserts or updates `key`.  If the key already exists, its position
  is preserved; otherwise it is appended.
  """
  @spec put(t(), term(), term()) :: t()
  def put({:py_dict, map, keys}, key, value) do
    if Map.has_key?(map, key) do
      {:py_dict, Map.put(map, key, value), keys}
    else
      {:py_dict, Map.put(map, key, value), keys ++ [key]}
    end
  end

  @doc """
  Deletes `key`.  No-op if not present.
  """
  @spec delete(t(), term()) :: t()
  def delete({:py_dict, map, keys}, key) do
    {:py_dict, Map.delete(map, key), List.delete(keys, key)}
  end

  @doc """
  Returns the keys in insertion order.
  """
  @spec keys(t()) :: [term()]
  def keys({:py_dict, _map, keys}), do: keys

  @doc """
  Returns the values in insertion order.
  """
  @spec values(t()) :: [term()]
  def values({:py_dict, map, keys}) do
    Enum.map(keys, &Map.fetch!(map, &1))
  end

  @doc """
  Returns `{key, value}` pairs in insertion order.
  """
  @spec items(t()) :: [{term(), term()}]
  def items({:py_dict, map, keys}) do
    Enum.map(keys, fn k -> {k, Map.fetch!(map, k)} end)
  end

  @doc """
  Returns the number of entries.
  """
  @spec size(t()) :: non_neg_integer()
  def size({:py_dict, map, _keys}), do: map_size(map)

  @doc """
  Returns true if the dict is empty.
  """
  @spec empty?(t()) :: boolean()
  def empty?({:py_dict, map, _keys}), do: map_size(map) == 0

  @doc """
  Merges `right` into `left`.  Keys from `right` that already exist in
  `left` keep their original position; new keys are appended.
  """
  @spec merge(t(), t()) :: t()
  def merge({:py_dict, l_map, l_keys}, {:py_dict, r_map, r_keys}) do
    new_keys =
      Enum.reduce(r_keys, l_keys, fn k, acc ->
        if Map.has_key?(l_map, k), do: acc, else: acc ++ [k]
      end)

    {:py_dict, Map.merge(l_map, r_map), new_keys}
  end

  @doc """
  Merges a plain map into a py_dict.  New keys are appended in the
  map's iteration order.
  """
  @spec merge_map(t(), %{optional(term()) => term()}) :: t()
  def merge_map({:py_dict, l_map, l_keys}, right) when is_map(right) do
    new_keys =
      Enum.reduce(right, l_keys, fn {k, _v}, acc ->
        if Map.has_key?(l_map, k), do: acc, else: acc ++ [k]
      end)

    {:py_dict, Map.merge(l_map, right), new_keys}
  end

  @doc """
  Pops a key, returning `{value, updated_dict}` or `{default, dict}`.
  """
  @spec pop(t(), term(), term()) :: {term(), t()}
  def pop({:py_dict, map, keys} = dict, key, default \\ nil) do
    case Map.fetch(map, key) do
      {:ok, val} -> {val, {:py_dict, Map.delete(map, key), List.delete(keys, key)}}
      :error -> {default, dict}
    end
  end

  @doc """
  Extracts the inner map (for pattern matching or Map operations).
  """
  @spec to_map(t()) :: %{optional(term()) => term()}
  def to_map({:py_dict, map, _keys}), do: map

  @doc """
  Returns true if the value is a py_dict.
  """
  defmacro is_py_dict(val) do
    quote do
      is_tuple(unquote(val)) and tuple_size(unquote(val)) == 3 and
        elem(unquote(val), 0) == :py_dict
    end
  end
end
