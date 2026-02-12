defmodule Pyex.Stdlib.Json do
  @moduledoc """
  Python `json` module backed by Jason.

  Provides `json.loads(string)` and `json.dumps(value)`.
  """

  @behaviour Pyex.Stdlib.Module

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
      {:ok, value} -> value
      {:error, reason} -> {:exception, "json.loads failed: #{inspect(reason)}"}
    end
  end

  @spec do_dumps(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: String.t() | {:exception, String.t()}
  defp do_dumps([value], kwargs) do
    indent = Map.get(kwargs, "indent")
    opts = if is_integer(indent) and indent > 0, do: [pretty: true], else: []

    case Jason.encode(to_json(value), opts) do
      {:ok, json} ->
        if is_integer(indent) and indent > 0 do
          reindent(json, indent)
        else
          json
        end

      {:error, reason} ->
        {:exception, "TypeError: Object of type is not JSON serializable: #{inspect(reason)}"}
    end
  end

  @spec to_json(Pyex.Interpreter.pyvalue()) :: term()
  defp to_json({:tuple, items}), do: Enum.map(items, &to_json/1)
  defp to_json({:set, s}), do: s |> MapSet.to_list() |> Enum.map(&to_json/1)
  defp to_json({:frozenset, s}), do: s |> MapSet.to_list() |> Enum.map(&to_json/1)
  defp to_json(list) when is_list(list), do: Enum.map(list, &to_json/1)

  defp to_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_json(k), to_json(v)} end)
  end

  defp to_json(other), do: other

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
