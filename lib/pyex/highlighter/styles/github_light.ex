defmodule Pyex.Highlighter.Styles.GithubLight do
  @moduledoc """
  GitHub light theme. Matches GitHub's current syntax highlighting on
  light backgrounds — comfortable default for SSR blogs.
  """

  alias Pyex.Highlighter.Style

  @style Style.from_dict(
           %{
             "Text" => "#24292f",
             "Error" => "#cf222e",
             "Keyword" => "#cf222e",
             "Keyword.Constant" => "#0550ae",
             "Keyword.Declaration" => "#cf222e",
             "Keyword.Namespace" => "#cf222e",
             "Keyword.Pseudo" => "#cf222e",
             "Keyword.Reserved" => "#cf222e",
             "Keyword.Type" => "#953800",
             "Name" => "#24292f",
             "Name.Attribute" => "#0550ae",
             "Name.Builtin" => "#0550ae",
             "Name.Builtin.Pseudo" => "#0550ae",
             "Name.Class" => "#953800",
             "Name.Constant" => "#0550ae",
             "Name.Decorator" => "#8250df",
             "Name.Exception" => "#953800",
             "Name.Function" => "#8250df",
             "Name.Function.Magic" => "#8250df",
             "Name.Tag" => "#116329",
             "Name.Variable" => "#24292f",
             "Literal" => "#0550ae",
             "Literal.String" => "#0a3069",
             "Literal.String.Doc" => "italic #6e7781",
             "Literal.String.Escape" => "#0550ae",
             "Literal.String.Interpol" => "#0550ae",
             "Literal.String.Regex" => "#116329",
             "Literal.Number" => "#0550ae",
             "Operator" => "#cf222e",
             "Operator.Word" => "#cf222e",
             "Punctuation" => "#24292f",
             "Comment" => "italic #6e7781",
             "Generic.Deleted" => "bg:#ffebe9 #82071e",
             "Generic.Inserted" => "bg:#dafbe1 #116329",
             "Generic.Heading" => "bold #0550ae",
             "Generic.Subheading" => "bold #0969da",
             "Generic.Emph" => "italic",
             "Generic.Strong" => "bold",
             "Generic.Traceback" => "#cf222e"
           },
           background_color: "#ffffff",
           highlight_color: "#fff8c5",
           name: "github-light"
         )

  @spec style() :: Style.t()
  def style, do: @style
end
