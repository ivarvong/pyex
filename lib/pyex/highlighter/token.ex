defmodule Pyex.Highlighter.Token do
  @moduledoc """
  Token type hierarchy used by lexers and formatters.

  Clean-room reimplementation of Pygments' token model. A token type is
  an atom like `:keyword`, `:name_function`, or `:string_double`. Each
  type has:

    * a **short CSS class** (e.g. `k`, `nf`, `s2`) — compatible with
      Pygments so existing themes drop in
    * a **dotted name** (e.g. `"Keyword"`, `"Name.Function"`) — used
      as the canonical key in user-supplied style dicts
    * a **parent** — unmatched token types fall back to their parent's
      style, so `:string_double` inherits from `:string` inherits from
      `:literal` inherits from `:text`.

  Lexers emit `{type, text}` tuples. Formatters resolve each type to a
  CSS class and a style definition by walking toward the root.
  """

  @type t :: atom()

  # {atom, short_class, dotted_name, parent}
  @types [
    {:text, "", "Text", nil},
    {:whitespace, "w", "Text.Whitespace", :text},
    {:error, "err", "Error", :text},
    {:other, "x", "Other", :text},
    {:keyword, "k", "Keyword", :text},
    {:keyword_constant, "kc", "Keyword.Constant", :keyword},
    {:keyword_declaration, "kd", "Keyword.Declaration", :keyword},
    {:keyword_namespace, "kn", "Keyword.Namespace", :keyword},
    {:keyword_pseudo, "kp", "Keyword.Pseudo", :keyword},
    {:keyword_reserved, "kr", "Keyword.Reserved", :keyword},
    {:keyword_type, "kt", "Keyword.Type", :keyword},
    {:name, "n", "Name", :text},
    {:name_attribute, "na", "Name.Attribute", :name},
    {:name_builtin, "nb", "Name.Builtin", :name},
    {:name_builtin_pseudo, "bp", "Name.Builtin.Pseudo", :name_builtin},
    {:name_class, "nc", "Name.Class", :name},
    {:name_constant, "no", "Name.Constant", :name},
    {:name_decorator, "nd", "Name.Decorator", :name},
    {:name_entity, "ni", "Name.Entity", :name},
    {:name_exception, "ne", "Name.Exception", :name},
    {:name_function, "nf", "Name.Function", :name},
    {:name_function_magic, "fm", "Name.Function.Magic", :name_function},
    {:name_label, "nl", "Name.Label", :name},
    {:name_namespace, "nn", "Name.Namespace", :name},
    {:name_property, "py", "Name.Property", :name},
    {:name_tag, "nt", "Name.Tag", :name},
    {:name_variable, "nv", "Name.Variable", :name},
    {:name_variable_class, "vc", "Name.Variable.Class", :name_variable},
    {:name_variable_global, "vg", "Name.Variable.Global", :name_variable},
    {:name_variable_instance, "vi", "Name.Variable.Instance", :name_variable},
    {:name_variable_magic, "vm", "Name.Variable.Magic", :name_variable},
    {:literal, "l", "Literal", :text},
    {:literal_date, "ld", "Literal.Date", :literal},
    {:string, "s", "Literal.String", :literal},
    {:string_affix, "sa", "Literal.String.Affix", :string},
    {:string_backtick, "sb", "Literal.String.Backtick", :string},
    {:string_char, "sc", "Literal.String.Char", :string},
    {:string_delimiter, "dl", "Literal.String.Delimiter", :string},
    {:string_doc, "sd", "Literal.String.Doc", :string},
    {:string_double, "s2", "Literal.String.Double", :string},
    {:string_escape, "se", "Literal.String.Escape", :string},
    {:string_heredoc, "sh", "Literal.String.Heredoc", :string},
    {:string_interpol, "si", "Literal.String.Interpol", :string},
    {:string_other, "sx", "Literal.String.Other", :string},
    {:string_regex, "sr", "Literal.String.Regex", :string},
    {:string_single, "s1", "Literal.String.Single", :string},
    {:string_symbol, "ss", "Literal.String.Symbol", :string},
    {:number, "m", "Literal.Number", :literal},
    {:number_bin, "mb", "Literal.Number.Bin", :number},
    {:number_float, "mf", "Literal.Number.Float", :number},
    {:number_hex, "mh", "Literal.Number.Hex", :number},
    {:number_integer, "mi", "Literal.Number.Integer", :number},
    {:number_integer_long, "il", "Literal.Number.Integer.Long", :number_integer},
    {:number_oct, "mo", "Literal.Number.Oct", :number},
    {:operator, "o", "Operator", :text},
    {:operator_word, "ow", "Operator.Word", :operator},
    {:punctuation, "p", "Punctuation", :text},
    {:punctuation_marker, "pm", "Punctuation.Marker", :punctuation},
    {:comment, "c", "Comment", :text},
    {:comment_hashbang, "ch", "Comment.Hashbang", :comment},
    {:comment_multiline, "cm", "Comment.Multiline", :comment},
    {:comment_preproc, "cp", "Comment.Preproc", :comment},
    {:comment_single, "c1", "Comment.Single", :comment},
    {:comment_special, "cs", "Comment.Special", :comment},
    {:generic, "g", "Generic", :text},
    {:generic_deleted, "gd", "Generic.Deleted", :generic},
    {:generic_emph, "ge", "Generic.Emph", :generic},
    {:generic_error, "gr", "Generic.Error", :generic},
    {:generic_heading, "gh", "Generic.Heading", :generic},
    {:generic_inserted, "gi", "Generic.Inserted", :generic},
    {:generic_output, "go", "Generic.Output", :generic},
    {:generic_prompt, "gp", "Generic.Prompt", :generic},
    {:generic_strong, "gs", "Generic.Strong", :generic},
    {:generic_subheading, "gu", "Generic.Subheading", :generic},
    {:generic_traceback, "gt", "Generic.Traceback", :generic}
  ]

  @short_for Map.new(@types, fn {atom, short, _dotted, _parent} -> {atom, short} end)
  @dotted_for Map.new(@types, fn {atom, _short, dotted, _parent} -> {atom, dotted} end)
  @parent_for Map.new(@types, fn {atom, _short, _dotted, parent} -> {atom, parent} end)
  @by_dotted Map.new(@types, fn {atom, _short, dotted, _parent} -> {dotted, atom} end)
  @by_short Map.new(@types, fn {atom, short, _dotted, _parent} -> {short, atom} end)
  @all_atoms Enum.map(@types, fn {atom, _, _, _} -> atom end)

  @doc "Returns the short CSS class for a token type (e.g. `:keyword` → `\"k\"`)."
  @spec short_class(t()) :: String.t()
  def short_class(type), do: Map.get(@short_for, type, "")

  @doc "Returns the canonical dotted name (e.g. `:keyword` → `\"Keyword\"`)."
  @spec dotted_name(t()) :: String.t()
  def dotted_name(type), do: Map.get(@dotted_for, type, "Text")

  @doc "Returns the parent token type, or `nil` for `:text`."
  @spec parent(t()) :: t() | nil
  def parent(type), do: Map.get(@parent_for, type)

  @doc """
  Returns the chain from `type` up to the root (`:text`), inclusive.

      iex> Pyex.Highlighter.Token.ancestry(:string_double)
      [:string_double, :string, :literal, :text]
  """
  @spec ancestry(t()) :: [t()]
  def ancestry(type), do: ancestry(type, [])

  defp ancestry(nil, acc), do: Enum.reverse(acc)
  defp ancestry(type, acc), do: ancestry(parent(type), [type | acc])

  @doc """
  Looks up a token type by dotted name (case-sensitive).

      iex> Pyex.Highlighter.Token.from_dotted("Name.Function")
      {:ok, :name_function}
  """
  @spec from_dotted(String.t()) :: {:ok, t()} | :error
  def from_dotted(name) do
    case Map.fetch(@by_dotted, name) do
      {:ok, atom} -> {:ok, atom}
      :error -> :error
    end
  end

  @doc "Looks up a token type by short class (e.g. `\"nf\"` → `{:ok, :name_function}`)."
  @spec from_short(String.t()) :: {:ok, t()} | :error
  def from_short(s) do
    case Map.fetch(@by_short, s) do
      {:ok, atom} -> {:ok, atom}
      :error -> :error
    end
  end

  @doc "All token type atoms."
  @spec all() :: [t()]
  def all, do: @all_atoms
end
