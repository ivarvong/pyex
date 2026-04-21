defmodule Pyex.Highlighter.Lexers.Json do
  @moduledoc """
  JSON lexer. Tokenizes strict RFC 8259 JSON plus common extensions
  (leading/trailing whitespace, nested objects and arrays).

  Strings that appear immediately before `:` are tagged `:name_tag`
  instead of `:string_double` so formatters can render object keys
  distinctly from string values.
  """

  @behaviour Pyex.Highlighter.Lexer

  @name "json"
  @aliases ["json"]
  @filenames ["*.json"]
  @mimetypes ["application/json"]

  def name, do: @name
  def aliases, do: @aliases
  def filenames, do: @filenames
  def mimetypes, do: @mimetypes

  @impl Pyex.Highlighter.Lexer
  def rules do
    %{
      root: [
        {~r/\s+/, :whitespace, :none},
        # A string followed (after optional whitespace) by `:` is a
        # key — look ahead to decide. We split the match into the
        # string itself (as :name_tag) and leave the `:` for the next
        # iteration.
        {~r/"(?:\\.|[^"\\])*"(?=\s*:)/, :name_tag, :none},
        {~r/"(?:\\.|[^"\\])*"/, :string_double, :none},
        {~r/-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/, :number, :none},
        {~r/\btrue\b|\bfalse\b/, :keyword_constant, :none},
        {~r/\bnull\b/, :keyword_constant, :none},
        {~r/[{}\[\],:]/, :punctuation, :none}
      ]
    }
  end
end
