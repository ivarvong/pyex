defmodule Pyex.Parser.Imports do
  @moduledoc """
  Import statement parsing helpers for `Pyex.Parser`.

  Keeps `import` and `from ... import ...` parsing isolated from the
  main parser so the top-level statement dispatcher stays smaller
  without changing the public parser API.
  """

  alias Pyex.{Lexer, Parser}

  @typep parse_result :: {:ok, Parser.ast_node(), [Lexer.token()]} | {:error, String.t()}
  @typep import_spec :: {String.t(), String.t() | nil}

  @doc """
  Parses an `import ...` statement body.
  """
  @spec parse_import([Lexer.token()], pos_integer()) :: parse_result()
  def parse_import([{:name, line, first} | rest], _line) do
    {module_name, rest} = parse_dotted_name(first, rest)

    {first_import, rest} = maybe_parse_alias(module_name, rest)

    case rest do
      [{:op, _, :comma} | rest] ->
        case parse_import_list(rest, [first_import]) do
          {:ok, imports, rest} ->
            {:ok, {:import, [line: line], imports}, drop_newline(rest)}

          {:error, _} = error ->
            error
        end

      _ ->
        {:ok, {:import, [line: line], [first_import]}, drop_newline(rest)}
    end
  end

  def parse_import(tokens, line) do
    {:error, "expected module name after 'import' on line #{line} at #{token_line(tokens)}"}
  end

  @doc """
  Parses a `from ... import ...` statement body.
  """
  @spec parse_from_import([Lexer.token()], pos_integer()) :: parse_result()
  def parse_from_import([{:name, _, first} | rest], line) do
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

  def parse_from_import(tokens, line) do
    {:error, "expected module name after 'from' on line #{line} at #{token_line(tokens)}"}
  end

  @spec maybe_parse_alias(String.t(), [Lexer.token()]) :: {import_spec(), [Lexer.token()]}
  defp maybe_parse_alias(module_name, [{:keyword, _, "as"}, {:name, _, alias_name} | rest]) do
    {{module_name, alias_name}, rest}
  end

  defp maybe_parse_alias(module_name, rest) do
    {{module_name, nil}, rest}
  end

  @spec parse_import_list([Lexer.token()], [import_spec()]) ::
          {:ok, [import_spec()], [Lexer.token()]} | {:error, String.t()}
  defp parse_import_list([{:name, _, name} | rest], acc) do
    {module_name, rest} = parse_dotted_name(name, rest)
    {import_spec, rest} = maybe_parse_alias(module_name, rest)

    case rest do
      [{:op, _, :comma} | rest] ->
        parse_import_list(rest, [import_spec | acc])

      _ ->
        {:ok, Enum.reverse([import_spec | acc]), rest}
    end
  end

  defp parse_import_list(tokens, _acc) do
    {:error, "expected module name after ',' at #{token_line(tokens)}"}
  end

  @spec parse_dotted_name(String.t(), [Lexer.token()]) :: {String.t(), [Lexer.token()]}
  defp parse_dotted_name(acc, [{:op, _, :dot}, {:name, _, part} | rest]) do
    parse_dotted_name(acc <> "." <> part, rest)
  end

  defp parse_dotted_name(acc, rest), do: {acc, rest}

  @spec parse_import_names([Lexer.token()]) ::
          {:ok, [import_spec()], [Lexer.token()]} | {:error, String.t()}
  defp parse_import_names(tokens), do: parse_import_names(tokens, [])

  @spec parse_import_names([Lexer.token()], [import_spec()]) ::
          {:ok, [import_spec()], [Lexer.token()]} | {:error, String.t()}
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

  @spec drop_newline([Lexer.token()]) :: [Lexer.token()]
  defp drop_newline([:newline | rest]), do: rest
  defp drop_newline(rest), do: rest

  @spec token_line([Lexer.token()]) :: String.t()
  defp token_line([{_, line, _} | _]), do: "line #{line}"
  defp token_line(_), do: "end of input"
end
