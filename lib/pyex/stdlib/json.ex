defmodule Pyex.Stdlib.JSON do
  @moduledoc """
  Python `json` module.

  Encoding is implemented natively to match CPython byte-for-byte
  (separators, `ensure_ascii`, `indent=0`, float formatting, etc.).
  Decoding is backed by Jason since the JSON grammar is standard.

  Provides `json.loads(string)` and `json.dumps(value)` with
  `indent`, `sort_keys`, `separators`, `ensure_ascii` kwargs.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.PyDict
  alias Pyex.Interpreter.Helpers

  @max_indent 32

  @doc """
  Returns the module value -- a map with callable attributes.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "loads" => {:builtin, &do_loads/1},
      "dumps" => {:builtin_kw, &do_dumps/2},
      "load" => {:builtin, &do_load/1},
      "dump" => {:builtin_kw, &do_dump/2},
      "JSONDecodeError" => {:class, "JSONDecodeError", [], %{}}
    }
  end

  @spec do_load([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_load([{:file_handle, id}]) do
    {:io_call,
     fn env, ctx ->
       case Pyex.Ctx.read_handle(ctx, id) do
         {:ok, content, ctx} ->
           case Jason.decode(content) do
             {:ok, value} ->
               {from_json(value), env, ctx}

             {:error, reason} ->
               {{:exception, "JSONDecodeError: #{format_decode_error(reason)}"}, env, ctx}
           end

         {:error, msg} ->
           {{:exception, msg}, env, ctx}
       end
     end}
  end

  defp do_load(_args) do
    {:exception, "TypeError: json.load() argument must be a file object"}
  end

  @spec do_dump(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: Pyex.Interpreter.pyvalue()
  defp do_dump([value, {:file_handle, id}], kwargs) do
    case do_dumps([value], kwargs) do
      {:exception, _} = err ->
        err

      json_str ->
        {:io_call,
         fn env, ctx ->
           case Pyex.Ctx.write_handle(ctx, id, json_str) do
             {:ok, ctx} -> {nil, env, ctx}
             {:error, msg} -> {{:exception, msg}, env, ctx}
           end
         end}
    end
  end

  defp do_dump(_args, _kwargs) do
    {:exception, "TypeError: json.dump() requires a value and a file object"}
  end

  @spec do_loads([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_loads([string]) when is_binary(string) do
    case Jason.decode(string) do
      {:ok, value} ->
        from_json(value)

      {:error, reason} ->
        {:exception, "JSONDecodeError: #{format_decode_error(reason)}"}
    end
  end

  @spec format_decode_error(Jason.DecodeError.t()) :: String.t()
  defp format_decode_error(%Jason.DecodeError{position: pos, data: data}) when is_binary(data) do
    {line, col} = line_col(data, pos)
    "Expecting value: line #{line} column #{col} (char #{pos})"
  end

  @spec line_col(String.t(), non_neg_integer()) :: {pos_integer(), pos_integer()}
  defp line_col(data, pos) do
    prefix = binary_part(data, 0, min(pos, byte_size(data)))

    line = 1 + (prefix |> String.graphemes() |> Enum.count(&(&1 == "\n")))

    col =
      case :binary.matches(prefix, "\n") do
        [] -> pos + 1
        matches -> pos - elem(List.last(matches), 0)
      end

    {line, col}
  end

  @spec from_json(term()) :: Pyex.Interpreter.pyvalue()
  defp from_json(list) when is_list(list) do
    items = Enum.map(list, &from_json/1)
    {:py_list, Enum.reverse(items), length(items)}
  end

  defp from_json(map) when is_map(map) do
    pairs = Enum.map(map, fn {k, v} -> {k, from_json(v)} end)
    PyDict.from_pairs(pairs)
  end

  defp from_json(other), do: other

  @spec do_dumps(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: String.t() | {:exception, String.t()}
  defp do_dumps([value], kwargs) do
    indent = Map.get(kwargs, "indent")
    sort_keys = Map.get(kwargs, "sort_keys", false)
    ensure_ascii = Map.get(kwargs, "ensure_ascii", true)
    separators = resolve_separators(Map.get(kwargs, "separators"), indent)

    cond do
      is_integer(indent) and indent > @max_indent ->
        {:exception, "ValueError: indent must be <= #{@max_indent}, got #{indent}"}

      is_integer(indent) ->
        encode(value, %{
          indent: indent,
          level: 0,
          sort_keys: sort_keys,
          ensure_ascii: ensure_ascii,
          item_sep: elem(separators, 0),
          key_sep: elem(separators, 1)
        })

      true ->
        encode(value, %{
          indent: nil,
          level: 0,
          sort_keys: sort_keys,
          ensure_ascii: ensure_ascii,
          item_sep: elem(separators, 0),
          key_sep: elem(separators, 1)
        })
    end
  end

  @spec resolve_separators(
          {String.t(), String.t()} | {:tuple, [String.t()]} | nil,
          integer() | nil
        ) :: {String.t(), String.t()}
  defp resolve_separators(nil, nil), do: {", ", ": "}
  defp resolve_separators(nil, _indent), do: {",", ": "}

  defp resolve_separators({:tuple, [item, key]}, _indent) when is_binary(item) and is_binary(key),
    do: {item, key}

  defp resolve_separators({item, key}, _indent) when is_binary(item) and is_binary(key),
    do: {item, key}

  defp resolve_separators(_, indent), do: resolve_separators(nil, indent)

  @type encode_opts :: %{
          indent: integer() | nil,
          level: non_neg_integer(),
          sort_keys: boolean(),
          ensure_ascii: boolean(),
          item_sep: String.t(),
          key_sep: String.t()
        }

  @spec encode(Pyex.Interpreter.pyvalue(), encode_opts()) ::
          String.t() | {:exception, String.t()}
  defp encode(nil, _opts), do: "null"
  defp encode(true, _opts), do: "true"
  defp encode(false, _opts), do: "false"
  defp encode(v, _opts) when is_integer(v), do: Integer.to_string(v)
  defp encode(v, _opts) when is_float(v), do: encode_float(v)
  defp encode(:infinity, _opts), do: encode_float(:infinity)
  defp encode(:neg_infinity, _opts), do: encode_float(:neg_infinity)
  defp encode(:nan, _opts), do: encode_float(:nan)
  defp encode(v, opts) when is_binary(v), do: encode_string(v, opts.ensure_ascii)

  defp encode({:py_list, reversed, _}, opts) do
    items = Enum.reverse(reversed)
    encode_array(items, opts)
  end

  defp encode(list, opts) when is_list(list), do: encode_array(list, opts)

  defp encode({:tuple, items}, opts), do: encode_array(items, opts)
  defp encode({:set, s}, opts), do: encode_array(MapSet.to_list(s), opts)
  defp encode({:frozenset, s}, opts), do: encode_array(MapSet.to_list(s), opts)

  defp encode({:py_dict, _, _} = dict, opts) do
    pairs = PyDict.items(dict)

    pairs =
      if opts.sort_keys do
        Enum.sort_by(pairs, fn {k, _v} -> to_json_key(k) end)
      else
        pairs
      end

    encode_object(pairs, opts)
  end

  defp encode(map, opts) when is_map(map) do
    pairs = Enum.into(map, [])

    pairs =
      if opts.sort_keys do
        Enum.sort_by(pairs, fn {k, _v} -> to_json_key(k) end)
      else
        pairs
      end

    encode_object(pairs, opts)
  end

  defp encode(other, _opts) do
    {:exception, "TypeError: Object of type #{type_name(other)} is not JSON serializable"}
  end

  @spec encode_array([Pyex.Interpreter.pyvalue()], encode_opts()) ::
          String.t() | {:exception, String.t()}
  defp encode_array([], _opts), do: "[]"

  defp encode_array(items, %{indent: nil} = opts) do
    parts = Enum.map(items, &encode(&1, opts))

    case first_exception(parts) do
      nil -> "[" <> Enum.join(parts, opts.item_sep) <> "]"
      exc -> exc
    end
  end

  defp encode_array(items, opts) do
    inner_opts = %{opts | level: opts.level + 1}
    parts = Enum.map(items, &encode(&1, inner_opts))

    case first_exception(parts) do
      nil ->
        indent_str = indent_at(inner_opts)
        close_indent = indent_at(opts)
        sep = String.trim_trailing(opts.item_sep) <> "\n" <> indent_str
        "[\n" <> indent_str <> Enum.join(parts, sep) <> "\n" <> close_indent <> "]"

      exc ->
        exc
    end
  end

  @spec encode_object([{Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()}], encode_opts()) ::
          String.t() | {:exception, String.t()}
  defp encode_object([], _opts), do: "{}"

  defp encode_object(pairs, %{indent: nil} = opts) do
    parts =
      Enum.map(pairs, fn {k, v} ->
        key = encode_string(to_json_key(k), opts.ensure_ascii)
        val = encode(v, opts)

        case val do
          {:exception, _} = e -> e
          s -> key <> opts.key_sep <> s
        end
      end)

    case first_exception(parts) do
      nil -> "{" <> Enum.join(parts, opts.item_sep) <> "}"
      exc -> exc
    end
  end

  defp encode_object(pairs, opts) do
    inner_opts = %{opts | level: opts.level + 1}

    parts =
      Enum.map(pairs, fn {k, v} ->
        key = encode_string(to_json_key(k), opts.ensure_ascii)
        val = encode(v, inner_opts)

        case val do
          {:exception, _} = e -> e
          s -> key <> opts.key_sep <> s
        end
      end)

    case first_exception(parts) do
      nil ->
        indent_str = indent_at(inner_opts)
        close_indent = indent_at(opts)
        sep = String.trim_trailing(opts.item_sep) <> "\n" <> indent_str
        "{\n" <> indent_str <> Enum.join(parts, sep) <> "\n" <> close_indent <> "}"

      exc ->
        exc
    end
  end

  @spec indent_at(encode_opts()) :: String.t()
  defp indent_at(%{indent: n, level: level}) when is_integer(n) do
    String.duplicate(" ", n * level)
  end

  defp indent_at(_), do: ""

  @spec first_exception([term()]) :: {:exception, String.t()} | nil
  defp first_exception(parts) do
    Enum.find(parts, fn
      {:exception, _} -> true
      _ -> false
    end)
  end

  @spec encode_float(float() | :infinity | :neg_infinity | :nan) :: String.t()
  defp encode_float(:infinity), do: "Infinity"
  defp encode_float(:neg_infinity), do: "-Infinity"
  defp encode_float(:nan), do: "NaN"
  defp encode_float(v) when is_float(v), do: Helpers.py_float_str(v)

  @spec encode_string(String.t(), boolean()) :: String.t()
  defp encode_string(s, ensure_ascii) do
    inner =
      s
      |> String.to_charlist()
      |> Enum.map_join(&encode_char(&1, ensure_ascii))

    "\"" <> inner <> "\""
  end

  @spec encode_char(integer(), boolean()) :: String.t()
  defp encode_char(?", _), do: "\\\""
  defp encode_char(?\\, _), do: "\\\\"
  defp encode_char(?\b, _), do: "\\b"
  defp encode_char(?\f, _), do: "\\f"
  defp encode_char(?\n, _), do: "\\n"
  defp encode_char(?\r, _), do: "\\r"
  defp encode_char(?\t, _), do: "\\t"

  defp encode_char(c, _) when c < 0x20 do
    "\\u" <> (c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))
  end

  defp encode_char(c, true) when c > 0x7E do
    encode_ascii_escape(c)
  end

  defp encode_char(c, _), do: <<c::utf8>>

  @spec encode_ascii_escape(integer()) :: String.t()
  defp encode_ascii_escape(c) when c <= 0xFFFF do
    "\\u" <> (c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))
  end

  defp encode_ascii_escape(c) do
    # Surrogate pair encoding for codepoints above BMP.
    shifted = c - 0x10000
    hi = 0xD800 + Bitwise.bsr(shifted, 10)
    lo = 0xDC00 + Bitwise.band(shifted, 0x3FF)
    encode_ascii_escape(hi) <> encode_ascii_escape(lo)
  end

  @spec to_json_key(Pyex.Interpreter.pyvalue()) :: String.t()
  defp to_json_key(k) when is_binary(k), do: k
  defp to_json_key(k) when is_integer(k), do: Integer.to_string(k)
  defp to_json_key(k) when is_float(k), do: Helpers.py_float_str(k)
  defp to_json_key(true), do: "true"
  defp to_json_key(false), do: "false"
  defp to_json_key(nil), do: "null"
  defp to_json_key(k), do: to_string(k)

  @spec type_name(Pyex.Interpreter.pyvalue()) :: String.t()
  defp type_name({:instance, {:class, name, _, _}, _}), do: name
  defp type_name(_), do: "object"
end
