defmodule Pyex.Highlighter.Lexers.Jsx do
  @moduledoc "JSX lexer — JavaScript with embedded XML-like tags."

  @behaviour Pyex.Highlighter.Lexer

  def name, do: "jsx"
  def aliases, do: ["jsx"]
  def filenames, do: ["*.jsx"]
  def mimetypes, do: ["text/jsx"]

  @impl true
  def rules, do: Pyex.Highlighter.Lexers.Ecma.rules(types: false, jsx: true)
end
