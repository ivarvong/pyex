defmodule Pyex.Builtins do
  @moduledoc """
  Built-in Python functions available without import.

  Provides `len()`, `range()`, `print()`, `str()`, `int()`,
  `float()`, `type()`, `abs()`, `min()`, `max()`, `sum()`,
  `sorted()`, `reversed()`, `enumerate()`, `zip()`, `map()`,
  `filter()`, `list()`, `dict()`, `bool()`, `isinstance()`,
  and `append()` (as a method-like helper).
  """

  alias Pyex.{Ctx, Env, Interpreter, PyDict}

  @doc """
  Returns an environment pre-populated with all builtins.

  By default, the environment is rebuilt on each call (~14μs).
  Call `cache!/0` at application startup to store the result
  in `:persistent_term` for zero-cost subsequent reads.
  """
  @spec env() :: Env.t()
  def env do
    case :persistent_term.get({__MODULE__, :env}, :miss) do
      :miss -> build_env()
      cached -> cached
    end
  end

  @doc """
  Returns a top-level runtime environment for executing user code.

  Includes the builtins plus `__name__ == "__main__"` and, when present,
  `__file__` from the provided context.
  """
  @spec runtime_env(Ctx.t()) :: Env.t()
  def runtime_env(%Ctx{} = ctx) do
    env = Env.put(env(), "__name__", "__main__")

    if is_binary(ctx.file) do
      Env.put(env, "__file__", ctx.file)
    else
      env
    end
  end

  @doc """
  Pre-computes the builtins environment and stores it in
  `:persistent_term` for zero-cost reads. Triggers a single
  global GC across the VM -- call once at application startup.

      # In your Application.start/2:
      Pyex.Builtins.cache!()
  """
  @spec cache!() :: :ok
  def cache! do
    :persistent_term.put({__MODULE__, :env}, build_env())
    :ok
  end

  @spec build_env() :: Env.t()
  defp build_env do
    env =
      Enum.reduce(all(), Env.new(), fn
        {name, {:kw, fun}}, env ->
          Env.put(env, name, {:builtin_kw, fun})

        {name, fun}, env ->
          Env.put(env, name, {:builtin, fun})
      end)

    Enum.reduce(type_constructors(), env, fn {name, fun}, env ->
      Env.put(env, name, {:builtin_type, name, fun})
    end)
    |> Env.put("Ellipsis", :ellipsis)
  end

  @spec all() :: [{String.t(), ([Interpreter.pyvalue()] -> Interpreter.pyvalue())}]
  defp all do
    [
      {"len", &builtin_len/1},
      {"range", &builtin_range/1},
      {"print", {:kw, &builtin_print/2}},
      {"type", &builtin_type/1},
      {"abs", &builtin_abs/1},
      {"min", {:kw, &builtin_min/2}},
      {"max", {:kw, &builtin_max/2}},
      {"sum", &builtin_sum/1},
      {"sorted", {:kw, &builtin_sorted/2}},
      {"reversed", &builtin_reversed/1},
      {"enumerate", {:kw, &builtin_enumerate/2}},
      {"zip", {:kw, &builtin_zip/2}},
      {"isinstance", &builtin_isinstance/1},
      {"issubclass", &builtin_issubclass/1},
      {"round", &builtin_round/1},
      {"input", &builtin_input/1},
      {"open", {:kw, &builtin_open/2}},
      {"any", &builtin_any/1},
      {"all", &builtin_all/1},
      {"map", &builtin_map/1},
      {"filter", &builtin_filter/1},
      {"chr", &builtin_chr/1},
      {"ord", &builtin_ord/1},
      {"hex", &builtin_hex/1},
      {"oct", &builtin_oct/1},
      {"bin", &builtin_bin/1},
      {"pow", &builtin_pow/1},
      {"divmod", &builtin_divmod/1},
      {"repr", &builtin_repr/1},
      {"callable", &builtin_callable/1},
      {"frozenset", &builtin_frozenset/1},
      {"hasattr", &builtin_hasattr/1},
      {"getattr", &builtin_getattr/1},
      {"setattr", &builtin_setattr/1},
      {"super", &builtin_super/1},
      {"iter", &builtin_iter/1},
      {"next", &builtin_next/1},
      {"exec", &builtin_exec/1},
      {"eval", &builtin_eval/1},
      {"compile", &builtin_compile/1},
      {"complex", &builtin_complex/1},
      {"bytes", &builtin_bytes/1},
      {"bytearray", &builtin_bytearray/1},
      {"dir", &builtin_dir/1},
      {"vars", &builtin_vars/1},
      {"id", &builtin_id/1},
      {"hash", &builtin_hash/1},
      {"object", &builtin_object/1},
      {"property", &builtin_property/1},
      {"staticmethod", &builtin_staticmethod/1},
      {"classmethod", &builtin_classmethod/1}
    ]
  end

  @spec type_constructors() :: [{String.t(), ([Interpreter.pyvalue()] -> Interpreter.pyvalue())}]
  defp type_constructors do
    [
      {"str", &builtin_str/1},
      {"int", &builtin_int/1},
      {"float", &builtin_float/1},
      {"bool", &builtin_bool/1},
      {"list", &builtin_list/1},
      {"dict", &builtin_dict/1},
      {"tuple", &builtin_tuple/1},
      {"set", &builtin_set/1}
    ]
  end

  @spec builtin_len([Interpreter.pyvalue()]) ::
          Interpreter.pyvalue() | Interpreter.builtin_signal()
  defp builtin_len([{:py_list, _reversed, len}]), do: len
  defp builtin_len([val]) when is_list(val), do: length(val)

  defp builtin_len([val]) when is_binary(val) do
    val |> String.codepoints() |> length()
  end

  defp builtin_len([{:py_dict, _, _} = dict]), do: PyDict.size(visible_dict(dict))
  defp builtin_len([val]) when is_map(val), do: map_size(visible_dict(val))
  defp builtin_len([{:tuple, items}]), do: length(items)
  defp builtin_len([{:set, s}]), do: MapSet.size(s)
  defp builtin_len([{:frozenset, s}]), do: MapSet.size(s)
  defp builtin_len([{:deque, items, _}]), do: length(items)
  defp builtin_len([{:generator, items}]), do: length(items)
  defp builtin_len([{:range, _, _, _} = r]), do: range_length(r)
  defp builtin_len([{:pandas_series, s}]), do: Explorer.Series.count(s)
  defp builtin_len([{:pandas_dataframe, df}]), do: elem(Explorer.DataFrame.shape(df), 0)

  defp builtin_len([{:instance, _, _} = inst]),
    do: {:dunder_call, inst, "__len__", []}

  defp builtin_len([val]),
    do: {:exception, "TypeError: object of type '#{pytype(val)}' has no len()"}

  @spec builtin_range([Interpreter.pyvalue()]) ::
          {:range, integer(), integer(), integer()} | {:exception, String.t()}
  defp builtin_range([stop]) when is_integer(stop), do: {:range, 0, stop, 1}

  defp builtin_range([start, stop]) when is_integer(start) and is_integer(stop),
    do: {:range, start, stop, 1}

  defp builtin_range([start, stop, step])
       when is_integer(start) and is_integer(stop) and is_integer(step) and step != 0,
       do: {:range, start, stop, step}

  defp builtin_range([_, _, 0]), do: {:exception, "ValueError: range() arg 3 must not be zero"}

  @max_range_len 10_000_000

  @doc false
  @spec range_to_list({:range, integer(), integer(), integer()}) ::
          [integer()] | {:exception, String.t()}
  def range_to_list({:range, _, _, _} = r) do
    len = range_length(r)

    if len > @max_range_len do
      {:exception,
       "MemoryError: range of #{len} elements exceeds maximum allowed size (#{@max_range_len})"}
    else
      do_range_to_list(r)
    end
  end

  @spec do_range_to_list({:range, integer(), integer(), integer()}) :: [integer()]
  defp do_range_to_list({:range, start, stop, step}) when step > 0 do
    if start >= stop, do: [], else: Enum.to_list(start..(stop - 1)//step)
  end

  defp do_range_to_list({:range, start, stop, step}) when step < 0 do
    if start <= stop, do: [], else: Enum.to_list(start..(stop + 1)//step)
  end

  @doc false
  @spec range_length({:range, integer(), integer(), integer()}) :: non_neg_integer()
  def range_length({:range, start, stop, step}) when step > 0 do
    if start >= stop, do: 0, else: div(stop - start + step - 1, step)
  end

  def range_length({:range, start, stop, step}) when step < 0 do
    if start <= stop, do: 0, else: div(start - stop - step - 1, -step)
  end

  @doc false
  @spec visible_dict(map() | PyDict.t()) :: map() | PyDict.t()
  def visible_dict({:py_dict, _, _} = dict) do
    dict
    |> PyDict.delete("__defaultdict_factory__")
    |> PyDict.delete("__counter__")
    |> PyDict.delete("most_common")
    |> PyDict.delete("elements")
  end

  def visible_dict(map) when is_map(map) do
    map
    |> Map.delete("__defaultdict_factory__")
    |> Map.delete("__counter__")
    |> Map.delete("most_common")
    |> Map.delete("elements")
  end

  @doc """
  Materializes an iterable value into a list of items suitable
  for creating an iterator. Returns `{:ok, items}`, `{:pass, iter}`
  if the value is already an iterator, or `:error` if not iterable.
  """
  @spec materialize_iterable(Interpreter.pyvalue()) ::
          {:ok, [Interpreter.pyvalue()]} | {:pass, Interpreter.pyvalue()} | :error
  def materialize_iterable(val) do
    case val do
      {:py_list, reversed, _} ->
        {:ok, Enum.reverse(reversed)}

      list when is_list(list) ->
        {:ok, list}

      str when is_binary(str) ->
        {:ok, String.codepoints(str)}

      {:tuple, elems} ->
        {:ok, elems}

      {:set, s} ->
        {:ok, MapSet.to_list(s)}

      {:generator, elems} ->
        {:ok, elems}

      {:range, _, _, _} = r ->
        case range_to_list(r) do
          {:exception, _} = err -> err
          list -> {:ok, list}
        end

      {:py_dict, _, _} = dict ->
        {:ok, PyDict.keys(visible_dict(dict))}

      map when is_map(map) ->
        {:ok, map |> visible_dict() |> Map.keys()}

      {:iterator, _} = it ->
        {:pass, it}

      _ ->
        :error
    end
  end

  @spec builtin_print(
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()}
        ) ::
          {:print_call, [Interpreter.pyvalue()], String.t(), String.t()}
  defp builtin_print(args, kwargs) do
    sep = Map.get(kwargs, "sep", " ")
    end_str = Map.get(kwargs, "end", "\n")
    sep = if is_binary(sep), do: sep, else: " "
    end_str = if is_binary(end_str), do: end_str, else: "\n"
    {:print_call, args, sep, end_str}
  end

  @spec builtin_str([Interpreter.pyvalue()]) ::
          Interpreter.pyvalue() | Interpreter.builtin_signal()
  defp builtin_str([]), do: ""

  defp builtin_str([{:instance, _, _} = inst]), do: {:dunder_call, inst, "__str__", []}

  defp builtin_str([val]), do: py_repr(val)

  @spec builtin_int([Interpreter.pyvalue()]) :: integer() | {:exception, String.t()}
  defp builtin_int([]), do: 0
  defp builtin_int([val]) when is_integer(val), do: val
  defp builtin_int([val]) when is_float(val), do: trunc(val)

  defp builtin_int([val]) when is_binary(val) do
    # Python accepts underscores as digit separators: int("1_000_000") == 1000000.
    trimmed = String.trim(val)

    case validate_and_strip_underscores(trimmed) do
      {:ok, cleaned} ->
        case Integer.parse(cleaned) do
          {n, ""} -> n
          _ -> {:exception, "ValueError: invalid literal for int() with base 10: '#{val}'"}
        end

      :error ->
        {:exception, "ValueError: invalid literal for int() with base 10: '#{val}'"}
    end
  end

  defp builtin_int([val, base]) when is_binary(val) and is_integer(base) do
    int_with_base(String.trim(val), base)
  end

  defp builtin_int([true]), do: 1
  defp builtin_int([false]), do: 0

  defp builtin_int([val]),
    do:
      {:exception, "TypeError: int() argument must be a string or a number, not '#{pytype(val)}'"}

  @spec validate_and_strip_underscores(String.t()) :: {:ok, String.t()} | :error
  defp validate_and_strip_underscores(""), do: :error

  defp validate_and_strip_underscores(s) do
    cond do
      String.starts_with?(s, "_") or String.ends_with?(s, "_") -> :error
      String.contains?(s, "__") -> :error
      true -> {:ok, String.replace(s, "_", "")}
    end
  end

  @spec int_with_base(String.t(), integer()) :: integer() | {:exception, String.t()}
  defp int_with_base(_str, base) when base != 0 and (base < 2 or base > 36) do
    {:exception, "ValueError: int() base must be >= 2 and <= 36, or 0"}
  end

  defp int_with_base(str, 0) do
    case str do
      "0x" <> rest -> int_with_base(rest, 16)
      "0X" <> rest -> int_with_base(rest, 16)
      "0o" <> rest -> int_with_base(rest, 8)
      "0O" <> rest -> int_with_base(rest, 8)
      "0b" <> rest -> int_with_base(rest, 2)
      "0B" <> rest -> int_with_base(rest, 2)
      _ -> int_with_base(str, 10)
    end
  end

  defp int_with_base(str, base) do
    cleaned =
      str
      |> strip_base_prefix(base)
      |> String.replace("_", "")

    case Integer.parse(cleaned, base) do
      {n, ""} -> n
      _ -> {:exception, "ValueError: invalid literal for int() with base #{base}: '#{str}'"}
    end
  end

  @spec strip_base_prefix(String.t(), integer()) :: String.t()
  defp strip_base_prefix("0x" <> rest, 16), do: rest
  defp strip_base_prefix("0X" <> rest, 16), do: rest
  defp strip_base_prefix("0o" <> rest, 8), do: rest
  defp strip_base_prefix("0O" <> rest, 8), do: rest
  defp strip_base_prefix("0b" <> rest, 2), do: rest
  defp strip_base_prefix("0B" <> rest, 2), do: rest
  defp strip_base_prefix(str, _base), do: str

  @spec builtin_float([Interpreter.pyvalue()]) :: float() | {:exception, String.t()}
  defp builtin_float([]), do: 0.0
  defp builtin_float([val]) when is_float(val), do: val
  defp builtin_float([val]) when is_integer(val), do: val / 1
  defp builtin_float([true]), do: 1.0
  defp builtin_float([false]), do: 0.0

  defp builtin_float([val]) when is_binary(val) do
    trimmed = String.trim(val)

    case String.downcase(trimmed) do
      s when s in ["inf", "+inf", "infinity", "+infinity"] ->
        :infinity

      s when s in ["-inf", "-infinity"] ->
        :neg_infinity

      "nan" ->
        :nan

      _ ->
        case Float.parse(trimmed) do
          {f, ""} -> f
          _ -> {:exception, "ValueError: could not convert string to float: '#{val}'"}
        end
    end
  end

  defp builtin_float([val]),
    do:
      {:exception,
       "TypeError: float() argument must be a string or a number, not '#{pytype(val)}'"}

  @spec builtin_type([Interpreter.pyvalue()]) ::
          {:instance, {:class, String.t(), [], map()}, map()}
  defp builtin_type([val]) do
    name = pytype(val)

    {:instance, {:class, "type", [], %{}},
     %{"__name__" => name, "__repr__" => "<class '#{name}'>"}}
  end

  @spec builtin_abs([Interpreter.pyvalue()]) ::
          Interpreter.pyvalue() | {:exception, String.t()} | {:dunder_call, any(), list()}
  defp builtin_abs([true]), do: 1
  defp builtin_abs([false]), do: 0
  defp builtin_abs([val]) when is_number(val), do: abs(val)

  defp builtin_abs([{:instance, {:class, _name, _bases, class_attrs}, inst_attrs} = inst]) do
    abs_fn = Map.get(inst_attrs, "__abs__") || Map.get(class_attrs, "__abs__")

    case abs_fn do
      {:builtin, fun} -> fun.([inst])
      nil -> {:exception, "TypeError: bad operand type for abs()"}
      _ -> {:exception, "TypeError: bad operand type for abs()"}
    end
  end

  defp builtin_abs([_]), do: {:exception, "TypeError: bad operand type for abs()"}

  @spec builtin_min(
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()}
        ) :: Interpreter.pyvalue() | Interpreter.builtin_signal()
  defp builtin_min(args, kwargs) do
    key_fn = Map.get(kwargs, "key")
    has_default = Map.has_key?(kwargs, "default")
    default = Map.get(kwargs, "default")

    case extract_minmax_items(args) do
      {:ok, items} when items != [] ->
        if key_fn, do: {:min_call, items, key_fn}, else: Enum.min(items)

      {:ok, []} ->
        if has_default do
          default
        else
          {:exception, "ValueError: min() arg is an empty sequence"}
        end

      {:error, msg} ->
        {:exception, msg}
    end
  end

  @spec builtin_max(
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()}
        ) :: Interpreter.pyvalue() | Interpreter.builtin_signal()
  defp builtin_max(args, kwargs) do
    key_fn = Map.get(kwargs, "key")
    has_default = Map.has_key?(kwargs, "default")
    default = Map.get(kwargs, "default")

    case extract_minmax_items(args) do
      {:ok, items} when items != [] ->
        if key_fn, do: {:max_call, items, key_fn}, else: Enum.max(items)

      {:ok, []} ->
        if has_default do
          default
        else
          {:exception, "ValueError: max() arg is an empty sequence"}
        end

      {:error, msg} ->
        {:exception, msg}
    end
  end

  @spec extract_minmax_items([Interpreter.pyvalue()]) ::
          {:ok, [Interpreter.pyvalue()]} | {:error, String.t()}
  defp extract_minmax_items([{:py_list, reversed, _}]), do: {:ok, Enum.reverse(reversed)}
  defp extract_minmax_items([list]) when is_list(list), do: {:ok, list}
  defp extract_minmax_items([{:generator, items}]), do: {:ok, items}

  defp extract_minmax_items([{:range, _, _, _} = r]) do
    case range_to_list(r) do
      {:exception, msg} -> {:error, msg}
      list -> {:ok, list}
    end
  end

  defp extract_minmax_items([{:set, s}]),
    do: {:ok, MapSet.to_list(s)}

  defp extract_minmax_items([{:frozenset, s}]),
    do: {:ok, MapSet.to_list(s)}

  defp extract_minmax_items([{:tuple, items}]), do: {:ok, items}

  defp extract_minmax_items(args) when length(args) >= 2, do: {:ok, args}
  defp extract_minmax_items(_), do: {:error, "TypeError: expected iterable argument"}

  @spec builtin_sum([Interpreter.pyvalue()]) ::
          Interpreter.pyvalue() | {:iter_sum, Interpreter.pyvalue()} | {:exception, String.t()}
  defp builtin_sum([iterable]), do: builtin_sum([iterable, 0])

  defp builtin_sum([{:py_list, reversed, _}, start]),
    do: sum_with_start(Enum.reverse(reversed), start)

  defp builtin_sum([list, start]) when is_list(list), do: sum_with_start(list, start)
  defp builtin_sum([{:tuple, items}, start]), do: sum_with_start(items, start)
  defp builtin_sum([{:generator, items}, start]), do: sum_with_start(items, start)

  defp builtin_sum([{:range, _, _, _} = r, start]) do
    case range_to_list(r) do
      {:exception, _} = err -> err
      list -> sum_with_start(list, start)
    end
  end

  defp builtin_sum([{:instance, _, _} = inst, start]), do: {:iter_sum, inst, start}
  defp builtin_sum([{:iterator, _} = it, start]), do: {:iter_sum, it, start}

  @spec sum_with_start([Interpreter.pyvalue()], Interpreter.pyvalue()) ::
          Interpreter.pyvalue() | {:exception, String.t()}
  defp sum_with_start(items, start) do
    cond do
      py_numeric?(start) and Enum.all?(items, &py_numeric?/1) ->
        ints = Enum.map([start | items], &bool_to_int/1)

        if is_float(start) or Enum.any?(items, &is_float/1) do
          neumaier_sum(ints)
        else
          Enum.reduce(tl(ints), hd(ints), &+/2)
        end

      true ->
        Enum.reduce(items, start, &sum_step/2)
    end
  end

  @spec py_numeric?(Interpreter.pyvalue()) :: boolean()
  defp py_numeric?(v) when is_number(v), do: true
  defp py_numeric?(true), do: true
  defp py_numeric?(false), do: true
  defp py_numeric?(_), do: false

  # Neumaier summation: a Kahan variant that handles the case where
  # `x` is larger than the running sum.  Matches CPython's `math.fsum`
  # / `sum` precision for the common float-accumulation patterns.
  @spec neumaier_sum([number()]) :: float()
  defp neumaier_sum(items) do
    {sum, c} =
      Enum.reduce(items, {0.0, 0.0}, fn x, {s, c} ->
        t = s + x

        new_c =
          if abs(s) >= abs(x) do
            c + (s - t + x)
          else
            c + (x - t + s)
          end

        {t, new_c}
      end)

    sum + c
  end

  @spec sum_step(Interpreter.pyvalue(), Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp sum_step(x, acc) when is_number(x) and is_number(acc), do: acc + x

  defp sum_step({:py_list, xr, xlen}, {:py_list, ar, alen}),
    do: {:py_list, xr ++ ar, alen + xlen}

  defp sum_step({:py_list, xr, xlen}, list) when is_list(list),
    do: {:py_list, xr ++ Enum.reverse(list), length(list) + xlen}

  defp sum_step(x, acc) when is_list(x) and is_list(acc), do: acc ++ x
  defp sum_step({:tuple, x}, {:tuple, acc}), do: {:tuple, acc ++ x}
  defp sum_step(x, acc) when is_binary(x) and is_binary(acc), do: acc <> x

  @spec builtin_sorted([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          {:sort_call, [Interpreter.pyvalue()], Interpreter.pyvalue() | nil, boolean()}
          | {:iter_sorted, Interpreter.pyvalue(), Interpreter.pyvalue() | nil, boolean()}
          | {:exception, String.t()}
  defp builtin_sorted(args, kwargs) do
    items =
      case args do
        [{:py_list, reversed, _}] ->
          Enum.reverse(reversed)

        [list] when is_list(list) ->
          list

        [{:set, s}] ->
          MapSet.to_list(s)

        [{:frozenset, s}] ->
          MapSet.to_list(s)

        [{:tuple, elems}] ->
          elems

        [{:generator, elems}] ->
          elems

        [{:range, _, _, _} = r] ->
          case range_to_list(r) do
            {:exception, _} = err -> err
            list -> list
          end

        [str] when is_binary(str) ->
          String.codepoints(str)

        [{:py_dict, _, _} = dict] ->
          PyDict.keys(visible_dict(dict))

        [map] when is_map(map) ->
          map |> visible_dict() |> Map.keys()

        [{:instance, _, _} = inst] ->
          {:needs_iter, inst}

        [{:iterator, _} = it] ->
          {:needs_iter, it}

        _ ->
          :error
      end

    case items do
      {:exception, _} = err ->
        err

      :error ->
        {:exception, "TypeError: sorted() expected iterable argument"}

      {:needs_iter, val} ->
        key_fn = Map.get(kwargs, "key")
        reverse = truthy?(Map.get(kwargs, "reverse", false))
        {:iter_sorted, val, key_fn, reverse}

      items ->
        key_fn = Map.get(kwargs, "key")
        reverse = truthy?(Map.get(kwargs, "reverse", false))
        {:sort_call, items, key_fn, reverse}
    end
  end

  @spec builtin_reversed([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  # Already reversed internally!
  defp builtin_reversed([{:py_list, reversed, _}]), do: reversed
  defp builtin_reversed([list]) when is_list(list), do: Enum.reverse(list)
  defp builtin_reversed([{:generator, items}]), do: Enum.reverse(items)

  defp builtin_reversed([{:range, _, _, _} = r]) do
    case range_to_list(r) do
      {:exception, _} = err -> err
      list -> Enum.reverse(list)
    end
  end

  defp builtin_reversed([{:tuple, items}]), do: Enum.reverse(items)

  defp builtin_reversed([str]) when is_binary(str),
    do: str |> String.codepoints() |> Enum.reverse()

  @spec builtin_enumerate([Interpreter.pyvalue()], map()) ::
          [{:tuple, [Interpreter.pyvalue()]}] | {:exception, String.t()}
  defp builtin_enumerate(args, kwargs) do
    {iterable, start} =
      case args do
        [it] -> {it, Map.get(kwargs, "start", 0)}
        [it, s] when is_integer(s) -> {it, s}
        _ -> {nil, 0}
      end

    items =
      case iterable do
        {:py_list, reversed, _} ->
          Enum.reverse(reversed)

        list when is_list(list) ->
          list

        {:generator, elems} ->
          elems

        {:range, _, _, _} = r ->
          case range_to_list(r) do
            {:exception, _} = err -> err
            list -> list
          end

        {:tuple, elems} ->
          elems

        str when is_binary(str) ->
          String.codepoints(str)

        _ ->
          nil
      end

    case items do
      {:exception, _} = err ->
        err

      nil ->
        {:exception, "TypeError: enumerate() requires an iterable"}

      _ ->
        items
        |> Enum.with_index(start)
        |> Enum.map(fn {val, idx} -> {:tuple, [idx, val]} end)
    end
  end

  @spec builtin_zip([Interpreter.pyvalue()], map()) ::
          [{:tuple, [Interpreter.pyvalue()]}] | {:exception, String.t()}
  defp builtin_zip([], _kwargs), do: []

  defp builtin_zip(args, kwargs) when is_list(args) do
    strict = Map.get(kwargs, "strict", false)

    lists =
      Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, acc} ->
        case to_list(arg) do
          {:ok, list} -> {:cont, {:ok, [list | acc]}}
          :error -> {:halt, :error}
        end
      end)

    case lists do
      {:ok, reversed_lists} ->
        ordered = Enum.reverse(reversed_lists)
        lengths = Enum.map(ordered, &length/1)

        cond do
          strict and length(Enum.uniq(lengths)) > 1 ->
            {:exception,
             "ValueError: zip() argument #{Enum.find_index(lengths, fn l -> l != List.first(lengths) end) + 1} is shorter than argument #{1}"}

          true ->
            ordered
            |> Enum.zip()
            |> Enum.map(fn t -> {:tuple, Tuple.to_list(t)} end)
        end

      :error ->
        {:exception, "TypeError: zip argument is not iterable"}
    end
  end

  @spec to_list(Interpreter.pyvalue()) :: {:ok, [Interpreter.pyvalue()]} | :error
  @doc false
  @spec to_list_safe(Interpreter.pyvalue()) :: [Interpreter.pyvalue()]
  def to_list_safe(val) do
    case to_list(val) do
      {:ok, items} -> items
      :error -> []
    end
  end

  defp to_list({:deque, items, _}), do: {:ok, items}
  defp to_list({:py_list, reversed, _}), do: {:ok, Enum.reverse(reversed)}
  defp to_list(list) when is_list(list), do: {:ok, list}

  defp to_list({:range, _, _, _} = r) do
    case range_to_list(r) do
      {:exception, _} -> :error
      list -> {:ok, list}
    end
  end

  defp to_list({:tuple, items}), do: {:ok, items}
  defp to_list({:generator, items}), do: {:ok, items}
  defp to_list({:set, s}), do: {:ok, MapSet.to_list(s)}
  defp to_list({:frozenset, s}), do: {:ok, MapSet.to_list(s)}
  defp to_list(str) when is_binary(str), do: {:ok, String.codepoints(str)}
  defp to_list({:py_dict, _, _} = dict), do: {:ok, PyDict.keys(visible_dict(dict))}
  defp to_list(map) when is_map(map), do: {:ok, map |> visible_dict() |> Map.keys()}
  defp to_list(_), do: :error

  @spec builtin_bool([Interpreter.pyvalue()]) ::
          boolean() | {:dunder_call, Interpreter.pyvalue(), String.t(), []}
  defp builtin_bool([{:instance, _, _} = inst]), do: {:dunder_call, inst, "__bool__", []}
  defp builtin_bool([val]), do: truthy?(val)

  @spec builtin_list([Interpreter.pyvalue()]) ::
          [Interpreter.pyvalue()] | {:iter_to_list, Interpreter.pyvalue()}
  defp builtin_list([]), do: []
  defp builtin_list([{:py_list, reversed, _}]), do: Enum.reverse(reversed)
  defp builtin_list([list]) when is_list(list), do: list

  defp builtin_list([string]) when is_binary(string) do
    String.codepoints(string)
  end

  defp builtin_list([{:tuple, items}]), do: items
  defp builtin_list([{:set, s}]), do: MapSet.to_list(s)
  defp builtin_list([{:frozenset, s}]), do: MapSet.to_list(s)
  defp builtin_list([{:deque, items, _}]), do: items
  defp builtin_list([{:generator, items}]), do: items

  defp builtin_list([{:range, _, _, _} = r]) do
    case range_to_list(r) do
      {:exception, _} = err -> err
      list -> list
    end
  end

  defp builtin_list([{:py_dict, _, _} = dict]), do: PyDict.keys(visible_dict(dict))
  defp builtin_list([map]) when is_map(map), do: map |> visible_dict() |> Map.keys()
  defp builtin_list([{:instance, _, _} = inst]), do: {:iter_to_list, inst}
  defp builtin_list([{:iterator, _} = it]), do: {:iter_to_list, it}

  @doc false
  @spec builtin_dict([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          PyDict.t() | {:exception, String.t()}
  def builtin_dict(args, kwargs \\ %{}) do
    with {:ok, dict} <- builtin_dict_positional(args) do
      Enum.reduce(kwargs, dict, fn {k, v}, acc -> PyDict.put(acc, k, v) end)
    end
  end

  @spec builtin_dict_positional([Interpreter.pyvalue()]) ::
          {:ok, PyDict.t()} | {:exception, String.t()}
  defp builtin_dict_positional([]), do: {:ok, PyDict.new()}

  defp builtin_dict_positional([{:py_dict, _, _} = dict]) do
    {:ok, visible_dict(dict)}
  end

  defp builtin_dict_positional([map]) when is_map(map) do
    {:ok,
     map
     |> visible_dict()
     |> Map.reject(fn {_k, v} ->
       match?({:builtin, _}, v) or match?({:builtin_kw, _}, v) or
         match?({:function, _, _, _, _}, v) or match?({:bound_method, _, _}, v) or
         match?({:bound_method, _, _, _}, v)
     end)
     |> PyDict.from_map()}
  end

  defp builtin_dict_positional([list]) when is_list(list) do
    {:ok,
     Enum.reduce(list, PyDict.new(), fn
       {:tuple, [k, v]}, acc -> PyDict.put(acc, k, v)
       [k, v], acc -> PyDict.put(acc, k, v)
       _, acc -> acc
     end)}
  end

  defp builtin_dict_positional([{:py_list, reversed, _}]) do
    list = Enum.reverse(reversed)

    {:ok,
     Enum.reduce(list, PyDict.new(), fn
       {:tuple, [k, v]}, acc -> PyDict.put(acc, k, v)
       [k, v], acc -> PyDict.put(acc, k, v)
       _, acc -> acc
     end)}
  end

  defp builtin_dict_positional([_]), do: {:exception, "TypeError: cannot convert to dict"}

  defp builtin_dict_positional(args) do
    {:exception, "TypeError: dict expected at most 1 argument, got #{length(args)}"}
  end

  @doc false
  @spec dict_fromkeys(Interpreter.pyvalue(), Interpreter.pyvalue()) ::
          PyDict.t() | {:exception, String.t()}
  def dict_fromkeys(keys, default) do
    keys_list =
      case keys do
        {:py_list, reversed, _} -> Enum.reverse(reversed)
        list when is_list(list) -> list
        {:tuple, items} -> items
        {:set, s} -> MapSet.to_list(s)
        {:frozenset, s} -> MapSet.to_list(s)
        {:range, _, _, _} = r -> range_to_list(r)
        str when is_binary(str) -> String.codepoints(str)
        _ -> {:error, "TypeError: dict.fromkeys() argument is not iterable"}
      end

    case keys_list do
      {:error, msg} ->
        {:exception, msg}

      list ->
        Enum.reduce(list, PyDict.new(), fn k, acc -> PyDict.put(acc, k, default) end)
    end
  end

  @spec builtin_isinstance([Interpreter.pyvalue()]) :: boolean()
  defp builtin_isinstance([val, type_name]) when is_binary(type_name) do
    pytype(val) == type_name
  end

  defp builtin_isinstance([val, {:builtin_type, type_name, _}]) do
    actual = pytype(val)

    actual == type_name or
      (type_name == "int" and actual == "bool")
  end

  defp builtin_isinstance([{:instance, {:class, name, bases, _}, _}, {:class, target_name, _, _}]) do
    name == target_name or check_bases(bases, target_name)
  end

  defp builtin_isinstance([val, {:tuple, types}]) do
    Enum.any?(types, fn t ->
      builtin_isinstance([val, t])
    end)
  end

  defp builtin_isinstance([_, _]), do: false

  @spec builtin_issubclass([Interpreter.pyvalue()]) :: boolean() | {:exception, String.t()}
  defp builtin_issubclass([{:class, name, bases, _}, {:class, target_name, _, _}]) do
    name == target_name or check_bases(bases, target_name)
  end

  defp builtin_issubclass([{:class, name, bases, _}, {:builtin_type, type_name, _}]) do
    name == type_name or check_bases(bases, type_name)
  end

  defp builtin_issubclass([{:class, _, _, _} = cls, {:tuple, types}]) do
    Enum.any?(types, fn t ->
      builtin_issubclass([cls, t])
    end)
  end

  defp builtin_issubclass([{:class, _, _, _}, _]), do: false

  # Built-in type hierarchy: bool is a subtype of int
  defp builtin_issubclass([{:builtin_type, sub, _}, {:builtin_type, sup, _}]) do
    sub == sup or builtin_subtype?(sub, sup)
  end

  defp builtin_issubclass([{:builtin_type, sub, _}, {:class, sup_name, _, _}]) do
    sub == sup_name
  end

  defp builtin_issubclass([{:builtin_type, _, _}, _]), do: false

  defp builtin_issubclass([arg1, _arg2]) do
    {:exception, "TypeError: issubclass() arg 1 must be a class, not #{pytype(arg1)}"}
  end

  @builtin_hierarchy %{
    "bool" => ["int"],
    "int" => ["object"],
    "float" => ["object"],
    "str" => ["object"],
    "list" => ["object"],
    "dict" => ["object"],
    "tuple" => ["object"],
    "set" => ["object"],
    "object" => []
  }

  @spec builtin_subtype?(String.t(), String.t()) :: boolean()
  defp builtin_subtype?(sub, sup) do
    parents = Map.get(@builtin_hierarchy, sub, [])

    Enum.any?(parents, fn parent ->
      parent == sup or builtin_subtype?(parent, sup)
    end)
  end

  @spec check_bases([Interpreter.pyvalue()], String.t()) :: boolean()
  defp check_bases([], _target), do: false

  defp check_bases(bases, target) do
    Enum.any?(bases, fn
      {:class, name, sub_bases, _} ->
        name == target or check_bases(sub_bases, target)

      _ ->
        false
    end)
  end

  @spec builtin_tuple([Interpreter.pyvalue()]) ::
          Interpreter.pyvalue() | Interpreter.builtin_signal()
  defp builtin_tuple([]), do: {:tuple, []}
  defp builtin_tuple([{:py_list, reversed, _}]), do: {:tuple, Enum.reverse(reversed)}
  defp builtin_tuple([list]) when is_list(list), do: {:tuple, list}
  defp builtin_tuple([{:tuple, _} = t]), do: t

  defp builtin_tuple([str]) when is_binary(str),
    do: {:tuple, String.codepoints(str)}

  defp builtin_tuple([{:generator, items}]), do: {:tuple, items}

  defp builtin_tuple([{:range, _, _, _} = r]) do
    case range_to_list(r) do
      {:exception, _} = err -> err
      list -> {:tuple, list}
    end
  end

  defp builtin_tuple([{:instance, _, _} = inst]), do: {:iter_to_tuple, inst}
  defp builtin_tuple([{:iterator, _} = it]), do: {:iter_to_tuple, it}

  @spec builtin_set([Interpreter.pyvalue()]) ::
          Interpreter.pyvalue() | Interpreter.builtin_signal()
  defp builtin_set([]), do: {:set, MapSet.new()}
  defp builtin_set([{:py_list, reversed, _}]), do: {:set, MapSet.new(Enum.reverse(reversed))}
  defp builtin_set([list]) when is_list(list), do: {:set, MapSet.new(list)}
  defp builtin_set([{:tuple, items}]), do: {:set, MapSet.new(items)}
  defp builtin_set([{:set, _} = s]), do: s
  defp builtin_set([{:frozenset, s}]), do: {:set, s}
  defp builtin_set([str]) when is_binary(str), do: {:set, MapSet.new(String.codepoints(str))}
  defp builtin_set([{:generator, items}]), do: {:set, MapSet.new(items)}

  defp builtin_set([{:range, _, _, _} = r]) do
    case range_to_list(r) do
      {:exception, _} = err -> err
      list -> {:set, MapSet.new(list)}
    end
  end

  defp builtin_set([{:instance, _, _} = inst]), do: {:iter_to_set, inst}
  defp builtin_set([{:iterator, _} = it]), do: {:iter_to_set, it}

  @spec builtin_frozenset([Interpreter.pyvalue()]) ::
          Interpreter.pyvalue() | Interpreter.builtin_signal()
  defp builtin_frozenset([]), do: {:frozenset, MapSet.new()}

  defp builtin_frozenset([{:py_list, reversed, _}]),
    do: {:frozenset, MapSet.new(Enum.reverse(reversed))}

  defp builtin_frozenset([list]) when is_list(list), do: {:frozenset, MapSet.new(list)}
  defp builtin_frozenset([{:tuple, items}]), do: {:frozenset, MapSet.new(items)}
  defp builtin_frozenset([{:set, s}]), do: {:frozenset, s}
  defp builtin_frozenset([{:frozenset, _} = fs]), do: fs

  defp builtin_frozenset([str]) when is_binary(str),
    do: {:frozenset, MapSet.new(String.codepoints(str))}

  defp builtin_frozenset([{:generator, items}]), do: {:frozenset, MapSet.new(items)}

  defp builtin_frozenset([{:range, _, _, _} = r]) do
    case range_to_list(r) do
      {:exception, _} = err -> err
      list -> {:frozenset, MapSet.new(list)}
    end
  end

  defp builtin_frozenset([{:instance, _, _} = inst]), do: {:iter_to_frozenset, inst}
  defp builtin_frozenset([{:iterator, _} = it]), do: {:iter_to_frozenset, it}

  @spec builtin_round([Interpreter.pyvalue()]) ::
          Interpreter.pyvalue() | Interpreter.builtin_signal()
  defp builtin_round([val]) when is_boolean(val), do: bool_to_int(val)
  defp builtin_round([val]) when is_integer(val), do: val
  defp builtin_round([val]) when is_float(val), do: bankers_round(val)

  defp builtin_round([val, ndigits]) when is_boolean(val) and is_integer(ndigits),
    do: bool_to_int(val)

  defp builtin_round([val, ndigits]) when is_number(val) and is_integer(ndigits) do
    float_str = :erlang.float_to_binary(val / 1, [])

    case Decimal.parse(float_str) do
      {d, ""} ->
        rounded = Decimal.round(d, ndigits, :half_even)
        result = Decimal.to_float(rounded)
        if ndigits <= 0 and is_integer(val), do: round(result), else: result

      _ ->
        factor = :math.pow(10, ndigits)
        scaled = val * factor
        bankers_round(scaled) / factor
    end
  end

  defp builtin_round([_]),
    do: {:exception, "TypeError: type has no __round__ method"}

  defp builtin_round([_, _]),
    do: {:exception, "TypeError: type has no __round__ method"}

  # Python uses banker's rounding (round-half-to-even).
  @spec bankers_round(float()) :: integer()
  defp bankers_round(x) when x < 0, do: -bankers_round(-x)

  defp bankers_round(x) do
    fi = trunc(x)
    frac = x - fi

    cond do
      abs(frac - 0.5) < 1.0e-9 ->
        if rem(fi, 2) == 0, do: fi, else: fi + 1

      frac > 0.5 ->
        fi + 1

      true ->
        fi
    end
  end

  @spec builtin_input([Interpreter.pyvalue()]) :: {:exception, String.t()}
  defp builtin_input(_args) do
    {:exception, "RuntimeError: input() is not supported in the sandbox"}
  end

  @spec builtin_open(
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()}
        ) ::
          {:ctx_call, (Pyex.Env.t(), Pyex.Ctx.t() -> term())}
          | {:exception, String.t()}
  defp builtin_open(args, kwargs) do
    with :ok <- validate_open_kwargs(kwargs),
         {:ok, path} <- resolve_open_path(args, kwargs),
         {:ok, mode_str} <- resolve_open_mode(args, kwargs) do
      open_file_handle(path, mode_str)
    else
      {:exception, _} = error -> error
    end
  end

  @open_supported_kwargs ["file", "mode", "encoding", "newline", "errors"]

  @spec validate_open_kwargs(%{optional(String.t()) => Interpreter.pyvalue()}) ::
          :ok | {:exception, String.t()}
  defp validate_open_kwargs(kwargs) do
    case Map.keys(kwargs) -- @open_supported_kwargs do
      [] -> :ok
      [name | _] -> {:exception, "TypeError: open() got an unexpected keyword argument '#{name}'"}
    end
  end

  @spec resolve_open_path([Interpreter.pyvalue()], %{
          optional(String.t()) => Interpreter.pyvalue()
        }) ::
          {:ok, String.t()} | {:exception, String.t()}
  defp resolve_open_path(args, kwargs) do
    cond do
      length(args) > 2 ->
        {:exception,
         "TypeError: open() takes from 1 to 2 positional arguments but #{length(args)} were given"}

      length(args) >= 1 and Map.has_key?(kwargs, "file") ->
        {:exception, "TypeError: argument for open() given by name ('file') and position (1)"}

      length(args) >= 1 ->
        coerce_pathlike(hd(args), "open() argument 'file'")

      Map.has_key?(kwargs, "file") ->
        coerce_pathlike(Map.fetch!(kwargs, "file"), "open() argument 'file'")

      args == [] and not Map.has_key?(kwargs, "file") ->
        {:exception, "TypeError: open() missing required argument 'file' (pos 1)"}

      true ->
        {:exception, "TypeError: invalid arguments"}
    end
  end

  @spec coerce_pathlike(Interpreter.pyvalue(), String.t()) ::
          {:ok, String.t()} | {:exception, String.t()}
  defp coerce_pathlike(value, label) do
    case Pyex.Path.coerce(value) do
      {:ok, path} -> {:ok, path}
      :error -> {:exception, "TypeError: #{label} must be str or PathLike"}
    end
  end

  @spec resolve_open_mode([Interpreter.pyvalue()], %{
          optional(String.t()) => Interpreter.pyvalue()
        }) ::
          {:ok, String.t()} | {:exception, String.t()}
  defp resolve_open_mode(args, kwargs) do
    cond do
      length(args) >= 2 and Map.has_key?(kwargs, "mode") ->
        {:exception, "TypeError: argument for open() given by name ('mode') and position (2)"}

      match?([_, mode] when is_binary(mode), args) ->
        {:ok, Enum.at(args, 1)}

      match?(%{"mode" => mode} when is_binary(mode), kwargs) ->
        {:ok, Map.fetch!(kwargs, "mode")}

      length(args) <= 1 and not Map.has_key?(kwargs, "mode") ->
        {:ok, "r"}

      true ->
        {:exception, "TypeError: invalid arguments"}
    end
  end

  @spec open_file_handle(String.t(), String.t()) ::
          {:ctx_call, (Pyex.Env.t(), Pyex.Ctx.t() -> term())}
          | {:exception, String.t()}
  defp open_file_handle(path, mode_str) do
    normalized = String.replace(mode_str, "b", "")

    case normalized do
      m when m in ["r", "w", "a"] ->
        mode = %{"r" => :read, "w" => :write, "a" => :append} |> Map.fetch!(m)

        {:ctx_call,
         fn env, ctx ->
           case Pyex.Ctx.open_handle(ctx, path, mode) do
             {:ok, id, ctx} ->
               {{:file_handle, id}, env, ctx}

             {:error, msg} ->
               {{:exception, msg}, env, ctx}
           end
         end}

      _ ->
        {:exception, "ValueError: invalid mode: '#{mode_str}' (normalized: '#{normalized}')"}
    end
  end

  @spec builtin_any([Interpreter.pyvalue()]) :: boolean() | {:exception, String.t()}
  defp builtin_any([{:py_list, reversed, _}]), do: Enum.any?(Enum.reverse(reversed), &truthy?/1)
  defp builtin_any([list]) when is_list(list), do: Enum.any?(list, &truthy?/1)
  defp builtin_any([{:tuple, items}]), do: Enum.any?(items, &truthy?/1)
  defp builtin_any([{:generator, items}]), do: Enum.any?(items, &truthy?/1)

  defp builtin_any([{:range, _, _, _} = r]) do
    case range_to_list(r) do
      {:exception, _} = err -> err
      list -> Enum.any?(list, &truthy?/1)
    end
  end

  defp builtin_any([val]),
    do: {:exception, "TypeError: argument of type '#{pytype(val)}' is not iterable"}

  @spec builtin_all([Interpreter.pyvalue()]) :: boolean() | {:exception, String.t()}
  defp builtin_all([{:py_list, reversed, _}]), do: Enum.all?(Enum.reverse(reversed), &truthy?/1)
  defp builtin_all([list]) when is_list(list), do: Enum.all?(list, &truthy?/1)
  defp builtin_all([{:tuple, items}]), do: Enum.all?(items, &truthy?/1)
  defp builtin_all([{:generator, items}]), do: Enum.all?(items, &truthy?/1)

  defp builtin_all([{:range, _, _, _} = r]) do
    case range_to_list(r) do
      {:exception, _} = err -> err
      list -> Enum.all?(list, &truthy?/1)
    end
  end

  defp builtin_all([val]),
    do: {:exception, "TypeError: argument of type '#{pytype(val)}' is not iterable"}

  @spec builtin_map([Interpreter.pyvalue()]) ::
          Interpreter.pyvalue() | Interpreter.builtin_signal()
  defp builtin_map([{:builtin, func} | iterables]) when iterables != [] do
    case collect_iterables(iterables) do
      {:ok, lists} -> map_with_func(func, lists)
      {:exception, _} = e -> e
    end
  end

  defp builtin_map([{:builtin_type, _, func} | iterables]) when iterables != [] do
    case collect_iterables(iterables) do
      {:ok, lists} -> map_with_func(func, lists)
      {:exception, _} = e -> e
    end
  end

  defp builtin_map([{:function, _, _, _, _} = func | iterables]) when iterables != [] do
    case collect_iterables(iterables) do
      {:ok, lists} -> {:map_call, func, zip_truncate(lists)}
      {:exception, _} = e -> e
    end
  end

  defp builtin_map([{:builtin_kw, func} | iterables]) when iterables != [] do
    case collect_iterables(iterables) do
      {:ok, lists} ->
        map_with_func(fn args -> func.(args, %{}) end, lists)

      {:exception, _} = e ->
        e
    end
  end

  defp builtin_map([_func | _]),
    do: {:exception, "TypeError: map() first arg must be callable"}

  defp builtin_map(_),
    do: {:exception, "TypeError: map() requires at least 2 arguments"}

  @spec collect_iterables([Interpreter.pyvalue()]) ::
          {:ok, [[Interpreter.pyvalue()]]} | {:exception, String.t()}
  defp collect_iterables(iterables) do
    Enum.reduce_while(iterables, {:ok, []}, fn iter, {:ok, acc} ->
      case to_list(iter) do
        {:ok, list} -> {:cont, {:ok, [list | acc]}}
        :error -> {:halt, {:exception, "TypeError: map() argument is not iterable"}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  @spec zip_truncate([[Interpreter.pyvalue()]]) :: [[Interpreter.pyvalue()]]
  defp zip_truncate([]), do: []
  defp zip_truncate([single]), do: Enum.map(single, &[&1])

  defp zip_truncate(lists) do
    lists
    |> Enum.zip()
    |> Enum.map(&Tuple.to_list/1)
  end

  @spec map_with_func(
          ([Interpreter.pyvalue()] -> Interpreter.pyvalue()),
          [[Interpreter.pyvalue()]]
        ) :: [Interpreter.pyvalue()] | {:exception, String.t()}
  defp map_with_func(func, lists) do
    grouped = zip_truncate(lists)

    result =
      Enum.reduce_while(grouped, [], fn args, acc ->
        case func.(args) do
          {:exception, _} = exc -> {:halt, exc}
          val -> {:cont, [val | acc]}
        end
      end)

    case result do
      {:exception, _} = exc -> exc
      acc -> Enum.reverse(acc)
    end
  end

  @spec builtin_filter([Interpreter.pyvalue()]) ::
          Interpreter.pyvalue() | Interpreter.builtin_signal()
  defp builtin_filter([nil, list]) when is_list(list) do
    Enum.filter(list, &truthy?/1)
  end

  defp builtin_filter([nil, {:py_list, reversed, _}]) do
    Enum.filter(Enum.reverse(reversed), &truthy?/1)
  end

  defp builtin_filter([nil, iterable]) do
    case to_list(iterable) do
      {:ok, items} -> Enum.filter(items, &truthy?/1)
      :error -> {:exception, "TypeError: filter() argument is not iterable"}
    end
  end

  defp builtin_filter([{:builtin, func}, list]) when is_list(list) do
    filter_with_func(func, list)
  end

  defp builtin_filter([{:builtin_type, _, func}, list]) when is_list(list) do
    filter_with_func(func, list)
  end

  defp builtin_filter([{:function, _, _, _, _} = func, list]) when is_list(list) do
    {:filter_call, func, list}
  end

  defp builtin_filter([func, iterable]) do
    case to_list(iterable) do
      {:ok, items} -> builtin_filter([func, items])
      :error -> {:exception, "TypeError: filter() argument is not iterable"}
    end
  end

  @spec filter_with_func(
          ([Interpreter.pyvalue()] -> Interpreter.pyvalue()),
          [Interpreter.pyvalue()]
        ) :: [Interpreter.pyvalue()] | {:exception, String.t()}
  defp filter_with_func(func, list) do
    result =
      Enum.reduce_while(list, [], fn item, acc ->
        case func.([item]) do
          {:exception, _} = exc -> {:halt, exc}
          val -> if truthy?(val), do: {:cont, [item | acc]}, else: {:cont, acc}
        end
      end)

    case result do
      {:exception, _} = exc -> exc
      acc -> Enum.reverse(acc)
    end
  end

  @spec builtin_chr([Interpreter.pyvalue()]) :: String.t() | {:exception, String.t()}
  defp builtin_chr([val]) when is_boolean(val), do: builtin_chr([bool_to_int(val)])

  defp builtin_chr([val]) when is_integer(val) and val >= 0 and val <= 0x10FFFF do
    <<val::utf8>>
  end

  defp builtin_chr([val]) when is_integer(val) do
    {:exception, "ValueError: chr() arg not in range(0x110000)"}
  end

  defp builtin_chr([_]), do: {:exception, "TypeError: an integer is required"}

  @spec builtin_ord([Interpreter.pyvalue()]) :: integer() | {:exception, String.t()}
  defp builtin_ord([val]) when is_binary(val) do
    case String.to_charlist(val) do
      [cp] ->
        cp

      _ ->
        {:exception,
         "TypeError: ord() expected a character, but string of length #{String.length(val)} found"}
    end
  end

  defp builtin_ord([_]), do: {:exception, "TypeError: ord() expected string of length 1"}

  @spec builtin_hex([Interpreter.pyvalue()]) :: String.t() | {:exception, String.t()}
  defp builtin_hex([val]) when is_boolean(val), do: builtin_hex([bool_to_int(val)])

  defp builtin_hex([val]) when is_integer(val) and val >= 0,
    do: ("0x" <> Integer.to_string(val, 16)) |> String.downcase()

  defp builtin_hex([val]) when is_integer(val),
    do: ("-0x" <> Integer.to_string(abs(val), 16)) |> String.downcase()

  defp builtin_hex([_]),
    do: {:exception, "TypeError: 'float' object cannot be interpreted as an integer"}

  @spec builtin_oct([Interpreter.pyvalue()]) :: String.t() | {:exception, String.t()}
  defp builtin_oct([val]) when is_boolean(val), do: builtin_oct([bool_to_int(val)])
  defp builtin_oct([val]) when is_integer(val) and val >= 0, do: "0o" <> Integer.to_string(val, 8)
  defp builtin_oct([val]) when is_integer(val), do: "-0o" <> Integer.to_string(abs(val), 8)

  defp builtin_oct([_]),
    do: {:exception, "TypeError: 'float' object cannot be interpreted as an integer"}

  @spec builtin_bin([Interpreter.pyvalue()]) :: String.t() | {:exception, String.t()}
  defp builtin_bin([val]) when is_boolean(val), do: builtin_bin([bool_to_int(val)])
  defp builtin_bin([val]) when is_integer(val) and val >= 0, do: "0b" <> Integer.to_string(val, 2)
  defp builtin_bin([val]) when is_integer(val), do: "-0b" <> Integer.to_string(abs(val), 2)

  defp builtin_bin([_]),
    do: {:exception, "TypeError: 'float' object cannot be interpreted as an integer"}

  @spec builtin_pow([Interpreter.pyvalue()]) :: number() | {:exception, String.t()}
  defp builtin_pow(args) when is_list(args) do
    coerced =
      Enum.map(args, fn
        v when is_boolean(v) -> bool_to_int(v)
        v -> v
      end)

    builtin_pow_dispatch(coerced)
  end

  defp builtin_pow_dispatch([base, exp]) when is_integer(base) and is_integer(exp) and exp >= 0,
    do: int_pow(base, exp)

  defp builtin_pow_dispatch([base, exp]) when is_number(base) and is_number(exp),
    do: :math.pow(base, exp)

  defp builtin_pow_dispatch([base, exp, mod])
       when is_integer(base) and is_integer(exp) and is_integer(mod) and mod != 0 do
    mod_pow(base, exp, mod)
  end

  defp builtin_pow_dispatch([_, _, 0]),
    do: {:exception, "ValueError: pow() 3rd argument cannot be 0"}

  defp builtin_pow_dispatch(_),
    do: {:exception, "TypeError: unsupported operand type(s) for pow()"}

  @spec int_pow(integer(), non_neg_integer()) :: integer()
  defp int_pow(_base, 0), do: 1
  defp int_pow(base, 1), do: base

  defp int_pow(base, exp) when rem(exp, 2) == 0 do
    half = int_pow(base, div(exp, 2))
    half * half
  end

  defp int_pow(base, exp) do
    base * int_pow(base, exp - 1)
  end

  @spec builtin_divmod([Interpreter.pyvalue()]) ::
          {:tuple, [integer()]} | {:exception, String.t()}
  defp builtin_divmod([a, b]) when is_boolean(a) or is_boolean(b),
    do: builtin_divmod([bool_to_int(a), bool_to_int(b)])

  defp builtin_divmod([_, b]) when b == 0 or b == 0.0,
    do: {:exception, "ZeroDivisionError: integer division or modulo by zero"}

  defp builtin_divmod([a, b]) when is_integer(a) and is_integer(b) do
    q = Integer.floor_div(a, b)
    r = a - q * b
    {:tuple, [q, r]}
  end

  defp builtin_divmod([a, b]) when is_number(a) and is_number(b) do
    q = Float.floor(a / b)
    r = a - q * b
    {:tuple, [q, r]}
  end

  @spec builtin_repr([Interpreter.pyvalue()]) ::
          Interpreter.pyvalue() | Interpreter.builtin_signal()
  defp builtin_repr([{:instance, _, _} = inst]), do: {:dunder_call, inst, "__repr__", []}

  defp builtin_repr([val]) when is_list(val) do
    {:ctx_call, fn env, ctx -> Pyex.Interpreter.Protocols.eval_py_repr(val, env, ctx) end}
  end

  defp builtin_repr([{:py_list, _, _} = val]) do
    {:ctx_call, fn env, ctx -> Pyex.Interpreter.Protocols.eval_py_repr(val, env, ctx) end}
  end

  defp builtin_repr([{:tuple, _} = val]) do
    {:ctx_call, fn env, ctx -> Pyex.Interpreter.Protocols.eval_py_repr(val, env, ctx) end}
  end

  defp builtin_repr([{:py_dict, _, _} = val]) do
    {:ctx_call, fn env, ctx -> Pyex.Interpreter.Protocols.eval_py_repr(val, env, ctx) end}
  end

  defp builtin_repr([val]), do: py_repr_quoted(val)

  @spec builtin_hasattr([Interpreter.pyvalue()]) :: boolean()
  defp builtin_hasattr([{:instance, {:class, _, _, _} = class, attrs}, attr])
       when is_binary(attr) do
    Map.has_key?(attrs, attr) or has_class_attr?(class, attr) or
      has_class_attr?(class, "__getattr__")
  end

  defp builtin_hasattr([{:py_dict, _, _} = dict, attr]) when is_binary(attr) do
    PyDict.has_key?(dict, attr)
  end

  defp builtin_hasattr([obj, attr]) when is_map(obj) and is_binary(attr) do
    Map.has_key?(obj, attr)
  end

  defp builtin_hasattr([obj, attr]) when is_binary(attr) do
    Pyex.Methods.resolve(obj, attr) != :error
  end

  defp builtin_hasattr([_, _]), do: false

  @spec has_class_attr?(Interpreter.pyvalue(), String.t()) :: boolean()
  defp has_class_attr?({:class, _, bases, class_attrs}, attr) do
    Map.has_key?(class_attrs, attr) or Enum.any?(bases, &has_class_attr?(&1, attr))
  end

  @spec find_class_attr(Interpreter.pyvalue(), String.t()) ::
          {:ok, Interpreter.pyvalue()} | :error
  defp find_class_attr({:class, _, bases, class_attrs}, attr) do
    case Map.fetch(class_attrs, attr) do
      {:ok, _val} = found -> found
      :error -> Enum.find_value(bases, :error, &find_class_attr(&1, attr))
    end
  end

  @spec builtin_getattr([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp builtin_getattr([{:instance, {:class, name, _, _} = class, attrs}, attr])
       when is_binary(attr) do
    case Map.get(attrs, attr) do
      nil ->
        case find_class_attr(class, attr) do
          {:ok, val} -> val
          :error -> {:exception, "AttributeError: '#{name}' object has no attribute '#{attr}'"}
        end

      val ->
        val
    end
  end

  defp builtin_getattr([{:instance, class, attrs}, attr, default]) when is_binary(attr) do
    case Map.get(attrs, attr) do
      nil ->
        case find_class_attr(class, attr) do
          {:ok, val} -> val
          :error -> default
        end

      val ->
        val
    end
  end

  defp builtin_getattr([{:py_dict, _, _} = dict, attr]) when is_binary(attr) do
    case PyDict.fetch(dict, attr) do
      {:ok, val} -> val
      :error -> {:exception, "AttributeError: 'dict' object has no attribute '#{attr}'"}
    end
  end

  defp builtin_getattr([{:py_dict, _, _} = dict, attr, default]) when is_binary(attr) do
    PyDict.get(dict, attr, default)
  end

  defp builtin_getattr([obj, attr]) when is_map(obj) and is_binary(attr) do
    case Map.get(obj, attr) do
      nil -> {:exception, "AttributeError: 'dict' object has no attribute '#{attr}'"}
      val -> val
    end
  end

  defp builtin_getattr([obj, attr, default]) when is_map(obj) and is_binary(attr) do
    Map.get(obj, attr, default)
  end

  defp builtin_getattr([obj, attr]) when is_binary(attr) do
    {:exception, "AttributeError: '#{pytype(obj)}' object has no attribute '#{attr}'"}
  end

  @spec builtin_setattr([Interpreter.pyvalue()]) ::
          {:mutate, Interpreter.pyvalue(), nil} | {:exception, String.t()}
  defp builtin_setattr([{:instance, class, attrs}, attr, value]) when is_binary(attr) do
    {:mutate, {:instance, class, Map.put(attrs, attr, value)}, nil}
  end

  defp builtin_setattr([_, attr, _]) when is_binary(attr) do
    {:exception, "AttributeError: cannot set attribute '#{attr}'"}
  end

  @spec builtin_super([Interpreter.pyvalue()]) :: {:super_call}
  defp builtin_super([]), do: {:super_call}

  @spec builtin_callable([Interpreter.pyvalue()]) :: boolean()
  defp builtin_callable([{:builtin, _}]), do: true
  defp builtin_callable([{:builtin_kw, _}]), do: true
  defp builtin_callable([{:builtin_type, _, _}]), do: true
  defp builtin_callable([{:function, _, _, _, _}]), do: true
  defp builtin_callable([{:class, _, _, _}]), do: true
  defp builtin_callable([{:bound_method, _, _}]), do: true
  defp builtin_callable([{:bound_method, _, _, _}]), do: true

  defp builtin_callable([{:instance, {:class, _, _, class_attrs}, _}]) do
    Map.has_key?(class_attrs, "__call__")
  end

  defp builtin_callable([_]), do: false

  @spec builtin_dir([Interpreter.pyvalue()]) :: [String.t()]
  defp builtin_dir([{:instance, {:class, _, bases, class_attrs}, instance_attrs}]) do
    inherited = collect_inherited_attrs(bases)
    all_keys = Map.keys(class_attrs) ++ Map.keys(instance_attrs) ++ Map.keys(inherited)
    all_keys |> Enum.uniq() |> Enum.sort()
  end

  defp builtin_dir([{:class, _, bases, class_attrs}]) do
    inherited = collect_inherited_attrs(bases)
    all_keys = Map.keys(class_attrs) ++ Map.keys(inherited)
    all_keys |> Enum.uniq() |> Enum.sort()
  end

  defp builtin_dir([{:py_dict, _, _} = dict]) do
    own_keys = dict |> PyDict.keys() |> Enum.filter(&is_binary/1)
    methods = Pyex.Methods.method_names(dict)
    (own_keys ++ methods) |> Enum.uniq() |> Enum.sort()
  end

  defp builtin_dir([val]) when is_map(val) do
    own_keys = val |> Map.keys() |> Enum.filter(&is_binary/1)
    methods = Pyex.Methods.method_names(val)
    (own_keys ++ methods) |> Enum.uniq() |> Enum.sort()
  end

  defp builtin_dir([val]) do
    Pyex.Methods.method_names(val) |> Enum.sort()
  end

  defp builtin_dir([]) do
    {:exception, "TypeError: dir expected at most 1 argument, got 0"}
  end

  @spec collect_inherited_attrs([Interpreter.pyvalue()]) :: %{
          optional(String.t()) => Interpreter.pyvalue()
        }
  defp collect_inherited_attrs(bases) do
    Enum.reduce(bases, %{}, fn
      {:class, _, parent_bases, attrs}, acc ->
        parent = collect_inherited_attrs(parent_bases)
        Map.merge(parent, Map.merge(attrs, acc))

      _, acc ->
        acc
    end)
  end

  @spec builtin_vars([Interpreter.pyvalue()]) :: %{optional(String.t()) => Interpreter.pyvalue()}
  defp builtin_vars([{:instance, _class, attrs}]), do: attrs

  defp builtin_vars([{:class, _, _bases, attrs}]), do: attrs

  defp builtin_vars([{:py_dict, _, _} = dict]), do: dict
  defp builtin_vars([val]) when is_map(val), do: val

  defp builtin_vars([other]) do
    type_name = pytype(other)
    {:exception, "TypeError: vars() argument must have __dict__ attribute (got #{type_name})"}
  end

  defp builtin_vars([]) do
    {:exception, "TypeError: vars expected at most 1 argument, got 0"}
  end

  @spec builtin_object([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp builtin_object([]) do
    {:object, :erlang.unique_integer()}
  end

  defp builtin_object(_args) do
    {:exception, "TypeError: object() takes no arguments"}
  end

  @doc false
  @spec builtin_property([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def builtin_property([fget]), do: {:property, fget, nil, nil}
  def builtin_property([fget, fset]), do: {:property, fget, fset, nil}
  def builtin_property([fget, fset, fdel]), do: {:property, fget, fset, fdel}
  def builtin_property([]), do: {:property, nil, nil, nil}

  def builtin_property(_),
    do: {:exception, "TypeError: property() takes at most 3 arguments"}

  @doc false
  @spec builtin_staticmethod([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def builtin_staticmethod([func]), do: {:staticmethod, func}

  def builtin_staticmethod(_),
    do: {:exception, "TypeError: staticmethod() takes exactly 1 argument"}

  @doc false
  @spec builtin_classmethod([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def builtin_classmethod([func]), do: {:classmethod, func}

  def builtin_classmethod(_),
    do: {:exception, "TypeError: classmethod() takes exactly 1 argument"}

  @spec builtin_id([Interpreter.pyvalue()]) :: integer()
  defp builtin_id([val]) do
    :erlang.phash2(val)
  end

  @spec builtin_hash([Interpreter.pyvalue()]) :: integer() | {:exception, String.t()}
  defp builtin_hash([val]) when is_integer(val), do: val
  defp builtin_hash([val]) when is_float(val), do: :erlang.phash2(val)
  defp builtin_hash([val]) when is_binary(val), do: :erlang.phash2(val)
  defp builtin_hash([true]), do: 1
  defp builtin_hash([false]), do: 0
  defp builtin_hash([nil]), do: 0
  defp builtin_hash([{:tuple, items}]), do: :erlang.phash2(items)
  defp builtin_hash([{:frozenset, s}]), do: :erlang.phash2(MapSet.to_list(s))
  defp builtin_hash([{:object, id}]), do: id

  defp builtin_hash([{:py_list, _, _}]),
    do: {:exception, "TypeError: unhashable type: 'list'"}

  defp builtin_hash([{:py_dict, _, _}]),
    do: {:exception, "TypeError: unhashable type: 'dict'"}

  defp builtin_hash([{:set, _}]),
    do: {:exception, "TypeError: unhashable type: 'set'"}

  defp builtin_hash([val]) when is_map(val),
    do: {:exception, "TypeError: unhashable type: 'dict'"}

  defp builtin_hash([val]), do: :erlang.phash2(val)

  @spec mod_pow(integer(), integer(), integer()) :: integer()
  defp mod_pow(_base, _exp, 1), do: 0

  defp mod_pow(base, exp, mod) when exp >= 0 do
    base = rem(base, mod)
    do_mod_pow(base, exp, mod, 1)
  end

  @spec do_mod_pow(integer(), integer(), integer(), integer()) :: integer()
  defp do_mod_pow(_base, 0, _mod, result), do: result

  defp do_mod_pow(base, exp, mod, result) do
    result = if rem(exp, 2) == 1, do: rem(result * base, mod), else: result
    base = rem(base * base, mod)
    do_mod_pow(base, div(exp, 2), mod, result)
  end

  @spec builtin_exec([Interpreter.pyvalue()]) :: {:exception, String.t()}
  defp builtin_exec(_args) do
    {:exception,
     "NotImplementedError: exec() is not supported. " <>
       "Write your logic directly instead of using dynamic code execution"}
  end

  @spec builtin_eval([Interpreter.pyvalue()]) :: {:exception, String.t()}
  defp builtin_eval(_args) do
    {:exception,
     "NotImplementedError: eval() is not supported. " <>
       "Write your logic directly instead of using dynamic code execution"}
  end

  @spec builtin_compile([Interpreter.pyvalue()]) :: {:exception, String.t()}
  defp builtin_compile(_args) do
    {:exception,
     "NotImplementedError: compile() is not supported. " <>
       "Write your logic directly instead of using dynamic code execution"}
  end

  @spec builtin_complex([Interpreter.pyvalue()]) :: {:exception, String.t()}
  defp builtin_complex(_args) do
    {:exception,
     "NotImplementedError: complex numbers are not supported. " <>
       "Use separate variables for real and imaginary parts"}
  end

  @spec builtin_bytes([Interpreter.pyvalue()]) :: {:exception, String.t()}
  defp builtin_bytes(_args) do
    {:exception,
     "NotImplementedError: bytes type is not supported. " <>
       "Use strings instead"}
  end

  @spec builtin_bytearray([Interpreter.pyvalue()]) :: {:exception, String.t()}
  defp builtin_bytearray(_args) do
    {:exception,
     "NotImplementedError: bytearray type is not supported. " <>
       "Use lists of integers or strings instead"}
  end

  @doc """
  Returns whether a Python value is truthy.
  """
  @spec truthy?(Interpreter.pyvalue()) :: boolean()
  def truthy?(false), do: false
  def truthy?(nil), do: false
  def truthy?(0), do: false
  def truthy?(+0.0), do: false
  def truthy?(-0.0), do: false
  def truthy?(""), do: false
  def truthy?([]), do: false
  def truthy?({:py_list, _, 0}), do: false
  def truthy?({:py_dict, map, _}) when map == %{}, do: false
  def truthy?({:py_dict, _, _}), do: true
  def truthy?(map) when map == %{}, do: false
  def truthy?({:tuple, []}), do: false
  def truthy?({:set, s}), do: MapSet.size(s) > 0
  def truthy?({:frozenset, s}), do: MapSet.size(s) > 0

  def truthy?({:range, start, stop, step}),
    do: range_length({:range, start, stop, step}) > 0

  def truthy?({:pyex_decimal, d}), do: not Decimal.equal?(d, Decimal.new(0))

  def truthy?(_), do: true

  @spec pytype(Interpreter.pyvalue()) :: String.t()
  defp pytype(val) when is_integer(val), do: "int"
  defp pytype(val) when is_float(val), do: "float"
  defp pytype(:ellipsis), do: "ellipsis"
  defp pytype(val) when is_binary(val), do: "str"
  defp pytype(val) when is_boolean(val), do: "bool"
  defp pytype(nil), do: "NoneType"
  defp pytype({:py_list, _, _}), do: "list"
  defp pytype(val) when is_list(val), do: "list"
  defp pytype({:py_dict, _, _}), do: "dict"
  defp pytype(val) when is_map(val), do: "dict"
  defp pytype({:tuple, _}), do: "tuple"
  defp pytype({:set, _}), do: "set"
  defp pytype({:frozenset, _}), do: "frozenset"
  defp pytype({:function, _, _, _, _}), do: "function"
  defp pytype({:builtin, _}), do: "builtin_function_or_method"
  defp pytype({:builtin_kw, _}), do: "builtin_function_or_method"
  defp pytype({:class, name, _, _}), do: name
  defp pytype({:instance, {:class, name, _, _}, _}), do: name
  defp pytype({:deque, _, _}), do: "deque"
  defp pytype({:range, _, _, _}), do: "range"
  defp pytype({:bound_method, _, _}), do: "method"
  defp pytype({:bound_method, _, _, _}), do: "method"

  @doc """
  Converts a Python value to its `str()` representation.
  """
  @spec py_repr(Interpreter.pyvalue()) :: String.t()
  def py_repr(nil), do: "None"
  def py_repr(true), do: "True"
  def py_repr(false), do: "False"
  def py_repr(val) when is_binary(val), do: val
  def py_repr(val) when is_integer(val), do: Integer.to_string(val)
  def py_repr(:infinity), do: "inf"
  def py_repr(:neg_infinity), do: "-inf"
  def py_repr(:nan), do: "nan"
  def py_repr(:ellipsis), do: "Ellipsis"
  def py_repr(val) when is_float(val), do: Pyex.Interpreter.Helpers.py_float_str(val)

  def py_repr({:py_list, reversed, _len}) do
    inner = reversed |> Enum.reverse() |> Enum.map(&py_repr_quoted/1) |> Enum.join(", ")
    "[#{inner}]"
  end

  def py_repr(val) when is_list(val) do
    inner = val |> Enum.map(&py_repr_quoted/1) |> Enum.join(", ")
    "[#{inner}]"
  end

  def py_repr({:py_dict, _, _} = dict) do
    visible = visible_dict(dict)

    inner =
      visible
      |> PyDict.items()
      |> Enum.map(fn {k, v} -> "#{py_repr_quoted(k)}: #{py_repr_quoted(v)}" end)
      |> Enum.join(", ")

    "{#{inner}}"
  end

  def py_repr(val) when is_map(val) do
    visible = visible_dict(val)

    inner =
      visible
      |> Enum.map(fn {k, v} -> "#{py_repr_quoted(k)}: #{py_repr_quoted(v)}" end)
      |> Enum.join(", ")

    "{#{inner}}"
  end

  def py_repr({:tuple, items}) do
    case items do
      [single] -> "(#{py_repr_quoted(single)},)"
      _ -> "(#{items |> Enum.map(&py_repr_quoted/1) |> Enum.join(", ")})"
    end
  end

  def py_repr({:set, s}) do
    if MapSet.size(s) == 0 do
      "set()"
    else
      "{#{s |> MapSet.to_list() |> Enum.map(&py_repr_quoted/1) |> Enum.join(", ")}}"
    end
  end

  def py_repr({:frozenset, s}) do
    if MapSet.size(s) == 0 do
      "frozenset()"
    else
      inner = s |> MapSet.to_list() |> Enum.map(&py_repr_quoted/1) |> Enum.join(", ")
      "frozenset({#{inner}})"
    end
  end

  def py_repr({:range, s, e, st}) do
    if st == 1, do: "range(#{s}, #{e})", else: "range(#{s}, #{e}, #{st})"
  end

  def py_repr({:instance, {:class, name, _, _}, _}), do: "<#{name} instance>"
  def py_repr({:class, name, _, _}), do: "<class '#{name}'>"
  def py_repr({:function, name, _, _, _}), do: "<function #{name}>"
  def py_repr({:builtin, _}), do: "<built-in function>"
  def py_repr({:builtin_kw, _}), do: "<built-in function>"
  def py_repr({:pyex_decimal, d}), do: Decimal.to_string(d)
  def py_repr(_), do: "<object>"

  @spec py_repr_quoted(Interpreter.pyvalue()) :: String.t()
  defp py_repr_quoted(val) when is_binary(val) do
    if String.contains?(val, "'") and not String.contains?(val, "\"") do
      "\"#{escape_string(val, "\"")}\""
    else
      "'#{escape_string(val, "'")}'"
    end
  end

  defp py_repr_quoted(val), do: py_repr(val)

  @spec escape_string(String.t(), String.t()) :: String.t()
  defp escape_string(s, quote_char) do
    s =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    if quote_char == "'" do
      String.replace(s, "'", "\\'")
    else
      String.replace(s, "\"", "\\\"")
    end
    |> String.replace("\0", "\\x00")
  end

  @spec builtin_iter([Interpreter.pyvalue()]) ::
          Interpreter.pyvalue() | Interpreter.builtin_signal()
  defp builtin_iter([{:instance, _, _} = inst]) do
    {:iter_instance, inst}
  end

  defp builtin_iter([{:iterator, _} = it]) do
    it
  end

  defp builtin_iter([val]) do
    case materialize_iterable(val) do
      {:ok, items} -> {:make_iter, items}
      {:pass, iter} -> iter
      :error -> {:exception, "TypeError: '#{pytype(val)}' object is not iterable"}
    end
  end

  @spec builtin_next([Interpreter.pyvalue()]) ::
          Interpreter.pyvalue() | Interpreter.builtin_signal()
  defp builtin_next([{:generator, _items}]) do
    {:exception,
     "TypeError: cannot call next() directly on a generator. " <>
       "Use iter() first: g = iter(gen()); next(g)"}
  end

  defp builtin_next([{:generator, _items}, _default]) do
    {:exception,
     "TypeError: cannot call next() directly on a generator. " <>
       "Use iter() first: g = iter(gen()); next(g)"}
  end

  defp builtin_next([{:iterator, id}]) do
    {:iter_next, id}
  end

  defp builtin_next([{:iterator, id}, default]) do
    {:iter_next_default, id, default}
  end

  defp builtin_next([{:instance, _, _} = inst]) do
    {:dunder_call, inst, "__next__", []}
  end

  defp builtin_next([{:instance, _, _} = inst, default]) do
    {:next_with_default, inst, default}
  end

  defp builtin_next(_) do
    {:exception, "TypeError: next() argument must be an iterator"}
  end

  @spec bool_to_int(boolean() | term()) :: integer() | term()
  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0
  defp bool_to_int(other), do: other
end
