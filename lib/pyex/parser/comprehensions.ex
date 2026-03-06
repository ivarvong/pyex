defmodule Pyex.Parser.Comprehensions do
  @moduledoc """
  Comprehension and collection-literal parsing helpers for `Pyex.Parser`.

  Keeps generator expressions and collection literals that can lower into
  comprehensions together so the main parser can focus on statement and
  expression dispatch.
  """

  alias Pyex.{Lexer, Parser}

  @typep parse_result :: {:ok, Parser.ast_node(), [Lexer.token()]} | {:error, String.t()}
  @typep comp_clause ::
           {:comp_for, String.t() | [String.t()], Parser.ast_node()}
           | {:comp_if, Parser.ast_node()}

  @doc """
  Parses a parenthesized expression, tuple, or generator expression.
  """
  @spec parse_parenthesized([Lexer.token()], pos_integer()) :: parse_result()
  def parse_parenthesized([{:op, _, :rparen} | rest], line) do
    {:ok, {:tuple, [line: line], [[]]}, rest}
  end

  def parse_parenthesized(tokens, line) do
    with {:ok, expr, rest} <- Parser.parse_expression(tokens) do
      case rest do
        [{:keyword, _, "for"} | for_rest] ->
          parse_gen_expr(expr, for_rest, line)

        [{:op, _, :comma} | rest] ->
          parse_tuple_rest(rest, line, [expr])

        [{:op, _, :rparen} | rest] ->
          {:ok, expr, rest}

        _ ->
          {:error, "expected ')' at #{token_line(rest)}"}
      end
    end
  end

  @doc """
  Parses a list literal or list comprehension.
  """
  @spec parse_list_literal([Lexer.token()], pos_integer()) :: parse_result()
  def parse_list_literal([{:op, _, :rbracket} | rest], line) do
    {:ok, {:list, [line: line], [[]]}, rest}
  end

  def parse_list_literal(tokens, line) do
    with {:ok, expr, rest} <- Parser.parse_or(tokens) do
      case rest do
        [{:keyword, _, "for"} | for_rest] ->
          parse_list_comp(expr, for_rest, line)

        [{:keyword, _, "if"} | _] ->
          with {:ok, full_expr, rest} <- Parser.parse_expression(tokens) do
            case rest do
              [{:keyword, _, "for"} | for_rest] ->
                parse_list_comp(full_expr, for_rest, line)

              _ ->
                parse_list_elements_rest(rest, line, [full_expr])
            end
          end

        _ ->
          parse_list_elements_rest(rest, line, [expr])
      end
    end
  end

  @doc """
  Parses a dict literal, set literal, dict comprehension, or set comprehension.
  """
  @spec parse_dict_literal([Lexer.token()], pos_integer()) :: parse_result()
  def parse_dict_literal([{:op, _, :rbrace} | rest], line) do
    {:ok, {:dict, [line: line], [[]]}, rest}
  end

  def parse_dict_literal(tokens, line) do
    parse_dict_entries(tokens, line, [])
  end

  @doc """
  Parses a generator-expression body after the leading `for`.
  """
  @spec parse_gen_expr_body(Parser.ast_node(), [Lexer.token()], pos_integer()) :: parse_result()
  def parse_gen_expr_body(expr, [{:name, _, first_name}, {:op, _, :comma} | rest], line) do
    case collect_for_vars(rest, [first_name]) do
      {:ok, var_names, rest} ->
        with {:ok, iterable, rest} <- Parser.parse_or(rest),
             {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
          clauses = [{:comp_for, var_names, iterable} | clauses]
          {:ok, {:gen_expr, [line: line], [expr, clauses]}, rest}
        end

      {:error, _} = error ->
        error
    end
  end

  def parse_gen_expr_body(expr, [{:name, _, var_name}, {:keyword, _, "in"} | rest], line) do
    with {:ok, iterable, rest} <- Parser.parse_or(rest),
         {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
      clauses = [{:comp_for, var_name, iterable} | clauses]
      {:ok, {:gen_expr, [line: line], [expr, clauses]}, rest}
    end
  end

  def parse_gen_expr_body(_expr, tokens, _line) do
    {:error,
     "expected variable name after 'for' in generator expression at #{token_line(tokens)}"}
  end

  @spec parse_list_elements_rest([Lexer.token()], pos_integer(), [Parser.ast_node()]) ::
          parse_result()
  defp parse_list_elements_rest(rest, line, acc) do
    case rest do
      [{:op, _, :comma} | rest] -> parse_list_elements(rest, line, acc)
      [{:op, _, :rbracket} | rest] -> {:ok, {:list, [line: line], [Enum.reverse(acc)]}, rest}
      _ -> {:error, "expected ',' or ']' in list at #{token_line(rest)}"}
    end
  end

  @spec parse_list_elements([Lexer.token()], pos_integer(), [Parser.ast_node()]) :: parse_result()
  defp parse_list_elements([{:op, _, :rbracket} | rest], line, acc) do
    {:ok, {:list, [line: line], [Enum.reverse(acc)]}, rest}
  end

  defp parse_list_elements(tokens, line, acc) do
    with {:ok, expr, rest} <- Parser.parse_expression(tokens) do
      case rest do
        [{:op, _, :comma} | rest] ->
          parse_list_elements(rest, line, [expr | acc])

        [{:op, _, :rbracket} | rest] ->
          {:ok, {:list, [line: line], [Enum.reverse([expr | acc])]}, rest}

        _ ->
          {:error, "expected ',' or ']' in list at #{token_line(rest)}"}
      end
    end
  end

  @spec parse_list_comp(Parser.ast_node(), [Lexer.token()], pos_integer()) :: parse_result()
  defp parse_list_comp(expr, [{:name, _, first_name}, {:op, _, :comma} | rest], line) do
    case collect_for_vars(rest, [first_name]) do
      {:ok, var_names, rest} ->
        with {:ok, iterable, rest} <- Parser.parse_or(rest),
             {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
          clauses = [{:comp_for, var_names, iterable} | clauses]

          case rest do
            [{:op, _, :rbracket} | rest] ->
              {:ok, {:list_comp, [line: line], [expr, clauses]}, rest}

            _ ->
              {:error, "expected ']' after list comprehension at #{token_line(rest)}"}
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_list_comp(expr, [{:name, _, var_name}, {:keyword, _, "in"} | rest], line) do
    with {:ok, iterable, rest} <- Parser.parse_or(rest),
         {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
      clauses = [{:comp_for, var_name, iterable} | clauses]

      case rest do
        [{:op, _, :rbracket} | rest] -> {:ok, {:list_comp, [line: line], [expr, clauses]}, rest}
        _ -> {:error, "expected ']' after list comprehension at #{token_line(rest)}"}
      end
    end
  end

  defp parse_list_comp(_expr, tokens, _line) do
    {:error, "expected variable name after 'for' in list comprehension at #{token_line(tokens)}"}
  end

  @spec parse_gen_expr(Parser.ast_node(), [Lexer.token()], pos_integer()) :: parse_result()
  defp parse_gen_expr(expr, [{:name, _, first_name}, {:op, _, :comma} | rest], line) do
    case collect_for_vars(rest, [first_name]) do
      {:ok, var_names, rest} ->
        with {:ok, iterable, rest} <- Parser.parse_or(rest),
             {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
          clauses = [{:comp_for, var_names, iterable} | clauses]

          case rest do
            [{:op, _, :rparen} | rest] -> {:ok, {:gen_expr, [line: line], [expr, clauses]}, rest}
            _ -> {:error, "expected ')' after generator expression at #{token_line(rest)}"}
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_gen_expr(expr, [{:name, _, var_name}, {:keyword, _, "in"} | rest], line) do
    with {:ok, iterable, rest} <- Parser.parse_or(rest),
         {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
      clauses = [{:comp_for, var_name, iterable} | clauses]

      case rest do
        [{:op, _, :rparen} | rest] -> {:ok, {:gen_expr, [line: line], [expr, clauses]}, rest}
        _ -> {:error, "expected ')' after generator expression at #{token_line(rest)}"}
      end
    end
  end

  defp parse_gen_expr(_expr, tokens, _line) do
    {:error,
     "expected variable name after 'for' in generator expression at #{token_line(tokens)}"}
  end

  @spec parse_tuple_rest([Lexer.token()], pos_integer(), [Parser.ast_node()]) :: parse_result()
  defp parse_tuple_rest([{:op, _, :rparen} | rest], line, acc) do
    {:ok, {:tuple, [line: line], [Enum.reverse(acc)]}, rest}
  end

  defp parse_tuple_rest(tokens, line, acc) do
    with {:ok, expr, rest} <- Parser.parse_expression(tokens) do
      case rest do
        [{:op, _, :comma} | rest] ->
          parse_tuple_rest(rest, line, [expr | acc])

        [{:op, _, :rparen} | rest] ->
          {:ok, {:tuple, [line: line], [Enum.reverse([expr | acc])]}, rest}

        _ ->
          {:error, "expected ',' or ')' in tuple at #{token_line(rest)}"}
      end
    end
  end

  @spec parse_dict_entries([Lexer.token()], pos_integer(), [
          {Parser.ast_node(), Parser.ast_node()}
        ]) ::
          parse_result()
  defp parse_dict_entries(tokens, line, acc) do
    with {:ok, key, rest} <- Parser.parse_or(tokens) do
      case rest do
        [{:op, _, :colon} | rest] ->
          with {:ok, value, rest} <- Parser.parse_or(rest) do
            case rest do
              [{:keyword, _, "for"} | comp_rest] when acc == [] ->
                parse_dict_comp(key, value, comp_rest, line)

              _ ->
                pair = {key, value}

                case rest do
                  [{:op, _, :comma}, {:op, _, :rbrace} | rest] ->
                    {:ok, {:dict, [line: line], [Enum.reverse([pair | acc])]}, rest}

                  [{:op, _, :comma} | rest] ->
                    parse_dict_entries(rest, line, [pair | acc])

                  [{:op, _, :rbrace} | rest] ->
                    {:ok, {:dict, [line: line], [Enum.reverse([pair | acc])]}, rest}

                  _ ->
                    {:error, "expected ',' or '}' in dict at #{token_line(rest)}"}
                end
            end
          end

        [{:keyword, _, "for"} | comp_rest] when acc == [] ->
          parse_set_comp(key, comp_rest, line)

        [{:op, _, :comma} | set_rest] when acc == [] ->
          parse_set_entries(set_rest, line, [key])

        [{:op, _, :rbrace} | set_rest] when acc == [] ->
          {:ok, {:set, [line: line], [[key]]}, set_rest}

        _ ->
          {:error, "expected ':' in dict entry at #{token_line(rest)}"}
      end
    end
  end

  @spec parse_set_entries([Lexer.token()], pos_integer(), [Parser.ast_node()]) :: parse_result()
  defp parse_set_entries([{:op, _, :rbrace} | rest], line, acc) do
    {:ok, {:set, [line: line], [Enum.reverse(acc)]}, rest}
  end

  defp parse_set_entries(tokens, line, acc) do
    with {:ok, elem, rest} <- Parser.parse_or(tokens) do
      case rest do
        [{:op, _, :comma} | rest] ->
          parse_set_entries(rest, line, [elem | acc])

        [{:op, _, :rbrace} | rest] ->
          {:ok, {:set, [line: line], [Enum.reverse([elem | acc])]}, rest}

        _ ->
          {:error, "expected ',' or '}' in set literal at #{token_line(rest)}"}
      end
    end
  end

  @spec parse_set_comp(Parser.ast_node(), [Lexer.token()], pos_integer()) :: parse_result()
  defp parse_set_comp(expr, [{:name, _, first_name}, {:op, _, :comma} | rest], line) do
    case collect_for_vars(rest, [first_name]) do
      {:ok, var_names, rest} ->
        with {:ok, iterable, rest} <- Parser.parse_or(rest),
             {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
          clauses = [{:comp_for, var_names, iterable} | clauses]

          case rest do
            [{:op, _, :rbrace} | rest] -> {:ok, {:set_comp, [line: line], [expr, clauses]}, rest}
            _ -> {:error, "expected '}' after set comprehension at #{token_line(rest)}"}
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_set_comp(expr, [{:name, _, var_name}, {:keyword, _, "in"} | rest], line) do
    with {:ok, iterable, rest} <- Parser.parse_or(rest),
         {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
      clauses = [{:comp_for, var_name, iterable} | clauses]

      case rest do
        [{:op, _, :rbrace} | rest] -> {:ok, {:set_comp, [line: line], [expr, clauses]}, rest}
        _ -> {:error, "expected '}' after set comprehension at #{token_line(rest)}"}
      end
    end
  end

  defp parse_set_comp(_expr, tokens, _line) do
    {:error, "expected variable name in set comprehension at #{token_line(tokens)}"}
  end

  @spec parse_dict_comp(Parser.ast_node(), Parser.ast_node(), [Lexer.token()], pos_integer()) ::
          parse_result()
  defp parse_dict_comp(
         key_expr,
         val_expr,
         [{:name, _, first_name}, {:op, _, :comma} | rest],
         line
       ) do
    case collect_for_vars(rest, [first_name]) do
      {:ok, var_names, rest} ->
        with {:ok, iterable, rest} <- Parser.parse_or(rest),
             {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
          clauses = [{:comp_for, var_names, iterable} | clauses]

          case rest do
            [{:op, _, :rbrace} | rest] ->
              {:ok, {:dict_comp, [line: line], [key_expr, val_expr, clauses]}, rest}

            _ ->
              {:error, "expected '}' after dict comprehension at #{token_line(rest)}"}
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_dict_comp(
         key_expr,
         val_expr,
         [{:name, _, var_name}, {:keyword, _, "in"} | rest],
         line
       ) do
    with {:ok, iterable, rest} <- Parser.parse_or(rest),
         {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
      clauses = [{:comp_for, var_name, iterable} | clauses]

      case rest do
        [{:op, _, :rbrace} | rest] ->
          {:ok, {:dict_comp, [line: line], [key_expr, val_expr, clauses]}, rest}

        _ ->
          {:error, "expected '}' after dict comprehension at #{token_line(rest)}"}
      end
    end
  end

  defp parse_dict_comp(_key_expr, _val_expr, tokens, _line) do
    {:error, "expected variable name in dict comprehension at #{token_line(tokens)}"}
  end

  @spec parse_comp_clauses([Lexer.token()], [comp_clause()]) ::
          {:ok, [comp_clause()], [Lexer.token()]} | {:error, String.t()}
  defp parse_comp_clauses([{:keyword, _, "if"} | rest], acc) do
    with {:ok, filter, rest} <- Parser.parse_or(rest) do
      parse_comp_clauses(rest, [{:comp_if, filter} | acc])
    end
  end

  defp parse_comp_clauses([{:keyword, _, "for"} | rest], acc) do
    parse_comp_for_clause(rest, acc)
  end

  defp parse_comp_clauses(rest, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  @spec parse_comp_for_clause([Lexer.token()], [comp_clause()]) ::
          {:ok, [comp_clause()], [Lexer.token()]} | {:error, String.t()}
  defp parse_comp_for_clause([{:name, _, first_name}, {:op, _, :comma} | rest], acc) do
    case collect_for_vars(rest, [first_name]) do
      {:ok, var_names, rest} ->
        with {:ok, iterable, rest} <- Parser.parse_or(rest) do
          parse_comp_clauses(rest, [{:comp_for, var_names, iterable} | acc])
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_comp_for_clause([{:name, _, var_name}, {:keyword, _, "in"} | rest], acc) do
    with {:ok, iterable, rest} <- Parser.parse_or(rest) do
      parse_comp_clauses(rest, [{:comp_for, var_name, iterable} | acc])
    end
  end

  defp parse_comp_for_clause(tokens, _acc) do
    {:error, "expected variable name after 'for' in comprehension at #{token_line(tokens)}"}
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

  @spec token_line([Lexer.token()]) :: String.t()
  defp token_line([{_, line, _} | _]), do: "line #{line}"
  defp token_line(_), do: "end of input"
end
