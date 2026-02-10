defmodule Pyex.Stdlib.Re do
  @moduledoc """
  Python `re` module backed by Elixir's `Regex`.

  Provides `match`, `search`, `findall`, `sub`, `split`,
  and `compile`.
  """

  @behaviour Pyex.Stdlib.Module

  @doc """
  Returns the module value map.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "match" => {:builtin, &do_match/1},
      "search" => {:builtin, &do_search/1},
      "findall" => {:builtin, &do_findall/1},
      "sub" => {:builtin, &do_sub/1},
      "split" => {:builtin, &do_split/1}
    }
  end

  @spec do_match([Pyex.Interpreter.pyvalue()]) ::
          Pyex.Interpreter.pyvalue() | {:exception, String.t()}
  defp do_match([pattern, string]) when is_binary(pattern) and is_binary(string) do
    anchored = "\\A" <> pattern

    case Regex.compile(anchored) do
      {:ok, re} ->
        case Regex.run(re, string) do
          nil -> nil
          [match | groups] -> make_match_object(match, groups)
        end

      {:error, {msg, _}} ->
        {:exception, "re.error: #{msg}"}
    end
  end

  @spec do_search([Pyex.Interpreter.pyvalue()]) ::
          Pyex.Interpreter.pyvalue() | {:exception, String.t()}
  defp do_search([pattern, string]) when is_binary(pattern) and is_binary(string) do
    case Regex.compile(pattern) do
      {:ok, re} ->
        case Regex.run(re, string) do
          nil -> nil
          [match | groups] -> make_match_object(match, groups)
        end

      {:error, {msg, _}} ->
        {:exception, "re.error: #{msg}"}
    end
  end

  @spec do_findall([Pyex.Interpreter.pyvalue()]) ::
          [String.t()] | {:exception, String.t()}
  defp do_findall([pattern, string]) when is_binary(pattern) and is_binary(string) do
    case Regex.compile(pattern) do
      {:ok, re} ->
        case Regex.scan(re, string) do
          results -> Enum.map(results, fn [m | _] -> m end)
        end

      {:error, {msg, _}} ->
        {:exception, "re.error: #{msg}"}
    end
  end

  @spec do_sub([Pyex.Interpreter.pyvalue()]) :: String.t() | {:exception, String.t()}
  defp do_sub([pattern, replacement, string])
       when is_binary(pattern) and is_binary(replacement) and is_binary(string) do
    case Regex.compile(pattern) do
      {:ok, re} -> Regex.replace(re, string, replacement)
      {:error, {msg, _}} -> {:exception, "re.error: #{msg}"}
    end
  end

  @spec do_split([Pyex.Interpreter.pyvalue()]) :: [String.t()] | {:exception, String.t()}
  defp do_split([pattern, string]) when is_binary(pattern) and is_binary(string) do
    case Regex.compile(pattern) do
      {:ok, re} -> Regex.split(re, string)
      {:error, {msg, _}} -> {:exception, "re.error: #{msg}"}
    end
  end

  @spec make_match_object(String.t(), [String.t()]) :: map()
  defp make_match_object(full_match, groups) do
    %{
      "group" =>
        {:builtin,
         fn
           [] -> full_match
           [0] -> full_match
           [n] when is_integer(n) and n > 0 -> Enum.at(groups, n - 1)
         end}
    }
  end
end
