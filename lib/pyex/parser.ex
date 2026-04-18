defmodule Pyex.Parser do
  @moduledoc """
  Transforms a flat token stream from the lexer into an AST.

  The AST uses plain tuples: `{node_type, meta, children}` where
  meta carries line information for error reporting. All parse
  functions return `{:ok, node, rest}` or `{:error, message}`.
  """

  alias Pyex.Lexer
  alias Pyex.Parser.Comprehensions
  alias Pyex.Parser.ControlFlow
  alias Pyex.Parser.Definitions
  alias Pyex.Parser.Imports
  alias Pyex.Parser.Match

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

  @type unpack_target :: String.t() | {:starred, String.t()} | [unpack_target()]

  @type param ::
          {String.t(), ast_node() | nil}
          | {String.t(), ast_node() | nil, String.t()}

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

  @doc false
  @spec parse_block([Lexer.token()]) ::
          {:ok, [ast_node()], [Lexer.token()]} | {:error, String.t()}
  def parse_block(tokens), do: parse_block(tokens, [])

  @spec parse_block([Lexer.token()], [ast_node()]) ::
          {:ok, [ast_node()], [Lexer.token()]} | {:error, String.t()}
  defp parse_block(tokens, acc)
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
    Definitions.parse_function_def(rest)
  end

  defp parse_statement([{:keyword, _line, "class"} | rest]) do
    Definitions.parse_class_def(rest)
  end

  defp parse_statement([{:keyword, line, "with"} | rest]) do
    Definitions.parse_with(rest, line)
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
    ControlFlow.parse_if(rest)
  end

  defp parse_statement([{:keyword, _line, "while"} | rest]) do
    ControlFlow.parse_while(rest)
  end

  defp parse_statement([{:keyword, _line, "for"} | rest]) do
    ControlFlow.parse_for(rest)
  end

  defp parse_statement([{:keyword, line, "from"} | rest]) do
    Imports.parse_from_import(rest, line)
  end

  defp parse_statement([{:keyword, line, "import"} | rest]) do
    Imports.parse_import(rest, line)
  end

  defp parse_statement([{:keyword, _line, "try"} | rest]) do
    ControlFlow.parse_try(rest)
  end

  defp parse_statement([{:keyword, line, "raise"} | rest]) do
    case rest do
      [:newline | _] ->
        {:ok, {:raise, [line: line], [nil]}, drop_newline(rest)}

      [] ->
        {:ok, {:raise, [line: line], [nil]}, []}

      _ ->
        case parse_expression(rest) do
          {:ok, expr, [{:keyword, _, "from"} | rest]} ->
            case parse_expression(rest) do
              {:ok, cause, rest} ->
                {:ok, {:raise, [line: line], [expr, cause]}, drop_newline(rest)}

              {:error, _} = error ->
                error
            end

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
    case parse_expression(rest) do
      {:ok, {:var, _, [var_name]}, rest} ->
        {:ok, {:del, [line: line], [:var, var_name]}, drop_newline(rest)}

      {:ok, {:subscript, _, [target_expr, key_expr]}, rest} ->
        {:ok, {:del, [line: line], [:subscript, target_expr, key_expr]}, drop_newline(rest)}

      {:ok, {:getattr, _, [obj_expr, attr]}, rest} ->
        {:ok, {:del, [line: line], [:attr, obj_expr, attr]}, drop_newline(rest)}

      {:ok, _expr, _rest} ->
        {:error, "expected variable or subscript after 'del' at line #{line}"}

      {:error, _} = error ->
        error
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
    case Match.try_match(rest, line) do
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

  defp parse_statement([{:op, line, :lparen} | _] = tokens) do
    case try_paren_unpack_assign(tokens, line) do
      {:ok, _, _} = result -> result
      :not_assign -> parse_expression_statement(tokens)
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
            parse_subscript_assign_value(rest, line, [{name, key}])

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

          # slice: a[start:stop] = val  or  a[start:stop:step] = val
          [{:op, _, :colon} | slice_rest] ->
            parse_slice_assign(slice_rest, line, name, key)

          # bare slice: a[:stop] = val  or  a[:] = val
          _ ->
            :not_assign
        end

      # bare colon start: a[:stop] = val  or  a[:] = val
      {:error, _} ->
        case tokens do
          [{:op, _, :colon} | slice_rest] ->
            parse_slice_assign(slice_rest, line, name, nil)

          _ ->
            :not_assign
        end
    end
  end

  @spec parse_slice_assign(
          [Lexer.token()],
          pos_integer(),
          String.t(),
          term()
        ) :: parse_result() | :not_assign
  defp parse_slice_assign(tokens, line, name, start_key) do
    {stop_key, tokens} =
      case tokens do
        [{:op, _, :rbracket} | _] = rest ->
          {nil, rest}

        [{:op, _, :colon} | _] = rest ->
          {nil, rest}

        _ ->
          case parse_expression(tokens) do
            {:ok, stop, rest} -> {stop, rest}
            {:error, _} -> {nil, tokens}
          end
      end

    {step_key, tokens} =
      case tokens do
        [{:op, _, :colon} | rest] ->
          case rest do
            [{:op, _, :rbracket} | _] ->
              {nil, rest}

            _ ->
              case parse_expression(rest) do
                {:ok, step, rest} -> {step, rest}
                {:error, _} -> {nil, rest}
              end
          end

        _ ->
          {nil, tokens}
      end

    case tokens do
      [{:op, _, :rbracket}, {:op, _, :assign} | rest] ->
        slice_key =
          {:slice, [line: line], [{:var, [line: line], [name]}, start_key, stop_key, step_key]}

        parse_subscript_assign_value(rest, line, [{name, slice_key}])

      _ ->
        :not_assign
    end
  end

  # Parse the value side of a subscript assignment, handling chained targets like:
  #   a[0] = a[1] = False  →  block(a[1] = False, a[0] = False)
  # `targets` is a list of {name_or_target, key} tuples collected so far.
  @spec parse_subscript_assign_value([Lexer.token()], pos_integer(), list()) ::
          parse_result()
  defp parse_subscript_assign_value(tokens, line, targets) do
    case parse_expression(tokens) do
      {:ok, val_expr, [{:op, _, :assign} | rest]} ->
        # The parsed expression is actually another chained target.
        # Extract the subscript target from the expression.
        case val_expr do
          {:subscript, _, [{:var, _, [next_name]}, next_key]} ->
            parse_subscript_assign_value(rest, line, [{next_name, next_key} | targets])

          {:var, _, [var_name]} ->
            # Mixed chain like a[0] = b = val — desugar as block
            case parse_expression(rest) do
              {:ok, final_val, rest} ->
                assigns =
                  [
                    {:assign, [line: line], [var_name, final_val]}
                    | Enum.map(targets, fn {n, k} ->
                        {:subscript_assign, [line: line], [n, k, final_val]}
                      end)
                  ]

                {:ok, {:block, [line: line], [Enum.reverse(assigns)]}, drop_newline(rest)}

              {:error, _} = error ->
                error
            end

          _ ->
            {:error, "unsupported chained assignment target"}
        end

      {:ok, val, rest} ->
        # No more chaining — emit assignments
        case targets do
          [{single_name, single_key}] ->
            {:ok, {:subscript_assign, [line: line], [single_name, single_key, val]},
             drop_newline(rest)}

          _ ->
            assigns =
              Enum.map(targets, fn {n, k} ->
                {:subscript_assign, [line: line], [n, k, val]}
              end)

            {:ok, {:block, [line: line], [Enum.reverse(assigns)]}, drop_newline(rest)}
        end

      {:error, _} = error ->
        error
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

  @doc false
  @spec expect_block_start([Lexer.token()], String.t()) ::
          {:ok, [Lexer.token()]} | {:error, String.t()}
  def expect_block_start([{:op, _, :colon}, :newline, :indent | rest], _ctx) do
    {:ok, rest}
  end

  def expect_block_start(tokens, ctx) do
    {:error, "expected ':' after #{ctx} at #{token_line(tokens)}"}
  end

  @doc false
  @spec parse_inline_body([Lexer.token()]) :: parse_result()
  def parse_inline_body(tokens) do
    parse_statement(tokens)
  end

  @doc false
  @spec parse_or([Lexer.token()]) :: parse_result()
  def parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens) do
      parse_or_rest(left, rest)
    end
  end

  @doc false
  @spec parse_expression([Lexer.token()]) :: parse_result()
  def parse_expression([{:name, line, name}, {:op, _, :walrus} | rest]) do
    with {:ok, expr, rest} <- parse_expression(rest) do
      {:ok, {:walrus, [line: line], [name, expr]}, rest}
    end
  end

  def parse_expression(tokens) do
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

          case Comprehensions.parse_gen_expr_body(expr, for_rest, line) do
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

                case Comprehensions.parse_gen_expr_body(full_expr, for_rest, line) do
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

  defp parse_atom([{:op, line, :ellipsis} | rest]),
    do: {:ok, {:lit, [line: line], [:ellipsis]}, rest}

  defp parse_atom([{:name, line, name} | rest]), do: {:ok, {:var, [line: line], [name]}, rest}

  defp parse_atom([{:keyword, line, "lambda"} | rest]) do
    parse_lambda(rest, line)
  end

  defp parse_atom([{:op, line, :lparen} | rest]) do
    Comprehensions.parse_parenthesized(rest, line)
  end

  defp parse_atom([{:op, line, :lbracket} | rest]) do
    Comprehensions.parse_list_literal(rest, line)
  end

  defp parse_atom([{:op, line, :lbrace} | rest]) do
    Comprehensions.parse_dict_literal(rest, line)
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

  @spec try_multi_assign([Lexer.token()], pos_integer(), [unpack_target()]) ::
          parse_result() | :not_assign
  defp try_multi_assign([{:name, _, name}, {:op, _, :comma} | rest], line, acc) do
    try_multi_assign(rest, line, [name | acc])
  end

  defp try_multi_assign([{:op, _, :star}, {:name, _, name}, {:op, _, :comma} | rest], line, acc) do
    try_multi_assign(rest, line, [{:starred, name} | acc])
  end

  defp try_multi_assign([{:op, _, :lparen} | _] = tokens, line, acc) do
    case parse_paren_target(tokens) do
      {:ok, nested, [{:op, _, :comma} | rest]} ->
        try_multi_assign(rest, line, [nested | acc])

      {:ok, nested, [{:op, _, :assign} | rest]} ->
        names = Enum.reverse([nested | acc])

        case parse_comma_exprs(rest) do
          {:ok, exprs, rest} ->
            {:ok, {:multi_assign, [line: line], [names, exprs]}, drop_newline(rest)}

          {:error, _} = error ->
            error
        end

      _ ->
        :not_assign
    end
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

  @spec try_paren_unpack_assign([Lexer.token()], pos_integer()) ::
          parse_result() | :not_assign
  defp try_paren_unpack_assign(tokens, line) do
    case parse_paren_target(tokens) do
      {:ok, nested, [{:op, _, :comma} | rest]} ->
        try_multi_assign(rest, line, [nested])

      {:ok, nested, [{:op, _, :assign} | rest]} ->
        names = [nested]

        case parse_comma_exprs(rest) do
          {:ok, exprs, rest} ->
            {:ok, {:multi_assign, [line: line], [names, exprs]}, drop_newline(rest)}

          {:error, _} = error ->
            error
        end

      _ ->
        :not_assign
    end
  end

  @spec parse_paren_target([Lexer.token()]) ::
          {:ok, [unpack_target()], [Lexer.token()]} | :error
  defp parse_paren_target([{:op, _, :lparen} | rest]) do
    parse_paren_target_names(rest, [])
  end

  defp parse_paren_target(_), do: :error

  @spec parse_paren_target_names([Lexer.token()], [unpack_target()]) ::
          {:ok, [unpack_target()], [Lexer.token()]} | :error
  defp parse_paren_target_names([{:name, _, name}, {:op, _, :comma} | rest], acc) do
    parse_paren_target_names(rest, [name | acc])
  end

  defp parse_paren_target_names([{:name, _, name}, {:op, _, :rparen} | rest], acc) do
    {:ok, Enum.reverse([name | acc]), rest}
  end

  defp parse_paren_target_names([{:op, _, :lparen} | _] = tokens, acc) do
    case parse_paren_target(tokens) do
      {:ok, nested, [{:op, _, :comma} | rest]} ->
        parse_paren_target_names(rest, [nested | acc])

      {:ok, nested, [{:op, _, :rparen} | rest]} ->
        {:ok, Enum.reverse([nested | acc]), rest}

      _ ->
        :error
    end
  end

  defp parse_paren_target_names(_, _acc), do: :error

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
      case rest do
        [{:op, _, :comma} | rest] -> parse_lambda_params(rest, [{name, default} | acc])
        _ -> {:ok, Enum.reverse([{name, default} | acc]), rest}
      end
    end
  end

  defp parse_lambda_params([{:name, _, name}, {:op, _, :comma} | rest], acc) do
    parse_lambda_params(rest, [{name, nil} | acc])
  end

  defp parse_lambda_params([{:name, _, name} | rest], acc) do
    {:ok, Enum.reverse([{name, nil} | acc]), rest}
  end

  defp parse_lambda_params([{:op, _, :star}, {:name, _, name} | rest], acc) do
    case rest do
      [{:op, _, :comma} | rest] -> parse_lambda_params(rest, [{"*" <> name, nil} | acc])
      _ -> {:ok, Enum.reverse([{"*" <> name, nil} | acc]), rest}
    end
  end

  defp parse_lambda_params([{:op, _, :double_star}, {:name, _, name} | rest], acc) do
    {:ok, Enum.reverse([{"**" <> name, nil} | acc]), rest}
  end

  defp parse_lambda_params([{:op, _, :colon} | _] = tokens, acc) do
    {:ok, Enum.reverse(acc), tokens}
  end

  defp parse_lambda_params(tokens, _acc) do
    {:error, "unexpected token in lambda params at #{token_line(tokens)}"}
  end

  @doc """
  Parses the body of an f-string or f-string format spec into a list of
  `{:lit, str}` / `{:expr, ast}` / `{:expr, ast, spec}` parts.

  Exported so the interpreter can recursively resolve nested format
  specs (`f"{x:{width}d}"`) without duplicating the tokenization logic.
  """
  @spec parse_fstring_template(String.t()) ::
          {:ok, [{:lit, String.t()} | {:expr, ast_node()} | {:expr, ast_node(), String.t()}]}
          | {:error, String.t()}
  def parse_fstring_template(template), do: parse_fstring_parts(template, 1)

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

  # `{{` is an f-string escape for a literal `{`.
  defp parse_fstring_parts(<<"{{", rest::binary>>, line, buf, acc) do
    parse_fstring_parts(rest, line, <<buf::binary, "{">>, acc)
  end

  # `}}` is an f-string escape for a literal `}`.
  defp parse_fstring_parts(<<"}}", rest::binary>>, line, buf, acc) do
    parse_fstring_parts(rest, line, <<buf::binary, "}">>, acc)
  end

  defp parse_fstring_parts(<<"{", rest::binary>>, line, buf, acc) do
    acc = if buf == "", do: acc, else: [{:lit, buf} | acc]

    case extract_brace_content(rest, 0, <<>>) do
      {:ok, full_content, rest} ->
        {expr_str, conversion, format_spec, debug?} =
          split_fstring_expr_debug(full_content)

        case Lexer.tokenize(expr_str) do
          {:ok, tokens} ->
            case parse_expression(tokens) do
              {:ok, expr, _} ->
                expr_with_conv =
                  case conversion do
                    nil -> expr
                    "r" -> {:call, [line: line], [{:var, [line: line], ["repr"]}, [expr]]}
                    "s" -> {:call, [line: line], [{:var, [line: line], ["str"]}, [expr]]}
                    "a" -> {:call, [line: line], [{:var, [line: line], ["repr"]}, [expr]]}
                    _ -> expr
                  end

                part =
                  case format_spec do
                    nil -> {:expr, expr_with_conv}
                    spec -> {:expr, expr_with_conv, spec}
                  end

                # Debug form `{expr=}` prepends "<expr text>=" as a literal.
                acc =
                  if debug? do
                    [part, {:lit, expr_str <> "="} | acc]
                  else
                    [part | acc]
                  end

                parse_fstring_parts(rest, line, <<>>, acc)

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

  # Variant of split_fstring_expr that also detects the debug form `expr=`.
  # If the expression part (before any `!` conversion or `:` format spec)
  # ends with `=`, CPython prepends the source text as a literal.
  # Returns a 4-tuple with a boolean flag for the debug form.
  @spec split_fstring_expr_debug(String.t()) ::
          {String.t(), String.t() | nil, String.t() | nil, boolean()}
  defp split_fstring_expr_debug(content) do
    # First isolate the expression part (before the first `!` conv or
    # `:` spec at depth 0).  Debug `=` must live within this part.
    {expr_only, rest} = split_expr_from_spec_conv(content)

    case check_debug_equals(expr_only) do
      nil ->
        {e, conv, spec} = split_fstring_expr(content)
        {e, conv, spec, false}

      expr_part ->
        {_, conv, spec} = split_fstring_expr("x" <> rest)
        {String.trim(expr_part), conv, spec, true}
    end
  end

  # Split `content` at the first `:` or `!r/!s/!a` at depth 0 (not inside
  # brackets/parens/strings).  Returns `{expr, rest_including_delimiter}`.
  @spec split_expr_from_spec_conv(String.t()) :: {String.t(), String.t()}
  defp split_expr_from_spec_conv(content) do
    split_esc_loop(content, 0, 0, 0, false, nil, <<>>)
  end

  defp split_esc_loop(<<>>, _b, _p, _s, _in_str, _q, acc), do: {acc, ""}

  defp split_esc_loop(<<q, rest::binary>>, b, p, s, false, nil, acc)
       when q in [?', ?"] do
    split_esc_loop(rest, b, p, s, true, q, <<acc::binary, q>>)
  end

  defp split_esc_loop(<<q, rest::binary>>, b, p, s, true, q, acc) do
    split_esc_loop(rest, b, p, s, false, nil, <<acc::binary, q>>)
  end

  defp split_esc_loop(<<c, rest::binary>>, b, p, s, true, q, acc) do
    split_esc_loop(rest, b, p, s, true, q, <<acc::binary, c>>)
  end

  defp split_esc_loop(<<"[", rest::binary>>, b, p, s, false, nil, acc),
    do: split_esc_loop(rest, b + 1, p, s, false, nil, <<acc::binary, "[">>)

  defp split_esc_loop(<<"]", rest::binary>>, b, p, s, false, nil, acc) when b > 0,
    do: split_esc_loop(rest, b - 1, p, s, false, nil, <<acc::binary, "]">>)

  defp split_esc_loop(<<"(", rest::binary>>, b, p, s, false, nil, acc),
    do: split_esc_loop(rest, b, p + 1, s, false, nil, <<acc::binary, "(">>)

  defp split_esc_loop(<<")", rest::binary>>, b, p, s, false, nil, acc) when p > 0,
    do: split_esc_loop(rest, b, p - 1, s, false, nil, <<acc::binary, ")">>)

  defp split_esc_loop(<<"{", rest::binary>>, b, p, s, false, nil, acc),
    do: split_esc_loop(rest, b, p, s + 1, false, nil, <<acc::binary, "{">>)

  defp split_esc_loop(<<"}", rest::binary>>, b, p, s, false, nil, acc) when s > 0,
    do: split_esc_loop(rest, b, p, s - 1, false, nil, <<acc::binary, "}">>)

  # At depth 0, `:` or `!r/!s/!a` terminates the expression part.
  defp split_esc_loop(<<":", _::binary>> = rest, 0, 0, 0, false, nil, acc) do
    {acc, rest}
  end

  defp split_esc_loop(<<"!", conv, rest::binary>>, 0, 0, 0, false, nil, acc)
       when conv in [?r, ?s, ?a] do
    {acc, <<"!", conv, rest::binary>>}
  end

  defp split_esc_loop(<<c, rest::binary>>, b, p, s, in_str, q, acc) do
    split_esc_loop(rest, b, p, s, in_str, q, <<acc::binary, c>>)
  end

  # If `expr_only` ends with a debug-form `=` (a top-level `=` not part
  # of `==`, `!=`, etc.), return the expression part before the `=`.
  # Otherwise return nil.
  @spec check_debug_equals(String.t()) :: String.t() | nil
  defp check_debug_equals(expr_only) do
    case split_at_debug_eq_loop(expr_only, 0, 0, 0, false, nil, <<>>) do
      {_, nil} -> nil
      {expr, _rest} -> expr
    end
  end

  # Returns `{before_equals, after_equals}` if a top-level `=` is present,
  # else `{acc, nil}`.  Treats `==`, `!=`, `<=`, `>=` as non-debug.
  defp split_at_debug_eq_loop(<<>>, _b, _p, _s, _in_str, _q, _acc), do: {"", nil}

  defp split_at_debug_eq_loop(<<q, rest::binary>>, b, p, s, false, nil, acc)
       when q in [?', ?"] do
    split_at_debug_eq_loop(rest, b, p, s, true, q, <<acc::binary, q>>)
  end

  defp split_at_debug_eq_loop(<<q, rest::binary>>, b, p, s, true, q, acc) do
    split_at_debug_eq_loop(rest, b, p, s, false, nil, <<acc::binary, q>>)
  end

  defp split_at_debug_eq_loop(<<c, rest::binary>>, b, p, s, true, q, acc) do
    split_at_debug_eq_loop(rest, b, p, s, true, q, <<acc::binary, c>>)
  end

  defp split_at_debug_eq_loop(<<"[", rest::binary>>, b, p, s, false, nil, acc),
    do: split_at_debug_eq_loop(rest, b + 1, p, s, false, nil, <<acc::binary, "[">>)

  defp split_at_debug_eq_loop(<<"]", rest::binary>>, b, p, s, false, nil, acc) when b > 0,
    do: split_at_debug_eq_loop(rest, b - 1, p, s, false, nil, <<acc::binary, "]">>)

  defp split_at_debug_eq_loop(<<"(", rest::binary>>, b, p, s, false, nil, acc),
    do: split_at_debug_eq_loop(rest, b, p + 1, s, false, nil, <<acc::binary, "(">>)

  defp split_at_debug_eq_loop(<<")", rest::binary>>, b, p, s, false, nil, acc) when p > 0,
    do: split_at_debug_eq_loop(rest, b, p - 1, s, false, nil, <<acc::binary, ")">>)

  defp split_at_debug_eq_loop(<<"{", rest::binary>>, b, p, s, false, nil, acc),
    do: split_at_debug_eq_loop(rest, b, p, s + 1, false, nil, <<acc::binary, "{">>)

  defp split_at_debug_eq_loop(<<"}", rest::binary>>, b, p, s, false, nil, acc) when s > 0,
    do: split_at_debug_eq_loop(rest, b, p, s - 1, false, nil, <<acc::binary, "}">>)

  defp split_at_debug_eq_loop(<<"==", rest::binary>>, b, p, s, false, nil, acc),
    do: split_at_debug_eq_loop(rest, b, p, s, false, nil, <<acc::binary, "==">>)

  defp split_at_debug_eq_loop(<<"!=", rest::binary>>, b, p, s, false, nil, acc),
    do: split_at_debug_eq_loop(rest, b, p, s, false, nil, <<acc::binary, "!=">>)

  defp split_at_debug_eq_loop(<<"<=", rest::binary>>, b, p, s, false, nil, acc),
    do: split_at_debug_eq_loop(rest, b, p, s, false, nil, <<acc::binary, "<=">>)

  defp split_at_debug_eq_loop(<<">=", rest::binary>>, b, p, s, false, nil, acc),
    do: split_at_debug_eq_loop(rest, b, p, s, false, nil, <<acc::binary, ">=">>)

  defp split_at_debug_eq_loop(<<"=", rest::binary>>, 0, 0, 0, false, nil, acc) do
    {acc, rest}
  end

  defp split_at_debug_eq_loop(<<c, rest::binary>>, b, p, s, in_str, q, acc) do
    split_at_debug_eq_loop(rest, b, p, s, in_str, q, <<acc::binary, c>>)
  end

  @spec extract_brace_content(String.t(), non_neg_integer(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, String.t()}
  # Splits "expr:spec" at the colon that is NOT inside brackets, parens, or strings.
  # Returns {expr_str, format_spec | nil}.
  @spec split_fstring_expr(String.t()) :: {String.t(), String.t() | nil, String.t() | nil}
  defp split_fstring_expr(content) do
    # Extract optional !r / !s / !a conversion before the format spec colon.
    # E.g. "x!r" -> {"x", "r", nil}; "x!r:.2f" -> {"x", "r", ".2f"}
    case Regex.run(~r/^(.*?)!([rsa])(:.*)?\s*$/, content) do
      [_, expr, conv, spec] ->
        spec_str = if spec == "", do: nil, else: String.trim_leading(spec, ":")
        {String.trim(expr), conv, spec_str}

      [_, expr, conv] ->
        {String.trim(expr), conv, nil}

      _ ->
        {expr, spec} = split_format_spec(content)
        {expr, nil, spec}
    end
  end

  @spec split_format_spec(String.t()) :: {String.t(), String.t() | nil}
  defp split_format_spec(content) do
    split_format_spec(content, 0, 0, 0, false, nil, <<>>)
  end

  defp split_format_spec(<<>>, _bd, _pd, _sd, _in_str, _qch, acc),
    do: {acc, nil}

  # Handle string delimiters
  defp split_format_spec(<<q, rest::binary>>, bd, pd, sd, false, nil, acc)
       when q in [?', ?"] do
    split_format_spec(rest, bd, pd, sd, true, q, <<acc::binary, q>>)
  end

  defp split_format_spec(<<q, rest::binary>>, bd, pd, sd, true, q, acc) do
    split_format_spec(rest, bd, pd, sd, false, nil, <<acc::binary, q>>)
  end

  # Don't split inside strings
  defp split_format_spec(<<c, rest::binary>>, bd, pd, sd, true, qch, acc) do
    split_format_spec(rest, bd, pd, sd, true, qch, <<acc::binary, c>>)
  end

  # Track bracket/paren depth
  defp split_format_spec(<<"[", rest::binary>>, bd, pd, sd, in_str, qch, acc),
    do: split_format_spec(rest, bd + 1, pd, sd, in_str, qch, <<acc::binary, "[">>)

  defp split_format_spec(<<"]", rest::binary>>, bd, pd, sd, in_str, qch, acc) when bd > 0,
    do: split_format_spec(rest, bd - 1, pd, sd, in_str, qch, <<acc::binary, "]">>)

  defp split_format_spec(<<"(", rest::binary>>, bd, pd, sd, in_str, qch, acc),
    do: split_format_spec(rest, bd, pd + 1, sd, in_str, qch, <<acc::binary, "(">>)

  defp split_format_spec(<<")", rest::binary>>, bd, pd, sd, in_str, qch, acc) when pd > 0,
    do: split_format_spec(rest, bd, pd - 1, sd, in_str, qch, <<acc::binary, ")">>)

  defp split_format_spec(<<"{", rest::binary>>, bd, pd, sd, in_str, qch, acc),
    do: split_format_spec(rest, bd, pd, sd + 1, in_str, qch, <<acc::binary, "{">>)

  defp split_format_spec(<<"}", rest::binary>>, bd, pd, sd, in_str, qch, acc) when sd > 0,
    do: split_format_spec(rest, bd, pd, sd - 1, in_str, qch, <<acc::binary, "}">>)

  # Colon at depth 0 → split point
  defp split_format_spec(<<":", rest::binary>>, 0, 0, 0, false, nil, acc),
    do: {acc, rest}

  # Regular character
  defp split_format_spec(<<c, rest::binary>>, bd, pd, sd, in_str, qch, acc),
    do: split_format_spec(rest, bd, pd, sd, in_str, qch, <<acc::binary, c>>)

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

  @spec collect_type_annotation([Lexer.token()]) :: {String.t(), [Lexer.token()]}
  defp collect_type_annotation([{:name, _, name} | rest]) do
    {subscript, rest} = collect_type_subscript(rest)
    {name <> subscript, rest}
  end

  defp collect_type_annotation([{:keyword, _, "None"} | rest]), do: {"None", rest}
  defp collect_type_annotation(tokens), do: {"", tokens}

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

  @spec token_line([Lexer.token()]) :: String.t()
  defp token_line([{_, line, _} | _]), do: "line #{line}"
  defp token_line(_), do: "end of input"

  @doc false
  @spec node_line(ast_node() | term()) :: pos_integer()
  def node_line({_, [line: line], _}), do: line
  def node_line(_), do: 1

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
