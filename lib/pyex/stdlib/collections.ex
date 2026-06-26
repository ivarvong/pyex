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
      "OrderedDict" => {:builtin, &ordered_dict/1},
      "namedtuple" => {:builtin, &namedtuple/1},
      "deque" => {:builtin_kw, &deque/2},
      "ChainMap" => {:builtin, &chain_map/1}
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

  defp counter([{:generator, items}], _kwargs) do
    counts =
      Enum.reduce(items, %{}, fn item, acc ->
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

  @doc "Subtract two Counters, keeping only positive counts (CPython semantics)."
  @spec counter_subtract(PyDict.t() | map(), PyDict.t() | map()) :: PyDict.t()
  def counter_subtract(a, b) do
    va_map = a |> Pyex.Builtins.visible_dict() |> as_map()
    vb_map = b |> Pyex.Builtins.visible_dict() |> as_map()

    counts =
      Enum.reduce(va_map, %{}, fn {k, v}, acc ->
        diff = v - Map.get(vb_map, k, 0)
        if diff > 0, do: Map.put(acc, k, diff), else: acc
      end)

    counter_with_methods(counts)
  end

  @spec as_map(PyDict.t() | map()) :: map()
  defp as_map({:py_dict, _, _} = dict), do: PyDict.to_map(dict)
  defp as_map(map) when is_map(map), do: map

  @spec counter_with_methods(%{optional(Pyex.Interpreter.pyvalue()) => integer()}) ::
          PyDict.t()
  defp counter_with_methods(counts) do
    # `most_common`/`elements` are NOT baked in as closures — they would
    # capture the construction-time counts and go stale the moment the Counter
    # is mutated incrementally (`c[k] += 1`). They're served self-aware from the
    # live dict by `Pyex.Methods` instead.
    counts
    |> PyDict.from_map()
    |> PyDict.put("__counter__", true)
  end

  @doc """
  `Counter.most_common([n])` — read from the *current* counts (self), sorted by
  descending count with ties in first-seen order. Called from `Pyex.Methods`.
  """
  @spec counter_most_common(PyDict.t(), [Pyex.Interpreter.pyvalue()]) ::
          [Pyex.Interpreter.pyvalue()]
  def counter_most_common(dict, args) do
    sorted =
      dict
      |> ordered_counts()
      |> Enum.sort_by(fn {_k, v} -> -v end)

    taken =
      case args do
        [n] when is_integer(n) -> Enum.take(sorted, n)
        _ -> sorted
      end

    Enum.map(taken, fn {k, v} -> {:tuple, [k, v]} end)
  end

  @doc """
  `Counter.elements()` — each element repeated by its (live) count, in
  first-seen order. Called from `Pyex.Methods`.
  """
  @spec counter_elements(PyDict.t(), [Pyex.Interpreter.pyvalue()]) ::
          [Pyex.Interpreter.pyvalue()]
  def counter_elements(dict, _args) do
    dict
    |> ordered_counts()
    |> Enum.flat_map(fn {k, v} -> List.duplicate(k, max(v, 0)) end)
  end

  # Live element→count pairs in insertion order, markers/methods stripped.
  @spec ordered_counts(PyDict.t()) :: [{Pyex.Interpreter.pyvalue(), integer()}]
  defp ordered_counts(dict) do
    dict
    |> PyDict.items()
    |> Enum.reject(fn {k, v} -> is_marker_key?(k) or match?({:builtin, _}, v) end)
  end

  @doc """
  Counter.update(iterable) — adds counts from another iterable or Counter.
  Called from `Pyex.Methods` when a Counter dict receives the `update` message.
  """
  @spec counter_update(PyDict.t(), Pyex.Interpreter.pyvalue()) :: PyDict.t()
  def counter_update(counter_dict, arg) do
    counts = dict_to_counts(counter_dict)

    added =
      case arg do
        {:py_list, reversed, _} ->
          Enum.reverse(reversed)

        {:generator, items} ->
          items

        list when is_list(list) ->
          list

        str when is_binary(str) ->
          String.codepoints(str)

        {:py_dict, _, _} = dict ->
          # Mapping mode: values are added as counts.
          for {k, v} <- PyDict.to_map(dict), do: {k, v}

        _ ->
          []
      end

    new_counts =
      Enum.reduce(added, counts, fn
        {k, v}, acc when is_integer(v) -> Map.update(acc, k, v, &(&1 + v))
        item, acc -> Map.update(acc, item, 1, &(&1 + 1))
      end)

    counter_with_methods(new_counts)
  end

  @spec dict_to_counts(PyDict.t()) :: %{term() => integer()}
  defp dict_to_counts(dict) do
    dict
    |> PyDict.to_map()
    |> Enum.reject(fn {k, _} -> is_marker_key?(k) end)
    |> Enum.reject(fn {_, v} -> match?({:builtin, _}, v) end)
    |> Map.new()
  end

  @spec is_marker_key?(term()) :: boolean()
  defp is_marker_key?("__counter__"), do: true
  defp is_marker_key?("__defaultdict_factory__"), do: true
  defp is_marker_key?("most_common"), do: true
  defp is_marker_key?("elements"), do: true
  defp is_marker_key?("update"), do: true
  defp is_marker_key?(_), do: false

  @spec defaultdict([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp defaultdict([]) do
    PyDict.new()
  end

  defp defaultdict([factory]) do
    PyDict.from_pairs([{"__defaultdict_factory__", factory}])
  end

  # defaultdict(factory, mapping_or_iterable) — seed with the initial contents.
  defp defaultdict([factory, initial]) do
    seeded =
      case initial do
        {:py_dict, _, _} = dict ->
          Enum.reduce(PyDict.items(dict), PyDict.new(), fn {k, v}, acc ->
            PyDict.put(acc, k, v)
          end)

        map when is_map(map) ->
          Enum.reduce(map, PyDict.new(), fn {k, v}, acc -> PyDict.put(acc, k, v) end)

        _ ->
          PyDict.new()
      end

    PyDict.put(seeded, "__defaultdict_factory__", factory)
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

  # ── namedtuple ─────────────────────────────────────────────────────────────

  @spec namedtuple([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp namedtuple([name, fields]) when is_binary(name) do
    field_names = parse_field_names(fields)
    make_namedtuple_class(name, field_names)
  end

  defp namedtuple([name, {:tuple, fields}]) when is_binary(name) do
    namedtuple([name, fields])
  end

  defp namedtuple([name, fields]) when is_binary(name) and is_list(fields) do
    make_namedtuple_class(name, Enum.map(fields, &to_string/1))
  end

  defp namedtuple(_), do: {:exception, "TypeError: namedtuple() arguments wrong type"}

  @spec parse_field_names(Pyex.Interpreter.pyvalue()) :: [String.t()]
  defp parse_field_names(str) when is_binary(str) do
    str |> String.split(~r/[\s,]+/, trim: true)
  end

  defp parse_field_names(list) when is_list(list) do
    Enum.map(list, &to_string/1)
  end

  defp parse_field_names({:tuple, items}) do
    Enum.map(items, &to_string/1)
  end

  defp parse_field_names(_), do: []

  @spec make_namedtuple_class(String.t(), [String.t()]) :: Pyex.Interpreter.pyvalue()
  defp make_namedtuple_class(name, field_names) do
    # The class is callable (creates instances) and instances have named field access
    constructor = fn args ->
      if length(args) != length(field_names) do
        {:exception,
         "TypeError: #{name}() takes #{length(field_names)} positional argument(s) but #{length(args)} were given"}
      else
        attrs =
          Enum.zip(field_names, args)
          |> Map.new()
          |> Map.put("__namedtuple_fields__", {:tuple, Enum.map(field_names, & &1)})
          |> Map.put("__namedtuple_name__", name)

        {:instance, {:class, name, [], attrs}, %{}}
      end
    end

    class_attrs = %{
      "__name__" => name,
      "_fields" => {:tuple, field_names},
      "_make" => {:builtin, fn [items] -> constructor.(to_list(items)) end},
      "_asdict" =>
        {:builtin,
         fn [{:instance, _, attrs}] ->
           field_names
           |> Enum.map(fn k -> {k, Map.get(attrs, k)} end)
           |> PyDict.from_pairs()
         end}
    }

    {:class, name, [], Map.merge(class_attrs, %{"__constructor__" => {:builtin, constructor}})}
  end

  defp to_list({:py_list, reversed, _}), do: Enum.reverse(reversed)
  defp to_list(list) when is_list(list), do: list
  defp to_list({:tuple, items}), do: items
  defp to_list({:range, _, _, _} = r), do: Pyex.Builtins.range_to_list(r)
  defp to_list({:deque, _, _, _, _} = d), do: Pyex.Methods.deque_to_list(d)
  defp to_list(other), do: [other]

  # ── deque ───────────────────────────────────────────────────────────────────

  @spec deque([Pyex.Interpreter.pyvalue()], map()) :: Pyex.Interpreter.pyvalue()
  defp deque(args, kwargs) do
    items =
      case args do
        [] -> []
        [iterable] -> to_list(iterable)
        _ -> []
      end

    maxlen = Map.get(kwargs, "maxlen")

    items =
      if is_integer(maxlen) and length(items) > maxlen do
        Enum.take(items, -maxlen)
      else
        items
      end

    Pyex.Methods.deque_from_list(items, maxlen)
  end

  # ── ChainMap ────────────────────────────────────────────────────────────────

  @spec chain_map([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp chain_map(maps) do
    merged =
      maps
      |> Enum.reverse()
      |> Enum.reduce(PyDict.new(), fn m, acc ->
        case m do
          {:py_dict, _, _} = d ->
            Enum.reduce(PyDict.items(d), acc, fn {k, v}, a -> PyDict.put(a, k, v) end)

          map when is_map(map) ->
            Enum.reduce(map, acc, fn {k, v}, a -> PyDict.put(a, k, v) end)

          _ ->
            acc
        end
      end)

    merged
  end
end
