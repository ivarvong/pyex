defmodule Pyex.Highlighter.Styles.Dracula do
  @moduledoc """
  Dracula theme. Dark background, purple/pink/cyan palette popularized
  by the Dracula community project.
  """

  alias Pyex.Highlighter.Style

  @spec style() :: Style.t()
  def style do
    Style.from_dict(
      %{
        "Text" => "#f8f8f2",
        "Error" => "#ff5555",
        "Keyword" => "#ff79c6",
        "Keyword.Constant" => "#bd93f9",
        "Keyword.Declaration" => "#8be9fd italic",
        "Keyword.Namespace" => "#ff79c6",
        "Keyword.Pseudo" => "#bd93f9",
        "Keyword.Reserved" => "#ff79c6",
        "Keyword.Type" => "#8be9fd",
        "Name" => "#f8f8f2",
        "Name.Attribute" => "#50fa7b",
        "Name.Builtin" => "#8be9fd italic",
        "Name.Builtin.Pseudo" => "#bd93f9",
        "Name.Class" => "#50fa7b",
        "Name.Constant" => "#bd93f9",
        "Name.Decorator" => "#f1fa8c",
        "Name.Exception" => "#50fa7b",
        "Name.Function" => "#50fa7b",
        "Name.Function.Magic" => "#50fa7b",
        "Name.Tag" => "#ff79c6",
        "Name.Variable" => "#f8f8f2",
        "Literal" => "#bd93f9",
        "Literal.String" => "#f1fa8c",
        "Literal.String.Doc" => "#f1fa8c",
        "Literal.String.Escape" => "#ff79c6",
        "Literal.String.Interpol" => "#ff79c6",
        "Literal.String.Regex" => "#ff5555",
        "Literal.Number" => "#bd93f9",
        "Operator" => "#ff79c6",
        "Operator.Word" => "#ff79c6",
        "Punctuation" => "#f8f8f2",
        "Comment" => "italic #6272a4",
        "Generic.Deleted" => "#ff5555",
        "Generic.Inserted" => "#50fa7b",
        "Generic.Heading" => "bold #f8f8f2",
        "Generic.Subheading" => "#6272a4",
        "Generic.Emph" => "italic",
        "Generic.Strong" => "bold",
        "Generic.Traceback" => "#ff5555"
      },
      background_color: "#282a36",
      highlight_color: "#44475a",
      name: "dracula"
    )
  end
end
