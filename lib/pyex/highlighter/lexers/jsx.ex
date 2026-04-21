defmodule Pyex.Highlighter.Lexers.JSX do
  @moduledoc "JSX lexer — JavaScript with embedded XML-like tags."

  @behaviour Pyex.Highlighter.Lexer

  def name, do: "jsx"
  def aliases, do: ["jsx"]
  def filenames, do: ["*.jsx"]
  def mimetypes, do: ["text/jsx"]

  @impl true
  def rules, do: Pyex.Highlighter.Lexers.ECMA.rules(types: false, jsx: true)
end
