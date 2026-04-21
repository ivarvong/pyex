defmodule Pyex.Highlighter.Lexers.Typescript do
  @moduledoc "TypeScript lexer — JS + type keywords and primitive types."

  @behaviour Pyex.Highlighter.Lexer

  def name, do: "typescript"
  def aliases, do: ["typescript", "ts"]
  def filenames, do: ["*.ts", "*.mts", "*.cts"]
  def mimetypes, do: ["application/typescript", "text/typescript"]

  @impl true
  def rules, do: Pyex.Highlighter.Lexers.ECMA.rules(types: true, jsx: false)
end
