defmodule Pyex.Stdlib.Fnmatch do
  @moduledoc """
  Minimal `fnmatch` support.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Interpreter

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "fnmatch" => {:builtin, &fnmatch/1},
      "fnmatchcase" => {:builtin, &fnmatchcase/1},
      "filter" => {:builtin, &filter/1}
    }
  end

  @spec fnmatch([Interpreter.pyvalue()]) :: boolean() | {:exception, String.t()}
  defp fnmatch([name, pattern]) when is_binary(name) and is_binary(pattern) do
    glob_match(String.downcase(name), String.downcase(pattern))
  end

  defp fnmatch(_args), do: {:exception, "TypeError: fnmatch() expects (name, pat) strings"}

  @spec fnmatchcase([Interpreter.pyvalue()]) :: boolean() | {:exception, String.t()}
  defp fnmatchcase([name, pattern]) when is_binary(name) and is_binary(pattern) do
    glob_match(name, pattern)
  end

  defp fnmatchcase(_args),
    do: {:exception, "TypeError: fnmatchcase() expects (name, pat) strings"}

  @spec filter([Interpreter.pyvalue()]) :: [String.t()] | {:exception, String.t()}
  defp filter([names, pattern]) when is_list(names) and is_binary(pattern) do
    Enum.filter(names, &(is_binary(&1) and glob_match(&1, pattern)))
  end

  defp filter([{:py_list, reversed, _}, pattern]) when is_binary(pattern) do
    reversed
    |> Enum.reverse()
    |> Enum.filter(&(is_binary(&1) and glob_match(&1, pattern)))
  end

  defp filter(_args), do: {:exception, "TypeError: filter() expects (names, pat)"}

  @spec glob_match(String.t(), String.t()) :: boolean()
  defp glob_match(name, pattern) do
    Pyex.Path.glob_match?(name, pattern)
  end
end
