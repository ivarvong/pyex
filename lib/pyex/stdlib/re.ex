defmodule Pyex.Stdlib.Re do
  @moduledoc """
  Python `re` module backed by Elixir's `Regex`.

  Provides `match`, `search`, `findall`, `finditer`, `sub`, `split`,
  and `compile`.
  """

  @behaviour Pyex.Stdlib.Module

  @regex_timeout_ms 10_000

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
      "finditer" => {:builtin, &do_finditer/1},
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
        case safe_regex(fn -> Regex.run(re, string, return: :index) end) do
          {:ok, nil} ->
            nil

          {:ok, indices} ->
            make_match_object(re, string, indices)

          {:exception, _} = err ->
            err
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
        case safe_regex(fn -> Regex.run(re, string, return: :index) end) do
          {:ok, nil} ->
            nil

          {:ok, indices} ->
            make_match_object(re, string, indices)

          {:exception, _} = err ->
            err
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

  @spec do_finditer([Pyex.Interpreter.pyvalue()]) ::
          {:generator, [map()]} | {:exception, String.t()}
  defp do_finditer([pattern, string]) when is_binary(pattern) and is_binary(string) do
    do_finditer_with_flags(pattern, string, 0)
  end

  defp do_finditer([pattern, string, flags])
       when is_binary(pattern) and is_binary(string) and is_integer(flags) do
    do_finditer_with_flags(pattern, string, flags)
  end

  @spec do_finditer_with_flags(String.t(), String.t(), integer()) ::
          {:generator, [map()]} | {:exception, String.t()}
  defp do_finditer_with_flags(pattern, string, flags) do
    opts = flags_to_regex_opts(flags)

    case Regex.compile(pattern, opts) do
      {:ok, re} ->
        case safe_regex(fn -> Regex.scan(re, string, return: :index) end) do
          {:ok, results} ->
            match_objects = Enum.map(results, &make_match_object(re, string, &1))
            {:generator, match_objects}

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
                 case safe_regex(fn -> Regex.run(anchored_re, string, return: :index) end) do
                   {:ok, nil} -> nil
                   {:ok, indices} -> make_match_object(anchored_re, string, indices)
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
             case safe_regex(fn -> Regex.run(re, string, return: :index) end) do
               {:ok, nil} -> nil
               {:ok, indices} -> make_match_object(re, string, indices)
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
      "finditer" =>
        {:builtin,
         fn
           [string] when is_binary(string) ->
             case safe_regex(fn -> Regex.scan(re, string, return: :index) end) do
               {:ok, results} ->
                 match_objects = Enum.map(results, &make_match_object(re, string, &1))
                 {:generator, match_objects}

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

  @spec byte_offset_to_codepoint(String.t(), non_neg_integer()) :: non_neg_integer()
  defp byte_offset_to_codepoint(string, byte_offset) do
    string
    |> binary_part(0, byte_offset)
    |> String.length()
  end

  @spec extract_match_text(String.t(), {non_neg_integer(), non_neg_integer()}) :: String.t()
  defp extract_match_text(string, {byte_start, byte_len}) do
    binary_part(string, byte_start, byte_len)
  end

  @spec names_in_pattern_order(Regex.t()) :: [String.t()]
  defp names_in_pattern_order(re) do
    source = Regex.source(re)

    ~r/\(\?P?<([^>]+)>/
    |> Regex.scan(source)
    |> Enum.map(fn [_, name] -> name end)
  end

  @spec make_match_object(Regex.t(), String.t(), [{non_neg_integer(), non_neg_integer()}]) ::
          map()
  defp make_match_object(re, string, indices) do
    [{full_byte_start, full_byte_len} | group_indices] = indices
    full_match = extract_match_text(string, {full_byte_start, full_byte_len})

    groups =
      Enum.map(group_indices, fn
        {-1, 0} -> nil
        {s, l} -> extract_match_text(string, {s, l})
      end)

    ordered_names = names_in_pattern_order(re)

    named_map =
      ordered_names
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {name, idx}, acc ->
        Map.put(acc, name, Enum.at(groups, idx))
      end)

    last_group =
      ordered_names
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {name, idx} ->
        if Enum.at(groups, idx) != nil, do: name
      end)

    full_cp_start = byte_offset_to_codepoint(string, full_byte_start)
    full_cp_end = byte_offset_to_codepoint(string, full_byte_start + full_byte_len)

    group_cp_positions =
      Enum.map(group_indices, fn
        {-1, 0} -> {nil, nil}
        {s, l} -> {byte_offset_to_codepoint(string, s), byte_offset_to_codepoint(string, s + l)}
      end)

    %{
      "group" =>
        {:builtin,
         fn
           [] ->
             full_match

           [0] ->
             full_match

           [n] when is_integer(n) and n > 0 ->
             Enum.at(groups, n - 1)

           [name] when is_binary(name) ->
             case Map.fetch(named_map, name) do
               {:ok, value} -> value
               :error -> {:exception, "IndexError: no such group '#{name}'"}
             end
         end},
      "start" =>
        {:builtin,
         fn
           [] ->
             full_cp_start

           [0] ->
             full_cp_start

           [n] when is_integer(n) and n > 0 ->
             case Enum.at(group_cp_positions, n - 1) do
               {s, _} -> s
               nil -> {:exception, "IndexError: no such group #{n}"}
             end
         end},
      "end" =>
        {:builtin,
         fn
           [] ->
             full_cp_end

           [0] ->
             full_cp_end

           [n] when is_integer(n) and n > 0 ->
             case Enum.at(group_cp_positions, n - 1) do
               {_, e} -> e
               nil -> {:exception, "IndexError: no such group #{n}"}
             end
         end},
      "span" =>
        {:builtin,
         fn
           [] ->
             {:tuple, [full_cp_start, full_cp_end]}

           [0] ->
             {:tuple, [full_cp_start, full_cp_end]}

           [n] when is_integer(n) and n > 0 ->
             case Enum.at(group_cp_positions, n - 1) do
               {s, e} -> {:tuple, [s, e]}
               nil -> {:exception, "IndexError: no such group #{n}"}
             end
         end},
      "groups" =>
        {:builtin,
         fn
           [] -> {:tuple, groups}
         end},
      "lastgroup" => last_group
    }
  end
end
