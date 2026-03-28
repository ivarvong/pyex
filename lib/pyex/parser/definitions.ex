defmodule Pyex.Parser.Definitions do
  @moduledoc """
  Definition-style statement parsing helpers for `Pyex.Parser`.

  Keeps parsing for `def`, `class`, and `with` statements together so
  block-oriented statement parsing stays cohesive without changing the
  main parser entrypoints.
  """

  alias Pyex.{Lexer, Parser}

  @typep parse_result :: {:ok, Parser.ast_node(), [Lexer.token()]} | {:error, String.t()}
  @typep param :: Parser.param()
  @typep base_class :: String.t() | {:dotted, String.t(), String.t()}

  @doc """
  Parses a function definition.
  """
  @spec parse_function_def([Lexer.token()]) :: parse_result()
  def parse_function_def([{:name, line, name}, {:op, _, :lparen} | rest]) do
    case parse_params(rest) do
      {:ok, params, rest} ->
        rest = skip_return_annotation(rest)

        case rest do
          [{:op, _, :colon}, :newline, :indent | rest] ->
            case Parser.parse_block(rest) do
              {:ok, body, rest} ->
                {:ok, {:def, [line: line], [name, params, body]}, drop_newline(rest)}

              {:error, _} = error ->
                error
            end

          [{:op, _, :colon} | inline_rest] ->
            case Parser.parse_inline_body(inline_rest) do
              {:ok, stmt, rest} ->
                {:ok, {:def, [line: line], [name, params, [stmt]]}, drop_newline(rest)}

              {:error, _} = error ->
                error
            end

          _ ->
            {:error, "expected ':' after function definition on line #{line}"}
        end

      {:error, _} = error ->
        error
    end
  end

  def parse_function_def(tokens) do
    {:error, "expected function name at #{token_line(tokens)}"}
  end

  @doc """
  Parses a `with` statement.
  """
  @spec parse_with([Lexer.token()], pos_integer()) :: parse_result()
  def parse_with(rest, line) do
    with {:ok, targets, rest} <- parse_with_targets(rest, line) do
      case rest do
        [{:op, _, :colon}, :newline, :indent | rest] ->
          case Parser.parse_block(rest) do
            {:ok, body, rest} ->
              {:ok, nest_with(targets, body, line), drop_newline(rest)}

            {:error, _} = error ->
              error
          end

        _ ->
          {:error, "expected ':' after with statement on line #{line}"}
      end
    end
  end

  @spec parse_with_targets([Lexer.token()], pos_integer()) ::
          {:ok, [{term(), String.t() | nil}], [Lexer.token()]} | {:error, String.t()}
  defp parse_with_targets(tokens, line) do
    case Parser.parse_expression(tokens) do
      {:ok, expr, [{:keyword, _, "as"}, {:name, _, name} | rest]} ->
        collect_with_targets(rest, [{expr, name}], line)

      {:ok, expr, rest} ->
        collect_with_targets(rest, [{expr, nil}], line)

      {:error, _} = error ->
        error
    end
  end

  @spec collect_with_targets([Lexer.token()], [{term(), String.t() | nil}], pos_integer()) ::
          {:ok, [{term(), String.t() | nil}], [Lexer.token()]} | {:error, String.t()}
  defp collect_with_targets([{:op, _, :comma} | rest], acc, line) do
    case Parser.parse_expression(rest) do
      {:ok, expr, [{:keyword, _, "as"}, {:name, _, name} | rest]} ->
        collect_with_targets(rest, [{expr, name} | acc], line)

      {:ok, expr, rest} ->
        collect_with_targets(rest, [{expr, nil} | acc], line)

      {:error, _} = error ->
        error
    end
  end

  defp collect_with_targets(rest, acc, _line) do
    {:ok, Enum.reverse(acc), rest}
  end

  @spec nest_with([{term(), String.t() | nil}], [term()], pos_integer()) :: term()
  defp nest_with([{expr, name}], body, line) do
    {:with, [line: line], [expr, name, body]}
  end

  defp nest_with([{expr, name} | rest], body, line) do
    inner = nest_with(rest, body, line)
    {:with, [line: line], [expr, name, [inner]]}
  end

  @doc """
  Parses a class definition.
  """
  @spec parse_class_def([Lexer.token()]) :: parse_result()
  def parse_class_def([{:name, line, name}, {:op, _, :lparen} | rest]) do
    case parse_base_classes(rest) do
      {:ok, bases, rest} ->
        case rest do
          [{:op, _, :colon}, :newline, :indent | rest] ->
            case Parser.parse_block(rest) do
              {:ok, body, rest} ->
                {:ok, {:class, [line: line], [name, bases, body]}, drop_newline(rest)}

              {:error, _} = error ->
                error
            end

          [{:op, _, :colon} | inline_rest] ->
            case Parser.parse_inline_body(inline_rest) do
              {:ok, stmt, rest} ->
                {:ok, {:class, [line: line], [name, bases, [stmt]]}, drop_newline(rest)}

              {:error, _} = error ->
                error
            end

          _ ->
            {:error, "expected ':' after class definition on line #{line}"}
        end

      {:error, _} = error ->
        error
    end
  end

  def parse_class_def([{:name, line, name}, {:op, _, :colon}, :newline, :indent | rest]) do
    case Parser.parse_block(rest) do
      {:ok, body, rest} ->
        {:ok, {:class, [line: line], [name, [], body]}, drop_newline(rest)}

      {:error, _} = error ->
        error
    end
  end

  def parse_class_def([{:name, line, name}, {:op, _, :colon} | inline_rest]) do
    case Parser.parse_inline_body(inline_rest) do
      {:ok, stmt, rest} ->
        {:ok, {:class, [line: line], [name, [], [stmt]]}, drop_newline(rest)}

      {:error, _} = error ->
        error
    end
  end

  def parse_class_def(tokens) do
    {:error, "expected class name at #{token_line(tokens)}"}
  end

  @spec parse_base_classes([Lexer.token()]) ::
          {:ok, [base_class()], [Lexer.token()]} | {:error, String.t()}
  defp parse_base_classes(tokens), do: parse_base_classes(tokens, [])

  @spec parse_base_classes([Lexer.token()], [base_class()]) ::
          {:ok, [base_class()], [Lexer.token()]} | {:error, String.t()}
  defp parse_base_classes([{:op, _, :rparen} | rest], acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_base_classes([{:op, _, :comma} | rest], acc) do
    parse_base_classes(rest, acc)
  end

  defp parse_base_classes([{:name, _, name}, {:op, _, :dot}, {:name, _, attr} | rest], acc) do
    parse_base_classes(rest, [{:dotted, name, attr} | acc])
  end

  defp parse_base_classes([{:name, _, name} | rest], acc) do
    parse_base_classes(rest, [name | acc])
  end

  defp parse_base_classes(tokens, _acc) do
    {:error, "unexpected token in class bases at #{token_line(tokens)}"}
  end

  @spec parse_params([Lexer.token()]) :: {:ok, [param()], [Lexer.token()]} | {:error, String.t()}
  defp parse_params(tokens), do: parse_params(tokens, [])

  @spec parse_params([Lexer.token()], [param()]) ::
          {:ok, [param()], [Lexer.token()]} | {:error, String.t()}
  defp parse_params([{:op, _, :rparen} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_params([{:op, _, :comma} | rest], acc) do
    parse_params(rest, acc)
  end

  defp parse_params([{:name, _, name}, {:op, _, :colon} | rest], acc) do
    {type_str, rest} = collect_type_annotation(rest)

    case rest do
      [{:op, _, :assign} | rest] ->
        with {:ok, default, rest} <- Parser.parse_expression(rest) do
          parse_params(rest, [{name, default, type_str} | acc])
        end

      _ ->
        parse_params(rest, [{name, nil, type_str} | acc])
    end
  end

  defp parse_params([{:name, _, name}, {:op, _, :assign} | rest], acc) do
    with {:ok, default, rest} <- Parser.parse_expression(rest) do
      parse_params(rest, [{name, default} | acc])
    end
  end

  defp parse_params([{:op, _, :double_star}, {:name, _, name} | rest], acc) do
    parse_params(rest, [{"**" <> name, nil} | acc])
  end

  defp parse_params([{:op, _, :star}, {:name, _, name} | rest], acc) do
    parse_params(rest, [{"*" <> name, nil} | acc])
  end

  defp parse_params([{:op, _, :star}, {:op, _, :comma} | rest], acc) do
    parse_params(rest, [{"*", :kwonly_sep} | acc])
  end

  defp parse_params([{:op, _, :star}, {:op, _, :rparen} | rest], acc) do
    parse_params([{:op, 0, :rparen} | rest], [{"*", :kwonly_sep} | acc])
  end

  defp parse_params([{:name, _, name} | rest], acc) do
    parse_params(rest, [{name, nil} | acc])
  end

  defp parse_params(tokens, _acc) do
    {:error, "unexpected token in parameter list at #{token_line(tokens)}"}
  end

  @spec skip_return_annotation([Lexer.token()]) :: [Lexer.token()]
  defp skip_return_annotation([{:op, _, :minus}, {:op, _, :gt} | rest]) do
    skip_type_annotation(rest)
  end

  defp skip_return_annotation(tokens), do: tokens

  @spec collect_type_annotation([Lexer.token()]) :: {String.t(), [Lexer.token()]}
  defp collect_type_annotation([{:name, _, name} | rest]) do
    {subscript, rest} = collect_type_subscript(rest)
    {name <> subscript, rest}
  end

  defp collect_type_annotation([{:keyword, _, "None"} | rest]), do: {"None", rest}
  defp collect_type_annotation(tokens), do: {"", tokens}

  @spec skip_type_annotation([Lexer.token()]) :: [Lexer.token()]
  defp skip_type_annotation([{:name, _, _} | rest]), do: skip_type_subscript(rest)
  defp skip_type_annotation([{:keyword, _, "None"} | rest]), do: rest
  defp skip_type_annotation(tokens), do: tokens

  @spec collect_type_subscript([Lexer.token()]) :: {String.t(), [Lexer.token()]}
  defp collect_type_subscript([{:op, _, :lbracket} | rest]) do
    {inner, rest} = collect_brackets(rest, 1, [])
    {"[" <> inner <> "]", rest}
  end

  defp collect_type_subscript(tokens), do: {"", tokens}

  @spec collect_brackets([Lexer.token()], non_neg_integer(), [String.t()]) ::
          {String.t(), [Lexer.token()]}
  defp collect_brackets(tokens, 0, acc), do: {acc |> Enum.reverse() |> Enum.join(), tokens}

  defp collect_brackets([{:op, _, :lbracket} | rest], depth, acc),
    do: collect_brackets(rest, depth + 1, ["[" | acc])

  defp collect_brackets([{:op, _, :rbracket} | rest], 1, acc),
    do: collect_brackets(rest, 0, acc)

  defp collect_brackets([{:op, _, :rbracket} | rest], depth, acc),
    do: collect_brackets(rest, depth - 1, ["]" | acc])

  defp collect_brackets([{:op, _, :comma} | rest], depth, acc),
    do: collect_brackets(rest, depth, [", " | acc])

  defp collect_brackets([{:op, _, :ellipsis} | rest], depth, acc),
    do: collect_brackets(rest, depth, ["..." | acc])

  defp collect_brackets([{:name, _, name} | rest], depth, acc),
    do: collect_brackets(rest, depth, [name | acc])

  defp collect_brackets([{:keyword, _, kw} | rest], depth, acc),
    do: collect_brackets(rest, depth, [kw | acc])

  defp collect_brackets([_ | rest], depth, acc),
    do: collect_brackets(rest, depth, acc)

  defp collect_brackets([], _depth, acc),
    do: {acc |> Enum.reverse() |> Enum.join(), []}

  @spec skip_type_subscript([Lexer.token()]) :: [Lexer.token()]
  defp skip_type_subscript([{:op, _, :lbracket} | rest]), do: skip_brackets(rest, 1)
  defp skip_type_subscript(tokens), do: tokens

  @spec skip_brackets([Lexer.token()], non_neg_integer()) :: [Lexer.token()]
  defp skip_brackets(tokens, 0), do: tokens
  defp skip_brackets([{:op, _, :lbracket} | rest], depth), do: skip_brackets(rest, depth + 1)
  defp skip_brackets([{:op, _, :rbracket} | rest], depth), do: skip_brackets(rest, depth - 1)
  defp skip_brackets([_ | rest], depth), do: skip_brackets(rest, depth)
  defp skip_brackets([], _depth), do: []

  @spec drop_newline([Lexer.token()]) :: [Lexer.token()]
  defp drop_newline([:newline | rest]), do: rest
  defp drop_newline(rest), do: rest

  @spec token_line([Lexer.token()]) :: String.t()
  defp token_line([{_, line, _} | _]), do: "line #{line}"
  defp token_line(_), do: "end of input"
end
