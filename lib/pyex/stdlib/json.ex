defmodule Pyex.Stdlib.Json do
  @moduledoc """
  Python `json` module backed by Jason.

  Provides `json.loads(string)` and `json.dumps(value)`.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.PyDict

  @max_indent 32

  @doc """
  Returns the module value -- a map with callable attributes.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "loads" => {:builtin, &do_loads/1},
      "dumps" => {:builtin_kw, &do_dumps/2}
    }
  end

  @spec do_loads([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_loads([string]) when is_binary(string) do
    case Jason.decode(string) do
      {:ok, value} -> from_json(value)
      {:error, reason} -> {:exception, "json.loads failed: #{inspect(reason)}"}
    end
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
    json_value = to_json(value)
    json_value = if sort_keys, do: sort_json_keys(json_value), else: json_value

    cond do
      is_integer(indent) and indent > @max_indent ->
        {:exception, "ValueError: indent must be <= #{@max_indent}, got #{indent}"}

      is_integer(indent) and indent > 0 ->
        case Jason.encode(json_value, pretty: true) do
          {:ok, json} -> reindent(json, indent)
          {:error, reason} -> encode_error(reason)
        end

      true ->
        case Jason.encode(json_value) do
          {:ok, json} -> add_python_spaces(json)
          {:error, reason} -> encode_error(reason)
        end
    end
  end

  @spec add_python_spaces(String.t()) :: String.t()
  defp add_python_spaces(json) do
    # Python json.dumps uses ", " and ": " as separators by default.
    # Jason produces compact JSON without spaces.  We post-process the
    # output to match Python by inserting spaces after : and , that are
    # outside of string values.
    add_python_spaces(json, false, <<>>)
  end

  @spec add_python_spaces(String.t(), boolean(), binary()) :: String.t()
  defp add_python_spaces(<<>>, _in_str, acc), do: acc

  defp add_python_spaces(<<?\\, c, rest::binary>>, true, acc) do
    add_python_spaces(rest, true, <<acc::binary, ?\\, c>>)
  end

  defp add_python_spaces(<<?", rest::binary>>, in_str, acc) do
    add_python_spaces(rest, not in_str, <<acc::binary, ?">>)
  end

  defp add_python_spaces(<<?:, rest::binary>>, false, acc) do
    add_python_spaces(rest, false, <<acc::binary, ?:, ?\s>>)
  end

  defp add_python_spaces(<<?,, rest::binary>>, false, acc) do
    add_python_spaces(rest, false, <<acc::binary, ?,, ?\s>>)
  end

  defp add_python_spaces(<<c, rest::binary>>, in_str, acc) do
    add_python_spaces(rest, in_str, <<acc::binary, c>>)
  end

  @spec encode_error(term()) :: {:exception, String.t()}
  defp encode_error(reason) do
    {:exception, "TypeError: Object of type is not JSON serializable: #{inspect(reason)}"}
  end

  @spec to_json(Pyex.Interpreter.pyvalue()) :: term()
  defp to_json({:tuple, items}), do: Enum.map(items, &to_json/1)
  defp to_json({:set, s}), do: s |> MapSet.to_list() |> Enum.map(&to_json/1)
  defp to_json({:frozenset, s}), do: s |> MapSet.to_list() |> Enum.map(&to_json/1)
  defp to_json({:py_list, reversed, _}), do: reversed |> Enum.reverse() |> Enum.map(&to_json/1)
  defp to_json(list) when is_list(list), do: Enum.map(list, &to_json/1)

  defp to_json({:py_dict, _, _} = dict) do
    pairs = Enum.map(PyDict.items(dict), fn {k, v} -> {to_json_key(k), to_json(v)} end)
    %Jason.OrderedObject{values: pairs}
  end

  defp to_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_json(k), to_json(v)} end)
  end

  defp to_json(other), do: other

  @spec to_json_key(Pyex.Interpreter.pyvalue()) :: String.t()
  defp to_json_key(k) when is_binary(k), do: k
  defp to_json_key(k) when is_integer(k), do: Integer.to_string(k)
  defp to_json_key(k) when is_float(k), do: Float.to_string(k)
  defp to_json_key(k), do: to_string(k)

  @spec sort_json_keys(term()) :: term()
  defp sort_json_keys(%Jason.OrderedObject{values: pairs}) do
    sorted = Enum.sort_by(pairs, fn {k, _v} -> k end)
    %Jason.OrderedObject{values: Enum.map(sorted, fn {k, v} -> {k, sort_json_keys(v)} end)}
  end

  defp sort_json_keys(%{} = map) do
    Map.new(map, fn {k, v} -> {k, sort_json_keys(v)} end)
  end

  defp sort_json_keys(list) when is_list(list), do: Enum.map(list, &sort_json_keys/1)
  defp sort_json_keys(other), do: other

  @spec reindent(String.t(), pos_integer()) :: String.t()
  defp reindent(json, indent) when indent == 2, do: json

  defp reindent(json, indent) do
    spaces = String.duplicate(" ", indent)

    json
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      trimmed = String.trim_leading(line)
      leading = String.length(line) - String.length(trimmed)
      level = div(leading, 2)
      String.duplicate(spaces, level) <> trimmed
    end)
  end
end
