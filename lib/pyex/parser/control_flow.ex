defmodule Pyex.Parser.ControlFlow do
  @moduledoc """
  Control-flow statement parsing helpers for `Pyex.Parser`.

  Keeps statement-specific parsing for `if`, `while`, `for`, and `try`
  outside the main parser module while preserving the existing parser API.
  """

  alias Pyex.{Lexer, Parser}

  @typep parse_result :: {:ok, Parser.ast_node(), [Lexer.token()]} | {:error, String.t()}
  @typep branch_clause :: {Parser.ast_node(), [Parser.ast_node()]} | {:else, [Parser.ast_node()]}
  @typep except_clause :: {String.t() | [String.t()] | nil, String.t() | nil, [Parser.ast_node()]}

  @doc """
  Parses an `if` statement.
  """
  @spec parse_if([Lexer.token()]) :: parse_result()
  def parse_if(tokens) do
    with {:ok, condition, rest} <- Parser.parse_expression(tokens) do
      case rest do
        [{:op, _, :colon}, :newline, :indent | block_rest] ->
          with {:ok, body, rest} <- Parser.parse_block(block_rest),
               {:ok, else_clauses, rest} <- parse_elif_else(rest) do
            line = Parser.node_line(condition)
            {:ok, {:if, [line: line], [{condition, body} | else_clauses]}, drop_newline(rest)}
          end

        [{:op, _, :colon} | inline_rest] ->
          with {:ok, stmt, rest} <- Parser.parse_inline_body(inline_rest),
               {:ok, else_clauses, rest} <- parse_elif_else(rest) do
            line = Parser.node_line(condition)
            {:ok, {:if, [line: line], [{condition, [stmt]} | else_clauses]}, drop_newline(rest)}
          end

        _ ->
          {:error, "expected ':' after if at #{token_line(rest)}"}
      end
    end
  end

  @doc """
  Parses a `while` loop.
  """
  @spec parse_while([Lexer.token()]) :: parse_result()
  def parse_while(tokens) do
    with {:ok, condition, rest} <- Parser.parse_expression(tokens),
         {:ok, body, rest} <- parse_loop_body(rest, "while"),
         {:ok, else_body, rest} <- parse_loop_else(rest) do
      line = Parser.node_line(condition)
      {:ok, {:while, [line: line], [condition, body, else_body]}, drop_newline(rest)}
    end
  end

  @doc """
  Parses a `for` loop.
  """
  @spec parse_for([Lexer.token()]) :: parse_result()
  def parse_for([{:name, line, first_name}, {:op, _, :comma} | rest]) do
    with {:ok, var_names, rest} <- collect_for_vars(rest, [first_name]),
         {:ok, iterable, rest} <- Parser.parse_expression(rest),
         {:ok, body, rest} <- parse_loop_body(rest, "for"),
         {:ok, else_body, rest} <- parse_loop_else(rest) do
      {:ok, {:for, [line: line], [var_names, iterable, body, else_body]}, drop_newline(rest)}
    end
  end

  def parse_for([{:name, line, var_name}, {:keyword, _, "in"} | rest]) do
    with {:ok, iterable, rest} <- Parser.parse_expression(rest),
         {:ok, body, rest} <- parse_loop_body(rest, "for"),
         {:ok, else_body, rest} <- parse_loop_else(rest) do
      {:ok, {:for, [line: line], [var_name, iterable, body, else_body]}, drop_newline(rest)}
    end
  end

  def parse_for(tokens) do
    {:error, "expected variable name after 'for' at #{token_line(tokens)}"}
  end

  @doc """
  Parses a `try` statement.
  """
  @spec parse_try([Lexer.token()]) :: parse_result()
  def parse_try(tokens) do
    with {:ok, rest} <- expect_block_start(tokens, "try"),
         {:ok, body, rest} <- Parser.parse_block(rest),
         {:ok, handlers, rest} <- parse_except_clauses(rest),
         {:ok, else_body, rest} <- parse_try_else(rest),
         {:ok, finally_body, rest} <- parse_try_finally(rest) do
      line =
        case body do
          [{_, [line: body_line], _} | _] -> body_line
          _ -> 1
        end

      {:ok, {:try, [line: line], [body, handlers, else_body, finally_body]}, drop_newline(rest)}
    end
  end

  @spec parse_elif_else([Lexer.token()]) ::
          {:ok, [branch_clause()], [Lexer.token()]} | {:error, String.t()}
  defp parse_elif_else([{:keyword, _, "elif"} | rest]) do
    with {:ok, condition, rest} <- Parser.parse_expression(rest) do
      case rest do
        [{:op, _, :colon}, :newline, :indent | block_rest] ->
          with {:ok, body, rest} <- Parser.parse_block(block_rest),
               {:ok, more, rest} <- parse_elif_else(rest) do
            {:ok, [{condition, body} | more], rest}
          end

        [{:op, _, :colon} | inline_rest] ->
          with {:ok, stmt, rest} <- Parser.parse_inline_body(inline_rest),
               {:ok, more, rest} <- parse_elif_else(rest) do
            {:ok, [{condition, [stmt]} | more], rest}
          end

        _ ->
          {:error, "expected ':' after elif at #{token_line(rest)}"}
      end
    end
  end

  defp parse_elif_else([{:keyword, _, "else"}, {:op, _, :colon}, :newline, :indent | rest]) do
    case Parser.parse_block(rest) do
      {:ok, body, rest} -> {:ok, [{:else, body}], rest}
      {:error, _} = error -> error
    end
  end

  defp parse_elif_else([{:keyword, _, "else"}, {:op, _, :colon} | rest]) do
    case Parser.parse_inline_body(rest) do
      {:ok, stmt, rest} -> {:ok, [{:else, [stmt]}], rest}
      {:error, _} = error -> error
    end
  end

  defp parse_elif_else(rest), do: {:ok, [], rest}

  @spec parse_loop_else([Lexer.token()]) ::
          {:ok, [Parser.ast_node()] | nil, [Lexer.token()]} | {:error, String.t()}
  defp parse_loop_else([{:keyword, _, "else"}, {:op, _, :colon}, :newline, :indent | rest]) do
    case Parser.parse_block(rest) do
      {:ok, else_body, rest} -> {:ok, else_body, rest}
      {:error, _} = error -> error
    end
  end

  defp parse_loop_else([{:keyword, _, "else"}, {:op, _, :colon} | rest]) do
    case Parser.parse_inline_body(rest) do
      {:ok, stmt, rest} -> {:ok, [stmt], rest}
      {:error, _} = error -> error
    end
  end

  defp parse_loop_else(rest), do: {:ok, nil, rest}

  @spec parse_loop_body([Lexer.token()], String.t()) ::
          {:ok, [Parser.ast_node()], [Lexer.token()]} | {:error, String.t()}
  defp parse_loop_body([{:op, _, :colon}, :newline, :indent | rest], _context) do
    Parser.parse_block(rest)
  end

  defp parse_loop_body([{:op, _, :colon} | rest], _context) do
    case Parser.parse_inline_body(rest) do
      {:ok, stmt, rest} -> {:ok, [stmt], rest}
      {:error, _} = error -> error
    end
  end

  defp parse_loop_body(tokens, context) do
    {:error, "expected ':' after #{context} at #{token_line(tokens)}"}
  end

  @spec collect_for_vars([Lexer.token()], [String.t()]) ::
          {:ok, [String.t()], [Lexer.token()]} | {:error, String.t()}
  defp collect_for_vars([{:name, _, name}, {:keyword, _, "in"} | rest], acc) do
    {:ok, Enum.reverse([name | acc]), rest}
  end

  defp collect_for_vars([{:name, _, name}, {:op, _, :comma} | rest], acc) do
    collect_for_vars(rest, [name | acc])
  end

  defp collect_for_vars(tokens, _acc) do
    {:error, "expected variable name in for loop at #{token_line(tokens)}"}
  end

  @spec parse_try_else([Lexer.token()]) ::
          {:ok, [Parser.ast_node()] | nil, [Lexer.token()]} | {:error, String.t()}
  defp parse_try_else([{:keyword, _, "else"}, {:op, _, :colon}, :newline, :indent | rest]) do
    case Parser.parse_block(rest) do
      {:ok, else_body, rest} -> {:ok, else_body, rest}
      {:error, _} = error -> error
    end
  end

  defp parse_try_else(rest), do: {:ok, nil, rest}

  @spec parse_try_finally([Lexer.token()]) ::
          {:ok, [Parser.ast_node()] | nil, [Lexer.token()]} | {:error, String.t()}
  defp parse_try_finally([{:keyword, _, "finally"}, {:op, _, :colon}, :newline, :indent | rest]) do
    case Parser.parse_block(rest) do
      {:ok, finally_body, rest} -> {:ok, finally_body, rest}
      {:error, _} = error -> error
    end
  end

  defp parse_try_finally(rest), do: {:ok, nil, rest}

  @spec parse_except_clauses([Lexer.token()], [except_clause()]) ::
          {:ok, [except_clause()], [Lexer.token()]} | {:error, String.t()}
  defp parse_except_clauses(tokens, acc \\ [])

  defp parse_except_clauses([{:keyword, _, "except"} | rest], acc) do
    case rest do
      [{:op, _, :colon}, :newline, :indent | rest] ->
        case Parser.parse_block(rest) do
          {:ok, handler_body, rest} ->
            parse_except_clauses(rest, [{nil, nil, handler_body} | acc])

          {:error, _} = error ->
            error
        end

      [{:op, _, :lparen} | paren_rest] ->
        case collect_except_names(paren_rest, []) do
          {:ok, names, [{:keyword, _, "as"}, {:name, _, var_name} | after_as]} ->
            with {:ok, after_as} <- expect_block_start(after_as, "except"),
                 {:ok, handler_body, after_as} <- Parser.parse_block(after_as) do
              parse_except_clauses(after_as, [{names, var_name, handler_body} | acc])
            end

          {:ok, names, after_paren} ->
            with {:ok, after_paren} <- expect_block_start(after_paren, "except"),
                 {:ok, handler_body, after_paren} <- Parser.parse_block(after_paren) do
              parse_except_clauses(after_paren, [{names, nil, handler_body} | acc])
            end

          {:error, _} = error ->
            error
        end

      [{:name, _, _} | _] ->
        {exc_name, rest} = collect_dotted_name(rest)

        case rest do
          [{:keyword, _, "as"}, {:name, _, var_name} | rest] ->
            with {:ok, rest} <- expect_block_start(rest, "except"),
                 {:ok, handler_body, rest} <- Parser.parse_block(rest) do
              parse_except_clauses(rest, [{exc_name, var_name, handler_body} | acc])
            end

          _ ->
            with {:ok, rest} <- expect_block_start(rest, "except"),
                 {:ok, handler_body, rest} <- Parser.parse_block(rest) do
              parse_except_clauses(rest, [{exc_name, nil, handler_body} | acc])
            end
        end

      _ ->
        {:error, "expected ':' or exception name after 'except' at #{token_line(rest)}"}
    end
  end

  defp parse_except_clauses(rest, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  @spec collect_dotted_name([Lexer.token()]) :: {String.t(), [Lexer.token()]}
  defp collect_dotted_name([{:name, _, name}, {:op, _, :dot} | rest]) do
    {suffix, rest} = collect_dotted_name(rest)
    {name <> "." <> suffix, rest}
  end

  defp collect_dotted_name([{:name, _, name} | rest]) do
    {name, rest}
  end

  @spec collect_except_names([Lexer.token()], [String.t()]) ::
          {:ok, [String.t()], [Lexer.token()]} | {:error, String.t()}
  defp collect_except_names([{:name, _, _} | _] = tokens, acc) do
    {name, rest} = collect_dotted_name(tokens)

    case rest do
      [{:op, _, :rparen} | rest] ->
        {:ok, Enum.reverse([name | acc]), rest}

      [{:op, _, :comma} | rest] ->
        collect_except_names(rest, [name | acc])

      _ ->
        {:error, "expected ')' or ',' in except tuple at #{token_line(rest)}"}
    end
  end

  defp collect_except_names(tokens, _acc) do
    {:error, "expected exception name in except tuple at #{token_line(tokens)}"}
  end

  @spec expect_block_start([Lexer.token()], String.t()) ::
          {:ok, [Lexer.token()]} | {:error, String.t()}
  defp expect_block_start([{:op, _, :colon}, :newline, :indent | rest], _context) do
    {:ok, rest}
  end

  defp expect_block_start(tokens, context) do
    {:error, "expected ':' after #{context} at #{token_line(tokens)}"}
  end

  @spec drop_newline([Lexer.token()]) :: [Lexer.token()]
  defp drop_newline([:newline | rest]), do: rest
  defp drop_newline(rest), do: rest

  @spec token_line([Lexer.token()]) :: String.t()
  defp token_line([{_, line, _} | _]), do: "line #{line}"
  defp token_line(_), do: "end of input"
end
