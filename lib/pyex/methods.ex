defmodule Pyex.Methods do
  @moduledoc """
  Method dispatch for Python built-in types.

  Resolves attribute access on strings and lists to bound
  method callables (closures over the receiver).
  """

  alias Pyex.{Builtins, Interpreter, PyDict}
  alias Pyex.Interpreter.{FstringFormat, Helpers}

  @string_methods ~w(
    capitalize center count encode endswith expandtabs find format
    index isalnum isalpha isdigit islower isnumeric isspace istitle
    isupper join ljust lower lstrip partition replace rfind rindex
    rjust rpartition rsplit rstrip split splitlines startswith strip
    swapcase title upper zfill
  )

  @list_methods ~w(append clear copy count extend index insert pop remove reverse sort)
  @dict_methods ~w(clear copy get items keys pop setdefault update values)
  @set_methods ~w(
    add clear copy difference discard intersection isdisjoint
    issubset issuperset pop remove symmetric_difference union update
  )
  @frozenset_methods ~w(
    copy difference intersection isdisjoint
    issubset issuperset symmetric_difference union
  )
  @tuple_methods ~w(count index)

  @doc """
  Attempts to resolve `attr` on `object`. Returns
  `{:ok, value}` or `:error`.

  The resolved method is a `{:builtin, fun}` where `fun`
  returns either a plain value or `{:mutate, new_object, return_value}`
  for methods that mutate the receiver (e.g. `list.append`).
  """
  @spec resolve(Interpreter.pyvalue(), String.t()) ::
          {:ok, Interpreter.pyvalue()} | :error
  def resolve(object, attr) when is_binary(object) do
    case string_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin, bound(method_fn, object)}}
      {:ok_kw, method_fn} -> {:ok, {:builtin_kw, bound_kw(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve(object, attr) when is_list(object) do
    case list_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin, bound(method_fn, object)}}
      {:ok_kw, method_fn} -> {:ok, {:builtin_kw, bound_kw(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve({:py_list, _, _} = object, attr) do
    case list_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin, bound(method_fn, object)}}
      {:ok_kw, method_fn} -> {:ok, {:builtin_kw, bound_kw(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve({:file_handle, id}, attr) do
    case file_method(attr, id) do
      {:ok, method_fn} -> {:ok, {:builtin, method_fn}}
      :error -> :error
    end
  end

  def resolve({:py_dict, _, _} = object, attr) do
    case dict_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin, bound(method_fn, object)}}
      {:ok_kw, method_fn} -> {:ok, {:builtin_kw, bound_kw(method_fn, object)}}
      {:ok_raw, method_fn} -> {:ok, {:builtin_raw, bound(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve(object, attr) when is_map(object) do
    case dict_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin, bound(method_fn, object)}}
      {:ok_kw, method_fn} -> {:ok, {:builtin_kw, bound_kw(method_fn, object)}}
      {:ok_raw, method_fn} -> {:ok, {:builtin_raw, bound(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve({:set, _} = object, attr) do
    case set_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin, bound(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve({:frozenset, _} = object, attr) do
    case frozenset_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin, bound(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve({:tuple, _} = object, attr) do
    case tuple_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin, bound(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve(object, attr) when is_integer(object) do
    case int_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin, bound(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve(object, attr) when is_boolean(object) do
    # In Python, bool is a subclass of int, so int methods apply.
    case int_method(attr) do
      {:ok, method_fn} ->
        int_val = if object, do: 1, else: 0
        {:ok, {:builtin, bound(method_fn, int_val)}}

      :error ->
        :error
    end
  end

  def resolve({:deque, _, _} = object, attr) do
    case deque_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin_kw, bound_kw(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve({:stringio, _} = object, attr) do
    case stringio_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin_kw, bound_kw(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve({:pandas_series, _} = object, attr) do
    case pandas_series_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin, bound(method_fn, object)}}
      :error -> pandas_series_property(object, attr)
    end
  end

  def resolve({:pandas_rolling, _, _} = object, attr) do
    case pandas_rolling_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin, bound(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve({:pandas_dataframe, _} = object, attr) do
    pandas_dataframe_property(object, attr)
  end

  def resolve(_object, _attr), do: :error

  @doc """
  Returns the list of method names available on a value's type.
  """
  @spec method_names(Interpreter.pyvalue()) :: [String.t()]
  def method_names(val) when is_binary(val), do: @string_methods
  def method_names({:py_list, _, _}), do: @list_methods
  def method_names(val) when is_list(val), do: @list_methods
  def method_names({:py_dict, _, _}), do: @dict_methods
  def method_names(val) when is_map(val), do: @dict_methods
  def method_names({:set, _}), do: @set_methods
  def method_names({:frozenset, _}), do: @frozenset_methods
  def method_names({:tuple, _}), do: @tuple_methods
  def method_names(_), do: []

  @spec bound(
          (Interpreter.pyvalue(), [Interpreter.pyvalue()] -> Interpreter.pyvalue()),
          Interpreter.pyvalue()
        ) :: ([Interpreter.pyvalue()] -> Interpreter.pyvalue())
  defp bound(method_fn, receiver) do
    fn args -> method_fn.(receiver, args) end
  end

  @spec bound_kw(
          (Interpreter.pyvalue(), [Interpreter.pyvalue()], map() -> term()),
          Interpreter.pyvalue()
        ) :: ([Interpreter.pyvalue()], map() -> term())
  defp bound_kw(method_fn, receiver) do
    fn args, kwargs -> method_fn.(receiver, args, kwargs) end
  end

  @spec string_method(String.t()) ::
          {:ok, (String.t(), [Interpreter.pyvalue()] -> Interpreter.pyvalue())}
          | {:ok_kw, (String.t(), [Interpreter.pyvalue()], map() -> Interpreter.pyvalue())}
          | :error
  defp string_method("upper"), do: {:ok, &str_upper/2}
  defp string_method("lower"), do: {:ok, &str_lower/2}
  defp string_method("strip"), do: {:ok, &str_strip/2}
  defp string_method("lstrip"), do: {:ok, &str_lstrip/2}
  defp string_method("rstrip"), do: {:ok, &str_rstrip/2}
  defp string_method("split"), do: {:ok, &str_split/2}
  defp string_method("join"), do: {:ok, &str_join/2}
  defp string_method("replace"), do: {:ok, &str_replace/2}
  defp string_method("startswith"), do: {:ok, &str_startswith/2}
  defp string_method("endswith"), do: {:ok, &str_endswith/2}
  defp string_method("find"), do: {:ok, &str_find/2}
  defp string_method("count"), do: {:ok, &str_count/2}
  defp string_method("format"), do: {:ok_kw, &str_format/3}
  defp string_method("isdigit"), do: {:ok, &str_isdigit/2}
  defp string_method("isdecimal"), do: {:ok, &str_isdecimal/2}
  defp string_method("isnumeric"), do: {:ok, &str_isnumeric/2}
  defp string_method("casefold"), do: {:ok, &str_casefold/2}
  defp string_method("isalpha"), do: {:ok, &str_isalpha/2}
  defp string_method("title"), do: {:ok, &str_title/2}
  defp string_method("capitalize"), do: {:ok, &str_capitalize/2}
  defp string_method("zfill"), do: {:ok, &str_zfill/2}
  defp string_method("center"), do: {:ok, &str_center/2}
  defp string_method("ljust"), do: {:ok, &str_ljust/2}
  defp string_method("rjust"), do: {:ok, &str_rjust/2}
  defp string_method("swapcase"), do: {:ok, &str_swapcase/2}
  defp string_method("isupper"), do: {:ok, &str_isupper/2}
  defp string_method("islower"), do: {:ok, &str_islower/2}
  defp string_method("isspace"), do: {:ok, &str_isspace/2}
  defp string_method("isalnum"), do: {:ok, &str_isalnum/2}
  defp string_method("istitle"), do: {:ok, &str_istitle/2}
  defp string_method("index"), do: {:ok, &str_index/2}
  defp string_method("rfind"), do: {:ok, &str_rfind/2}
  defp string_method("rindex"), do: {:ok, &str_rindex/2}
  defp string_method("rsplit"), do: {:ok, &str_rsplit/2}
  defp string_method("splitlines"), do: {:ok, &str_splitlines/2}
  defp string_method("partition"), do: {:ok, &str_partition/2}
  defp string_method("rpartition"), do: {:ok, &str_rpartition/2}
  defp string_method("expandtabs"), do: {:ok, &str_expandtabs/2}
  defp string_method("encode"), do: {:ok, &str_encode/2}
  defp string_method(_), do: :error

  @spec list_method(String.t()) ::
          {:ok, ([Interpreter.pyvalue()], [Interpreter.pyvalue()] -> Interpreter.pyvalue())}
          | {:ok_kw,
             ([Interpreter.pyvalue()], [Interpreter.pyvalue()], map() -> Interpreter.pyvalue())}
          | :error
  defp list_method("append"), do: {:ok, &list_append/2}
  defp list_method("extend"), do: {:ok, &list_extend/2}
  defp list_method("insert"), do: {:ok, &list_insert/2}
  defp list_method("remove"), do: {:ok, &list_remove/2}
  defp list_method("pop"), do: {:ok, &list_pop/2}
  defp list_method("sort"), do: {:ok_kw, &list_sort/3}
  defp list_method("reverse"), do: {:ok, &list_reverse/2}
  defp list_method("clear"), do: {:ok, &list_clear/2}
  defp list_method("index"), do: {:ok, &list_index/2}
  defp list_method("count"), do: {:ok, &list_count/2}
  defp list_method("copy"), do: {:ok, &list_copy/2}
  defp list_method(_), do: :error

  @spec dict_method(String.t()) ::
          {:ok,
           (%{optional(Interpreter.pyvalue()) => Interpreter.pyvalue()},
            [Interpreter.pyvalue()] ->
              Interpreter.pyvalue())}
          | {:ok_kw,
             (%{optional(Interpreter.pyvalue()) => Interpreter.pyvalue()},
              [Interpreter.pyvalue()],
              %{optional(String.t()) => Interpreter.pyvalue()} ->
                term())}
          | {:ok_raw,
             (%{optional(Interpreter.pyvalue()) => Interpreter.pyvalue()},
              [Interpreter.pyvalue()] ->
                term())}
          | :error
  defp dict_method("get"), do: {:ok, &dict_get/2}
  defp dict_method("keys"), do: {:ok, &dict_keys/2}
  defp dict_method("values"), do: {:ok, &dict_values/2}
  defp dict_method("items"), do: {:ok, &dict_items/2}
  defp dict_method("pop"), do: {:ok, &dict_pop/2}
  defp dict_method("update"), do: {:ok_kw, &dict_update/3}
  defp dict_method("setdefault"), do: {:ok_raw, &dict_setdefault/2}
  defp dict_method("clear"), do: {:ok, &dict_clear/2}
  defp dict_method("copy"), do: {:ok, &dict_copy/2}
  defp dict_method(_), do: :error

  @spec int_method(String.t()) ::
          {:ok, (integer(), [Interpreter.pyvalue()] -> term())} | :error
  defp int_method("bit_length"), do: {:ok, &int_bit_length/2}
  defp int_method("bit_count"), do: {:ok, &int_bit_count/2}
  defp int_method("to_bytes"), do: {:ok, &int_to_bytes/2}
  defp int_method("__abs__"), do: {:ok, fn n, [] -> abs(n) end}
  defp int_method("__neg__"), do: {:ok, fn n, [] -> -n end}
  defp int_method(_), do: :error

  @spec int_bit_length(integer(), [Interpreter.pyvalue()]) :: non_neg_integer()
  defp int_bit_length(0, []), do: 0
  defp int_bit_length(n, []) when n < 0, do: int_bit_length(-n, [])

  defp int_bit_length(n, []) do
    n
    |> Integer.to_string(2)
    |> byte_size()
  end

  @spec int_bit_count(integer(), [Interpreter.pyvalue()]) :: non_neg_integer()
  defp int_bit_count(n, []) when n < 0, do: int_bit_count(-n, [])

  defp int_bit_count(n, []) do
    n
    |> Integer.to_string(2)
    |> String.graphemes()
    |> Enum.count(&(&1 == "1"))
  end

  @spec int_to_bytes(integer(), [Interpreter.pyvalue()]) ::
          String.t() | {:exception, String.t()}
  defp int_to_bytes(n, [length, byteorder])
       when is_integer(length) and length >= 0 and is_binary(byteorder) do
    int_to_bytes_impl(n, length, byteorder, false)
  end

  defp int_to_bytes(n, [length]) when is_integer(length) and length >= 0,
    do: int_to_bytes_impl(n, length, "big", false)

  defp int_to_bytes(_, _),
    do: {:exception, "TypeError: to_bytes() expects (length, byteorder)"}

  @spec int_to_bytes_impl(integer(), non_neg_integer(), String.t(), boolean()) ::
          String.t() | {:exception, String.t()}
  defp int_to_bytes_impl(n, length, byteorder, _signed) do
    if n < 0 do
      {:exception, "OverflowError: can't convert negative int to unsigned"}
    else
      bytes = int_to_byte_list(n, length, [])

      if length(bytes) > length do
        {:exception, "OverflowError: int too big to convert"}
      else
        padded = List.duplicate(0, length - length(bytes)) ++ bytes

        ordered =
          case byteorder do
            "big" -> padded
            "little" -> Enum.reverse(padded)
            _ -> {:exception, "ValueError: byteorder must be 'big' or 'little'"}
          end

        case ordered do
          {:exception, _} = e -> e
          list -> :erlang.list_to_binary(list)
        end
      end
    end
  end

  @spec int_to_byte_list(non_neg_integer(), non_neg_integer(), [byte()]) :: [byte()]
  defp int_to_byte_list(0, 0, acc), do: acc
  defp int_to_byte_list(0, _remaining, acc), do: acc

  defp int_to_byte_list(n, _remaining, acc) do
    int_to_byte_list(Bitwise.bsr(n, 8), 0, [Bitwise.band(n, 0xFF) | acc])
  end

  @spec file_method(String.t(), non_neg_integer()) ::
          {:ok, ([Interpreter.pyvalue()] -> term())} | :error
  defp file_method("read", id) do
    {:ok,
     fn [] ->
       {:ctx_call,
        fn env, ctx ->
          case Pyex.Ctx.read_handle(ctx, id) do
            {:ok, content, ctx} -> {content, env, ctx}
            {:error, msg} -> {{:exception, msg}, env, ctx}
          end
        end}
     end}
  end

  defp file_method("write", id) do
    {:ok,
     fn [content] when is_binary(content) ->
       {:ctx_call,
        fn env, ctx ->
          case Pyex.Ctx.write_handle(ctx, id, content) do
            {:ok, ctx} -> {nil, env, ctx}
            {:error, msg} -> {{:exception, msg}, env, ctx}
          end
        end}
     end}
  end

  defp file_method("close", id) do
    {:ok,
     fn [] ->
       {:ctx_call,
        fn env, ctx ->
          case Pyex.Ctx.close_handle(ctx, id) do
            {:ok, ctx} -> {nil, env, ctx}
            {:error, msg} -> {{:exception, msg}, env, ctx}
          end
        end}
     end}
  end

  defp file_method(_, _id), do: :error

  @spec str_upper(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_upper(s, []), do: String.upcase(s)

  @spec str_lower(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_lower(s, []), do: String.downcase(s)

  @spec str_strip(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_strip(s, []), do: String.trim(s)

  defp str_strip(s, [chars]) when is_binary(chars) do
    char_list = String.codepoints(chars)
    s |> trim_leading_chars(char_list) |> trim_trailing_chars(char_list)
  end

  @spec str_lstrip(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_lstrip(s, []), do: String.trim_leading(s)

  defp str_lstrip(s, [chars]) when is_binary(chars) do
    trim_leading_chars(s, String.codepoints(chars))
  end

  @spec str_rstrip(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_rstrip(s, []), do: String.trim_trailing(s)

  defp str_rstrip(s, [chars]) when is_binary(chars) do
    trim_trailing_chars(s, String.codepoints(chars))
  end

  @spec trim_leading_chars(String.t(), [String.t()]) :: String.t()
  defp trim_leading_chars("", _chars), do: ""

  defp trim_leading_chars(s, chars) do
    case String.next_codepoint(s) do
      {g, rest} ->
        if g in chars, do: trim_leading_chars(rest, chars), else: s

      nil ->
        ""
    end
  end

  @spec trim_trailing_chars(String.t(), [String.t()]) :: String.t()
  defp trim_trailing_chars(s, chars) do
    s |> String.reverse() |> trim_leading_chars(chars) |> String.reverse()
  end

  @spec str_split(String.t(), [Interpreter.pyvalue()]) ::
          [String.t()] | {:exception, String.t()}
  defp str_split(s, []), do: String.split(s)
  defp str_split(_s, [""]), do: {:exception, "ValueError: empty separator"}

  defp str_split(s, [sep]) when is_binary(sep), do: String.split(s, sep)

  defp str_split(s, [sep, maxsplit]) when is_binary(sep) and is_integer(maxsplit) do
    cond do
      sep == "" -> {:exception, "ValueError: empty separator"}
      # CPython: maxsplit < 0 means no limit.
      maxsplit < 0 -> String.split(s, sep)
      true -> String.split(s, sep, parts: maxsplit + 1)
    end
  end

  @spec str_join(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_join(s, [{:py_list, reversed, _}]), do: reversed |> Enum.reverse() |> Enum.join(s)
  defp str_join(s, [list]) when is_list(list), do: Enum.join(list, s)
  defp str_join(s, [{:generator, items}]), do: Enum.join(items, s)
  defp str_join(s, [{:tuple, items}]), do: Enum.join(items, s)

  @spec str_replace(String.t(), [Interpreter.pyvalue()]) :: String.t() | {:exception, String.t()}
  defp str_replace(s, [old, new]) when is_binary(old) and is_binary(new) do
    if old != "" and byte_size(new) > byte_size(old) and byte_size(s) > 1_000_000 do
      {:exception,
       "LimitError: memory limit exceeded (string replace would produce oversized result)"}
    else
      String.replace(s, old, new)
    end
  end

  defp str_replace(s, [old, new, count])
       when is_binary(old) and is_binary(new) and is_integer(count) do
    cond do
      count < 0 ->
        str_replace(s, [old, new])

      old == "" ->
        # Matches CPython: inserts `new` between every codepoint up to count.
        replace_empty_separator(s, new, count)

      true ->
        replace_first_n(s, old, new, count)
    end
  end

  @spec replace_first_n(String.t(), String.t(), String.t(), non_neg_integer()) :: String.t()
  defp replace_first_n(s, _old, _new, 0), do: s

  defp replace_first_n(s, old, new, count) do
    case :binary.match(s, old) do
      :nomatch ->
        s

      {start, len} ->
        prefix = binary_part(s, 0, start)
        rest = binary_part(s, start + len, byte_size(s) - start - len)
        prefix <> new <> replace_first_n(rest, old, new, count - 1)
    end
  end

  @spec replace_empty_separator(String.t(), String.t(), non_neg_integer()) :: String.t()
  defp replace_empty_separator(s, new, count) do
    graphemes = String.graphemes(s)
    {head, tail} = Enum.split(graphemes, count)

    # Python inserts `new` at the start, between each of the first `count`
    # graphemes, and once at the end only if count >= length of s.
    leading =
      case head do
        [] -> new
        _ -> new <> Enum.join(head, new)
      end

    if tail == [] do
      leading <> new
    else
      leading <> Enum.join(tail, "")
    end
  end

  @spec str_startswith(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_startswith(s, [prefix]) when is_binary(prefix), do: String.starts_with?(s, prefix)

  defp str_startswith(s, [{:tuple, prefixes}]) do
    Enum.any?(prefixes, fn p -> is_binary(p) and String.starts_with?(s, p) end)
  end

  @spec str_endswith(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_endswith(s, [suffix]) when is_binary(suffix), do: String.ends_with?(s, suffix)

  defp str_endswith(s, [{:tuple, suffixes}]) do
    Enum.any?(suffixes, fn p -> is_binary(p) and String.ends_with?(s, p) end)
  end

  @spec str_find(String.t(), [Interpreter.pyvalue()]) :: integer()
  defp str_find(s, [sub]) when is_binary(sub) do
    str_find(s, [sub, 0])
  end

  defp str_find(s, [sub, start]) when is_binary(sub) and is_integer(start) do
    str_find(s, [sub, start, String.length(s)])
  end

  defp str_find(s, [sub, start, stop])
       when is_binary(sub) and is_integer(start) and is_integer(stop) do
    len = String.length(s)
    norm_start = normalize_index(start, len)
    norm_stop = normalize_index(stop, len)
    slice = String.slice(s, norm_start, max(norm_stop - norm_start, 0))

    case :binary.match(slice, sub) do
      {byte_pos, _len} ->
        byte_prefix = binary_part(slice, 0, byte_pos)
        String.length(byte_prefix) + norm_start

      :nomatch ->
        -1
    end
  end

  @spec str_count(String.t(), [Interpreter.pyvalue()]) :: non_neg_integer()
  defp str_count(s, [sub]) when is_binary(sub) do
    count_substring(s, sub)
  end

  defp str_count(s, [sub, start]) when is_binary(sub) and is_integer(start) do
    len = String.length(s)
    norm_start = normalize_index(start, len)
    slice = String.slice(s, norm_start, len)
    count_substring(slice, sub)
  end

  defp str_count(s, [sub, start, stop])
       when is_binary(sub) and is_integer(start) and is_integer(stop) do
    len = String.length(s)
    norm_start = normalize_index(start, len)
    norm_stop = normalize_index(stop, len)
    slice = String.slice(s, norm_start, max(norm_stop - norm_start, 0))
    count_substring(slice, sub)
  end

  @spec count_substring(String.t(), String.t()) :: non_neg_integer()
  defp count_substring(s, ""), do: String.length(s) + 1
  defp count_substring(s, sub), do: length(String.split(s, sub)) - 1

  @spec str_format(String.t(), [Interpreter.pyvalue()], map()) ::
          String.t() | {:exception, String.t()}
  defp str_format(template, args, kwargs) do
    args_indexed = Enum.with_index(args) |> Map.new(fn {v, i} -> {i, v} end)
    do_str_format(template, args_indexed, kwargs, 0, <<>>)
  end

  @spec do_str_format(
          String.t(),
          %{non_neg_integer() => Interpreter.pyvalue()},
          map(),
          non_neg_integer(),
          binary()
        ) :: String.t() | {:exception, String.t()}
  defp do_str_format(<<>>, _ai, _kw, _auto, acc), do: acc

  defp do_str_format(<<?{, ?{, rest::binary>>, ai, kw, auto, acc) do
    do_str_format(rest, ai, kw, auto, <<acc::binary, ?{>>)
  end

  defp do_str_format(<<?}, ?}, rest::binary>>, ai, kw, auto, acc) do
    do_str_format(rest, ai, kw, auto, <<acc::binary, ?}>>)
  end

  defp do_str_format(<<?{, rest::binary>>, ai, kw, auto, acc) do
    {field, rest} = collect_to_closing_brace(rest, <<>>)

    {field_name, conversion, spec} = parse_field(field)

    val_result =
      case field_name do
        "" ->
          case Map.fetch(ai, auto) do
            {:ok, v} ->
              {:ok, v, auto + 1}

            :error ->
              {:error, "IndexError: Replacement index #{auto} out of range for positional args"}
          end

        name ->
          case Integer.parse(name) do
            {idx, ""} ->
              case Map.fetch(ai, idx) do
                {:ok, v} ->
                  {:ok, v, auto}

                :error ->
                  {:error,
                   "IndexError: Replacement index #{idx} out of range for positional args"}
              end

            _ ->
              # Attribute/item access chain (simplified: only top-level names)
              root = name |> String.split(".") |> hd() |> String.split("[") |> hd()

              case Map.fetch(kw, root) do
                {:ok, v} -> {:ok, v, auto}
                :error -> {:error, "KeyError: '#{root}'"}
              end
          end
      end

    case val_result do
      {:error, msg} ->
        {:exception, msg}

      {:ok, val, new_auto} ->
        converted =
          case conversion do
            "r" -> Helpers.py_repr_fmt(val)
            "s" -> Helpers.py_str(val)
            "a" -> Helpers.py_repr_fmt(val)
            _ -> Helpers.py_str(val)
          end

        formatted =
          if spec == "" do
            converted
          else
            FstringFormat.apply_format_spec(val, spec)
          end

        case formatted do
          {:exception, _} = exc ->
            exc

          s when is_binary(s) ->
            do_str_format(rest, ai, kw, new_auto, <<acc::binary, s::binary>>)
        end
    end
  end

  defp do_str_format(<<c::utf8, rest::binary>>, ai, kw, auto, acc) do
    do_str_format(rest, ai, kw, auto, <<acc::binary, c::utf8>>)
  end

  @spec collect_to_closing_brace(String.t(), binary()) :: {binary(), String.t()}
  defp collect_to_closing_brace(<<?}, rest::binary>>, acc), do: {acc, rest}

  defp collect_to_closing_brace(<<c::utf8, rest::binary>>, acc),
    do: collect_to_closing_brace(rest, <<acc::binary, c::utf8>>)

  defp collect_to_closing_brace(<<>>, acc), do: {acc, <<>>}

  @spec parse_field(binary()) :: {binary(), binary(), binary()}
  defp parse_field(field) do
    {name_conv, spec} =
      case :binary.split(field, ":") do
        [nc, s] -> {nc, s}
        [nc] -> {nc, ""}
      end

    {name, conversion} =
      case :binary.split(name_conv, "!") do
        [n, c] -> {n, c}
        [n] -> {n, ""}
      end

    {name, conversion, spec}
  end

  @spec str_isdigit(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_isdigit(s, []) when s == "", do: false
  defp str_isdigit(s, []), do: String.match?(s, ~r/^\d+$/)

  @spec str_isdecimal(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_isdecimal("", []), do: false
  defp str_isdecimal(s, []), do: String.match?(s, ~r/^[0-9]+$/)

  @spec str_isnumeric(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_isnumeric("", []), do: false
  defp str_isnumeric(s, []), do: String.match?(s, ~r/^\d+$/u)

  @spec str_casefold(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_casefold(s, []), do: String.downcase(s, :default)

  @spec str_isalpha(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_isalpha(s, []) when s == "", do: false
  defp str_isalpha(s, []), do: String.match?(s, ~r/^[a-zA-Z]+$/)

  @spec str_title(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_title(s, []) do
    s
    |> String.codepoints()
    |> title_codepoints(true, [])
    |> IO.iodata_to_binary()
  end

  @spec title_codepoints([String.t()], boolean(), iodata()) :: iodata()
  defp title_codepoints([], _capitalize_next, acc), do: Enum.reverse(acc)

  defp title_codepoints([cp | rest], capitalize_next, acc) do
    if alpha?(cp) do
      transformed = if capitalize_next, do: String.upcase(cp), else: String.downcase(cp)
      title_codepoints(rest, false, [transformed | acc])
    else
      title_codepoints(rest, true, [cp | acc])
    end
  end

  @spec alpha?(String.t()) :: boolean()
  defp alpha?(<<c::utf8>>) when c in ?a..?z or c in ?A..?Z, do: true
  defp alpha?(_), do: false

  @spec str_capitalize(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_capitalize("", []), do: ""

  defp str_capitalize(s, []) do
    <<first::utf8, rest::binary>> = s
    String.upcase(<<first::utf8>>) <> String.downcase(rest)
  end

  @spec str_zfill(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_zfill(s, [width]) when is_integer(width) do
    case s do
      <<sign, rest::binary>> when sign in [?+, ?-] ->
        <<sign>> <> String.pad_leading(rest, max(width - 1, 0), "0")

      _ ->
        String.pad_leading(s, width, "0")
    end
  end

  @spec str_center(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_center(s, [width]) when is_integer(width), do: str_center(s, [width, " "])

  defp str_center(s, [width, fill]) when is_integer(width) and is_binary(fill) do
    len = String.length(s)

    if len >= width do
      s
    else
      total_pad = width - len
      right_pad = div(total_pad, 2)
      left_pad = total_pad - right_pad
      String.duplicate(fill, left_pad) <> s <> String.duplicate(fill, right_pad)
    end
  end

  @spec str_ljust(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_ljust(s, [width]) when is_integer(width), do: str_ljust(s, [width, " "])

  defp str_ljust(s, [width, fill]) when is_integer(width) and is_binary(fill) do
    String.pad_trailing(s, width, fill)
  end

  @spec str_rjust(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_rjust(s, [width]) when is_integer(width), do: str_rjust(s, [width, " "])

  defp str_rjust(s, [width, fill]) when is_integer(width) and is_binary(fill) do
    String.pad_leading(s, width, fill)
  end

  @spec str_swapcase(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_swapcase(s, []) do
    s
    |> String.codepoints()
    |> Enum.map(fn cp ->
      up = String.upcase(cp)
      if cp == up, do: String.downcase(cp), else: up
    end)
    |> Enum.join()
  end

  @spec str_isupper(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_isupper("", []), do: false

  defp str_isupper(s, []) do
    has_cased = String.match?(s, ~r/[a-zA-Z]/)
    has_cased and s == String.upcase(s)
  end

  @spec str_islower(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_islower("", []), do: false

  defp str_islower(s, []) do
    has_cased = String.match?(s, ~r/[a-zA-Z]/)
    has_cased and s == String.downcase(s)
  end

  @spec str_isspace(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_isspace("", []), do: false
  defp str_isspace(s, []), do: String.match?(s, ~r/^\s+$/)

  @spec str_isalnum(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_isalnum("", []), do: false
  defp str_isalnum(s, []), do: String.match?(s, ~r/^[a-zA-Z0-9]+$/)

  @spec str_istitle(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_istitle("", []), do: false

  defp str_istitle(s, []) do
    words = String.split(s, ~r/\s+/)

    Enum.any?(words, &String.match?(&1, ~r/[a-zA-Z]/)) and
      Enum.all?(words, fn word ->
        if String.match?(word, ~r/[a-zA-Z]/) do
          <<first::utf8, rest::binary>> = word
          String.upcase(<<first::utf8>>) == <<first::utf8>> and rest == String.downcase(rest)
        else
          true
        end
      end)
  end

  @spec str_index(String.t(), [Interpreter.pyvalue()]) ::
          integer() | {:exception, String.t()}
  defp str_index(s, [sub]) when is_binary(sub) do
    str_index(s, [sub, 0])
  end

  defp str_index(s, [sub, start]) when is_binary(sub) and is_integer(start) do
    str_index(s, [sub, start, String.length(s)])
  end

  defp str_index(s, [sub, start, stop])
       when is_binary(sub) and is_integer(start) and is_integer(stop) do
    case str_find(s, [sub, start, stop]) do
      -1 -> {:exception, "ValueError: substring not found"}
      idx -> idx
    end
  end

  @spec str_rfind(String.t(), [Interpreter.pyvalue()]) :: integer()
  defp str_rfind(s, [sub]) when is_binary(sub) do
    str_rfind(s, [sub, 0])
  end

  defp str_rfind(s, [sub, start]) when is_binary(sub) and is_integer(start) do
    str_rfind(s, [sub, start, String.length(s)])
  end

  defp str_rfind(s, [sub, start, stop])
       when is_binary(sub) and is_integer(start) and is_integer(stop) do
    len = String.length(s)
    norm_start = normalize_index(start, len)
    norm_stop = normalize_index(stop, len)
    slice = String.slice(s, norm_start, max(norm_stop - norm_start, 0))

    case :binary.matches(slice, sub) do
      [] ->
        -1

      matches ->
        {byte_pos, _len} = List.last(matches)
        byte_prefix = binary_part(slice, 0, byte_pos)
        String.length(byte_prefix) + norm_start
    end
  end

  @spec str_rindex(String.t(), [Interpreter.pyvalue()]) ::
          integer() | {:exception, String.t()}
  defp str_rindex(s, [sub]) when is_binary(sub) do
    str_rindex(s, [sub, 0])
  end

  defp str_rindex(s, [sub, start]) when is_binary(sub) and is_integer(start) do
    str_rindex(s, [sub, start, String.length(s)])
  end

  defp str_rindex(s, [sub, start, stop])
       when is_binary(sub) and is_integer(start) and is_integer(stop) do
    case str_rfind(s, [sub, start, stop]) do
      -1 -> {:exception, "ValueError: substring not found"}
      idx -> idx
    end
  end

  @spec str_rsplit(String.t(), [Interpreter.pyvalue()]) :: [String.t()]
  defp str_rsplit(s, []), do: String.split(s)

  defp str_rsplit(s, [sep]) when is_binary(sep), do: String.split(s, sep)

  defp str_rsplit(s, [sep, maxsplit]) when is_binary(sep) and is_integer(maxsplit) do
    parts = String.split(s, sep)
    total = length(parts)

    if total <= maxsplit + 1 do
      parts
    else
      keep = total - maxsplit
      {head, tail} = Enum.split(parts, keep)
      [Enum.join(head, sep) | tail]
    end
  end

  @spec str_splitlines(String.t(), [Interpreter.pyvalue()]) :: [String.t()]
  defp str_splitlines("", []), do: []

  defp str_splitlines(s, []) do
    # Python's str.splitlines does NOT include a trailing empty line when
    # the string ends with a line terminator: "a\nb\n" -> ["a", "b"].
    parts = String.split(s, ~r/\r\n|\r|\n/)

    case Enum.reverse(parts) do
      ["" | rest] -> Enum.reverse(rest)
      _ -> parts
    end
  end

  defp str_splitlines("", [true]), do: []
  defp str_splitlines(s, [true]), do: split_keeping_ends(s)
  defp str_splitlines(s, [false]), do: String.split(s, ~r/\r\n|\r|\n/)

  @spec split_keeping_ends(String.t()) :: [String.t()]
  defp split_keeping_ends(s) do
    Regex.split(~r/(\r\n|\r|\n)/, s, include_captures: true)
    |> merge_line_endings()
  end

  @spec merge_line_endings([String.t()]) :: [String.t()]
  defp merge_line_endings([]), do: []
  defp merge_line_endings([line, ending | rest]), do: [line <> ending | merge_line_endings(rest)]
  defp merge_line_endings([last]), do: if(last == "", do: [], else: [last])

  @spec str_partition(String.t(), [Interpreter.pyvalue()]) :: {:tuple, [String.t()]}
  defp str_partition(s, [sep]) when is_binary(sep) do
    case :binary.match(s, sep) do
      {pos, len} ->
        before = binary_part(s, 0, pos)
        after_ = binary_part(s, pos + len, byte_size(s) - pos - len)
        {:tuple, [before, sep, after_]}

      :nomatch ->
        {:tuple, [s, "", ""]}
    end
  end

  @spec str_rpartition(String.t(), [Interpreter.pyvalue()]) :: {:tuple, [String.t()]}
  defp str_rpartition(s, [sep]) when is_binary(sep) do
    case :binary.matches(s, sep) do
      [] ->
        {:tuple, ["", "", s]}

      matches ->
        {pos, len} = List.last(matches)
        before = binary_part(s, 0, pos)
        after_ = binary_part(s, pos + len, byte_size(s) - pos - len)
        {:tuple, [before, sep, after_]}
    end
  end

  @spec str_expandtabs(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_expandtabs(s, []), do: String.replace(s, "\t", String.duplicate(" ", 8))

  defp str_expandtabs(s, [tabsize]) when is_integer(tabsize) do
    String.replace(s, "\t", String.duplicate(" ", tabsize))
  end

  @spec str_encode(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_encode(s, []), do: s
  defp str_encode(s, [_encoding]), do: s

  @spec dict_get(map() | PyDict.t(), [Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp dict_get({:py_dict, _, _} = dict, [key]), do: PyDict.get(dict, key)
  defp dict_get({:py_dict, _, _} = dict, [key, default]), do: PyDict.get(dict, key, default)
  defp dict_get(map, [key]), do: Map.get(map, key, nil)
  defp dict_get(map, [key, default]), do: Map.get(map, key, default)

  @spec dict_keys(map() | PyDict.t(), [Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp dict_keys({:py_dict, _, _} = dict, []),
    do: dict |> Builtins.visible_dict() |> PyDict.keys()

  defp dict_keys(map, []), do: map |> Builtins.visible_dict() |> Map.keys()

  @spec dict_values(map() | PyDict.t(), [Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp dict_values({:py_dict, _, _} = dict, []),
    do: dict |> Builtins.visible_dict() |> PyDict.values()

  defp dict_values(map, []), do: map |> Builtins.visible_dict() |> Map.values()

  @spec dict_items(map() | PyDict.t(), [Interpreter.pyvalue()]) :: [
          {:tuple, [Interpreter.pyvalue()]}
        ]
  defp dict_items({:py_dict, _, _} = dict, []),
    do:
      dict
      |> Builtins.visible_dict()
      |> PyDict.items()
      |> Enum.map(fn {k, v} -> {:tuple, [k, v]} end)

  defp dict_items(map, []),
    do: map |> Builtins.visible_dict() |> Enum.map(fn {k, v} -> {:tuple, [k, v]} end)

  @spec dict_pop(map() | PyDict.t(), [Interpreter.pyvalue()]) ::
          {:mutate, map() | PyDict.t(), Interpreter.pyvalue()} | {:exception, String.t()}
  defp dict_pop({:py_dict, _, _} = dict, [key]) do
    if PyDict.has_key?(dict, key) do
      {val, rest} = PyDict.pop(dict, key)
      {:mutate, rest, val}
    else
      {:exception, "KeyError: #{Builtins.py_repr(key)}"}
    end
  end

  defp dict_pop({:py_dict, _, _} = dict, [key, default]) do
    {val, rest} = PyDict.pop(dict, key, default)
    {:mutate, rest, val}
  end

  defp dict_pop(map, [key]) do
    if Map.has_key?(map, key) do
      {val, rest} = Map.pop(map, key)
      {:mutate, rest, val}
    else
      {:exception, "KeyError: #{Builtins.py_repr(key)}"}
    end
  end

  defp dict_pop(map, [key, default]) do
    {val, rest} = Map.pop(map, key, default)
    {:mutate, rest, val}
  end

  @spec dict_update(map() | PyDict.t(), [Interpreter.pyvalue()], map()) ::
          {:mutate, map() | PyDict.t(), nil}
  defp dict_update({:py_dict, attrs, _} = dict, [arg], _kwargs)
       when is_map_key(attrs, "__counter__") do
    {:mutate, Pyex.Stdlib.Collections.counter_update(dict, arg), nil}
  end

  defp dict_update({:py_dict, _, _} = dict, [{:py_dict, _, _} = other], kwargs) do
    merged = PyDict.merge(dict, Builtins.visible_dict(other))
    {:mutate, apply_kwargs_to_dict(merged, kwargs), nil}
  end

  defp dict_update({:py_dict, _, _} = dict, [other], kwargs) when is_map(other) do
    merged = PyDict.merge_map(dict, Builtins.visible_dict(other))
    {:mutate, apply_kwargs_to_dict(merged, kwargs), nil}
  end

  defp dict_update({:py_dict, _, _} = dict, [], kwargs) do
    {:mutate, apply_kwargs_to_dict(dict, kwargs), nil}
  end

  defp dict_update(map, [{:py_dict, _, _} = other], kwargs) when is_map(map) do
    merged = Map.merge(map, PyDict.to_map(Builtins.visible_dict(other)))
    merged = Enum.reduce(kwargs, merged, fn {k, v}, acc -> Map.put(acc, k, v) end)
    {:mutate, merged, nil}
  end

  defp dict_update(map, [other], kwargs) when is_map(other) do
    merged = Map.merge(map, Builtins.visible_dict(other))
    merged = Enum.reduce(kwargs, merged, fn {k, v}, acc -> Map.put(acc, k, v) end)
    {:mutate, merged, nil}
  end

  defp dict_update(map, [], kwargs) when is_map(map) do
    merged = Enum.reduce(kwargs, map, fn {k, v}, acc -> Map.put(acc, k, v) end)
    {:mutate, merged, nil}
  end

  @spec apply_kwargs_to_dict(PyDict.t(), map()) :: PyDict.t()
  defp apply_kwargs_to_dict(dict, kwargs) do
    Enum.reduce(kwargs, dict, fn {k, v}, acc -> PyDict.put(acc, k, v) end)
  end

  @spec dict_setdefault(map() | PyDict.t(), [Interpreter.pyvalue()]) ::
          {:mutate, map() | PyDict.t(), Interpreter.pyvalue()}
  defp dict_setdefault({:py_dict, _, _} = dict, [key]) do
    if PyDict.has_key?(dict, key) do
      {:ok, val} = PyDict.fetch(dict, key)
      {:mutate, dict, val}
    else
      {:mutate, PyDict.put(dict, key, nil), nil}
    end
  end

  defp dict_setdefault({:py_dict, _, _} = dict, [key, default]) do
    if PyDict.has_key?(dict, key) do
      {:ok, val} = PyDict.fetch(dict, key)
      {:mutate, dict, val}
    else
      {:mutate, PyDict.put(dict, key, default), default}
    end
  end

  defp dict_setdefault(map, [key]) do
    if Map.has_key?(map, key) do
      {:mutate, map, Map.fetch!(map, key)}
    else
      {:mutate, Map.put(map, key, nil), nil}
    end
  end

  defp dict_setdefault(map, [key, default]) do
    if Map.has_key?(map, key) do
      {:mutate, map, Map.fetch!(map, key)}
    else
      {:mutate, Map.put(map, key, default), default}
    end
  end

  @spec dict_clear(map() | PyDict.t(), [Interpreter.pyvalue()]) ::
          {:mutate, map() | PyDict.t(), nil}
  defp dict_clear({:py_dict, _, _} = dict, []) do
    case PyDict.fetch(dict, "__defaultdict_factory__") do
      {:ok, factory} -> {:mutate, PyDict.from_pairs([{"__defaultdict_factory__", factory}]), nil}
      :error -> {:mutate, PyDict.new(), nil}
    end
  end

  defp dict_clear(map, []) do
    case Map.fetch(map, "__defaultdict_factory__") do
      {:ok, factory} -> {:mutate, %{"__defaultdict_factory__" => factory}, nil}
      :error -> {:mutate, %{}, nil}
    end
  end

  @spec dict_copy(map() | PyDict.t(), [Interpreter.pyvalue()]) :: map() | PyDict.t()
  defp dict_copy({:py_dict, _, _} = dict, []), do: dict
  defp dict_copy(map, []), do: map

  @spec list_append({:py_list, [term()], non_neg_integer()}, [Interpreter.pyvalue()]) ::
          {:mutate, {:py_list, [term()], non_neg_integer()}, nil}
  defp list_append({:py_list, reversed, len}, [item]),
    do: {:mutate, {:py_list, [item | reversed], len + 1}, nil}

  # Fallback for legacy list format (during transition)
  defp list_append(list, [item]) when is_list(list),
    do: {:mutate, list ++ [item], nil}

  @spec list_extend({:py_list, [term()], non_neg_integer()}, [Interpreter.pyvalue()]) ::
          {:mutate, {:py_list, [term()], non_neg_integer()}, nil} | {:exception, String.t()}
  # Fast path: extend with another py_list (just prepend their reversed storage)
  defp list_extend({:py_list, reversed, len}, [{:py_list, other_reversed, other_len}])
       when is_list(other_reversed),
       do: {:mutate, {:py_list, other_reversed ++ reversed, len + other_len}, nil}

  defp list_extend({:py_list, reversed, len}, [other]) when is_list(other),
    do: {:mutate, {:py_list, Enum.reverse(other) ++ reversed, len + length(other)}, nil}

  defp list_extend({:py_list, reversed, len}, [{:tuple, items}]),
    do: {:mutate, {:py_list, Enum.reverse(items) ++ reversed, len + length(items)}, nil}

  defp list_extend({:py_list, reversed, len}, [{:set, s}]),
    do:
      {:mutate, {:py_list, Enum.reverse(MapSet.to_list(s)) ++ reversed, len + MapSet.size(s)},
       nil}

  defp list_extend({:py_list, reversed, len}, [{:frozenset, s}]),
    do:
      {:mutate, {:py_list, Enum.reverse(MapSet.to_list(s)) ++ reversed, len + MapSet.size(s)},
       nil}

  defp list_extend({:py_list, reversed, len}, [{:generator, items}]),
    do: {:mutate, {:py_list, Enum.reverse(items) ++ reversed, len + length(items)}, nil}

  defp list_extend({:py_list, reversed, len}, [str]) when is_binary(str),
    do:
      {:mutate,
       {:py_list, Enum.reverse(String.codepoints(str)) ++ reversed, len + String.length(str)},
       nil}

  defp list_extend({:py_list, reversed, len}, [{:py_dict, _, _} = dict]) do
    keys = PyDict.keys(Builtins.visible_dict(dict))
    {:mutate, {:py_list, Enum.reverse(keys) ++ reversed, len + length(keys)}, nil}
  end

  defp list_extend({:py_list, reversed, len}, [map]) when is_map(map),
    do:
      {:mutate,
       {:py_list, Enum.reverse(Map.keys(Builtins.visible_dict(map))) ++ reversed,
        len + map_size(map)}, nil}

  defp list_extend({:py_list, reversed, len}, [{:range, _, _, _} = r]) do
    case Builtins.range_to_list(r) do
      {:exception, _} = err -> err
      items -> {:mutate, {:py_list, Enum.reverse(items) ++ reversed, len + length(items)}, nil}
    end
  end

  # Fallback for legacy list format
  defp list_extend(list, [other]) when is_list(list) and is_list(other),
    do: {:mutate, list ++ other, nil}

  defp list_extend(list, [{:tuple, items}]) when is_list(list),
    do: {:mutate, list ++ items, nil}

  @spec list_insert({:py_list, [term()], non_neg_integer()}, [Interpreter.pyvalue()]) ::
          {:mutate, {:py_list, [term()], non_neg_integer()}, nil}
  defp list_insert({:py_list, reversed, len}, [index, item]) when is_integer(index) do
    # Resolve python index to a clamped python position in [0, len].
    py_pos =
      cond do
        index < 0 -> max(len + index, 0)
        index > len -> len
        true -> index
      end

    # Storage is reversed: python position `p` corresponds to storage
    # position `len - p` when inserting (shifts everything at p..end
    # right by one in python, which is storage positions 0..len-p-1).
    storage_index = len - py_pos

    {before, rest} = Enum.split(reversed, storage_index)
    {:mutate, {:py_list, before ++ [item | rest], len + 1}, nil}
  end

  defp list_insert(list, [index, item]) when is_list(list) and is_integer(index) do
    len = length(list)

    pos =
      cond do
        index < 0 -> max(len + index, 0)
        index > len -> len
        true -> index
      end

    {:mutate, List.insert_at(list, pos, item), nil}
  end

  @spec list_remove({:py_list, [term()], non_neg_integer()}, [Interpreter.pyvalue()]) ::
          {:mutate, {:py_list, [term()], non_neg_integer()}, nil}
  defp list_remove({:py_list, reversed, len}, [item]) do
    items = Enum.reverse(reversed)

    case Enum.find_index(items, &(&1 == item)) do
      nil ->
        {:exception, "ValueError: list.remove(x): x not in list"}

      idx ->
        new_items = List.delete_at(items, idx)
        {:mutate, {:py_list, Enum.reverse(new_items), len - 1}, nil}
    end
  end

  defp list_remove(list, [item]) when is_list(list) do
    case Enum.find_index(list, &(&1 == item)) do
      nil -> {:exception, "ValueError: list.remove(x): x not in list"}
      idx -> {:mutate, List.delete_at(list, idx), nil}
    end
  end

  @spec list_pop({:py_list, [term()], non_neg_integer()}, [Interpreter.pyvalue()]) ::
          {:mutate, {:py_list, [term()], non_neg_integer()}, Interpreter.pyvalue()}
          | {:exception, String.t()}
  defp list_pop({:py_list, [], 0}, _), do: {:exception, "IndexError: pop from empty list"}

  defp list_pop({:py_list, [head | tail], len}, []),
    do: {:mutate, {:py_list, tail, len - 1}, head}

  defp list_pop({:py_list, reversed, len}, [index]) when is_integer(index) do
    # Transform Python index to storage index
    real_index =
      if index < 0 do
        # Python negative: -1 → 0 (first in reversed), -2 → 1, etc.
        -index - 1
      else
        # Python positive: 0 → len-1 (last in reversed), 1 → len-2, etc.
        len - 1 - index
      end

    if real_index < 0 or real_index >= len do
      {:exception, "IndexError: pop index out of range"}
    else
      value = Enum.at(reversed, real_index)
      {before, [_ | rest]} = Enum.split(reversed, real_index)
      new_reversed = before ++ rest
      {:mutate, {:py_list, new_reversed, len - 1}, value}
    end
  end

  # Fallback for legacy list format
  defp list_pop([], _), do: {:exception, "IndexError: pop from empty list"}
  defp list_pop(list, []), do: list_pop(list, [-1])

  defp list_pop(list, [index]) when is_list(list) and is_integer(index) do
    len = length(list)
    idx = if index < 0, do: len + index, else: index

    if idx < 0 or idx >= len do
      {:exception, "IndexError: pop index out of range"}
    else
      value = Enum.at(list, idx)
      {:mutate, List.delete_at(list, idx), value}
    end
  end

  @spec list_sort({:py_list, [term()], non_neg_integer()}, [Interpreter.pyvalue()], map()) ::
          {:mutate, {:py_list, [term()], non_neg_integer()}, nil}
          | {:list_sort_call, [term()], Interpreter.pyvalue() | nil, boolean(), non_neg_integer()}
  defp list_sort({:py_list, reversed, len}, [], kwargs) do
    key_fn = Map.get(kwargs, "key")
    reverse = Map.get(kwargs, "reverse", false)

    if key_fn == nil do
      # Storage is reversed: ascending Python order = descending storage order
      order = if reverse == true, do: :asc, else: :desc
      sorted_storage = Enum.sort(reversed, order)
      {:mutate, {:py_list, sorted_storage, len}, nil}
    else
      # Pass items in Python order so eval_sort can compare and sort them
      # correctly.  builtin_results re-wraps the result back into py_list.
      {:list_sort_call, Enum.reverse(reversed), key_fn, reverse == true, len}
    end
  end

  defp list_sort(list, [], kwargs) when is_list(list) do
    key_fn = Map.get(kwargs, "key")
    reverse = Map.get(kwargs, "reverse", false)

    if key_fn == nil and reverse == false do
      {:mutate, Enum.sort(list), nil}
    else
      {:list_sort_call, list, key_fn, reverse == true, length(list)}
    end
  end

  @spec list_reverse({:py_list, [term()], non_neg_integer()}, [Interpreter.pyvalue()]) ::
          {:mutate, {:py_list, [term()], non_neg_integer()}, nil}
  defp list_reverse({:py_list, reversed, len}, []),
    do: {:mutate, {:py_list, Enum.reverse(reversed), len}, nil}

  defp list_reverse(list, []) when is_list(list),
    do: {:mutate, Enum.reverse(list), nil}

  @spec list_clear({:py_list, [term()], non_neg_integer()}, [Interpreter.pyvalue()]) ::
          {:mutate, {:py_list, [term()], non_neg_integer()}, nil}
  defp list_clear({:py_list, _, _}, []), do: {:mutate, {:py_list, [], 0}, nil}
  defp list_clear(list, []) when is_list(list), do: {:mutate, [], nil}

  @spec list_index({:py_list, [term()], non_neg_integer()}, [Interpreter.pyvalue()]) ::
          integer() | {:exception, String.t()}
  defp list_index({:py_list, reversed, _len}, args) do
    items = Enum.reverse(reversed)
    list_index_impl(items, args)
  end

  defp list_index(list, args) when is_list(list), do: list_index_impl(list, args)

  @spec list_index_impl([Interpreter.pyvalue()], [Interpreter.pyvalue()]) ::
          integer() | {:exception, String.t()}
  defp list_index_impl(items, [item]), do: find_index_or_error(items, item, 0)

  defp list_index_impl(items, [item, start]) when is_integer(start) do
    len = length(items)
    s = clamp_slice_index(start, len)
    sliced = Enum.drop(items, s)

    case find_index_or_error(sliced, item, 0) do
      {:exception, _} = e -> e
      idx -> idx + s
    end
  end

  defp list_index_impl(items, [item, start, stop])
       when is_integer(start) and is_integer(stop) do
    len = length(items)
    s = clamp_slice_index(start, len)
    e = clamp_slice_index(stop, len)
    sliced = items |> Enum.drop(s) |> Enum.take(max(e - s, 0))

    case find_index_or_error(sliced, item, 0) do
      {:exception, _} = err -> err
      idx -> idx + s
    end
  end

  @spec find_index_or_error([Interpreter.pyvalue()], Interpreter.pyvalue(), non_neg_integer()) ::
          non_neg_integer() | {:exception, String.t()}
  defp find_index_or_error(items, item, offset) do
    case Enum.find_index(items, &(&1 == item)) do
      nil -> {:exception, "ValueError: #{inspect(item)} is not in list"}
      idx -> idx + offset
    end
  end

  @spec clamp_slice_index(integer(), non_neg_integer()) :: non_neg_integer()
  defp clamp_slice_index(i, len) when i < 0, do: max(len + i, 0)
  defp clamp_slice_index(i, len), do: min(i, len)

  @spec list_count({:py_list, [term()], non_neg_integer()}, [Interpreter.pyvalue()]) ::
          non_neg_integer()
  defp list_count({:py_list, reversed, _}, [item]) do
    Enum.count(reversed, &(&1 == item))
  end

  defp list_count(list, [item]) when is_list(list) do
    Enum.count(list, &(&1 == item))
  end

  @spec list_copy({:py_list, [term()], non_neg_integer()}, [Interpreter.pyvalue()]) ::
          {:py_list, [term()], non_neg_integer()}
  defp list_copy({:py_list, reversed, len}, []), do: {:py_list, reversed, len}
  defp list_copy(list, []) when is_list(list), do: list

  @spec tuple_method(String.t()) ::
          {:ok, (Interpreter.pyvalue(), [Interpreter.pyvalue()] -> Interpreter.pyvalue())}
          | :error
  defp tuple_method("count"), do: {:ok, &tuple_count/2}
  defp tuple_method("index"), do: {:ok, &tuple_index/2}
  defp tuple_method(_), do: :error

  @spec tuple_count(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: non_neg_integer()
  defp tuple_count({:tuple, items}, [item]) do
    Enum.count(items, &(&1 == item))
  end

  @spec tuple_index(Interpreter.pyvalue(), [Interpreter.pyvalue()]) ::
          integer() | {:exception, String.t()}
  defp tuple_index({:tuple, items}, [item]) do
    case Enum.find_index(items, &(&1 == item)) do
      nil -> {:exception, "ValueError: tuple.index(x): x not in tuple"}
      idx -> idx
    end
  end

  @spec set_method(String.t()) ::
          {:ok, (Interpreter.pyvalue(), [Interpreter.pyvalue()] -> Interpreter.pyvalue())}
          | :error
  defp set_method("add"), do: {:ok, &set_add/2}
  defp set_method("remove"), do: {:ok, &set_remove/2}
  defp set_method("discard"), do: {:ok, &set_discard/2}
  defp set_method("pop"), do: {:ok, &set_pop/2}
  defp set_method("clear"), do: {:ok, &set_clear/2}
  defp set_method("copy"), do: {:ok, &set_copy/2}
  defp set_method("union"), do: {:ok, &set_union/2}
  defp set_method("intersection"), do: {:ok, &set_intersection/2}
  defp set_method("difference"), do: {:ok, &set_difference/2}
  defp set_method("symmetric_difference"), do: {:ok, &set_symmetric_difference/2}
  defp set_method("issubset"), do: {:ok, &set_issubset/2}
  defp set_method("issuperset"), do: {:ok, &set_issuperset/2}
  defp set_method("isdisjoint"), do: {:ok, &set_isdisjoint/2}
  defp set_method("update"), do: {:ok, &set_update/2}
  defp set_method(_), do: :error

  @spec set_add(Interpreter.pyvalue(), [Interpreter.pyvalue()]) ::
          {:mutate, Interpreter.pyvalue(), nil}
  defp set_add({:set, s}, [item]), do: {:mutate, {:set, MapSet.put(s, item)}, nil}

  @spec set_remove(Interpreter.pyvalue(), [Interpreter.pyvalue()]) ::
          {:mutate, Interpreter.pyvalue(), nil} | {:exception, String.t()}
  defp set_remove({:set, s}, [item]) do
    if MapSet.member?(s, item) do
      {:mutate, {:set, MapSet.delete(s, item)}, nil}
    else
      {:exception, "KeyError: #{inspect(item)}"}
    end
  end

  @spec set_discard(Interpreter.pyvalue(), [Interpreter.pyvalue()]) ::
          {:mutate, Interpreter.pyvalue(), nil}
  defp set_discard({:set, s}, [item]), do: {:mutate, {:set, MapSet.delete(s, item)}, nil}

  @spec set_pop(Interpreter.pyvalue(), [Interpreter.pyvalue()]) ::
          {:mutate, Interpreter.pyvalue(), Interpreter.pyvalue()} | {:exception, String.t()}
  defp set_pop({:set, s}, []) do
    case MapSet.to_list(s) do
      [] -> {:exception, "KeyError: 'pop from an empty set'"}
      [item | _] -> {:mutate, {:set, MapSet.delete(s, item)}, item}
    end
  end

  @spec set_clear(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: tuple()
  defp set_clear({:set, _}, []), do: {:mutate, {:set, MapSet.new()}, nil}

  @spec set_update(Interpreter.pyvalue(), [Interpreter.pyvalue()]) ::
          {:mutate, Interpreter.pyvalue(), nil}
  defp set_update({:set, a}, [{:set, b}]), do: {:mutate, {:set, MapSet.union(a, b)}, nil}
  defp set_update({:set, a}, [{:frozenset, b}]), do: {:mutate, {:set, MapSet.union(a, b)}, nil}

  defp set_update({:set, a}, [list]) when is_list(list),
    do: {:mutate, {:set, MapSet.union(a, MapSet.new(list))}, nil}

  defp set_update({:set, a}, [{:tuple, items}]),
    do: {:mutate, {:set, MapSet.union(a, MapSet.new(items))}, nil}

  defp set_update({:set, a}, [{:generator, items}]),
    do: {:mutate, {:set, MapSet.union(a, MapSet.new(items))}, nil}

  defp set_update({:set, a}, [str]) when is_binary(str),
    do: {:mutate, {:set, MapSet.union(a, MapSet.new(String.codepoints(str)))}, nil}

  defp set_update({:set, a}, [{:py_dict, _, _} = dict]),
    do:
      {:mutate, {:set, MapSet.union(a, MapSet.new(PyDict.keys(Builtins.visible_dict(dict))))},
       nil}

  defp set_update({:set, a}, [map]) when is_map(map),
    do: {:mutate, {:set, MapSet.union(a, MapSet.new(Map.keys(Builtins.visible_dict(map))))}, nil}

  @spec set_copy(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp set_copy({:set, _} = s, []), do: s

  @spec set_union(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp set_union({:set, a}, [{:set, b}]), do: {:set, MapSet.union(a, b)}

  defp set_union({:set, a}, [list]) when is_list(list),
    do: {:set, MapSet.union(a, MapSet.new(list))}

  @spec set_intersection(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp set_intersection({:set, a}, [{:set, b}]), do: {:set, MapSet.intersection(a, b)}

  defp set_intersection({:set, a}, [list]) when is_list(list),
    do: {:set, MapSet.intersection(a, MapSet.new(list))}

  @spec set_difference(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp set_difference({:set, a}, [{:set, b}]), do: {:set, MapSet.difference(a, b)}

  defp set_difference({:set, a}, [list]) when is_list(list),
    do: {:set, MapSet.difference(a, MapSet.new(list))}

  @spec set_symmetric_difference(Interpreter.pyvalue(), [Interpreter.pyvalue()]) ::
          Interpreter.pyvalue()
  defp set_symmetric_difference({:set, a}, [{:set, b}]),
    do: {:set, MapSet.symmetric_difference(a, b)}

  @spec set_issubset(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: boolean()
  defp set_issubset({:set, a}, [{:set, b}]), do: MapSet.subset?(a, b)

  @spec set_issuperset(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: boolean()
  defp set_issuperset({:set, a}, [{:set, b}]), do: MapSet.subset?(b, a)

  @spec set_isdisjoint(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: boolean()
  defp set_isdisjoint({:set, a}, [{:set, b}]), do: MapSet.disjoint?(a, b)

  @spec frozenset_method(String.t()) ::
          {:ok, (Interpreter.pyvalue(), [Interpreter.pyvalue()] -> Interpreter.pyvalue())}
          | :error
  defp frozenset_method("copy"), do: {:ok, &frozenset_copy/2}
  defp frozenset_method("union"), do: {:ok, &frozenset_union/2}
  defp frozenset_method("intersection"), do: {:ok, &frozenset_intersection/2}
  defp frozenset_method("difference"), do: {:ok, &frozenset_difference/2}
  defp frozenset_method("symmetric_difference"), do: {:ok, &frozenset_symmetric_difference/2}
  defp frozenset_method("issubset"), do: {:ok, &frozenset_issubset/2}
  defp frozenset_method("issuperset"), do: {:ok, &frozenset_issuperset/2}
  defp frozenset_method("isdisjoint"), do: {:ok, &frozenset_isdisjoint/2}
  defp frozenset_method(_), do: :error

  @spec frozenset_copy(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp frozenset_copy({:frozenset, _} = fs, []), do: fs

  @spec frozenset_union(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp frozenset_union({:frozenset, a}, [{:set, b}]), do: {:frozenset, MapSet.union(a, b)}
  defp frozenset_union({:frozenset, a}, [{:frozenset, b}]), do: {:frozenset, MapSet.union(a, b)}

  defp frozenset_union({:frozenset, a}, [list]) when is_list(list),
    do: {:frozenset, MapSet.union(a, MapSet.new(list))}

  @spec frozenset_intersection(Interpreter.pyvalue(), [Interpreter.pyvalue()]) ::
          Interpreter.pyvalue()
  defp frozenset_intersection({:frozenset, a}, [{:set, b}]),
    do: {:frozenset, MapSet.intersection(a, b)}

  defp frozenset_intersection({:frozenset, a}, [{:frozenset, b}]),
    do: {:frozenset, MapSet.intersection(a, b)}

  defp frozenset_intersection({:frozenset, a}, [list]) when is_list(list),
    do: {:frozenset, MapSet.intersection(a, MapSet.new(list))}

  @spec frozenset_difference(Interpreter.pyvalue(), [Interpreter.pyvalue()]) ::
          Interpreter.pyvalue()
  defp frozenset_difference({:frozenset, a}, [{:set, b}]),
    do: {:frozenset, MapSet.difference(a, b)}

  defp frozenset_difference({:frozenset, a}, [{:frozenset, b}]),
    do: {:frozenset, MapSet.difference(a, b)}

  defp frozenset_difference({:frozenset, a}, [list]) when is_list(list),
    do: {:frozenset, MapSet.difference(a, MapSet.new(list))}

  @spec frozenset_symmetric_difference(Interpreter.pyvalue(), [Interpreter.pyvalue()]) ::
          Interpreter.pyvalue()
  defp frozenset_symmetric_difference({:frozenset, a}, [{:set, b}]),
    do: {:frozenset, MapSet.symmetric_difference(a, b)}

  defp frozenset_symmetric_difference({:frozenset, a}, [{:frozenset, b}]),
    do: {:frozenset, MapSet.symmetric_difference(a, b)}

  @spec frozenset_issubset(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: boolean()
  defp frozenset_issubset({:frozenset, a}, [{:set, b}]), do: MapSet.subset?(a, b)
  defp frozenset_issubset({:frozenset, a}, [{:frozenset, b}]), do: MapSet.subset?(a, b)

  @spec frozenset_issuperset(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: boolean()
  defp frozenset_issuperset({:frozenset, a}, [{:set, b}]), do: MapSet.subset?(b, a)
  defp frozenset_issuperset({:frozenset, a}, [{:frozenset, b}]), do: MapSet.subset?(b, a)

  @spec frozenset_isdisjoint(Interpreter.pyvalue(), [Interpreter.pyvalue()]) :: boolean()
  defp frozenset_isdisjoint({:frozenset, a}, [{:set, b}]), do: MapSet.disjoint?(a, b)
  defp frozenset_isdisjoint({:frozenset, a}, [{:frozenset, b}]), do: MapSet.disjoint?(a, b)

  # ---------------------------------------------------------------------------
  # pandas Series methods (backed by Explorer/Polars)
  # ---------------------------------------------------------------------------

  @spec pandas_series_method(String.t()) ::
          {:ok, (Interpreter.pyvalue(), [Interpreter.pyvalue()] -> Interpreter.pyvalue())}
          | :error
  defp pandas_series_method("sum"), do: {:ok, &series_sum/2}
  defp pandas_series_method("mean"), do: {:ok, &series_mean/2}
  defp pandas_series_method("std"), do: {:ok, &series_std/2}
  defp pandas_series_method("min"), do: {:ok, &series_min/2}
  defp pandas_series_method("max"), do: {:ok, &series_max/2}
  defp pandas_series_method("median"), do: {:ok, &series_median/2}
  defp pandas_series_method("cumsum"), do: {:ok, &series_cumsum/2}
  defp pandas_series_method("diff"), do: {:ok, &series_diff/2}
  defp pandas_series_method("shift"), do: {:ok, &series_shift/2}
  defp pandas_series_method("abs"), do: {:ok, &series_abs/2}
  defp pandas_series_method("rolling"), do: {:ok, &series_rolling/2}
  defp pandas_series_method("tolist"), do: {:ok, &series_tolist/2}
  defp pandas_series_method(_), do: :error

  @spec pandas_series_property(Interpreter.pyvalue(), String.t()) ::
          {:ok, Interpreter.pyvalue()} | :error
  defp pandas_series_property({:pandas_series, s}, "dtype") do
    dtype = Explorer.Series.dtype(s)
    {:ok, Atom.to_string(dtype)}
  end

  defp pandas_series_property({:pandas_series, s}, "shape") do
    {:ok, {:tuple, [Explorer.Series.count(s)]}}
  end

  defp pandas_series_property(_, _), do: :error

  defp series_sum({:pandas_series, s}, []), do: Explorer.Series.sum(s)
  defp series_mean({:pandas_series, s}, []), do: Explorer.Series.mean(s)

  defp series_std({:pandas_series, s}, []) do
    Explorer.Series.standard_deviation(s)
  end

  defp series_min({:pandas_series, s}, []), do: Explorer.Series.min(s)
  defp series_max({:pandas_series, s}, []), do: Explorer.Series.max(s)
  defp series_median({:pandas_series, s}, []), do: Explorer.Series.median(s)

  defp series_cumsum({:pandas_series, s}, []) do
    {:pandas_series, Explorer.Series.cumulative_sum(s)}
  end

  defp series_diff({:pandas_series, s}, []) do
    series_diff({:pandas_series, s}, [1])
  end

  defp series_diff({:pandas_series, s}, [n]) when is_integer(n) do
    shifted = Explorer.Series.shift(s, n)
    {:pandas_series, Explorer.Series.subtract(s, shifted)}
  end

  defp series_shift({:pandas_series, s}, [n]) when is_integer(n) do
    {:pandas_series, Explorer.Series.shift(s, n)}
  end

  defp series_abs({:pandas_series, s}, []) do
    {:pandas_series, Explorer.Series.abs(s)}
  end

  defp series_rolling({:pandas_series, s}, [window]) when is_integer(window) do
    {:pandas_rolling, s, window}
  end

  defp series_tolist({:pandas_series, s}, []) do
    Explorer.Series.to_list(s)
    |> Enum.map(fn
      %Date{} = d -> Date.to_string(d)
      %NaiveDateTime{} = dt -> NaiveDateTime.to_string(dt)
      other -> other
    end)
  end

  # ---------------------------------------------------------------------------
  # pandas Rolling methods
  # ---------------------------------------------------------------------------

  @spec pandas_rolling_method(String.t()) ::
          {:ok, (Interpreter.pyvalue(), [Interpreter.pyvalue()] -> Interpreter.pyvalue())}
          | :error
  defp pandas_rolling_method("mean"), do: {:ok, &rolling_mean/2}
  defp pandas_rolling_method("sum"), do: {:ok, &rolling_sum/2}
  defp pandas_rolling_method("min"), do: {:ok, &rolling_min/2}
  defp pandas_rolling_method("max"), do: {:ok, &rolling_max/2}
  defp pandas_rolling_method("std"), do: {:ok, &rolling_std/2}
  defp pandas_rolling_method(_), do: :error

  defp rolling_mean({:pandas_rolling, s, w}, []) do
    {:pandas_series, Explorer.Series.window_mean(s, w, min_periods: w)}
  end

  defp rolling_sum({:pandas_rolling, s, w}, []) do
    {:pandas_series, Explorer.Series.window_sum(s, w, min_periods: w)}
  end

  defp rolling_min({:pandas_rolling, s, w}, []) do
    {:pandas_series, Explorer.Series.window_min(s, w, min_periods: w)}
  end

  defp rolling_max({:pandas_rolling, s, w}, []) do
    {:pandas_series, Explorer.Series.window_max(s, w, min_periods: w)}
  end

  defp rolling_std({:pandas_rolling, s, w}, []) do
    {:pandas_series, Explorer.Series.window_standard_deviation(s, w, min_periods: w)}
  end

  # ---------------------------------------------------------------------------
  # pandas DataFrame methods
  # ---------------------------------------------------------------------------

  @spec pandas_dataframe_property(Interpreter.pyvalue(), String.t()) ::
          {:ok, Interpreter.pyvalue()} | :error
  defp pandas_dataframe_property({:pandas_dataframe, df}, "columns") do
    {:ok, Explorer.DataFrame.names(df)}
  end

  defp pandas_dataframe_property({:pandas_dataframe, df}, "shape") do
    {rows, cols} = Explorer.DataFrame.shape(df)
    {:ok, {:tuple, [rows, cols]}}
  end

  defp pandas_dataframe_property(_, _), do: :error

  @spec normalize_index(integer(), non_neg_integer()) :: non_neg_integer()
  defp normalize_index(i, len) when i < 0, do: max(len + i, 0)
  defp normalize_index(i, len), do: min(i, len)

  # ── StringIO methods ────────────────────────────────────────────────────────

  @spec stringio_method(String.t()) :: {:ok, fun()} | :error
  defp stringio_method("write"), do: {:ok, &stringio_write/3}
  defp stringio_method("getvalue"), do: {:ok, &stringio_getvalue/3}
  defp stringio_method("read"), do: {:ok, &stringio_read/3}
  defp stringio_method("readline"), do: {:ok, &stringio_readline/3}
  defp stringio_method("readlines"), do: {:ok, &stringio_readlines/3}
  defp stringio_method("seek"), do: {:ok, &stringio_seek/3}
  defp stringio_method("tell"), do: {:ok, &stringio_tell/3}
  defp stringio_method("truncate"), do: {:ok, &stringio_truncate/3}
  defp stringio_method("close"), do: {:ok, &stringio_close/3}
  defp stringio_method("__enter__"), do: {:ok, &stringio_enter/3}
  defp stringio_method("__exit__"), do: {:ok, &stringio_exit/3}
  defp stringio_method(_), do: :error

  defp stringio_write({:stringio, buf}, [s], _kw) when is_binary(s) do
    {:mutate, {:stringio, buf <> s}, byte_size(s)}
  end

  defp stringio_write(_, _, _), do: {:exception, "TypeError: write() argument must be str"}

  defp stringio_getvalue({:stringio, buf}, _args, _kw), do: buf

  defp stringio_read({:stringio, buf}, [], _kw), do: buf
  defp stringio_read({:stringio, buf}, [n], _kw) when is_integer(n), do: String.slice(buf, 0, n)
  defp stringio_read(_, _, _), do: ""

  defp stringio_readline({:stringio, buf}, _args, _kw) do
    case String.split(buf, "\n", parts: 2) do
      [line, _] -> line <> "\n"
      [line] -> line
    end
  end

  defp stringio_readlines({:stringio, buf}, _args, _kw) do
    String.split(buf, "\n") |> Enum.map(&(&1 <> "\n"))
  end

  defp stringio_seek({:stringio, buf}, [_pos], _kw), do: {:mutate, {:stringio, buf}, 0}
  defp stringio_seek(sio, _, _), do: {:mutate, sio, 0}

  defp stringio_tell({:stringio, buf}, _args, _kw), do: byte_size(buf)

  defp stringio_truncate({:stringio, _buf}, [size], _kw) when is_integer(size) do
    {:mutate, {:stringio, ""}, size}
  end

  defp stringio_truncate({:stringio, _buf}, [], _kw) do
    {:mutate, {:stringio, ""}, 0}
  end

  defp stringio_close({:stringio, buf}, _args, _kw) do
    {:mutate, {:stringio, buf}, nil}
  end

  defp stringio_enter({:stringio, _} = sio, _args, _kw), do: sio
  defp stringio_exit({:stringio, _}, _args, _kw), do: false

  # ── deque methods ────────────────────────────────────────────────────────────

  @spec deque_method(String.t()) ::
          {:ok, (Interpreter.pyvalue(), [Interpreter.pyvalue()], map() -> Interpreter.pyvalue())}
          | :error
  defp deque_method("append"), do: {:ok, &deque_append/3}
  defp deque_method("appendleft"), do: {:ok, &deque_appendleft/3}
  defp deque_method("pop"), do: {:ok, &deque_pop/3}
  defp deque_method("popleft"), do: {:ok, &deque_popleft/3}
  defp deque_method("extend"), do: {:ok, &deque_extend/3}
  defp deque_method("extendleft"), do: {:ok, &deque_extendleft/3}
  defp deque_method("clear"), do: {:ok, &deque_clear/3}
  defp deque_method("rotate"), do: {:ok, &deque_rotate/3}
  defp deque_method("copy"), do: {:ok, &deque_copy/3}
  defp deque_method(_), do: :error

  defp deque_trim({:deque, items, maxlen} = d) do
    if is_integer(maxlen) and length(items) > maxlen do
      {:deque, Enum.take(items, -maxlen), maxlen}
    else
      d
    end
  end

  defp deque_append({:deque, items, maxlen}, [x], _kw) do
    new = deque_trim({:deque, items ++ [x], maxlen})
    {:mutate, new, nil}
  end

  defp deque_appendleft({:deque, items, maxlen}, [x], _kw) do
    new = deque_trim({:deque, [x | items], maxlen})
    {:mutate, new, nil}
  end

  defp deque_pop({:deque, [], _}, _args, _kw) do
    {:exception, "IndexError: pop from an empty deque"}
  end

  defp deque_pop({:deque, items, maxlen}, _args, _kw) do
    last = List.last(items)
    new = {:deque, Enum.drop(items, -1), maxlen}
    {:mutate, new, last}
  end

  defp deque_popleft({:deque, [], _}, _args, _kw) do
    {:exception, "IndexError: pop from an empty deque"}
  end

  defp deque_popleft({:deque, [head | rest], maxlen}, _args, _kw) do
    {:mutate, {:deque, rest, maxlen}, head}
  end

  defp deque_extend({:deque, items, maxlen}, [iterable], _kw) do
    new_items = Builtins.to_list_safe(iterable)
    new = deque_trim({:deque, items ++ new_items, maxlen})
    {:mutate, new, nil}
  end

  defp deque_extendleft({:deque, items, maxlen}, [iterable], _kw) do
    new_items = Builtins.to_list_safe(iterable)
    new = deque_trim({:deque, Enum.reverse(new_items) ++ items, maxlen})
    {:mutate, new, nil}
  end

  defp deque_clear({:deque, _, maxlen}, _args, _kw) do
    {:mutate, {:deque, [], maxlen}, nil}
  end

  defp deque_rotate({:deque, items, maxlen}, args, _kw) do
    n =
      case args do
        [n] when is_integer(n) -> n
        _ -> 1
      end

    len = length(items)

    if len == 0 do
      {:mutate, {:deque, items, maxlen}, nil}
    else
      n = rem(n, len)
      n = if n < 0, do: n + len, else: n
      {right, left} = Enum.split(items, len - n)
      {:mutate, {:deque, left ++ right, maxlen}, nil}
    end
  end

  defp deque_copy({:deque, items, maxlen}, _args, _kw) do
    {:deque, items, maxlen}
  end
end
