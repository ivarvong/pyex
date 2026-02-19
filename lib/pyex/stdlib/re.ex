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
      "split" => {:builtin, &do_split/1},
      "compile" => {:builtin, &do_compile/1},
      "IGNORECASE" => 2,
      "DOTALL" => 4,
      "MULTILINE" => 8
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
    do_findall_with_flags(pattern, string, 0)
  end

  defp do_findall([pattern, string, flags])
       when is_binary(pattern) and is_binary(string) and is_integer(flags) do
    do_findall_with_flags(pattern, string, flags)
  end

  defp do_findall_with_flags(pattern, string, flags) do
    opts = flags_to_regex_opts(flags)

    case Regex.compile(pattern, opts) do
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

  @spec do_compile([Pyex.Interpreter.pyvalue()]) :: map() | {:exception, String.t()}
  defp do_compile([pattern]) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, re} -> make_pattern_object(re, pattern)
      {:error, {msg, _}} -> {:exception, "re.error: #{msg}"}
    end
  end

  defp do_compile([pattern, flags]) when is_binary(pattern) and is_integer(flags) do
    opts = flags_to_regex_opts(flags)

    case Regex.compile(pattern, opts) do
      {:ok, re} -> make_pattern_object(re, pattern)
      {:error, {msg, _}} -> {:exception, "re.error: #{msg}"}
    end
  end

  @spec flags_to_regex_opts(integer()) :: [term()]
  defp flags_to_regex_opts(flags) do
    opts = []
    opts = if Bitwise.band(flags, 2) != 0, do: [:caseless | opts], else: opts
    opts = if Bitwise.band(flags, 4) != 0, do: [:dotall | opts], else: opts
    opts = if Bitwise.band(flags, 8) != 0, do: [:multiline | opts], else: opts
    opts
  end

  @spec make_pattern_object(Regex.t(), String.t()) :: map()
  defp make_pattern_object(re, pattern) do
    %{
      "pattern" => pattern,
      "match" =>
        {:builtin,
         fn
           [string] when is_binary(string) ->
             anchored = "\\A" <> pattern

             case Regex.compile(anchored) do
               {:ok, anchored_re} ->
                 case safe_regex(fn -> Regex.run(anchored_re, string) end) do
                   {:ok, nil} -> nil
                   {:ok, [match | groups]} -> make_match_object(match, groups)
                   {:exception, _} = err -> err
                 end

               {:error, {msg, _}} ->
                 {:exception, "re.error: #{msg}"}
             end
         end},
      "search" =>
        {:builtin,
         fn
           [string] when is_binary(string) ->
             case safe_regex(fn -> Regex.run(re, string) end) do
               {:ok, nil} -> nil
               {:ok, [match | groups]} -> make_match_object(match, groups)
               {:exception, _} = err -> err
             end
         end},
      "findall" =>
        {:builtin,
         fn
           [string] when is_binary(string) ->
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
         end},
      "sub" =>
        {:builtin,
         fn
           [replacement, string]
           when is_binary(replacement) and is_binary(string) ->
             case safe_regex(fn -> Regex.replace(re, string, replacement) end) do
               {:ok, result} -> result
               {:exception, _} = err -> err
             end
         end},
      "split" =>
        {:builtin,
         fn
           [string] when is_binary(string) ->
             case safe_regex(fn -> Regex.split(re, string) end) do
               {:ok, result} -> result
               {:exception, _} = err -> err
             end
         end}
    }
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
