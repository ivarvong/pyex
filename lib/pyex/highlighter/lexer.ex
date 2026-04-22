defmodule Pyex.Highlighter.Lexer do
  @moduledoc """
  State-machine regex lexer engine.

  A lexer is described by a `rules/0` callback returning a map of
  state names (atoms) to lists of rules. Each rule is a tuple:

      {pattern, token_spec, action}

  where `pattern` is a `Regex.t()` or literal `String.t()` prefix to
  match at the current position, `token_spec` describes how to emit
  the matched text, and `action` updates the state stack.

  ## Token specs

    * `atom` — emit the full match tagged with this token type
    * `{:bygroups, [atom | nil | {:using, mod}, ...]}` — split the
      match across capture groups, one spec per group (`nil` drops the
      capture entirely; `{:using, mod}` tokenizes the capture with
      another lexer and inlines the result)
    * `{:using, mod}` — tokenize the whole match with another lexer

  ## Actions

    * `:none` — stay in the current state
    * `{:push, state}` — push `state` onto the stack
    * `:pop` — pop the current state off the stack
    * `{:pop, n}` — pop `n` states
    * `{:goto, state}` — replace the current state with `state`
    * `:push_same` — push the current state again (useful for recursion)
  """

  alias Pyex.Highlighter.Token

  @type state_name :: atom()
  @type action ::
          :none
          | {:push, state_name()}
          | :pop
          | {:pop, pos_integer()}
          | {:goto, state_name()}
          | :push_same
  @type group_spec :: Token.t() | nil | {:using, module()}
  @type token_spec ::
          Token.t()
          | {:using, module()}
          | {:bygroups, [group_spec()]}
  @type rule :: {Regex.t() | String.t(), token_spec(), action()}
  @type state_rules :: [rule()]
  @type rules :: %{state_name() => state_rules()}

  @callback rules() :: rules()
  @callback start_state() :: state_name()

  @optional_callbacks start_state: 0

  @doc """
  Tokenizes `source` using the given lexer module.

  Returns a list of `{token_type, text}` tuples covering every
  character of the input. Unmatched bytes become `:error` tokens so
  the output round-trips losslessly.
  """
  @spec tokenize(module(), String.t()) :: [{Token.t(), String.t()}]
  def tokenize(lexer_module, source) when is_binary(source) do
    rules = lexer_module.rules()
    start = start_state(lexer_module)

    {acc, _state} =
      tokenize_loop(source, 0, byte_size(source), rules, [start], [])

    acc
    |> Enum.reverse()
    |> merge_adjacent()
  end

  defp start_state(lexer_module) do
    if function_exported?(lexer_module, :start_state, 0) do
      lexer_module.start_state()
    else
      :root
    end
  end

  defp tokenize_loop(_src, pos, size, _rules, stack, acc) when pos >= size do
    {acc, stack}
  end

  defp tokenize_loop(src, pos, size, rules, stack, acc) do
    state = hd(stack)
    state_rules = Map.fetch!(rules, state)

    case try_rules(state_rules, src, pos) do
      {:match, match_len, token_spec, captures, action} ->
        matched = binary_part(src, pos, match_len)
        acc = emit(token_spec, matched, captures, acc)
        stack = apply_action(action, stack)
        new_pos = pos + max(match_len, 1)
        tokenize_loop(src, new_pos, size, rules, stack, acc)

      :no_match ->
        # Emit one UNICODE codepoint as :error (not one byte!) so we
        # don't split mid-character. Important for inputs containing
        # non-ASCII text — PCRE refuses to run at mid-codepoint offsets.
        {char, advance} = next_char(src, pos, size)
        tokenize_loop(src, pos + advance, size, rules, stack, [{:error, char} | acc])
    end
  end

  # Returns {one-character binary, byte advance}. Handles UTF-8 char
  # widths 1–4 plus invalid bytes (advance by 1).
  defp next_char(src, pos, size) do
    first = :binary.at(src, pos)

    width =
      cond do
        first < 0x80 -> 1
        first < 0xC0 -> 1
        first < 0xE0 -> 2
        first < 0xF0 -> 3
        first < 0xF8 -> 4
        true -> 1
      end

    bytes = min(width, size - pos)
    {binary_part(src, pos, bytes), bytes}
  end

  defp try_rules([], _src, _pos), do: :no_match

  defp try_rules([{pattern, token_spec, action} | rest], src, pos) do
    case match_at(pattern, src, pos) do
      {:ok, length, captures} ->
        {:match, length, token_spec, captures, action}

      :no ->
        try_rules(rest, src, pos)
    end
  end

  defp match_at(pattern, src, pos) when is_binary(pattern) do
    psize = byte_size(pattern)
    remaining = byte_size(src) - pos

    if psize <= remaining and binary_part(src, pos, psize) == pattern do
      {:ok, psize, []}
    else
      :no
    end
  end

  defp match_at(%Regex{} = regex, src, pos) do
    # Anchor at `pos` — we want the rule's pattern to match exactly at
    # the current position, not scan forward. Regex.run does not expose
    # the :anchored flag, so drop down to :re.run.
    compiled = regex.re_pattern

    try do
      case :re.run(src, compiled, [
             {:offset, pos},
             :anchored,
             {:capture, :all, :index}
           ]) do
        {:match, [{^pos, length} | capture_indices]} ->
          captures =
            Enum.map(capture_indices, fn
              {start, len} when len >= 0 -> binary_part(src, start, len)
              _ -> ""
            end)

          {:ok, length, captures}

        _ ->
          :no
      end
    rescue
      # :re.run raises ArgumentError if the source isn't valid UTF-8
      # at the offset (lone continuation bytes, overlong encodings, etc.)
      # Treat as a non-match so the catch-all emits the byte as :error
      # and tokenization continues.
      ArgumentError -> :no
    end
  end

  # ----- emit -------------------------------------------------------

  defp emit({:bygroups, specs}, _matched, captures, acc) do
    specs
    |> Enum.zip(pad_captures(captures, length(specs)))
    |> Enum.reduce(acc, fn
      {nil, _}, acc -> acc
      {_, ""}, acc -> acc
      {{:using, mod}, text}, acc -> prepend_sub_tokens(mod, text, acc)
      {type, text}, acc when is_atom(type) -> [{type, text} | acc]
    end)
  end

  defp emit({:using, mod}, matched, _captures, acc) do
    prepend_sub_tokens(mod, matched, acc)
  end

  defp emit(type, matched, _captures, acc) when is_atom(type) do
    [{type, matched} | acc]
  end

  defp prepend_sub_tokens(mod, text, acc) do
    sub = tokenize(mod, text)
    Enum.reduce(sub, acc, fn tok, a -> [tok | a] end)
  end

  defp pad_captures(captures, n) do
    captures ++ List.duplicate("", max(0, n - length(captures)))
  end

  # ----- state actions ---------------------------------------------

  defp apply_action(:none, stack), do: stack
  defp apply_action({:push, state}, stack), do: [state | stack]
  defp apply_action(:pop, [_top, next | rest]), do: [next | rest]
  defp apply_action(:pop, [only]), do: [only]

  defp apply_action({:pop, n}, stack) do
    popped = Enum.drop(stack, n)

    case popped do
      [] -> [List.last(stack)]
      rest -> rest
    end
  end

  defp apply_action({:goto, state}, [_ | rest]), do: [state | rest]
  defp apply_action(:push_same, [top | _] = stack), do: [top | stack]

  # ----- post-processing -------------------------------------------

  # Merge runs of same-type tokens so downstream HTML emits one <span>
  # per run instead of many. Purely a size/readability optimization.
  defp merge_adjacent([]), do: []
  defp merge_adjacent([single]), do: [single]

  defp merge_adjacent([{type, a}, {type, b} | rest]) do
    merge_adjacent([{type, a <> b} | rest])
  end

  defp merge_adjacent([head | rest]), do: [head | merge_adjacent(rest)]
end
