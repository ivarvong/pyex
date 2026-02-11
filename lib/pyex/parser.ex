defmodule Pyex.Parser do
  @moduledoc """
  Transforms a flat token stream from the lexer into an AST.

  The AST uses plain tuples: `{node_type, meta, children}` where
  meta carries line information for error reporting. All parse
  functions return `{:ok, node, rest}` or `{:error, message}`.
  """

  alias Pyex.Lexer

  @type meta :: [line: pos_integer()]

  @type node_type ::
          :module
          | :def
          | :decorated_def
          | :kwarg
          | :assign
          | :aug_assign
          | :subscript_assign
          | :return
          | :if
          | :while
          | :for
          | :import
          | :pass
          | :break
          | :continue
          | :try
          | :raise
          | :expr
          | :call
          | :getattr
          | :subscript
          | :binop
          | :unaryop
          | :lit
          | :var
          | :list
          | :dict
          | :ternary
          | :lambda
          | :list_comp
          | :tuple
          | :multi_assign
          | :fstring
          | :from_import
          | :chained_compare
          | :assert
          | :del
          | :aug_subscript_assign
          | :dict_comp
          | :chained_assign
          | :global
          | :nonlocal
          | :set
          | :set_comp
          | :star_arg
          | :double_star_arg
          | :walrus
          | :class
          | :attr_assign
          | :aug_attr_assign
          | :with
          | :match
          | :yield
          | :yield_from
          | :gen_expr
          | :annotated_assign

  @type ast_node :: {node_type(), meta(), [term()]}

  @type param ::
          {String.t(), ast_node() | nil}
          | {String.t(), ast_node() | nil, String.t()}

  @typep comp_clause ::
           {:comp_for, String.t() | [String.t()], ast_node()}
           | {:comp_if, ast_node()}

  @typep parse_result :: {:ok, ast_node(), [Lexer.token()]} | {:error, String.t()}

  @doc """
  Parses a token list into an AST.

  Returns `{:ok, ast}` or `{:error, message}`.
  """
  @spec parse([Lexer.token()]) :: {:ok, ast_node()} | {:error, String.t()}
  def parse(tokens) do
    case parse_block(tokens) do
      {:ok, statements, []} ->
        {:ok, {:module, [line: 1], statements}}

      {:ok, _statements, rest} ->
        {:error, "unexpected tokens at #{token_line(rest)}: #{inspect_tokens(rest)}"}

      {:error, _} = error ->
        error
    end
  end

  @spec parse_block([Lexer.token()], [ast_node()]) ::
          {:ok, [ast_node()], [Lexer.token()]} | {:error, String.t()}
  defp parse_block(tokens, acc \\ [])
  defp parse_block([], acc), do: {:ok, Enum.reverse(acc), []}
  defp parse_block([:dedent | rest], acc), do: {:ok, Enum.reverse(acc), rest}
  defp parse_block([:newline | rest], acc), do: parse_block(rest, acc)

  defp parse_block(tokens, acc) do
    case parse_statement(tokens) do
      {:ok, statement, rest} -> parse_block(rest, [statement | acc])
      {:error, _} = error -> error
    end
  end

  @spec parse_statement([Lexer.token()]) :: parse_result()
  defp parse_statement([{:keyword, _line, "def"} | rest]) do
    parse_function_def(rest)
  end

  defp parse_statement([{:keyword, _line, "class"} | rest]) do
    parse_class_def(rest)
  end

  defp parse_statement([{:keyword, line, "with"} | rest]) do
    parse_with(rest, line)
  end

  defp parse_statement([{:keyword, line, "return"} | rest]) do
    if bare_return?(rest) do
      {:ok, {:return, [line: line], [{:lit, [line: line], [nil]}]}, drop_newline(rest)}
    else
      case parse_expression(rest) do
        {:ok, expr, [{:op, _, :comma} | rest]} ->
          collect_return_tuple(rest, line, [expr])

        {:ok, expr, rest} ->
          {:ok, {:return, [line: line], [expr]}, drop_newline(rest)}

        {:error, _} = error ->
          error
      end
    end
  end

  defp parse_statement([{:keyword, line, "yield"}, {:keyword, _, "from"} | rest]) do
    case parse_expression(rest) do
      {:ok, expr, rest} ->
        {:ok, {:yield_from, [line: line], [expr]}, drop_newline(rest)}

      {:error, _} = error ->
        error
    end
  end

  defp parse_statement([{:keyword, line, "yield"} | rest]) do
    if bare_return?(rest) do
      {:ok, {:yield, [line: line], [{:lit, [line: line], [nil]}]}, drop_newline(rest)}
    else
      case parse_expression(rest) do
        {:ok, expr, rest} ->
          {:ok, {:yield, [line: line], [expr]}, drop_newline(rest)}

        {:error, _} = error ->
          error
      end
    end
  end

  defp parse_statement([{:keyword, _line, "if"} | rest]) do
    parse_if(rest)
  end

  defp parse_statement([{:keyword, _line, "while"} | rest]) do
    parse_while(rest)
  end

  defp parse_statement([{:keyword, _line, "for"} | rest]) do
    parse_for(rest)
  end

  defp parse_statement([{:keyword, line, "from"} | rest]) do
    parse_from_import(rest, line)
  end

  defp parse_statement([{:keyword, line, "import"} | rest]) do
    parse_import(rest, line)
  end

  defp parse_statement([{:keyword, _line, "try"} | rest]) do
    parse_try(rest)
  end

  defp parse_statement([{:keyword, line, "raise"} | rest]) do
    case rest do
      [:newline | _] ->
        {:ok, {:raise, [line: line], [nil]}, drop_newline(rest)}

      [] ->
        {:ok, {:raise, [line: line], [nil]}, []}

      _ ->
        case parse_expression(rest) do
          {:ok, expr, rest} ->
            {:ok, {:raise, [line: line], [expr]}, drop_newline(rest)}

          {:error, _} = error ->
            error
        end
    end
  end

  defp parse_statement([{:keyword, line, "assert"} | rest]) do
    case parse_expression(rest) do
      {:ok, condition, [{:op, _, :comma} | msg_rest]} ->
        case parse_expression(msg_rest) do
          {:ok, msg_expr, rest} ->
            {:ok, {:assert, [line: line], [condition, msg_expr]}, drop_newline(rest)}

          {:error, _} = error ->
            error
        end

      {:ok, condition, rest} ->
        {:ok, {:assert, [line: line], [condition, nil]}, drop_newline(rest)}

      {:error, _} = error ->
        error
    end
  end

  defp parse_statement([{:keyword, line, "del"} | rest]) do
    case rest do
      [{:name, _, var_name}, {:op, _, :lbracket} | subscript_rest] ->
        with {:ok, key_expr, [{:op, _, :rbracket} | rest]} <- parse_expression(subscript_rest) do
          {:ok, {:del, [line: line], [:subscript, var_name, key_expr]}, drop_newline(rest)}
        end

      [{:name, _, var_name} | rest] ->
        {:ok, {:del, [line: line], [:var, var_name]}, drop_newline(rest)}

      _ ->
        {:error, "expected variable or subscript after 'del' at line #{line}"}
    end
  end

  defp parse_statement([{:keyword, line, "pass"} | rest]) do
    {:ok, {:pass, [line: line], []}, drop_newline(rest)}
  end

  defp parse_statement([{:keyword, line, "break"} | rest]) do
    {:ok, {:break, [line: line], []}, drop_newline(rest)}
  end

  defp parse_statement([{:keyword, line, "continue"} | rest]) do
    {:ok, {:continue, [line: line], []}, drop_newline(rest)}
  end

  defp parse_statement([{:keyword, line, "global"} | rest]) do
    parse_name_list(rest, line, :global)
  end

  defp parse_statement([{:keyword, line, "nonlocal"} | rest]) do
    parse_name_list(rest, line, :nonlocal)
  end

  defp parse_statement([{:keyword, line, "async"} | _rest]) do
    {:error,
     "NotImplementedError: 'async' is not supported. " <>
       "Write synchronous code instead (line #{line})"}
  end

  defp parse_statement([{:keyword, line, "await"} | _rest]) do
    {:error,
     "NotImplementedError: 'await' is not supported. " <>
       "Call functions directly instead of awaiting them (line #{line})"}
  end

  defp parse_statement([{:op, line, :at} | rest]) do
    with {:ok, decorator_expr, rest} <- parse_expression(rest) do
      rest = drop_newline(rest)

      case parse_statement(rest) do
        {:ok, {:def, _, _} = def_node, rest} ->
          {:ok, {:decorated_def, [line: line], [decorator_expr, def_node]}, rest}

        {:ok, {:class, _, _} = class_node, rest} ->
          {:ok, {:decorated_def, [line: line], [decorator_expr, class_node]}, rest}

        {:ok, {:decorated_def, _, _} = inner, rest} ->
          {:ok, {:decorated_def, [line: line], [decorator_expr, inner]}, rest}

        _ ->
          {:error, "expected function or class definition after decorator on line #{line}"}
      end
    end
  end

  @aug_assign_ops %{
    plus_assign: :plus,
    minus_assign: :minus,
    star_assign: :star,
    slash_assign: :slash,
    floor_div_assign: :floor_div,
    percent_assign: :percent,
    double_star_assign: :double_star,
    amp_assign: :amp,
    pipe_assign: :pipe,
    caret_assign: :caret,
    lshift_assign: :lshift,
    rshift_assign: :rshift
  }

  defp parse_statement([{:name, line, "match"} | rest] = tokens) do
    case try_match(rest, line) do
      {:ok, _, _} = result -> result
      :not_match -> parse_name_statement(tokens, line, "match")
    end
  end

  defp parse_statement([{:name, line, name} | _] = tokens) do
    parse_name_statement(tokens, line, name)
  end

  defp parse_statement([{:op, line, :star}, {:name, _, name}, {:op, _, :comma} | rest]) do
    case try_multi_assign(rest, line, [{:starred, name}]) do
      {:ok, _, _} = result ->
        result

      :not_assign ->
        {:error, "SyntaxError: starred assignment target must be in a tuple (line #{line})"}
    end
  end

  defp parse_statement(tokens) do
    parse_expression_statement(tokens)
  end

  @spec parse_name_statement([Lexer.token()], pos_integer(), String.t()) :: parse_result()
  defp parse_name_statement([{:name, line, _}, {:op, _, :dot} | _] = tokens, _line, _) do
    case try_attr_assign(tokens, line) do
      {:ok, _, _} = result -> result
      :not_assign -> parse_expression_statement(tokens)
    end
  end

  defp parse_name_statement([{:name, _, name}, {:op, _, aug_op} | rest], line, _)
       when is_map_key(@aug_assign_ops, aug_op) do
    case parse_expression(rest) do
      {:ok, expr, rest} ->
        op = Map.fetch!(@aug_assign_ops, aug_op)
        {:ok, {:aug_assign, [line: line], [name, op, expr]}, drop_newline(rest)}

      {:error, _} = error ->
        error
    end
  end

  defp parse_name_statement(
         [{:name, _, name}, {:op, _, :lbracket} | rest] = tokens,
         line,
         _
       ) do
    case try_subscript_assign(rest, line, name) do
      {:ok, _, _} = result -> result
      :not_assign -> parse_expression_statement(tokens)
    end
  end

  defp parse_name_statement(
         [{:name, _, name}, {:op, _, :comma} | rest] = tokens,
         line,
         _
       ) do
    case try_multi_assign(rest, line, [name]) do
      {:ok, _, _} = result -> result
      :not_assign -> parse_expression_statement(tokens)
    end
  end

  defp parse_name_statement(
         [{:name, _, name}, {:op, _, :colon}, {tag, _, _} | _] = tokens,
         line,
         _
       )
       when tag in [:name, :keyword] do
    [{:name, _, _}, {:op, _, :colon} | rest] = tokens
    {type_str, rest} = collect_type_annotation(rest)

    case rest do
      [{:op, _, :assign} | rest] ->
        case parse_expression(rest) do
          {:ok, expr, rest} ->
            {:ok, {:annotated_assign, [line: line], [name, type_str, expr]}, drop_newline(rest)}

          {:error, _} = error ->
            error
        end

      _ ->
        {:ok, {:annotated_assign, [line: line], [name, type_str, nil]}, drop_newline(rest)}
    end
  end

  defp parse_name_statement([{:name, _, name}, {:op, _, :assign} | rest], line, _) do
    collect_chained_assign(rest, line, [name])
  end

  defp parse_name_statement(tokens, _line, _) do
    parse_expression_statement(tokens)
  end

  @spec try_attr_assign([Lexer.token()], pos_integer()) ::
          {:ok, ast_node(), [Lexer.token()]} | :not_assign
  defp try_attr_assign(tokens, line) do
    case parse_dotted_target(tokens) do
      {:ok, target, [{:op, _, :assign} | rest]} ->
        case parse_expression(rest) do
          {:ok, expr, rest} ->
            {:ok, {:attr_assign, [line: line], [target, expr]}, drop_newline(rest)}

          {:error, _} ->
            :not_assign
        end

      {:ok, target, [{:op, _, aug_op} | rest]} when is_map_key(@aug_assign_ops, aug_op) ->
        case parse_expression(rest) do
          {:ok, expr, rest} ->
            op = Map.fetch!(@aug_assign_ops, aug_op)
            {:ok, {:aug_attr_assign, [line: line], [target, op, expr]}, drop_newline(rest)}

          {:error, _} ->
            :not_assign
        end

      {:ok, target, [{:op, _, :lbracket} | rest]} ->
        case parse_expression(rest) do
          {:ok, key_expr, [{:op, _, :rbracket}, {:op, _, :assign} | rest]} ->
            case parse_expression(rest) do
              {:ok, val_expr, rest} ->
                {:ok, {:subscript_assign, [line: line], [target, key_expr, val_expr]},
                 drop_newline(rest)}

              {:error, _} ->
                :not_assign
            end

          {:ok, key_expr, [{:op, _, :rbracket}, {:op, _, aug_op} | rest]}
          when is_map_key(@aug_assign_ops, aug_op) ->
            case parse_expression(rest) do
              {:ok, val_expr, rest} ->
                op = Map.fetch!(@aug_assign_ops, aug_op)

                {:ok, {:aug_subscript_assign, [line: line], [target, key_expr, op, val_expr]},
                 drop_newline(rest)}

              {:error, _} ->
                :not_assign
            end

          _ ->
            :not_assign
        end

      _ ->
        :not_assign
    end
  end

  @spec parse_dotted_target([Lexer.token()]) :: {:ok, ast_node(), [Lexer.token()]} | :error
  defp parse_dotted_target([{:name, line, name}, {:op, _, :dot}, {:name, line2, attr} | rest]) do
    target = {:getattr, [line: line2], [{:var, [line: line], [name]}, attr]}
    parse_dotted_target_rest(target, rest)
  end

  defp parse_dotted_target(_), do: :error

  @spec parse_dotted_target_rest(ast_node(), [Lexer.token()]) ::
          {:ok, ast_node(), [Lexer.token()]}
  defp parse_dotted_target_rest(target, [{:op, _, :dot}, {:name, line, attr} | rest]) do
    target = {:getattr, [line: line], [target, attr]}
    parse_dotted_target_rest(target, rest)
  end

  defp parse_dotted_target_rest(target, rest), do: {:ok, target, rest}

  @spec collect_chained_assign([Lexer.token()], pos_integer(), [String.t()]) :: parse_result()
  defp collect_chained_assign([{:name, _, next_name}, {:op, _, :assign} | rest], line, names) do
    collect_chained_assign(rest, line, [next_name | names])
  end

  defp collect_chained_assign(rest, line, names) do
    case parse_expression(rest) do
      {:ok, expr, rest} ->
        names = Enum.reverse(names)

        case names do
          [single] ->
            {:ok, {:assign, [line: line], [single, expr]}, drop_newline(rest)}

          _ ->
            {:ok, {:chained_assign, [line: line], [names, expr]}, drop_newline(rest)}
        end

      {:error, _} = error ->
        error
    end
  end

  @spec parse_expression_statement([Lexer.token()]) :: parse_result()
  defp parse_expression_statement(tokens) do
    case parse_expression(tokens) do
      {:ok, expr, rest} ->
        line = node_line(expr)
        {:ok, {:expr, [line: line], [expr]}, drop_newline(rest)}

      {:error, _} = error ->
        error
    end
  end

  @spec try_subscript_assign([Lexer.token()], pos_integer(), String.t()) ::
          parse_result() | :not_assign
  defp try_subscript_assign(tokens, line, name) do
    case parse_expression(tokens) do
      {:ok, key, rest} ->
        case rest do
          [{:op, _, :rbracket}, {:op, _, :lbracket} | nested_rest] ->
            target = {:subscript, [line: line], [{:var, [line: line], [name]}, key]}
            try_nested_subscript_assign(nested_rest, line, target)

          [{:op, _, :rbracket}, {:op, _, :assign} | rest] ->
            case parse_expression(rest) do
              {:ok, val, rest} ->
                {:ok, {:subscript_assign, [line: line], [name, key, val]}, drop_newline(rest)}

              {:error, _} = error ->
                error
            end

          [{:op, _, :rbracket}, {:op, _, aug_op} | rest]
          when is_map_key(@aug_assign_ops, aug_op) ->
            case parse_expression(rest) do
              {:ok, val, rest} ->
                op = Map.fetch!(@aug_assign_ops, aug_op)

                {:ok, {:aug_subscript_assign, [line: line], [name, key, op, val]},
                 drop_newline(rest)}

              {:error, _} = error ->
                error
            end

          _ ->
            :not_assign
        end

      {:error, _} ->
        :not_assign
    end
  end

  @spec try_nested_subscript_assign([Lexer.token()], pos_integer(), ast_node()) ::
          parse_result() | :not_assign
  defp try_nested_subscript_assign(tokens, line, target) do
    case parse_expression(tokens) do
      {:ok, key, rest} ->
        case rest do
          [{:op, _, :rbracket}, {:op, _, :lbracket} | nested_rest] ->
            nested_target = {:subscript, [line: line], [target, key]}
            try_nested_subscript_assign(nested_rest, line, nested_target)

          [{:op, _, :rbracket}, {:op, _, :assign} | rest] ->
            case parse_expression(rest) do
              {:ok, val, rest} ->
                {:ok, {:subscript_assign, [line: line], [target, key, val]}, drop_newline(rest)}

              {:error, _} = error ->
                error
            end

          [{:op, _, :rbracket}, {:op, _, aug_op} | rest]
          when is_map_key(@aug_assign_ops, aug_op) ->
            case parse_expression(rest) do
              {:ok, val, rest} ->
                op = Map.fetch!(@aug_assign_ops, aug_op)

                {:ok, {:aug_subscript_assign, [line: line], [target, key, op, val]},
                 drop_newline(rest)}

              {:error, _} = error ->
                error
            end

          _ ->
            :not_assign
        end

      {:error, _} ->
        :not_assign
    end
  end

  @spec parse_function_def([Lexer.token()]) :: parse_result()
  defp parse_function_def([{:name, line, name}, {:op, _, :lparen} | rest]) do
    case parse_params(rest) do
      {:ok, params, rest} ->
        rest = skip_return_annotation(rest)

        case rest do
          [{:op, _, :colon}, :newline, :indent | rest] ->
            case parse_block(rest) do
              {:ok, body, rest} ->
                {:ok, {:def, [line: line], [name, params, body]}, drop_newline(rest)}

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

  defp parse_function_def(tokens) do
    {:error, "expected function name at #{token_line(tokens)}"}
  end

  @spec parse_with([Lexer.token()], pos_integer()) :: parse_result()
  defp parse_with(rest, line) do
    case parse_expression(rest) do
      {:ok, expr,
       [{:keyword, _, "as"}, {:name, _, name}, {:op, _, :colon}, :newline, :indent | rest]} ->
        case parse_block(rest) do
          {:ok, body, rest} ->
            {:ok, {:with, [line: line], [expr, name, body]}, drop_newline(rest)}

          {:error, _} = error ->
            error
        end

      {:ok, expr, [{:op, _, :colon}, :newline, :indent | rest]} ->
        case parse_block(rest) do
          {:ok, body, rest} ->
            {:ok, {:with, [line: line], [expr, nil, body]}, drop_newline(rest)}

          {:error, _} = error ->
            error
        end

      {:ok, _expr, _rest} ->
        {:error, "expected ':' after with statement on line #{line}"}

      {:error, _} = error ->
        error
    end
  end

  @spec parse_class_def([Lexer.token()]) :: parse_result()
  defp parse_class_def([{:name, line, name}, {:op, _, :lparen} | rest]) do
    case parse_base_classes(rest) do
      {:ok, bases, rest} ->
        case rest do
          [{:op, _, :colon}, :newline, :indent | rest] ->
            case parse_block(rest) do
              {:ok, body, rest} ->
                {:ok, {:class, [line: line], [name, bases, body]}, drop_newline(rest)}

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

  defp parse_class_def([{:name, line, name}, {:op, _, :colon}, :newline, :indent | rest]) do
    case parse_block(rest) do
      {:ok, body, rest} ->
        {:ok, {:class, [line: line], [name, [], body]}, drop_newline(rest)}

      {:error, _} = error ->
        error
    end
  end

  defp parse_class_def(tokens) do
    {:error, "expected class name at #{token_line(tokens)}"}
  end

  @spec parse_base_classes([Lexer.token()], [String.t()]) ::
          {:ok, [String.t()], [Lexer.token()]} | {:error, String.t()}
  defp parse_base_classes(tokens, acc \\ [])
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

  @spec parse_params([Lexer.token()], [param()]) ::
          {:ok, [param()], [Lexer.token()]} | {:error, String.t()}
  defp parse_params(tokens, acc \\ [])

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
        with {:ok, default, rest} <- parse_expression(rest) do
          parse_params(rest, [{name, default, type_str} | acc])
        end

      _ ->
        parse_params(rest, [{name, nil, type_str} | acc])
    end
  end

  defp parse_params([{:name, _, name}, {:op, _, :assign} | rest], acc) do
    with {:ok, default, rest} <- parse_expression(rest) do
      parse_params(rest, [{name, default} | acc])
    end
  end

  defp parse_params([{:op, _, :double_star}, {:name, _, name} | rest], acc) do
    parse_params(rest, [{"**" <> name, nil} | acc])
  end

  defp parse_params([{:op, _, :star}, {:name, _, name} | rest], acc) do
    parse_params(rest, [{"*" <> name, nil} | acc])
  end

  defp parse_params([{:name, _, name} | rest], acc) do
    parse_params(rest, [{name, nil} | acc])
  end

  defp parse_params(tokens, _acc) do
    {:error, "unexpected token in parameter list at #{token_line(tokens)}"}
  end

  @spec parse_if([Lexer.token()]) :: parse_result()
  defp parse_if(tokens) do
    with {:ok, condition, rest} <- parse_expression(tokens) do
      case rest do
        [{:op, _, :colon}, :newline, :indent | block_rest] ->
          with {:ok, body, rest} <- parse_block(block_rest),
               {:ok, else_clauses, rest} <- parse_elif_else(rest) do
            line = node_line(condition)
            {:ok, {:if, [line: line], [{condition, body} | else_clauses]}, drop_newline(rest)}
          end

        [{:op, _, :colon} | inline_rest] ->
          with {:ok, stmt, rest} <- parse_inline_body(inline_rest) do
            {:ok, else_clauses, rest} = parse_elif_else(rest)
            line = node_line(condition)
            {:ok, {:if, [line: line], [{condition, [stmt]} | else_clauses]}, drop_newline(rest)}
          end

        _ ->
          {:error, "expected ':' after if at #{token_line(rest)}"}
      end
    end
  end

  @spec parse_elif_else([Lexer.token()]) ::
          {:ok, [{ast_node(), [ast_node()]} | {:else, [ast_node()]}], [Lexer.token()]}
          | {:error, String.t()}
  defp parse_elif_else([{:keyword, _, "elif"} | rest]) do
    with {:ok, condition, rest} <- parse_expression(rest) do
      case rest do
        [{:op, _, :colon}, :newline, :indent | block_rest] ->
          with {:ok, body, rest} <- parse_block(block_rest),
               {:ok, more, rest} <- parse_elif_else(rest) do
            {:ok, [{condition, body} | more], rest}
          end

        [{:op, _, :colon} | inline_rest] ->
          with {:ok, stmt, rest} <- parse_inline_body(inline_rest) do
            {:ok, more, rest} = parse_elif_else(rest)
            {:ok, [{condition, [stmt]} | more], rest}
          end

        _ ->
          {:error, "expected ':' after elif at #{token_line(rest)}"}
      end
    end
  end

  defp parse_elif_else([{:keyword, _, "else"}, {:op, _, :colon}, :newline, :indent | rest]) do
    case parse_block(rest) do
      {:ok, body, rest} -> {:ok, [{:else, body}], rest}
      {:error, _} = error -> error
    end
  end

  defp parse_elif_else([{:keyword, _, "else"}, {:op, _, :colon} | rest]) do
    case parse_inline_body(rest) do
      {:ok, stmt, rest} -> {:ok, [{:else, [stmt]}], rest}
      {:error, _} = error -> error
    end
  end

  defp parse_elif_else(rest), do: {:ok, [], rest}

  @spec parse_while([Lexer.token()]) :: parse_result()
  defp parse_while(tokens) do
    with {:ok, condition, rest} <- parse_expression(tokens),
         {:ok, rest} <- expect_block_start(rest, "while") do
      case parse_block(rest) do
        {:ok, body, rest} ->
          {:ok, else_body, rest} = parse_loop_else(rest)
          line = node_line(condition)
          {:ok, {:while, [line: line], [condition, body, else_body]}, drop_newline(rest)}

        {:error, _} = error ->
          error
      end
    end
  end

  @spec parse_for([Lexer.token()]) :: parse_result()
  defp parse_for([{:name, line, first_name}, {:op, _, :comma} | rest]) do
    case collect_for_vars(rest, [first_name]) do
      {:ok, var_names, rest} ->
        with {:ok, iterable, rest} <- parse_expression(rest),
             {:ok, rest} <- expect_block_start(rest, "for") do
          case parse_block(rest) do
            {:ok, body, rest} ->
              {:ok, else_body, rest} = parse_loop_else(rest)

              {:ok, {:for, [line: line], [var_names, iterable, body, else_body]},
               drop_newline(rest)}

            {:error, _} = error ->
              error
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_for([{:name, line, var_name}, {:keyword, _, "in"} | rest]) do
    with {:ok, iterable, rest} <- parse_expression(rest),
         {:ok, rest} <- expect_block_start(rest, "for") do
      case parse_block(rest) do
        {:ok, body, rest} ->
          {:ok, else_body, rest} = parse_loop_else(rest)
          {:ok, {:for, [line: line], [var_name, iterable, body, else_body]}, drop_newline(rest)}

        {:error, _} = error ->
          error
      end
    end
  end

  defp parse_for(tokens) do
    {:error, "expected variable name after 'for' at #{token_line(tokens)}"}
  end

  @spec parse_loop_else([Lexer.token()]) ::
          {:ok, [ast_node()] | nil, [Lexer.token()]} | {:error, String.t()}
  defp parse_loop_else([{:keyword, _, "else"}, {:op, _, :colon}, :newline, :indent | rest]) do
    case parse_block(rest) do
      {:ok, else_body, rest} -> {:ok, else_body, rest}
      {:error, _} = error -> error
    end
  end

  defp parse_loop_else(rest), do: {:ok, nil, rest}

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

  @spec parse_comp_clauses([Lexer.token()], [comp_clause()]) ::
          {:ok, [comp_clause()], [Lexer.token()]} | {:error, String.t()}
  defp parse_comp_clauses([{:keyword, _, "if"} | rest], acc) do
    with {:ok, filter, rest} <- parse_or(rest) do
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
  defp parse_comp_for_clause(
         [{:name, _, first_name}, {:op, _, :comma} | rest],
         acc
       ) do
    case collect_for_vars(rest, [first_name]) do
      {:ok, var_names, rest} ->
        with {:ok, iterable, rest} <- parse_or(rest) do
          parse_comp_clauses(rest, [{:comp_for, var_names, iterable} | acc])
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_comp_for_clause(
         [{:name, _, var_name}, {:keyword, _, "in"} | rest],
         acc
       ) do
    with {:ok, iterable, rest} <- parse_or(rest) do
      parse_comp_clauses(rest, [{:comp_for, var_name, iterable} | acc])
    end
  end

  defp parse_comp_for_clause(tokens, _acc) do
    {:error, "expected variable name after 'for' in comprehension at #{token_line(tokens)}"}
  end

  @spec parse_import([Lexer.token()], pos_integer()) :: parse_result()
  defp parse_import(
         [{:name, line, module_name}, {:keyword, _, "as"}, {:name, _, alias_name} | rest],
         _line
       ) do
    {:ok, {:import, [line: line], [module_name, alias_name]}, drop_newline(rest)}
  end

  defp parse_import([{:name, line, module_name} | rest], _line) do
    {:ok, {:import, [line: line], [module_name]}, drop_newline(rest)}
  end

  defp parse_import(tokens, line) do
    {:error, "expected module name after 'import' on line #{line} at #{token_line(tokens)}"}
  end

  @spec parse_from_import([Lexer.token()], pos_integer()) :: parse_result()
  defp parse_from_import([{:name, _, first} | rest], line) do
    {module_name, rest} = parse_dotted_name(first, rest)

    case rest do
      [{:keyword, _, "import"} | rest] ->
        case parse_import_names(rest) do
          {:ok, names, rest} ->
            {:ok, {:from_import, [line: line], [module_name, names]}, drop_newline(rest)}

          {:error, _} = error ->
            error
        end

      _ ->
        {:error, "expected 'import' after module name on line #{line} at #{token_line(rest)}"}
    end
  end

  defp parse_from_import(tokens, line) do
    {:error, "expected module name after 'from' on line #{line} at #{token_line(tokens)}"}
  end

  @spec parse_dotted_name(String.t(), [Lexer.token()]) :: {String.t(), [Lexer.token()]}
  defp parse_dotted_name(acc, [{:op, _, :dot}, {:name, _, part} | rest]) do
    parse_dotted_name(acc <> "." <> part, rest)
  end

  defp parse_dotted_name(acc, rest), do: {acc, rest}

  @spec parse_import_names([Lexer.token()]) ::
          {:ok, [{String.t(), String.t() | nil}], [Lexer.token()]} | {:error, String.t()}
  defp parse_import_names(tokens, acc \\ [])

  defp parse_import_names(
         [{:name, _, name}, {:keyword, _, "as"}, {:name, _, alias_name} | rest],
         acc
       ) do
    case rest do
      [{:op, _, :comma} | rest] -> parse_import_names(rest, [{name, alias_name} | acc])
      _ -> {:ok, Enum.reverse([{name, alias_name} | acc]), rest}
    end
  end

  defp parse_import_names([{:name, _, name} | rest], acc) do
    case rest do
      [{:op, _, :comma} | rest] -> parse_import_names(rest, [{name, nil} | acc])
      _ -> {:ok, Enum.reverse([{name, nil} | acc]), rest}
    end
  end

  defp parse_import_names(tokens, _acc) do
    {:error, "expected name after 'import' at #{token_line(tokens)}"}
  end

  @spec parse_try([Lexer.token()]) :: parse_result()
  defp parse_try(tokens) do
    with {:ok, rest} <- expect_block_start(tokens, "try"),
         {:ok, body, rest} <- parse_block(rest),
         {:ok, handlers, rest} <- parse_except_clauses(rest),
         {:ok, else_body, rest} <- parse_try_else(rest),
         {:ok, finally_body, rest} <- parse_try_finally(rest) do
      line =
        case body do
          [{_, [line: l], _} | _] -> l
          _ -> 1
        end

      {:ok, {:try, [line: line], [body, handlers, else_body, finally_body]}, drop_newline(rest)}
    end
  end

  @spec parse_try_else([Lexer.token()]) ::
          {:ok, [ast_node()] | nil, [Lexer.token()]} | {:error, String.t()}
  defp parse_try_else([{:keyword, _, "else"}, {:op, _, :colon}, :newline, :indent | rest]) do
    case parse_block(rest) do
      {:ok, else_body, rest} -> {:ok, else_body, rest}
      {:error, _} = error -> error
    end
  end

  defp parse_try_else(rest), do: {:ok, nil, rest}

  @spec parse_try_finally([Lexer.token()]) ::
          {:ok, [ast_node()] | nil, [Lexer.token()]} | {:error, String.t()}
  defp parse_try_finally([{:keyword, _, "finally"}, {:op, _, :colon}, :newline, :indent | rest]) do
    case parse_block(rest) do
      {:ok, finally_body, rest} -> {:ok, finally_body, rest}
      {:error, _} = error -> error
    end
  end

  defp parse_try_finally(rest), do: {:ok, nil, rest}

  @typep except_clause ::
           {String.t() | [String.t()] | nil, String.t() | nil, [ast_node()]}

  @spec parse_except_clauses([Lexer.token()], [except_clause()]) ::
          {:ok, [except_clause()], [Lexer.token()]} | {:error, String.t()}
  defp parse_except_clauses(tokens, acc \\ [])

  defp parse_except_clauses([{:keyword, _, "except"} | rest], acc) do
    case rest do
      [{:op, _, :colon}, :newline, :indent | rest] ->
        case parse_block(rest) do
          {:ok, handler_body, rest} ->
            clause = {nil, nil, handler_body}
            parse_except_clauses(rest, [clause | acc])

          {:error, _} = error ->
            error
        end

      [{:op, _, :lparen} | paren_rest] ->
        case collect_except_names(paren_rest, []) do
          {:ok, names, [{:keyword, _, "as"}, {:name, _, var_name} | after_as]} ->
            with {:ok, after_as} <- expect_block_start(after_as, "except"),
                 {:ok, handler_body, after_as} <- parse_block(after_as) do
              clause = {names, var_name, handler_body}
              parse_except_clauses(after_as, [clause | acc])
            end

          {:ok, names, after_paren} ->
            with {:ok, after_paren} <- expect_block_start(after_paren, "except"),
                 {:ok, handler_body, after_paren} <- parse_block(after_paren) do
              clause = {names, nil, handler_body}
              parse_except_clauses(after_paren, [clause | acc])
            end

          {:error, _} = error ->
            error
        end

      [{:name, _, exc_name}, {:keyword, _, "as"}, {:name, _, var_name} | rest] ->
        with {:ok, rest} <- expect_block_start(rest, "except"),
             {:ok, handler_body, rest} <- parse_block(rest) do
          clause = {exc_name, var_name, handler_body}
          parse_except_clauses(rest, [clause | acc])
        end

      [{:name, _, exc_name} | rest] ->
        with {:ok, rest} <- expect_block_start(rest, "except"),
             {:ok, handler_body, rest} <- parse_block(rest) do
          clause = {exc_name, nil, handler_body}
          parse_except_clauses(rest, [clause | acc])
        end

      _ ->
        {:error, "expected ':' or exception name after 'except' at #{token_line(rest)}"}
    end
  end

  defp parse_except_clauses(rest, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  @spec collect_except_names([Lexer.token()], [String.t()]) ::
          {:ok, [String.t()], [Lexer.token()]} | {:error, String.t()}
  defp collect_except_names([{:name, _, name}, {:op, _, :rparen} | rest], acc) do
    {:ok, Enum.reverse([name | acc]), rest}
  end

  defp collect_except_names([{:name, _, name}, {:op, _, :comma} | rest], acc) do
    collect_except_names(rest, [name | acc])
  end

  defp collect_except_names(tokens, _acc) do
    {:error, "expected exception name in except tuple at #{token_line(tokens)}"}
  end

  @spec expect_block_start([Lexer.token()], String.t()) ::
          {:ok, [Lexer.token()]} | {:error, String.t()}
  defp expect_block_start([{:op, _, :colon}, :newline, :indent | rest], _ctx) do
    {:ok, rest}
  end

  defp expect_block_start(tokens, ctx) do
    {:error, "expected ':' after #{ctx} at #{token_line(tokens)}"}
  end

  @typep match_pattern ::
           {:match_wildcard, meta(), []}
           | {:match_capture, meta(), [String.t()]}
           | {:match_or, meta(), [match_pattern()]}
           | {:match_sequence, meta(), [match_pattern()]}
           | {:match_mapping, meta(), [{ast_node(), match_pattern()}]}
           | {:match_class, meta(), [term()]}
           | {:match_star, meta(), [String.t() | nil]}
           | ast_node()

  @typep match_case :: {match_pattern(), ast_node() | nil, [ast_node()]}

  @spec try_match([Lexer.token()], pos_integer()) ::
          {:ok, ast_node(), [Lexer.token()]} | :not_match
  defp try_match(tokens, line) do
    with {:ok, subject, [{:op, _, :colon}, :newline, :indent | rest]} <- parse_expression(tokens),
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
         {:ok, rest} <- expect_block_start(rest, "case"),
         {:ok, body, rest} <- parse_block(rest) do
      parse_match_cases(rest, [{pattern, guard, body} | acc])
    end
  end

  defp parse_match_cases([:dedent | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_match_cases([:newline | rest], acc) do
    parse_match_cases(rest, acc)
  end

  defp parse_match_cases(rest, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  @spec parse_match_guard([Lexer.token()]) ::
          {:ok, ast_node() | nil, [Lexer.token()]} | {:error, String.t()}
  defp parse_match_guard([{:keyword, _, "if"} | rest]) do
    with {:ok, guard_expr, rest} <- parse_expression(rest) do
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

      parse_match_or({:match_or, [line: node_line(left)], alts}, rest)
    end
  end

  defp parse_match_or(pattern, rest), do: {:ok, pattern, rest}

  @spec parse_match_pattern_atom([Lexer.token()]) ::
          {:ok, match_pattern(), [Lexer.token()]} | {:error, String.t()}
  defp parse_match_pattern_atom([{:name, line, "_"} | rest]) do
    {:ok, {:match_wildcard, [line: line], []}, rest}
  end

  defp parse_match_pattern_atom([{:keyword, line, "None"} | rest]) do
    {:ok, {:lit, [line: line], [nil]}, rest}
  end

  defp parse_match_pattern_atom([{:keyword, line, "True"} | rest]) do
    {:ok, {:lit, [line: line], [true]}, rest}
  end

  defp parse_match_pattern_atom([{:keyword, line, "False"} | rest]) do
    {:ok, {:lit, [line: line], [false]}, rest}
  end

  defp parse_match_pattern_atom([{:integer, line, value} | rest]) do
    {:ok, {:lit, [line: line], [value]}, rest}
  end

  defp parse_match_pattern_atom([{:float, line, value} | rest]) do
    {:ok, {:lit, [line: line], [value]}, rest}
  end

  defp parse_match_pattern_atom([{:op, line, :minus}, {:integer, _, value} | rest]) do
    {:ok, {:lit, [line: line], [-value]}, rest}
  end

  defp parse_match_pattern_atom([{:op, line, :minus}, {:float, _, value} | rest]) do
    {:ok, {:lit, [line: line], [-value]}, rest}
  end

  defp parse_match_pattern_atom([{:string, line, value} | rest]) do
    {:ok, {:lit, [line: line], [value]}, rest}
  end

  defp parse_match_pattern_atom([{:fstring, line, parts} | rest]) do
    {:ok, {:fstring, [line: line], [parts]}, rest}
  end

  defp parse_match_pattern_atom([{:op, _, :star}, {:name, line, "_"} | rest]) do
    {:ok, {:match_star, [line: line], [nil]}, rest}
  end

  defp parse_match_pattern_atom([{:op, _, :star}, {:name, line, name} | rest]) do
    {:ok, {:match_star, [line: line], [name]}, rest}
  end

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

  defp parse_match_pattern_atom(tokens) do
    {:error, "unexpected token in match pattern at #{token_line(tokens)}"}
  end

  @spec parse_match_pattern_list([Lexer.token()], [match_pattern()]) ::
          {:ok, [match_pattern()], [Lexer.token()]} | {:error, String.t()}
  defp parse_match_pattern_list([{:op, _, :rbracket} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

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
  defp parse_match_pattern_tuple([{:op, _, :rparen} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_match_pattern_tuple(tokens, acc) do
    with {:ok, pattern, rest} <- parse_match_pattern(tokens) do
      case rest do
        [{:op, _, :comma} | rest] -> parse_match_pattern_tuple(rest, [pattern | acc])
        [{:op, _, :rparen} | rest] -> {:ok, Enum.reverse([pattern | acc]), rest}
        _ -> {:error, "expected ',' or ')' in match pattern tuple at #{token_line(rest)}"}
      end
    end
  end

  @spec parse_match_mapping_entries([Lexer.token()], [{ast_node(), match_pattern()}]) ::
          {:ok, [{ast_node(), match_pattern()}], [Lexer.token()]} | {:error, String.t()}
  defp parse_match_mapping_entries([{:op, _, :rbrace} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

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
          {:ok, ast_node(), [Lexer.token()]} | {:error, String.t()}
  defp parse_match_mapping_key([{:string, line, value} | rest]) do
    {:ok, {:lit, [line: line], [value]}, rest}
  end

  defp parse_match_mapping_key([{:integer, line, value} | rest]) do
    {:ok, {:lit, [line: line], [value]}, rest}
  end

  defp parse_match_mapping_key([{:float, line, value} | rest]) do
    {:ok, {:lit, [line: line], [value]}, rest}
  end

  defp parse_match_mapping_key([{:keyword, line, "None"} | rest]) do
    {:ok, {:lit, [line: line], [nil]}, rest}
  end

  defp parse_match_mapping_key([{:keyword, line, "True"} | rest]) do
    {:ok, {:lit, [line: line], [true]}, rest}
  end

  defp parse_match_mapping_key([{:keyword, line, "False"} | rest]) do
    {:ok, {:lit, [line: line], [false]}, rest}
  end

  defp parse_match_mapping_key(tokens) do
    {:error, "expected literal key in match mapping at #{token_line(tokens)}"}
  end

  @spec parse_match_class_args(
          [Lexer.token()],
          [match_pattern()],
          [{String.t(), match_pattern()}]
        ) ::
          {:ok, [match_pattern()], [{String.t(), match_pattern()}], [Lexer.token()]}
          | {:error, String.t()}
  defp parse_match_class_args([{:op, _, :rparen} | rest], pos_acc, kw_acc) do
    {:ok, Enum.reverse(pos_acc), Enum.reverse(kw_acc), rest}
  end

  defp parse_match_class_args(
         [{:name, _, name}, {:op, _, :assign} | rest],
         pos_acc,
         kw_acc
       ) do
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

  @spec parse_inline_body([Lexer.token()]) :: parse_result()
  defp parse_inline_body(tokens) do
    parse_statement(tokens)
  end

  @spec parse_expression([Lexer.token()]) :: parse_result()
  defp parse_expression([{:name, line, name}, {:op, _, :walrus} | rest]) do
    with {:ok, expr, rest} <- parse_expression(rest) do
      {:ok, {:walrus, [line: line], [name, expr]}, rest}
    end
  end

  defp parse_expression(tokens) do
    with {:ok, expr, rest} <- parse_or(tokens) do
      parse_ternary(expr, rest)
    end
  end

  @spec parse_ternary(ast_node(), [Lexer.token()]) :: parse_result()
  defp parse_ternary(true_expr, [{:keyword, _, "if"} | rest]) do
    with {:ok, condition, rest} <- parse_or(rest) do
      case rest do
        [{:keyword, _, "else"} | rest] ->
          with {:ok, false_expr, rest} <- parse_expression(rest) do
            line = node_line(true_expr)
            {:ok, {:ternary, [line: line], [condition, true_expr, false_expr]}, rest}
          end

        _ ->
          {:error, "expected 'else' in ternary expression at #{token_line(rest)}"}
      end
    end
  end

  defp parse_ternary(expr, rest), do: {:ok, expr, rest}

  @spec parse_or([Lexer.token()]) :: parse_result()
  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens) do
      parse_or_rest(left, rest)
    end
  end

  @spec parse_or_rest(ast_node(), [Lexer.token()]) :: parse_result()
  defp parse_or_rest(left, [{:keyword, _, "or"} | rest]) do
    with {:ok, right, rest} <- parse_and(rest) do
      line = node_line(left)
      parse_or_rest({:binop, [line: line], [:or, left, right]}, rest)
    end
  end

  defp parse_or_rest(left, rest), do: {:ok, left, rest}

  @spec parse_and([Lexer.token()]) :: parse_result()
  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_not(tokens) do
      parse_and_rest(left, rest)
    end
  end

  @spec parse_and_rest(ast_node(), [Lexer.token()]) :: parse_result()
  defp parse_and_rest(left, [{:keyword, _, "and"} | rest]) do
    with {:ok, right, rest} <- parse_not(rest) do
      line = node_line(left)
      parse_and_rest({:binop, [line: line], [:and, left, right]}, rest)
    end
  end

  defp parse_and_rest(left, rest), do: {:ok, left, rest}

  @spec parse_not([Lexer.token()]) :: parse_result()
  defp parse_not([{:keyword, line, "not"} | rest]) do
    with {:ok, expr, rest} <- parse_not(rest) do
      {:ok, {:unaryop, [line: line], [:not, expr]}, rest}
    end
  end

  defp parse_not(tokens), do: parse_comparison(tokens)

  @spec parse_comparison([Lexer.token()]) :: parse_result()
  defp parse_comparison(tokens) do
    with {:ok, left, rest} <- parse_bitor(tokens) do
      parse_comparison_chain(left, [], [], rest)
    end
  end

  @comparison_ops [:eq, :neq, :lt, :gt, :lte, :gte]

  @spec parse_comparison_chain(ast_node(), [atom()], [ast_node()], [Lexer.token()]) ::
          parse_result()
  defp parse_comparison_chain(first, ops_acc, operands_acc, [{:op, _, op} | rest])
       when op in @comparison_ops do
    with {:ok, right, rest} <- parse_bitor(rest) do
      parse_comparison_chain(first, ops_acc ++ [op], operands_acc ++ [right], rest)
    end
  end

  defp parse_comparison_chain(
         first,
         ops_acc,
         operands_acc,
         [{:keyword, _, "not"}, {:keyword, _, "in"} | rest]
       ) do
    with {:ok, right, rest} <- parse_bitor(rest) do
      parse_comparison_chain(first, ops_acc ++ [:not_in], operands_acc ++ [right], rest)
    end
  end

  defp parse_comparison_chain(first, ops_acc, operands_acc, [{:keyword, _, "in"} | rest]) do
    with {:ok, right, rest} <- parse_bitor(rest) do
      parse_comparison_chain(first, ops_acc ++ [:in], operands_acc ++ [right], rest)
    end
  end

  defp parse_comparison_chain(
         first,
         ops_acc,
         operands_acc,
         [{:keyword, _, "is"}, {:keyword, _, "not"} | rest]
       ) do
    with {:ok, right, rest} <- parse_bitor(rest) do
      parse_comparison_chain(first, ops_acc ++ [:is_not], operands_acc ++ [right], rest)
    end
  end

  defp parse_comparison_chain(first, ops_acc, operands_acc, [{:keyword, _, "is"} | rest]) do
    with {:ok, right, rest} <- parse_bitor(rest) do
      parse_comparison_chain(first, ops_acc ++ [:is], operands_acc ++ [right], rest)
    end
  end

  defp parse_comparison_chain(first, [], [], rest) do
    {:ok, first, rest}
  end

  defp parse_comparison_chain(first, [op], [right], rest) do
    line = node_line(first)
    {:ok, {:binop, [line: line], [op, first, right]}, rest}
  end

  defp parse_comparison_chain(first, ops, operands, rest) do
    line = node_line(first)
    {:ok, {:chained_compare, [line: line], [ops, [first | operands]]}, rest}
  end

  @spec parse_bitor([Lexer.token()]) :: parse_result()
  defp parse_bitor(tokens) do
    with {:ok, left, rest} <- parse_bitxor(tokens) do
      parse_bitor_rest(left, rest)
    end
  end

  @spec parse_bitor_rest(ast_node(), [Lexer.token()]) :: parse_result()
  defp parse_bitor_rest(left, [{:op, _, :pipe} | rest]) do
    with {:ok, right, rest} <- parse_bitxor(rest) do
      line = node_line(left)
      parse_bitor_rest({:binop, [line: line], [:pipe, left, right]}, rest)
    end
  end

  defp parse_bitor_rest(left, rest), do: {:ok, left, rest}

  @spec parse_bitxor([Lexer.token()]) :: parse_result()
  defp parse_bitxor(tokens) do
    with {:ok, left, rest} <- parse_bitand(tokens) do
      parse_bitxor_rest(left, rest)
    end
  end

  @spec parse_bitxor_rest(ast_node(), [Lexer.token()]) :: parse_result()
  defp parse_bitxor_rest(left, [{:op, _, :caret} | rest]) do
    with {:ok, right, rest} <- parse_bitand(rest) do
      line = node_line(left)
      parse_bitxor_rest({:binop, [line: line], [:caret, left, right]}, rest)
    end
  end

  defp parse_bitxor_rest(left, rest), do: {:ok, left, rest}

  @spec parse_bitand([Lexer.token()]) :: parse_result()
  defp parse_bitand(tokens) do
    with {:ok, left, rest} <- parse_shift(tokens) do
      parse_bitand_rest(left, rest)
    end
  end

  @spec parse_bitand_rest(ast_node(), [Lexer.token()]) :: parse_result()
  defp parse_bitand_rest(left, [{:op, _, :amp} | rest]) do
    with {:ok, right, rest} <- parse_shift(rest) do
      line = node_line(left)
      parse_bitand_rest({:binop, [line: line], [:amp, left, right]}, rest)
    end
  end

  defp parse_bitand_rest(left, rest), do: {:ok, left, rest}

  @spec parse_shift([Lexer.token()]) :: parse_result()
  defp parse_shift(tokens) do
    with {:ok, left, rest} <- parse_addition(tokens) do
      parse_shift_rest(left, rest)
    end
  end

  @spec parse_shift_rest(ast_node(), [Lexer.token()]) :: parse_result()
  defp parse_shift_rest(left, [{:op, _, op} | rest]) when op in [:lshift, :rshift] do
    with {:ok, right, rest} <- parse_addition(rest) do
      line = node_line(left)
      parse_shift_rest({:binop, [line: line], [op, left, right]}, rest)
    end
  end

  defp parse_shift_rest(left, rest), do: {:ok, left, rest}

  @spec parse_addition([Lexer.token()]) :: parse_result()
  defp parse_addition(tokens) do
    with {:ok, left, rest} <- parse_multiplication(tokens) do
      parse_addition_rest(left, rest)
    end
  end

  @spec parse_addition_rest(ast_node(), [Lexer.token()]) :: parse_result()
  defp parse_addition_rest(left, [{:op, _, op} | rest]) when op in [:plus, :minus] do
    with {:ok, right, rest} <- parse_multiplication(rest) do
      line = node_line(left)
      parse_addition_rest({:binop, [line: line], [op, left, right]}, rest)
    end
  end

  defp parse_addition_rest(left, rest), do: {:ok, left, rest}

  @spec parse_multiplication([Lexer.token()]) :: parse_result()
  defp parse_multiplication(tokens) do
    with {:ok, left, rest} <- parse_unary(tokens) do
      parse_multiplication_rest(left, rest)
    end
  end

  @mult_ops [:star, :slash, :floor_div, :percent]

  @spec parse_multiplication_rest(ast_node(), [Lexer.token()]) :: parse_result()
  defp parse_multiplication_rest(left, [{:op, _, op} | rest]) when op in @mult_ops do
    with {:ok, right, rest} <- parse_unary(rest) do
      line = node_line(left)
      parse_multiplication_rest({:binop, [line: line], [op, left, right]}, rest)
    end
  end

  defp parse_multiplication_rest(left, rest), do: {:ok, left, rest}

  @spec parse_unary([Lexer.token()]) :: parse_result()
  defp parse_unary([{:op, line, :minus} | rest]) do
    with {:ok, expr, rest} <- parse_unary(rest) do
      {:ok, {:unaryop, [line: line], [:neg, expr]}, rest}
    end
  end

  defp parse_unary([{:op, line, :plus} | rest]) do
    with {:ok, expr, rest} <- parse_unary(rest) do
      {:ok, {:unaryop, [line: line], [:pos, expr]}, rest}
    end
  end

  defp parse_unary([{:op, line, :tilde} | rest]) do
    with {:ok, expr, rest} <- parse_unary(rest) do
      {:ok, {:unaryop, [line: line], [:bitnot, expr]}, rest}
    end
  end

  defp parse_unary(tokens), do: parse_power(tokens)

  @spec parse_power([Lexer.token()]) :: parse_result()
  defp parse_power(tokens) do
    with {:ok, base, rest} <- parse_postfix(tokens) do
      case rest do
        [{:op, _, :double_star} | rest] ->
          with {:ok, exp, rest} <- parse_unary(rest) do
            line = node_line(base)
            {:ok, {:binop, [line: line], [:double_star, base, exp]}, rest}
          end

        _ ->
          {:ok, base, rest}
      end
    end
  end

  @spec parse_postfix([Lexer.token()]) :: parse_result()
  defp parse_postfix(tokens) do
    with {:ok, expr, rest} <- parse_atom(tokens) do
      parse_postfix_rest(expr, rest)
    end
  end

  @spec parse_postfix_rest(ast_node(), [Lexer.token()]) :: parse_result()
  defp parse_postfix_rest(expr, [{:op, _, :lparen} | rest]) do
    with {:ok, args, rest} <- parse_args(rest) do
      line = node_line(expr)
      parse_postfix_rest({:call, [line: line], [expr, args]}, rest)
    end
  end

  defp parse_postfix_rest(expr, [{:op, _, :dot}, {:name, line, attr} | rest]) do
    parse_postfix_rest({:getattr, [line: line], [expr, attr]}, rest)
  end

  defp parse_postfix_rest(expr, [{:op, _, :lbracket}, {:op, _, :colon} | rest]) do
    line = node_line(expr)
    parse_slice_after_colon(expr, line, nil, rest)
  end

  defp parse_postfix_rest(expr, [{:op, _, :lbracket} | rest]) do
    with {:ok, key, rest} <- parse_expression(rest) do
      case rest do
        [{:op, _, :rbracket} | rest] ->
          line = node_line(expr)
          parse_postfix_rest({:subscript, [line: line], [expr, key]}, rest)

        [{:op, _, :colon} | rest] ->
          line = node_line(expr)
          parse_slice_after_colon(expr, line, key, rest)

        _ ->
          {:error, "expected ']' at #{token_line(rest)}"}
      end
    end
  end

  defp parse_postfix_rest(expr, rest), do: {:ok, expr, rest}

  @spec parse_slice_after_colon(ast_node(), non_neg_integer(), ast_node() | nil, [Lexer.token()]) ::
          parse_result()
  defp parse_slice_after_colon(expr, line, start, [{:op, _, :rbracket} | rest]) do
    node = {:slice, [line: line], [expr, start, nil, nil]}
    parse_postfix_rest(node, rest)
  end

  defp parse_slice_after_colon(expr, line, start, [{:op, _, :colon} | rest]) do
    parse_slice_step(expr, line, start, nil, rest)
  end

  defp parse_slice_after_colon(expr, line, start, rest) do
    with {:ok, stop, rest} <- parse_expression(rest) do
      case rest do
        [{:op, _, :rbracket} | rest] ->
          node = {:slice, [line: line], [expr, start, stop, nil]}
          parse_postfix_rest(node, rest)

        [{:op, _, :colon} | rest] ->
          parse_slice_step(expr, line, start, stop, rest)

        _ ->
          {:error, "expected ']' or ':' in slice at #{token_line(rest)}"}
      end
    end
  end

  @spec parse_slice_step(ast_node(), non_neg_integer(), ast_node() | nil, ast_node() | nil, [
          Lexer.token()
        ]) :: parse_result()
  defp parse_slice_step(expr, line, start, stop, [{:op, _, :rbracket} | rest]) do
    node = {:slice, [line: line], [expr, start, stop, nil]}
    parse_postfix_rest(node, rest)
  end

  defp parse_slice_step(expr, line, start, stop, rest) do
    with {:ok, step, rest} <- parse_expression(rest) do
      case rest do
        [{:op, _, :rbracket} | rest] ->
          node = {:slice, [line: line], [expr, start, stop, step]}
          parse_postfix_rest(node, rest)

        _ ->
          {:error, "expected ']' after slice step at #{token_line(rest)}"}
      end
    end
  end

  @spec parse_args([Lexer.token()], [ast_node()]) ::
          {:ok, [ast_node()], [Lexer.token()]} | {:error, String.t()}
  defp parse_args(tokens, acc \\ [])

  defp parse_args([{:op, _, :rparen} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_args([{:op, _, :comma} | rest], acc) do
    parse_args(rest, acc)
  end

  defp parse_args([{:op, line, :double_star} | rest], acc) do
    with {:ok, expr, rest} <- parse_expression(rest) do
      parse_args(rest, [{:double_star_arg, [line: line], [expr]} | acc])
    end
  end

  defp parse_args([{:op, line, :star} | rest], acc) do
    with {:ok, expr, rest} <- parse_expression(rest) do
      parse_args(rest, [{:star_arg, [line: line], [expr]} | acc])
    end
  end

  defp parse_args([{:name, line, name}, {:op, _, :assign} | rest], acc) do
    with {:ok, expr, rest} <- parse_expression(rest) do
      parse_args(rest, [{:kwarg, [line: line], [name, expr]} | acc])
    end
  end

  defp parse_args(tokens, acc) do
    with {:ok, expr, rest} <- parse_or(tokens) do
      case rest do
        [{:keyword, _, "for"} | for_rest] ->
          line = node_line(expr)

          case parse_gen_expr_body(expr, for_rest, line) do
            {:ok, gen_expr, [{:op, _, :rparen} | rest]} ->
              {:ok, Enum.reverse([gen_expr | acc]), rest}

            {:ok, _gen_expr, rest} ->
              {:error, "expected ')' after generator expression at #{token_line(rest)}"}

            {:error, _} = error ->
              error
          end

        [{:keyword, _, "if"} | _] = if_rest ->
          with {:ok, full_expr, rest} <- parse_ternary(expr, if_rest) do
            case rest do
              [{:keyword, _, "for"} | for_rest] ->
                line = node_line(full_expr)

                case parse_gen_expr_body(full_expr, for_rest, line) do
                  {:ok, gen_expr, [{:op, _, :rparen} | rest]} ->
                    {:ok, Enum.reverse([gen_expr | acc]), rest}

                  {:ok, _gen_expr, rest} ->
                    {:error, "expected ')' after generator expression at #{token_line(rest)}"}

                  {:error, _} = error ->
                    error
                end

              _ ->
                parse_args(rest, [full_expr | acc])
            end
          end

        _ ->
          parse_args(rest, [expr | acc])
      end
    end
  end

  @spec parse_atom([Lexer.token()]) :: parse_result()
  defp parse_atom([{:integer, line, n} | rest]), do: {:ok, {:lit, [line: line], [n]}, rest}
  defp parse_atom([{:float, line, n} | rest]), do: {:ok, {:lit, [line: line], [n]}, rest}
  defp parse_atom([{:string, line, s} | rest]), do: {:ok, {:lit, [line: line], [s]}, rest}

  defp parse_atom([{:fstring, line, template} | rest]) do
    case parse_fstring_parts(template, line) do
      {:ok, parts} -> {:ok, {:fstring, [line: line], [parts]}, rest}
      {:error, _} = error -> error
    end
  end

  defp parse_atom([{:keyword, line, "True"} | rest]),
    do: {:ok, {:lit, [line: line], [true]}, rest}

  defp parse_atom([{:keyword, line, "False"} | rest]),
    do: {:ok, {:lit, [line: line], [false]}, rest}

  defp parse_atom([{:keyword, line, "None"} | rest]),
    do: {:ok, {:lit, [line: line], [nil]}, rest}

  defp parse_atom([{:name, line, name} | rest]), do: {:ok, {:var, [line: line], [name]}, rest}

  defp parse_atom([{:keyword, line, "lambda"} | rest]) do
    parse_lambda(rest, line)
  end

  defp parse_atom([{:op, line, :lparen} | rest]) do
    case rest do
      [{:op, _, :rparen} | rest] ->
        {:ok, {:tuple, [line: line], [[]]}, rest}

      _ ->
        with {:ok, expr, rest} <- parse_expression(rest) do
          case rest do
            [{:keyword, _, "for"} | for_rest] ->
              parse_gen_expr(expr, for_rest, line, :rparen)

            [{:op, _, :comma} | rest] ->
              parse_tuple_rest(rest, line, [expr])

            [{:op, _, :rparen} | rest] ->
              {:ok, expr, rest}

            _ ->
              {:error, "expected ')' at #{token_line(rest)}"}
          end
        end
    end
  end

  defp parse_atom([{:op, line, :lbracket} | rest]) do
    parse_list_literal(rest, line)
  end

  defp parse_atom([{:op, line, :lbrace} | rest]) do
    parse_dict_literal(rest, line)
  end

  defp parse_atom([{:keyword, line, "await"} | _]) do
    {:error,
     "NotImplementedError: 'await' is not supported. " <>
       "Call functions directly instead of awaiting them (line #{line})"}
  end

  defp parse_atom([{:keyword, line, "async"} | _]) do
    {:error,
     "NotImplementedError: 'async' is not supported. " <>
       "Write synchronous code instead (line #{line})"}
  end

  defp parse_atom([]) do
    {:error, "unexpected end of input"}
  end

  defp parse_atom(tokens) do
    {:error, "unexpected token at #{token_line(tokens)}: #{inspect_tokens(tokens)}"}
  end

  @spec parse_list_literal([Lexer.token()], pos_integer()) :: parse_result()
  defp parse_list_literal([{:op, _, :rbracket} | rest], line) do
    {:ok, {:list, [line: line], [[]]}, rest}
  end

  defp parse_list_literal(tokens, line) do
    with {:ok, expr, rest} <- parse_or(tokens) do
      case rest do
        [{:keyword, _, "for"} | rest] ->
          parse_list_comp(expr, rest, line)

        [{:keyword, _, "if"} | _] = rest ->
          with {:ok, full_expr, rest} <- parse_ternary(expr, rest) do
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

  @spec parse_list_elements_rest([Lexer.token()], pos_integer(), [ast_node()]) :: parse_result()
  defp parse_list_elements_rest(rest, line, acc) do
    case rest do
      [{:op, _, :comma} | rest] ->
        parse_list_elements(rest, line, acc)

      [{:op, _, :rbracket} | rest] ->
        {:ok, {:list, [line: line], [Enum.reverse(acc)]}, rest}

      _ ->
        {:error, "expected ',' or ']' in list at #{token_line(rest)}"}
    end
  end

  @spec parse_list_elements([Lexer.token()], pos_integer(), [ast_node()]) :: parse_result()
  defp parse_list_elements([{:op, _, :rbracket} | rest], line, acc) do
    {:ok, {:list, [line: line], [Enum.reverse(acc)]}, rest}
  end

  defp parse_list_elements(tokens, line, acc) do
    with {:ok, expr, rest} <- parse_expression(tokens) do
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

  @spec parse_list_comp(ast_node(), [Lexer.token()], pos_integer()) :: parse_result()
  defp parse_list_comp(expr, [{:name, _, first_name}, {:op, _, :comma} | rest], line) do
    case collect_for_vars(rest, [first_name]) do
      {:ok, var_names, rest} ->
        with {:ok, iterable, rest} <- parse_or(rest),
             {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
          all_clauses = [{:comp_for, var_names, iterable} | clauses]

          case rest do
            [{:op, _, :rbracket} | rest] ->
              {:ok, {:list_comp, [line: line], [expr, all_clauses]}, rest}

            _ ->
              {:error, "expected ']' after list comprehension at #{token_line(rest)}"}
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_list_comp(expr, [{:name, _, var_name}, {:keyword, _, "in"} | rest], line) do
    with {:ok, iterable, rest} <- parse_or(rest),
         {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
      all_clauses = [{:comp_for, var_name, iterable} | clauses]

      case rest do
        [{:op, _, :rbracket} | rest] ->
          {:ok, {:list_comp, [line: line], [expr, all_clauses]}, rest}

        _ ->
          {:error, "expected ']' after list comprehension at #{token_line(rest)}"}
      end
    end
  end

  defp parse_list_comp(_expr, tokens, _line) do
    {:error, "expected variable name after 'for' in list comprehension at #{token_line(tokens)}"}
  end

  @spec parse_gen_expr(ast_node(), [Lexer.token()], pos_integer(), :rparen) :: parse_result()
  defp parse_gen_expr(expr, [{:name, _, first_name}, {:op, _, :comma} | rest], line, _closer) do
    case collect_for_vars(rest, [first_name]) do
      {:ok, var_names, rest} ->
        with {:ok, iterable, rest} <- parse_or(rest),
             {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
          all_clauses = [{:comp_for, var_names, iterable} | clauses]

          case rest do
            [{:op, _, :rparen} | rest] ->
              {:ok, {:gen_expr, [line: line], [expr, all_clauses]}, rest}

            _ ->
              {:error, "expected ')' after generator expression at #{token_line(rest)}"}
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_gen_expr(expr, [{:name, _, var_name}, {:keyword, _, "in"} | rest], line, _closer) do
    with {:ok, iterable, rest} <- parse_or(rest),
         {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
      all_clauses = [{:comp_for, var_name, iterable} | clauses]

      case rest do
        [{:op, _, :rparen} | rest] ->
          {:ok, {:gen_expr, [line: line], [expr, all_clauses]}, rest}

        _ ->
          {:error, "expected ')' after generator expression at #{token_line(rest)}"}
      end
    end
  end

  defp parse_gen_expr(_expr, tokens, _line, _closer) do
    {:error,
     "expected variable name after 'for' in generator expression at #{token_line(tokens)}"}
  end

  @spec parse_gen_expr_body(ast_node(), [Lexer.token()], pos_integer()) :: parse_result()
  defp parse_gen_expr_body(
         expr,
         [{:name, _, first_name}, {:op, _, :comma} | rest],
         line
       ) do
    case collect_for_vars(rest, [first_name]) do
      {:ok, var_names, rest} ->
        with {:ok, iterable, rest} <- parse_or(rest),
             {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
          all_clauses = [{:comp_for, var_names, iterable} | clauses]
          {:ok, {:gen_expr, [line: line], [expr, all_clauses]}, rest}
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_gen_expr_body(
         expr,
         [{:name, _, var_name}, {:keyword, _, "in"} | rest],
         line
       ) do
    with {:ok, iterable, rest} <- parse_or(rest),
         {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
      all_clauses = [{:comp_for, var_name, iterable} | clauses]
      {:ok, {:gen_expr, [line: line], [expr, all_clauses]}, rest}
    end
  end

  defp parse_gen_expr_body(_expr, tokens, _line) do
    {:error,
     "expected variable name after 'for' in generator expression at #{token_line(tokens)}"}
  end

  @spec parse_dict_literal([Lexer.token()], pos_integer()) :: parse_result()
  defp parse_dict_literal([{:op, _, :rbrace} | rest], line) do
    {:ok, {:dict, [line: line], [[]]}, rest}
  end

  defp parse_dict_literal(tokens, line) do
    parse_dict_entries(tokens, line, [])
  end

  @spec parse_dict_entries([Lexer.token()], pos_integer(), [{ast_node(), ast_node()}]) ::
          parse_result()
  defp parse_dict_entries(tokens, line, acc) do
    with {:ok, key, rest} <- parse_or(tokens) do
      case rest do
        [{:op, _, :colon} | rest] ->
          with {:ok, value, rest} <- parse_or(rest) do
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

  @spec parse_set_entries([Lexer.token()], pos_integer(), [ast_node()]) :: parse_result()
  defp parse_set_entries([{:op, _, :rbrace} | rest], line, acc) do
    {:ok, {:set, [line: line], [Enum.reverse(acc)]}, rest}
  end

  defp parse_set_entries(tokens, line, acc) do
    with {:ok, elem, rest} <- parse_or(tokens) do
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

  @spec parse_set_comp(ast_node(), [Lexer.token()], pos_integer()) :: parse_result()
  defp parse_set_comp(expr, [{:name, _, first_name}, {:op, _, :comma} | rest], line) do
    case collect_for_vars(rest, [first_name]) do
      {:ok, var_names, rest} ->
        with {:ok, iterable, rest} <- parse_or(rest),
             {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
          all_clauses = [{:comp_for, var_names, iterable} | clauses]

          case rest do
            [{:op, _, :rbrace} | rest] ->
              {:ok, {:set_comp, [line: line], [expr, all_clauses]}, rest}

            _ ->
              {:error, "expected '}' after set comprehension at #{token_line(rest)}"}
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_set_comp(expr, [{:name, _, var_name}, {:keyword, _, "in"} | rest], line) do
    with {:ok, iterable, rest} <- parse_or(rest),
         {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
      all_clauses = [{:comp_for, var_name, iterable} | clauses]

      case rest do
        [{:op, _, :rbrace} | rest] ->
          {:ok, {:set_comp, [line: line], [expr, all_clauses]}, rest}

        _ ->
          {:error, "expected '}' after set comprehension at #{token_line(rest)}"}
      end
    end
  end

  defp parse_set_comp(_expr, tokens, _line) do
    {:error, "expected variable name in set comprehension at #{token_line(tokens)}"}
  end

  @spec parse_dict_comp(ast_node(), ast_node(), [Lexer.token()], pos_integer()) :: parse_result()
  defp parse_dict_comp(
         key_expr,
         val_expr,
         [{:name, _, first_name}, {:op, _, :comma} | rest],
         line
       ) do
    case collect_for_vars(rest, [first_name]) do
      {:ok, var_names, rest} ->
        with {:ok, iterable, rest} <- parse_or(rest),
             {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
          all_clauses = [{:comp_for, var_names, iterable} | clauses]

          case rest do
            [{:op, _, :rbrace} | rest] ->
              {:ok, {:dict_comp, [line: line], [key_expr, val_expr, all_clauses]}, rest}

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
    with {:ok, iterable, rest} <- parse_or(rest),
         {:ok, clauses, rest} <- parse_comp_clauses(rest, []) do
      all_clauses = [{:comp_for, var_name, iterable} | clauses]

      case rest do
        [{:op, _, :rbrace} | rest] ->
          {:ok, {:dict_comp, [line: line], [key_expr, val_expr, all_clauses]}, rest}

        _ ->
          {:error, "expected '}' after dict comprehension at #{token_line(rest)}"}
      end
    end
  end

  defp parse_dict_comp(_key_expr, _val_expr, tokens, _line) do
    {:error, "expected variable name in dict comprehension at #{token_line(tokens)}"}
  end

  @spec try_multi_assign([Lexer.token()], pos_integer(), [String.t() | {:starred, String.t()}]) ::
          parse_result() | :not_assign
  defp try_multi_assign([{:name, _, name}, {:op, _, :comma} | rest], line, acc) do
    try_multi_assign(rest, line, [name | acc])
  end

  defp try_multi_assign([{:op, _, :star}, {:name, _, name}, {:op, _, :comma} | rest], line, acc) do
    try_multi_assign(rest, line, [{:starred, name} | acc])
  end

  defp try_multi_assign([{:name, _, name}, {:op, _, :assign} | rest], line, acc) do
    names = Enum.reverse([name | acc])

    case parse_comma_exprs(rest) do
      {:ok, exprs, rest} ->
        {:ok, {:multi_assign, [line: line], [names, exprs]}, drop_newline(rest)}

      {:error, _} = error ->
        error
    end
  end

  defp try_multi_assign(
         [{:op, _, :star}, {:name, _, name}, {:op, _, :assign} | rest],
         line,
         acc
       ) do
    names = Enum.reverse([{:starred, name} | acc])

    case parse_comma_exprs(rest) do
      {:ok, exprs, rest} ->
        {:ok, {:multi_assign, [line: line], [names, exprs]}, drop_newline(rest)}

      {:error, _} = error ->
        error
    end
  end

  defp try_multi_assign(_, _line, _acc), do: :not_assign

  @spec parse_comma_exprs([Lexer.token()]) ::
          {:ok, [ast_node()], [Lexer.token()]} | {:error, String.t()}
  defp parse_comma_exprs(tokens) do
    with {:ok, first, rest} <- parse_expression(tokens) do
      parse_comma_exprs_rest(rest, [first])
    end
  end

  @spec parse_comma_exprs_rest([Lexer.token()], [ast_node()]) ::
          {:ok, [ast_node()], [Lexer.token()]} | {:error, String.t()}
  defp parse_comma_exprs_rest([{:op, _, :comma} | rest], acc) do
    with {:ok, expr, rest} <- parse_expression(rest) do
      parse_comma_exprs_rest(rest, [expr | acc])
    end
  end

  defp parse_comma_exprs_rest(rest, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  @spec parse_lambda([Lexer.token()], pos_integer()) :: parse_result()
  defp parse_lambda([{:op, _, :colon} | rest], line) do
    with {:ok, body, rest} <- parse_expression(rest) do
      {:ok, {:lambda, [line: line], [[], body]}, rest}
    end
  end

  defp parse_lambda(tokens, line) do
    with {:ok, params, rest} <- parse_lambda_params(tokens) do
      case rest do
        [{:op, _, :colon} | rest] ->
          with {:ok, body, rest} <- parse_expression(rest) do
            {:ok, {:lambda, [line: line], [params, body]}, rest}
          end

        _ ->
          {:error, "expected ':' in lambda at #{token_line(rest)}"}
      end
    end
  end

  @spec parse_lambda_params([Lexer.token()], [{String.t(), ast_node() | nil}]) ::
          {:ok, [{String.t(), ast_node() | nil}], [Lexer.token()]} | {:error, String.t()}
  defp parse_lambda_params(tokens, acc \\ [])

  defp parse_lambda_params([{:name, _, name}, {:op, _, :assign} | rest], acc) do
    with {:ok, default, rest} <- parse_expression(rest) do
      parse_lambda_params(rest, [{name, default} | acc])
    end
  end

  defp parse_lambda_params([{:name, _, name}, {:op, _, :comma} | rest], acc) do
    parse_lambda_params(rest, [{name, nil} | acc])
  end

  defp parse_lambda_params([{:name, _, name} | rest], acc) do
    {:ok, Enum.reverse([{name, nil} | acc]), rest}
  end

  defp parse_lambda_params(tokens, _acc) do
    {:error, "unexpected token in lambda params at #{token_line(tokens)}"}
  end

  @spec parse_tuple_rest([Lexer.token()], pos_integer(), [ast_node()]) :: parse_result()
  defp parse_tuple_rest([{:op, _, :rparen} | rest], line, acc) do
    {:ok, {:tuple, [line: line], [Enum.reverse(acc)]}, rest}
  end

  defp parse_tuple_rest(tokens, line, acc) do
    with {:ok, expr, rest} <- parse_expression(tokens) do
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

  @spec parse_fstring_parts(String.t(), pos_integer()) ::
          {:ok, [{:lit, String.t()} | {:expr, ast_node()}]} | {:error, String.t()}
  defp parse_fstring_parts(template, line) do
    parse_fstring_parts(template, line, <<>>, [])
  end

  @spec parse_fstring_parts(String.t(), pos_integer(), String.t(), [
          {:lit, String.t()} | {:expr, ast_node()}
        ]) :: {:ok, [{:lit, String.t()} | {:expr, ast_node()}]} | {:error, String.t()}
  defp parse_fstring_parts(<<>>, _line, buf, acc) do
    acc = if buf == "", do: acc, else: [{:lit, buf} | acc]
    {:ok, Enum.reverse(acc)}
  end

  defp parse_fstring_parts(<<"{", rest::binary>>, line, buf, acc) do
    acc = if buf == "", do: acc, else: [{:lit, buf} | acc]

    case extract_brace_content(rest, 0, <<>>) do
      {:ok, expr_str, rest} ->
        case Lexer.tokenize(expr_str) do
          {:ok, tokens} ->
            case parse_expression(tokens) do
              {:ok, expr, _} ->
                parse_fstring_parts(rest, line, <<>>, [{:expr, expr} | acc])

              {:error, msg} ->
                {:error, "f-string expression error: #{msg}"}
            end

          {:error, msg} ->
            {:error, "f-string tokenize error: #{msg}"}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp parse_fstring_parts(<<c, rest::binary>>, line, buf, acc) do
    parse_fstring_parts(rest, line, <<buf::binary, c>>, acc)
  end

  @spec extract_brace_content(String.t(), non_neg_integer(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, String.t()}
  defp extract_brace_content(<<>>, _depth, _acc), do: {:error, "unterminated f-string expression"}

  defp extract_brace_content(<<"}", rest::binary>>, 0, acc), do: {:ok, acc, rest}

  defp extract_brace_content(<<"}", rest::binary>>, depth, acc),
    do: extract_brace_content(rest, depth - 1, <<acc::binary, "}">>)

  defp extract_brace_content(<<"{", rest::binary>>, depth, acc),
    do: extract_brace_content(rest, depth + 1, <<acc::binary, "{">>)

  defp extract_brace_content(<<c, rest::binary>>, depth, acc),
    do: extract_brace_content(rest, depth, <<acc::binary, c>>)

  @spec bare_return?([Lexer.token()]) :: boolean()
  defp bare_return?([:newline | _]), do: true
  defp bare_return?([:dedent | _]), do: true
  defp bare_return?([]), do: true
  defp bare_return?(_), do: false

  @spec collect_return_tuple([Lexer.token()], pos_integer(), [ast_node()]) :: parse_result()
  defp collect_return_tuple(tokens, line, acc) do
    case parse_expression(tokens) do
      {:ok, expr, [{:op, _, :comma} | rest]} ->
        collect_return_tuple(rest, line, [expr | acc])

      {:ok, expr, rest} ->
        tuple_node = {:tuple, [line: line], [Enum.reverse([expr | acc])]}
        {:ok, {:return, [line: line], [tuple_node]}, drop_newline(rest)}

      {:error, _} = error ->
        error
    end
  end

  @spec parse_name_list([Lexer.token()], pos_integer(), :global | :nonlocal) :: parse_result()
  defp parse_name_list([{:name, _, name} | rest], line, kind) do
    collect_name_list(rest, [name], line, kind)
  end

  defp parse_name_list(_, line, kind) do
    {:error, "expected name after '#{kind}' at line #{line}"}
  end

  @spec collect_name_list([Lexer.token()], [String.t()], pos_integer(), :global | :nonlocal) ::
          parse_result()
  defp collect_name_list([{:op, _, :comma}, {:name, _, name} | rest], names, line, kind) do
    collect_name_list(rest, [name | names], line, kind)
  end

  defp collect_name_list(rest, names, line, kind) do
    {:ok, {kind, [line: line], [Enum.reverse(names)]}, drop_newline(rest)}
  end

  @spec drop_newline([Lexer.token()]) :: [Lexer.token()]
  defp drop_newline([:newline | rest]), do: rest
  defp drop_newline(rest), do: rest

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

  @spec token_line([Lexer.token()]) :: String.t()
  defp token_line([{_, line, _} | _]), do: "line #{line}"
  defp token_line(_), do: "end of input"

  @spec node_line(ast_node() | term()) :: pos_integer()
  defp node_line({_, [line: line], _}), do: line
  defp node_line(_), do: 1

  @spec inspect_tokens([Lexer.token()]) :: String.t()
  defp inspect_tokens(tokens) do
    tokens
    |> Enum.take(3)
    |> Enum.map(fn
      {tag, _line, val} -> "#{tag}:#{inspect(val)}"
      token -> inspect(token)
    end)
    |> Enum.join(", ")
  end
end
