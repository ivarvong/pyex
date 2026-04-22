defmodule Pyex.Highlighter.Styles.Monokai do
  @moduledoc """
  Monokai theme — dark background, high-contrast magenta/yellow/cyan palette.
  Clean-room reimplementation of the classic Sublime/Pygments scheme.
  """

  alias Pyex.Highlighter.Style

  @style Style.from_dict(
           %{
             "Text" => "#f8f8f2",
             "Error" => "bg:#1e0010 #960050",
             "Keyword" => "#66d9ef",
             "Keyword.Constant" => "#ae81ff",
             "Keyword.Declaration" => "#66d9ef",
             "Keyword.Namespace" => "#f92672",
             "Keyword.Pseudo" => "#ae81ff",
             "Keyword.Reserved" => "#66d9ef",
             "Keyword.Type" => "#66d9ef",
             "Name" => "#f8f8f2",
             "Name.Attribute" => "#a6e22e",
             "Name.Builtin" => "#f8f8f2",
             "Name.Builtin.Pseudo" => "#ae81ff",
             "Name.Class" => "#a6e22e",
             "Name.Constant" => "#66d9ef",
             "Name.Decorator" => "#a6e22e",
             "Name.Exception" => "#a6e22e",
             "Name.Function" => "#a6e22e",
             "Name.Function.Magic" => "#a6e22e",
             "Name.Tag" => "#f92672",
             "Name.Variable" => "#f8f8f2",
             "Literal" => "#ae81ff",
             "Literal.String" => "#e6db74",
             "Literal.String.Doc" => "#e6db74",
             "Literal.String.Escape" => "#ae81ff",
             "Literal.String.Interpol" => "#ae81ff",
             "Literal.String.Regex" => "#e6db74",
             "Literal.Number" => "#ae81ff",
             "Operator" => "#f92672",
             "Operator.Word" => "#f92672",
             "Punctuation" => "#f8f8f2",
             "Comment" => "italic #75715e",
             "Generic.Deleted" => "#f92672",
             "Generic.Inserted" => "#a6e22e",
             "Generic.Heading" => "bold #f8f8f2",
             "Generic.Subheading" => "#75715e",
             "Generic.Emph" => "italic",
             "Generic.Strong" => "bold",
             "Generic.Traceback" => "#960050"
           },
           background_color: "#272822",
           highlight_color: "#49483e",
           name: "monokai"
         )

  @doc "Returns the resolved Monokai style."
  @spec style() :: Style.t()
  def style, do: @style
end
