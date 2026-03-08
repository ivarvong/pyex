defmodule Pyex.Parser.Match do
  @moduledoc """
  Structural pattern matching parsing helpers for `Pyex.Parser`.

  Keeps `match`/`case` parsing and pattern grammar isolated from the main
  parser while preserving the existing parser entrypoints.
  """

  alias Pyex.{Lexer, Parser}

  @typep match_pattern ::
           {:match_wildcard, Parser.meta(), []}
           | {:match_capture, Parser.meta(), [String.t()]}
           | {:match_or, Parser.meta(), [match_pattern()]}
           | {:match_sequence, Parser.meta(), [match_pattern()]}
           | {:match_mapping, Parser.meta(), [{Parser.ast_node(), match_pattern()}]}
           | {:match_class, Parser.meta(), [term()]}
           | {:match_star, Parser.meta(), [String.t() | nil]}
           | Parser.ast_node()

  @typep match_case :: {match_pattern(), Parser.ast_node() | nil, [Parser.ast_node()]}

  @doc """
  Attempts to parse a `match` statement after the leading `match` name token.
  Returns `:not_match` if the token stream should be treated as a normal name.
  """
  @spec try_match([Lexer.token()], pos_integer()) ::
          {:ok, Parser.ast_node(), [Lexer.token()]} | :not_match
  def try_match(tokens, line) do
    with {:ok, subject, [{:op, _, :colon}, :newline, :indent | rest]} <-
           Parser.parse_expression(tokens),
         {:ok, cases, rest} <- parse_match_cases(rest) do
      {:ok, {:match, [line: line], [subject, cases]}, drop_newline(rest)}
    else
      _ -> :not_match
    end
  end

  @spec parse_match_cases([Lexer.token()], [match_case()]) ::
          {:ok, [match_case()], [Lexer.token()]} | {:error, String.t()}
  defp parse_match_cases(tokens, acc \\ [])

  defp parse_match_cases([{:name, _, "case"} | rest], acc) do
    with {:ok, pattern, rest} <- parse_match_pattern(rest),
         {:ok, guard, rest} <- parse_match_guard(rest),
         {:ok, rest} <- Parser.expect_block_start(rest, "case"),
         {:ok, body, rest} <- Parser.parse_block(rest) do
      parse_match_cases(rest, [{pattern, guard, body} | acc])
    end
  end

  defp parse_match_cases([:dedent | rest], acc), do: {:ok, Enum.reverse(acc), rest}
  defp parse_match_cases([:newline | rest], acc), do: parse_match_cases(rest, acc)
  defp parse_match_cases(rest, acc), do: {:ok, Enum.reverse(acc), rest}

  @spec parse_match_guard([Lexer.token()]) ::
          {:ok, Parser.ast_node() | nil, [Lexer.token()]} | {:error, String.t()}
  defp parse_match_guard([{:keyword, _, "if"} | rest]) do
    with {:ok, guard_expr, rest} <- Parser.parse_expression(rest) do
      {:ok, guard_expr, rest}
    end
  end

  defp parse_match_guard(tokens), do: {:ok, nil, tokens}

  @spec parse_match_pattern([Lexer.token()]) ::
          {:ok, match_pattern(), [Lexer.token()]} | {:error, String.t()}
  defp parse_match_pattern(tokens) do
    with {:ok, pattern, rest} <- parse_match_pattern_atom(tokens) do
      parse_match_or(pattern, rest)
    end
  end

  @spec parse_match_or(match_pattern(), [Lexer.token()]) ::
          {:ok, match_pattern(), [Lexer.token()]} | {:error, String.t()}
  defp parse_match_or(left, [{:op, _, :pipe} | rest]) do
    with {:ok, right, rest} <- parse_match_pattern_atom(rest) do
      alts =
        case left do
          {:match_or, _, existing} -> existing ++ [right]
          _ -> [left, right]
        end

      parse_match_or({:match_or, [line: Parser.node_line(left)], alts}, rest)
    end
  end

  defp parse_match_or(pattern, rest), do: {:ok, pattern, rest}

  @spec parse_match_pattern_atom([Lexer.token()]) ::
          {:ok, match_pattern(), [Lexer.token()]} | {:error, String.t()}
  defp parse_match_pattern_atom([{:name, line, "_"} | rest]),
    do: {:ok, {:match_wildcard, [line: line], []}, rest}

  defp parse_match_pattern_atom([{:keyword, line, "None"} | rest]),
    do: {:ok, {:lit, [line: line], [nil]}, rest}

  defp parse_match_pattern_atom([{:keyword, line, "True"} | rest]),
    do: {:ok, {:lit, [line: line], [true]}, rest}

  defp parse_match_pattern_atom([{:keyword, line, "False"} | rest]),
    do: {:ok, {:lit, [line: line], [false]}, rest}

  defp parse_match_pattern_atom([{:integer, line, value} | rest]),
    do: {:ok, {:lit, [line: line], [value]}, rest}

  defp parse_match_pattern_atom([{:float, line, value} | rest]),
    do: {:ok, {:lit, [line: line], [value]}, rest}

  defp parse_match_pattern_atom([{:op, line, :minus}, {:integer, _, value} | rest]),
    do: {:ok, {:lit, [line: line], [-value]}, rest}

  defp parse_match_pattern_atom([{:op, line, :minus}, {:float, _, value} | rest]),
    do: {:ok, {:lit, [line: line], [-value]}, rest}

  defp parse_match_pattern_atom([{:string, line, value} | rest]),
    do: {:ok, {:lit, [line: line], [value]}, rest}

  defp parse_match_pattern_atom([{:fstring, line, parts} | rest]),
    do: {:ok, {:fstring, [line: line], [parts]}, rest}

  defp parse_match_pattern_atom([{:op, _, :star}, {:name, line, "_"} | rest]),
    do: {:ok, {:match_star, [line: line], [nil]}, rest}

  defp parse_match_pattern_atom([{:op, _, :star}, {:name, line, name} | rest]),
    do: {:ok, {:match_star, [line: line], [name]}, rest}

  defp parse_match_pattern_atom([{:op, line, :lbracket} | rest]) do
    with {:ok, patterns, rest} <- parse_match_pattern_list(rest, []) do
      {:ok, {:match_sequence, [line: line], patterns}, rest}
    end
  end

  defp parse_match_pattern_atom([{:op, line, :lparen} | rest]) do
    with {:ok, patterns, rest} <- parse_match_pattern_tuple(rest, []) do
      {:ok, {:match_sequence, [line: line], patterns}, rest}
    end
  end

  defp parse_match_pattern_atom([{:op, line, :lbrace} | rest]) do
    with {:ok, pairs, rest} <- parse_match_mapping_entries(rest, []) do
      {:ok, {:match_mapping, [line: line], pairs}, rest}
    end
  end

  defp parse_match_pattern_atom([{:name, line, name}, {:op, _, :dot}, {:name, _, attr} | rest]) do
    {:ok, {:getattr, [line: line], [{:var, [line: line], [name]}, attr]}, rest}
  end

  defp parse_match_pattern_atom([{:name, line, name}, {:op, _, :lparen} | rest]) do
    with {:ok, pos_patterns, kw_patterns, rest} <- parse_match_class_args(rest, [], []) do
      {:ok, {:match_class, [line: line], [name, pos_patterns, kw_patterns]}, rest}
    end
  end

  defp parse_match_pattern_atom([{:name, line, name} | rest]) do
    {:ok, {:match_capture, [line: line], [name]}, rest}
  end

  defp parse_match_pattern_atom(tokens),
    do: {:error, "unexpected token in match pattern at #{token_line(tokens)}"}

  @spec parse_match_pattern_list([Lexer.token()], [match_pattern()]) ::
          {:ok, [match_pattern()], [Lexer.token()]} | {:error, String.t()}
  defp parse_match_pattern_list([{:op, _, :rbracket} | rest], acc),
    do: {:ok, Enum.reverse(acc), rest}

  defp parse_match_pattern_list(tokens, acc) do
    with {:ok, pattern, rest} <- parse_match_pattern(tokens) do
      case rest do
        [{:op, _, :comma} | rest] -> parse_match_pattern_list(rest, [pattern | acc])
        [{:op, _, :rbracket} | rest] -> {:ok, Enum.reverse([pattern | acc]), rest}
        _ -> {:error, "expected ',' or ']' in match pattern list at #{token_line(rest)}"}
      end
    end
  end

  @spec parse_match_pattern_tuple([Lexer.token()], [match_pattern()]) ::
          {:ok, [match_pattern()], [Lexer.token()]} | {:error, String.t()}
  defp parse_match_pattern_tuple([{:op, _, :rparen} | rest], acc),
    do: {:ok, Enum.reverse(acc), rest}

  defp parse_match_pattern_tuple(tokens, acc) do
    with {:ok, pattern, rest} <- parse_match_pattern(tokens) do
      case rest do
        [{:op, _, :comma} | rest] -> parse_match_pattern_tuple(rest, [pattern | acc])
        [{:op, _, :rparen} | rest] -> {:ok, Enum.reverse([pattern | acc]), rest}
        _ -> {:error, "expected ',' or ')' in match pattern tuple at #{token_line(rest)}"}
      end
    end
  end

  @spec parse_match_mapping_entries([Lexer.token()], [{Parser.ast_node(), match_pattern()}]) ::
          {:ok, [{Parser.ast_node(), match_pattern()}], [Lexer.token()]} | {:error, String.t()}
  defp parse_match_mapping_entries([{:op, _, :rbrace} | rest], acc),
    do: {:ok, Enum.reverse(acc), rest}

  defp parse_match_mapping_entries(tokens, acc) do
    with {:ok, key, [{:op, _, :colon} | rest]} <- parse_match_mapping_key(tokens),
         {:ok, value_pattern, rest} <- parse_match_pattern(rest) do
      case rest do
        [{:op, _, :comma} | rest] ->
          parse_match_mapping_entries(rest, [{key, value_pattern} | acc])

        [{:op, _, :rbrace} | rest] ->
          {:ok, Enum.reverse([{key, value_pattern} | acc]), rest}

        _ ->
          {:error, "expected ',' or '}' in match mapping at #{token_line(rest)}"}
      end
    else
      {:ok, _, rest} -> {:error, "expected ':' in match mapping at #{token_line(rest)}"}
      {:error, _} = error -> error
    end
  end

  @spec parse_match_mapping_key([Lexer.token()]) ::
          {:ok, Parser.ast_node(), [Lexer.token()]} | {:error, String.t()}
  defp parse_match_mapping_key([{:string, line, value} | rest]),
    do: {:ok, {:lit, [line: line], [value]}, rest}

  defp parse_match_mapping_key([{:integer, line, value} | rest]),
    do: {:ok, {:lit, [line: line], [value]}, rest}

  defp parse_match_mapping_key([{:float, line, value} | rest]),
    do: {:ok, {:lit, [line: line], [value]}, rest}

  defp parse_match_mapping_key([{:keyword, line, "None"} | rest]),
    do: {:ok, {:lit, [line: line], [nil]}, rest}

  defp parse_match_mapping_key([{:keyword, line, "True"} | rest]),
    do: {:ok, {:lit, [line: line], [true]}, rest}

  defp parse_match_mapping_key([{:keyword, line, "False"} | rest]),
    do: {:ok, {:lit, [line: line], [false]}, rest}

  defp parse_match_mapping_key(tokens),
    do: {:error, "expected literal key in match mapping at #{token_line(tokens)}"}

  @spec parse_match_class_args([Lexer.token()], [match_pattern()], [{String.t(), match_pattern()}]) ::
          {:ok, [match_pattern()], [{String.t(), match_pattern()}], [Lexer.token()]}
          | {:error, String.t()}
  defp parse_match_class_args([{:op, _, :rparen} | rest], pos_acc, kw_acc) do
    {:ok, Enum.reverse(pos_acc), Enum.reverse(kw_acc), rest}
  end

  defp parse_match_class_args([{:name, _, name}, {:op, _, :assign} | rest], pos_acc, kw_acc) do
    with {:ok, pattern, rest} <- parse_match_pattern(rest) do
      case rest do
        [{:op, _, :comma} | rest] ->
          parse_match_class_args(rest, pos_acc, [{name, pattern} | kw_acc])

        [{:op, _, :rparen} | rest] ->
          {:ok, Enum.reverse(pos_acc), Enum.reverse([{name, pattern} | kw_acc]), rest}

        _ ->
          {:error, "expected ',' or ')' in match class pattern at #{token_line(rest)}"}
      end
    end
  end

  defp parse_match_class_args(tokens, pos_acc, kw_acc) do
    with {:ok, pattern, rest} <- parse_match_pattern(tokens) do
      case rest do
        [{:op, _, :comma} | rest] ->
          parse_match_class_args(rest, [pattern | pos_acc], kw_acc)

        [{:op, _, :rparen} | rest] ->
          {:ok, Enum.reverse([pattern | pos_acc]), Enum.reverse(kw_acc), rest}

        _ ->
          {:error, "expected ',' or ')' in match class pattern at #{token_line(rest)}"}
      end
    end
  end

  @spec drop_newline([Lexer.token()]) :: [Lexer.token()]
  defp drop_newline([:newline | rest]), do: rest
  defp drop_newline(rest), do: rest

  @spec token_line([Lexer.token()]) :: String.t()
  defp token_line([{_, line, _} | _]), do: "line #{line}"
  defp token_line(_), do: "end of input"
end
