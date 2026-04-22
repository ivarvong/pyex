defmodule Pyex.Highlighter.Styles.SolarizedLight do
  @moduledoc """
  Solarized Light theme. Ethan Schoonover's carefully tuned palette
  with warm cream background and muted accent colors.
  """

  alias Pyex.Highlighter.Style

  @style Style.from_dict(
           %{
             "Text" => "#586e75",
             "Error" => "#dc322f",
             "Keyword" => "#859900",
             "Keyword.Constant" => "#cb4b16",
             "Keyword.Declaration" => "#268bd2",
             "Keyword.Namespace" => "#cb4b16",
             "Keyword.Reserved" => "#859900",
             "Keyword.Type" => "#b58900",
             "Name" => "#586e75",
             "Name.Attribute" => "#268bd2",
             "Name.Builtin" => "#268bd2",
             "Name.Builtin.Pseudo" => "#268bd2",
             "Name.Class" => "#268bd2",
             "Name.Constant" => "#b58900",
             "Name.Decorator" => "#268bd2",
             "Name.Exception" => "#cb4b16",
             "Name.Function" => "#268bd2",
             "Name.Function.Magic" => "#268bd2",
             "Name.Tag" => "#268bd2",
             "Name.Variable" => "#268bd2",
             "Literal" => "#2aa198",
             "Literal.String" => "#2aa198",
             "Literal.String.Doc" => "italic #586e75",
             "Literal.String.Escape" => "#cb4b16",
             "Literal.String.Interpol" => "#cb4b16",
             "Literal.String.Regex" => "#dc322f",
             "Literal.Number" => "#2aa198",
             "Operator" => "#859900",
             "Operator.Word" => "#859900",
             "Punctuation" => "#586e75",
             "Comment" => "italic #93a1a1",
             "Generic.Deleted" => "#dc322f",
             "Generic.Inserted" => "#859900",
             "Generic.Heading" => "bold #586e75",
             "Generic.Subheading" => "#93a1a1",
             "Generic.Emph" => "italic",
             "Generic.Strong" => "bold",
             "Generic.Traceback" => "#dc322f"
           },
           background_color: "#fdf6e3",
           highlight_color: "#eee8d5",
           name: "solarized-light"
         )

  @spec style() :: Style.t()
  def style, do: @style
end
