defmodule Pyex.Highlighter.Lexers.Tsx do
  @moduledoc "TSX lexer — TypeScript + JSX."

  @behaviour Pyex.Highlighter.Lexer

  def name, do: "tsx"
  def aliases, do: ["tsx"]
  def filenames, do: ["*.tsx"]
  def mimetypes, do: ["text/tsx"]

  @impl true
  def rules, do: Pyex.Highlighter.Lexers.Ecma.rules(types: true, jsx: true)
end
