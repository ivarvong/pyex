defmodule Pyex.Highlighter.Lexers.Javascript do
  @moduledoc "JavaScript / ECMAScript lexer."

  @behaviour Pyex.Highlighter.Lexer

  def name, do: "javascript"
  def aliases, do: ["javascript", "js", "ecmascript"]
  def filenames, do: ["*.js", "*.mjs", "*.cjs"]
  def mimetypes, do: ["application/javascript", "text/javascript"]

  @impl true
  def rules, do: Pyex.Highlighter.Lexers.ECMA.rules(types: false, jsx: false)
end
