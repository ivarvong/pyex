defmodule Pyex.Methods do
  @moduledoc """
  Method dispatch for Python built-in types.

  Resolves attribute access on strings and lists to bound
  method callables (closures over the receiver).
  """

  alias Pyex.{Builtins, Interpreter}

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
    issubset issuperset pop remove symmetric_difference union
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
      :error -> :error
    end
  end

  def resolve(object, attr) when is_list(object) do
    case list_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin, bound(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve({:file_handle, id}, attr) do
    case file_method(attr, id) do
      {:ok, method_fn} -> {:ok, {:builtin, method_fn}}
      :error -> :error
    end
  end

  def resolve(object, attr) when is_map(object) do
    case dict_method(attr) do
      {:ok, method_fn} -> {:ok, {:builtin, bound(method_fn, object)}}
      :error -> :error
    end
  end

  def resolve({:set, _} = object, attr) do
    case set_method(attr) do
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
  def method_names(val) when is_list(val), do: @list_methods
  def method_names(val) when is_map(val), do: @dict_methods
  def method_names({:set, _}), do: @set_methods
  def method_names({:tuple, _}), do: @tuple_methods
  def method_names(_), do: []

  @spec bound(
          (Interpreter.pyvalue(), [Interpreter.pyvalue()] -> Interpreter.pyvalue()),
          Interpreter.pyvalue()
        ) :: ([Interpreter.pyvalue()] -> Interpreter.pyvalue())
  defp bound(method_fn, receiver) do
    fn args -> method_fn.(receiver, args) end
  end

  @spec string_method(String.t()) ::
          {:ok, (String.t(), [Interpreter.pyvalue()] -> Interpreter.pyvalue())} | :error
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
  defp string_method("format"), do: {:ok, &str_format/2}
  defp string_method("isdigit"), do: {:ok, &str_isdigit/2}
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
  defp string_method("isnumeric"), do: {:ok, &str_isnumeric/2}
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
          | :error
  defp list_method("append"), do: {:ok, &list_append/2}
  defp list_method("extend"), do: {:ok, &list_extend/2}
  defp list_method("insert"), do: {:ok, &list_insert/2}
  defp list_method("remove"), do: {:ok, &list_remove/2}
  defp list_method("pop"), do: {:ok, &list_pop/2}
  defp list_method("sort"), do: {:ok, &list_sort/2}
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
          | :error
  defp dict_method("get"), do: {:ok, &dict_get/2}
  defp dict_method("keys"), do: {:ok, &dict_keys/2}
  defp dict_method("values"), do: {:ok, &dict_values/2}
  defp dict_method("items"), do: {:ok, &dict_items/2}
  defp dict_method("pop"), do: {:ok, &dict_pop/2}
  defp dict_method("update"), do: {:ok, &dict_update/2}
  defp dict_method("setdefault"), do: {:ok, &dict_setdefault/2}
  defp dict_method("clear"), do: {:ok, &dict_clear/2}
  defp dict_method("copy"), do: {:ok, &dict_copy/2}
  defp dict_method(_), do: :error

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

  @spec str_split(String.t(), [Interpreter.pyvalue()]) :: [String.t()]
  defp str_split(s, []), do: String.split(s)
  defp str_split(s, [sep]) when is_binary(sep), do: String.split(s, sep)

  @spec str_join(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_join(s, [list]) when is_list(list), do: Enum.join(list, s)
  defp str_join(s, [{:generator, items}]), do: Enum.join(items, s)
  defp str_join(s, [{:tuple, items}]), do: Enum.join(items, s)

  @spec str_replace(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_replace(s, [old, new]) when is_binary(old) and is_binary(new) do
    String.replace(s, old, new)
  end

  @spec str_startswith(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_startswith(s, [prefix]) when is_binary(prefix), do: String.starts_with?(s, prefix)

  @spec str_endswith(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_endswith(s, [suffix]) when is_binary(suffix), do: String.ends_with?(s, suffix)

  @spec str_find(String.t(), [Interpreter.pyvalue()]) :: integer()
  defp str_find(s, [sub]) when is_binary(sub) do
    case :binary.match(s, sub) do
      {pos, _len} -> pos
      :nomatch -> -1
    end
  end

  @spec str_count(String.t(), [Interpreter.pyvalue()]) :: non_neg_integer()
  defp str_count(s, [sub]) when is_binary(sub) do
    length(String.split(s, sub)) - 1
  end

  @spec str_format(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp str_format(s, args) do
    args
    |> Enum.with_index()
    |> Enum.reduce(s, fn {arg, idx}, acc ->
      String.replace(acc, "{#{idx}}", py_repr(arg), global: true)
      |> String.replace("{}", py_repr(arg), global: false)
    end)
  end

  @spec str_isdigit(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_isdigit(s, []) when s == "", do: false
  defp str_isdigit(s, []), do: String.match?(s, ~r/^\d+$/)

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
    String.pad_leading(s, width, "0")
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

  @spec str_isnumeric(String.t(), [Interpreter.pyvalue()]) :: boolean()
  defp str_isnumeric("", []), do: false
  defp str_isnumeric(s, []), do: String.match?(s, ~r/^\d+$/)

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
    case :binary.match(s, sub) do
      {pos, _len} -> pos
      :nomatch -> {:exception, "ValueError: substring not found"}
    end
  end

  @spec str_rfind(String.t(), [Interpreter.pyvalue()]) :: integer()
  defp str_rfind(s, [sub]) when is_binary(sub) do
    case :binary.matches(s, sub) do
      [] -> -1
      matches -> matches |> List.last() |> elem(0)
    end
  end

  @spec str_rindex(String.t(), [Interpreter.pyvalue()]) ::
          integer() | {:exception, String.t()}
  defp str_rindex(s, [sub]) when is_binary(sub) do
    case :binary.matches(s, sub) do
      [] -> {:exception, "ValueError: substring not found"}
      matches -> matches |> List.last() |> elem(0)
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
  defp str_splitlines(s, []), do: String.split(s, ~r/\r\n|\r|\n/)
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

  @spec dict_get(map(), [Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp dict_get(map, [key]), do: Map.get(map, key, nil)
  defp dict_get(map, [key, default]), do: Map.get(map, key, default)

  @spec dict_keys(map(), [Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp dict_keys(map, []), do: map |> Builtins.visible_dict() |> Map.keys()

  @spec dict_values(map(), [Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp dict_values(map, []), do: map |> Builtins.visible_dict() |> Map.values()

  @spec dict_items(map(), [Interpreter.pyvalue()]) :: [{:tuple, [Interpreter.pyvalue()]}]
  defp dict_items(map, []),
    do: map |> Builtins.visible_dict() |> Enum.map(fn {k, v} -> {:tuple, [k, v]} end)

  @spec dict_pop(map(), [Interpreter.pyvalue()]) ::
          {:mutate, map(), Interpreter.pyvalue()}
  defp dict_pop(map, [key]) do
    case Map.pop(map, key) do
      {nil, _} -> {:exception, "KeyError: #{inspect(key)}"}
      {val, rest} -> {:mutate, rest, val}
    end
  end

  defp dict_pop(map, [key, default]) do
    {val, rest} = Map.pop(map, key, default)
    {:mutate, rest, val}
  end

  @spec dict_update(map(), [Interpreter.pyvalue()]) :: {:mutate, map(), nil}
  defp dict_update(map, [other]) when is_map(other) do
    merged = Map.merge(map, Builtins.visible_dict(other))
    {:mutate, merged, nil}
  end

  @spec dict_setdefault(map(), [Interpreter.pyvalue()]) ::
          {:mutate, map(), Interpreter.pyvalue()}
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

  @spec dict_clear(map(), [Interpreter.pyvalue()]) :: {:mutate, map(), nil}
  defp dict_clear(map, []) do
    case Map.fetch(map, "__defaultdict_factory__") do
      {:ok, factory} -> {:mutate, %{"__defaultdict_factory__" => factory}, nil}
      :error -> {:mutate, %{}, nil}
    end
  end

  @spec dict_copy(map(), [Interpreter.pyvalue()]) :: map()
  defp dict_copy(map, []), do: map

  @spec list_append([Interpreter.pyvalue()], [Interpreter.pyvalue()]) ::
          {:mutate, [Interpreter.pyvalue()], nil}
  defp list_append(list, [item]), do: {:mutate, list ++ [item], nil}

  @spec list_extend([Interpreter.pyvalue()], [Interpreter.pyvalue()]) ::
          {:mutate, [Interpreter.pyvalue()], nil}
  defp list_extend(list, [other]) when is_list(other), do: {:mutate, list ++ other, nil}

  @spec list_insert([Interpreter.pyvalue()], [Interpreter.pyvalue()]) ::
          {:mutate, [Interpreter.pyvalue()], nil}
  defp list_insert(list, [index, item]) when is_integer(index) do
    {:mutate, List.insert_at(list, index, item), nil}
  end

  @spec list_remove([Interpreter.pyvalue()], [Interpreter.pyvalue()]) ::
          {:mutate, [Interpreter.pyvalue()], nil}
  defp list_remove(list, [item]) do
    case Enum.find_index(list, &(&1 == item)) do
      nil -> {:exception, "ValueError: list.remove(x): x not in list"}
      idx -> {:mutate, List.delete_at(list, idx), nil}
    end
  end

  @spec list_pop([Interpreter.pyvalue()], [Interpreter.pyvalue()]) ::
          {:mutate, [Interpreter.pyvalue()], Interpreter.pyvalue()}
  defp list_pop([], _), do: {:exception, "IndexError: pop from empty list"}
  defp list_pop(list, []), do: list_pop(list, [-1])

  defp list_pop(list, [index]) when is_integer(index) do
    len = length(list)
    idx = if index < 0, do: len + index, else: index

    if idx < 0 or idx >= len do
      {:exception, "IndexError: pop index out of range"}
    else
      value = Enum.at(list, idx)
      {:mutate, List.delete_at(list, idx), value}
    end
  end

  @spec list_sort([Interpreter.pyvalue()], [Interpreter.pyvalue()]) ::
          {:mutate, [Interpreter.pyvalue()], nil}
  defp list_sort(list, []), do: {:mutate, Enum.sort(list), nil}

  @spec list_reverse([Interpreter.pyvalue()], [Interpreter.pyvalue()]) ::
          {:mutate, [Interpreter.pyvalue()], nil}
  defp list_reverse(list, []), do: {:mutate, Enum.reverse(list), nil}

  @spec list_clear([Interpreter.pyvalue()], [Interpreter.pyvalue()]) ::
          {:mutate, [Interpreter.pyvalue()], nil}
  defp list_clear(_list, []), do: {:mutate, [], nil}

  @spec list_index([Interpreter.pyvalue()], [Interpreter.pyvalue()]) :: integer()
  defp list_index(list, [item]) do
    case Enum.find_index(list, &(&1 == item)) do
      nil -> {:exception, "ValueError: #{inspect(item)} is not in list"}
      idx -> idx
    end
  end

  @spec list_count([Interpreter.pyvalue()], [Interpreter.pyvalue()]) :: non_neg_integer()
  defp list_count(list, [item]) do
    Enum.count(list, &(&1 == item))
  end

  @spec list_copy([Interpreter.pyvalue()], [Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp list_copy(list, []), do: list

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

  @spec py_repr(Interpreter.pyvalue()) :: String.t()
  defp py_repr(nil), do: "None"
  defp py_repr(true), do: "True"
  defp py_repr(false), do: "False"
  defp py_repr(val) when is_binary(val), do: val
  defp py_repr(val) when is_integer(val), do: Integer.to_string(val)
  defp py_repr(val) when is_float(val), do: Float.to_string(val)
  defp py_repr(_), do: "<object>"

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
end
