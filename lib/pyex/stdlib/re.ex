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
      "sub" => {:builtin_kw, &do_sub/2},
      "split" => {:builtin_kw, &do_split/2},
      "compile" => {:builtin, &do_compile/1},
      "escape" => {:builtin, &do_escape/1},
      "fullmatch" => {:builtin, &do_fullmatch/1},
      "IGNORECASE" => 2,
      "I" => 2,
      "DOTALL" => 4,
      "S" => 4,
      "MULTILINE" => 8,
      "M" => 8
    }
  end

  @spec do_match([Pyex.Interpreter.pyvalue()]) ::
          Pyex.Interpreter.pyvalue() | {:exception, String.t()}
  defp do_match([pattern, string]) when is_binary(pattern) and is_binary(string),
    do: do_match_with_flags(pattern, string, 0)

  defp do_match([pattern, string, flags])
       when is_binary(pattern) and is_binary(string) and is_integer(flags),
       do: do_match_with_flags(pattern, string, flags)

  @spec do_match_with_flags(String.t(), String.t(), integer()) ::
          Pyex.Interpreter.pyvalue() | {:exception, String.t()}
  defp do_match_with_flags(pattern, string, flags) do
    opts = flags_to_regex_opts(flags)
    anchored = "\\A" <> pattern

    case Regex.compile(anchored, opts) do
      {:ok, re} ->
        case safe_regex(fn -> Regex.run(re, string, return: :index) end) do
          {:ok, nil} -> nil
          {:ok, indices} -> make_match_object(re, string, indices)
          {:exception, _} = err -> err
        end

      {:error, {msg, _}} ->
        {:exception, "re.error: #{msg}"}
    end
  end

  @spec do_search([Pyex.Interpreter.pyvalue()]) ::
          Pyex.Interpreter.pyvalue() | {:exception, String.t()}
  defp do_search([pattern, string]) when is_binary(pattern) and is_binary(string),
    do: do_search_with_flags(pattern, string, 0)

  defp do_search([pattern, string, flags])
       when is_binary(pattern) and is_binary(string) and is_integer(flags),
       do: do_search_with_flags(pattern, string, flags)

  @spec do_search_with_flags(String.t(), String.t(), integer()) ::
          Pyex.Interpreter.pyvalue() | {:exception, String.t()}
  defp do_search_with_flags(pattern, string, flags) do
    opts = flags_to_regex_opts(flags)

    case Regex.compile(pattern, opts) do
      {:ok, re} ->
        case safe_regex(fn -> Regex.run(re, string, return: :index) end) do
          {:ok, nil} -> nil
          {:ok, indices} -> make_match_object(re, string, indices)
          {:exception, _} = err -> err
        end

      {:error, {msg, _}} ->
        {:exception, "re.error: #{msg}"}
    end
  end

  @spec do_fullmatch([Pyex.Interpreter.pyvalue()]) ::
          Pyex.Interpreter.pyvalue() | {:exception, String.t()}
  defp do_fullmatch([pattern, string]) when is_binary(pattern) and is_binary(string),
    do: do_fullmatch_with_flags(pattern, string, 0)

  defp do_fullmatch([pattern, string, flags])
       when is_binary(pattern) and is_binary(string) and is_integer(flags),
       do: do_fullmatch_with_flags(pattern, string, flags)

  defp do_fullmatch_with_flags(pattern, string, flags) do
    opts = flags_to_regex_opts(flags)
    wrapped = "\\A(?:" <> pattern <> ")\\z"

    case Regex.compile(wrapped, opts) do
      {:ok, re} ->
        case safe_regex(fn -> Regex.run(re, string, return: :index) end) do
          {:ok, nil} -> nil
          {:ok, indices} -> make_match_object(re, string, indices)
          {:exception, _} = err -> err
        end

      {:error, {msg, _}} ->
        {:exception, "re.error: #{msg}"}
    end
  end

  @spec do_escape([Pyex.Interpreter.pyvalue()]) :: String.t() | {:exception, String.t()}
  defp do_escape([s]) when is_binary(s), do: Regex.escape(s)
  defp do_escape(_), do: {:exception, "TypeError: re.escape() expects a string"}

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

  @spec do_sub([Pyex.Interpreter.pyvalue()], map()) :: String.t() | {:exception, String.t()}
  defp do_sub([pattern, replacement, string], kwargs)
       when is_binary(pattern) and is_binary(replacement) and is_binary(string) do
    count = Map.get(kwargs, "count", 0)
    flags = Map.get(kwargs, "flags", 0)
    do_sub_impl(pattern, replacement, string, count, flags)
  end

  defp do_sub([pattern, replacement, string, count], kwargs)
       when is_binary(pattern) and is_binary(replacement) and is_binary(string) and
              is_integer(count) do
    flags = Map.get(kwargs, "flags", 0)
    do_sub_impl(pattern, replacement, string, count, flags)
  end

  defp do_sub([pattern, replacement, string, count, flags], _kwargs)
       when is_binary(pattern) and is_binary(replacement) and is_binary(string) and
              is_integer(count) and is_integer(flags) do
    do_sub_impl(pattern, replacement, string, count, flags)
  end

  defp do_sub(_args, _kwargs),
    do: {:exception, "TypeError: re.sub() expects (pattern, repl, string[, count, flags])"}

  @spec do_sub_impl(String.t(), String.t(), String.t(), integer(), integer()) ::
          String.t() | {:exception, String.t()}
  defp do_sub_impl(pattern, replacement, string, count, flags) do
    opts = flags_to_regex_opts(flags)

    case Regex.compile(pattern, opts) do
      {:ok, re} ->
        # Python uses \1..\9 and \g<N>/\g<name>; Elixir Regex.replace uses \0..\N
        # so we need to translate the replacement string.
        elixir_repl = translate_python_replacement(replacement)

        replace_opts =
          if count > 0, do: [global: false], else: []

        case safe_regex(fn ->
               if count > 0 and count > 1 do
                 apply_n_replacements(re, string, elixir_repl, count)
               else
                 Regex.replace(re, string, elixir_repl, replace_opts)
               end
             end) do
          {:ok, result} -> result
          {:exception, _} = err -> err
        end

      {:error, {msg, _}} ->
        {:exception, "re.error: #{msg}"}
    end
  end

  @spec apply_n_replacements(Regex.t(), String.t(), String.t(), non_neg_integer()) :: String.t()
  defp apply_n_replacements(_re, string, _repl, 0), do: string

  defp apply_n_replacements(re, string, repl, n) do
    # Replace the first occurrence, then recurse into the remaining string.
    case Regex.run(re, string, return: :index) do
      nil ->
        string

      [{start, len} | _] ->
        prefix = binary_part(string, 0, start)
        matched = binary_part(string, start, len)
        rest = binary_part(string, start + len, byte_size(string) - start - len)
        replaced = Regex.replace(re, matched, repl, global: false)
        prefix <> replaced <> apply_n_replacements(re, rest, repl, n - 1)
    end
  end

  @spec translate_python_replacement(String.t()) :: String.t()
  defp translate_python_replacement(repl) do
    # \g<0> -> \0, \g<N> -> \N, \g<name> -> \g{name}, \\N -> \N (already ok)
    # Elixir's Regex.replace already understands \0..\N; we only need to
    # handle \g<...> syntax.
    Regex.replace(~r/\\g<([^>]+)>/, repl, fn _, name ->
      case Integer.parse(name) do
        {n, ""} -> "\\#{n}"
        _ -> "\\g{#{name}}"
      end
    end)
  end

  @spec do_split([Pyex.Interpreter.pyvalue()], map()) :: [String.t()] | {:exception, String.t()}
  defp do_split([pattern, string], kwargs)
       when is_binary(pattern) and is_binary(string) do
    maxsplit = Map.get(kwargs, "maxsplit", 0)
    flags = Map.get(kwargs, "flags", 0)
    do_split_impl(pattern, string, maxsplit, flags)
  end

  defp do_split([pattern, string, maxsplit], kwargs)
       when is_binary(pattern) and is_binary(string) and is_integer(maxsplit) do
    flags = Map.get(kwargs, "flags", 0)
    do_split_impl(pattern, string, maxsplit, flags)
  end

  defp do_split([pattern, string, maxsplit, flags], _kwargs)
       when is_binary(pattern) and is_binary(string) and is_integer(maxsplit) and
              is_integer(flags) do
    do_split_impl(pattern, string, maxsplit, flags)
  end

  defp do_split(_args, _kwargs),
    do: {:exception, "TypeError: re.split() expects (pattern, string[, maxsplit, flags])"}

  @spec do_split_impl(String.t(), String.t(), integer(), integer()) ::
          [String.t()] | {:exception, String.t()}
  defp do_split_impl(pattern, string, maxsplit, flags) do
    opts = flags_to_regex_opts(flags)

    case Regex.compile(pattern, opts) do
      {:ok, re} ->
        split_opts = if maxsplit > 0, do: [parts: maxsplit + 1], else: []

        case safe_regex(fn -> Regex.split(re, string, split_opts) end) do
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
           [default] -> {:tuple, Enum.map(groups, fn g -> if is_nil(g), do: default, else: g end)}
         end},
      "groupdict" =>
        {:builtin,
         fn
           [] ->
             Pyex.PyDict.from_pairs(Enum.map(named_map, fn {k, v} -> {k, v} end))

           [default] ->
             pairs =
               Enum.map(named_map, fn {k, v} -> {k, if(is_nil(v), do: default, else: v)} end)

             Pyex.PyDict.from_pairs(pairs)
         end},
      "lastgroup" => last_group
    }
  end
end
