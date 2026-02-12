defmodule Pyex.Stdlib.Re do
  @moduledoc """
  Python `re` module backed by Elixir's `Regex`.

  Provides `match`, `search`, `findall`, `sub`, `split`,
  and `compile`.
  """

  @behaviour Pyex.Stdlib.Module

  @regex_timeout_ms 1_000

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
        case safe_regex(fn -> Regex.run(re, string) end) do
          {:ok, nil} -> nil
          {:ok, [match | groups]} -> make_match_object(match, groups)
          {:exception, _} = err -> err
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
        case safe_regex(fn -> Regex.run(re, string) end) do
          {:ok, nil} -> nil
          {:ok, [match | groups]} -> make_match_object(match, groups)
          {:exception, _} = err -> err
        end

      {:error, {msg, _}} ->
        {:exception, "re.error: #{msg}"}
    end
  end

  @spec do_findall([Pyex.Interpreter.pyvalue()]) ::
          [Pyex.Interpreter.pyvalue()] | {:exception, String.t()}
  defp do_findall([pattern, string]) when is_binary(pattern) and is_binary(string) do
    case Regex.compile(pattern) do
      {:ok, re} ->
        case safe_regex(fn -> Regex.scan(re, string) end) do
          {:ok, []} ->
            []

          {:ok, [[_full] | _] = results} ->
            Enum.map(results, fn [m | _] -> m end)

          {:ok, [[_full | _groups] | _] = results} ->
            Enum.map(results, fn
              [_full | [single]] -> single
              [_full | groups] -> {:tuple, groups}
            end)

          {:exception, _} = err ->
            err
        end

      {:error, {msg, _}} ->
        {:exception, "re.error: #{msg}"}
    end
  end

  @spec do_sub([Pyex.Interpreter.pyvalue()]) :: String.t() | {:exception, String.t()}
  defp do_sub([pattern, replacement, string])
       when is_binary(pattern) and is_binary(replacement) and is_binary(string) do
    case Regex.compile(pattern) do
      {:ok, re} ->
        case safe_regex(fn -> Regex.replace(re, string, replacement) end) do
          {:ok, result} -> result
          {:exception, _} = err -> err
        end

      {:error, {msg, _}} ->
        {:exception, "re.error: #{msg}"}
    end
  end

  @spec do_split([Pyex.Interpreter.pyvalue()]) :: [String.t()] | {:exception, String.t()}
  defp do_split([pattern, string]) when is_binary(pattern) and is_binary(string) do
    case Regex.compile(pattern) do
      {:ok, re} ->
        case safe_regex(fn -> Regex.split(re, string) end) do
          {:ok, result} -> result
          {:exception, _} = err -> err
        end

      {:error, {msg, _}} ->
        {:exception, "re.error: #{msg}"}
    end
  end

  @spec safe_regex((-> result)) :: {:ok, result} | {:exception, String.t()}
        when result: term()
  defp safe_regex(fun) do
    task = Task.async(fun)

    case Task.yield(task, @regex_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:exception, "re.error: regex evaluation timed out (possible ReDoS)"}
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
