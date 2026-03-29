defmodule Pyex.Stdlib.Textwrap do
  @moduledoc """
  Python `textwrap` module for text wrapping and dedenting.

  Provides `textwrap.dedent()`, `textwrap.indent()`,
  `textwrap.wrap()`, and `textwrap.fill()`.
  """

  @behaviour Pyex.Stdlib.Module

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "dedent" => {:builtin, &do_dedent/1},
      "indent" => {:builtin, &do_indent/1},
      "wrap" => {:builtin_kw, &do_wrap/2},
      "fill" => {:builtin_kw, &do_fill/2}
    }
  end

  @spec do_dedent([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_dedent([text]) when is_binary(text) do
    lines = String.split(text, "\n")

    prefix =
      lines
      |> Enum.reject(fn line -> String.trim(line) == "" end)
      |> Enum.map(&leading_whitespace/1)
      |> common_prefix()

    prefix_len = String.length(prefix)

    lines
    |> Enum.map_join("\n", fn line ->
      if String.trim(line) == "" do
        line
      else
        String.slice(line, prefix_len, String.length(line))
      end
    end)
  end

  defp do_dedent(_), do: {:exception, "TypeError: dedent() argument must be a string"}

  @spec do_indent([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_indent([text, prefix]) when is_binary(text) and is_binary(prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      if String.trim(line) != "" do
        prefix <> line
      else
        line
      end
    end)
  end

  defp do_indent([text, prefix, _predicate]) when is_binary(text) and is_binary(prefix) do
    # Predicate is ignored for now; behave like default
    do_indent([text, prefix])
  end

  defp do_indent(_), do: {:exception, "TypeError: indent() requires string arguments"}

  @spec do_wrap(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: Pyex.Interpreter.pyvalue()
  defp do_wrap(args, kwargs) do
    {text, width} = extract_text_and_width(args, kwargs)

    if is_binary(text) do
      lines = wrap_text(text, width)
      {:py_list, Enum.reverse(lines), length(lines)}
    else
      {:exception, "TypeError: wrap() argument must be a string"}
    end
  end

  @spec do_fill(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: Pyex.Interpreter.pyvalue()
  defp do_fill(args, kwargs) do
    {text, width} = extract_text_and_width(args, kwargs)

    if is_binary(text) do
      text
      |> wrap_text(width)
      |> Enum.join("\n")
    else
      {:exception, "TypeError: fill() argument must be a string"}
    end
  end

  @spec extract_text_and_width(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: {Pyex.Interpreter.pyvalue(), integer()}
  defp extract_text_and_width(args, kwargs) do
    text = List.first(args)
    width_from_args = Enum.at(args, 1)
    width = width_from_args || Map.get(kwargs, "width", 70)
    {text, width}
  end

  @spec wrap_text(String.t(), integer()) :: [String.t()]
  defp wrap_text(text, width) do
    words = String.split(text)

    if words == [] do
      []
    else
      build_lines(words, width, [], "")
    end
  end

  @spec build_lines([String.t()], integer(), [String.t()], String.t()) :: [String.t()]
  defp build_lines([], _width, lines, ""), do: Enum.reverse(lines)

  defp build_lines([], _width, lines, current_line) do
    Enum.reverse([current_line | lines])
  end

  defp build_lines([word | rest], width, lines, "") do
    build_lines(rest, width, lines, word)
  end

  defp build_lines([word | rest], width, lines, current_line) do
    candidate = current_line <> " " <> word

    if String.length(candidate) <= width do
      build_lines(rest, width, lines, candidate)
    else
      build_lines(rest, width, [current_line | lines], word)
    end
  end

  @spec leading_whitespace(String.t()) :: String.t()
  defp leading_whitespace(line) do
    trimmed = String.trim_leading(line)
    String.slice(line, 0, String.length(line) - String.length(trimmed))
  end

  @spec common_prefix([String.t()]) :: String.t()
  defp common_prefix([]), do: ""
  defp common_prefix([single]), do: single

  defp common_prefix([first | rest]) do
    Enum.reduce(rest, first, fn str, acc ->
      shared_prefix(acc, str)
    end)
  end

  @spec shared_prefix(String.t(), String.t()) :: String.t()
  defp shared_prefix(a, b) do
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)

    a_chars
    |> Enum.zip(b_chars)
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> Enum.map_join(fn {x, _} -> x end)
  end
end
