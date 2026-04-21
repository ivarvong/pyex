defmodule Pyex.Highlighter.Lexers.ElixirTest do
  use ExUnit.Case, async: true

  alias Pyex.Highlighter.Lexer
  alias Pyex.Highlighter.Lexers.Elixir, as: ElixirLexer

  defp tokenize(src), do: Lexer.tokenize(ElixirLexer, src)

  defp has_token?(src, type, text) do
    Enum.any?(tokenize(src), fn {t, s} -> t == type and s == text end)
  end

  test "round-trips losslessly" do
    src = ~S"""
    defmodule Greeter do
      @moduledoc "says hi"

      def greet(name) when is_binary(name) do
        "hello, #{name}"
      end

      defp shout(name), do: String.upcase(name)
    end
    """

    reconstructed = tokenize(src) |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
    assert reconstructed == src
  end

  test "def family tags keyword + name" do
    tokens = tokenize("def hello(), do: :ok")
    assert {:keyword_declaration, "def"} in tokens
    assert {:name_function, "hello"} in tokens

    tokens2 = tokenize("defmodule MyApp.Hello do\nend")
    assert {:keyword_declaration, "defmodule"} in tokens2
    assert {:name_function, "MyApp.Hello"} in tokens2
  end

  test "atoms" do
    assert has_token?(":ok", :string_symbol, ":ok")
    assert has_token?(":error", :string_symbol, ":error")
    assert has_token?(":foo?", :string_symbol, ":foo?")
    assert has_token?(~s(:"with spaces"), :string_symbol, ~s(:"with spaces"))
  end

  test "keywords" do
    assert has_token?("case x do\n y -> 1\nend", :keyword, "case")
    assert has_token?("case x do\n y -> 1\nend", :keyword, "do")
    assert has_token?("case x do\n y -> 1\nend", :keyword, "end")
    assert has_token?("fn x -> x end", :keyword, "fn")
    assert has_token?("with {:ok, v} <- f() do v end", :keyword, "with")
  end

  test "constants" do
    assert has_token?("x = true", :keyword_constant, "true")
    assert has_token?("x = nil", :keyword_constant, "nil")
  end

  test "module references" do
    assert has_token?("String.length(x)", :name_class, "String")
    assert has_token?("Enum.map(xs)", :name_class, "Enum")
    assert has_token?("alias MyApp.Foo", :name_class, "MyApp.Foo")
  end

  test "module attributes" do
    assert has_token?("@moduledoc", :name_attribute, "@moduledoc")
    assert has_token?("@spec add(integer()) :: integer()", :name_attribute, "@spec")
  end

  test "sigils" do
    regex = ~S"~r/^[a-z]+$/"
    words = ~S"~w(a b c)"
    string = ~S"~s{x y z}"
    date = ~S"~D[2024-01-01]"

    assert has_token?(regex, :string_regex, regex)
    assert has_token?(words, :string_regex, words)
    assert has_token?(string, :string_regex, string)
    assert has_token?(date, :string_regex, date)
  end

  test "numbers" do
    assert has_token?("42", :number_integer, "42")
    assert has_token?("3.14", :number_float, "3.14")
    assert has_token?("1_000_000", :number_integer, "1_000_000")
    assert has_token?("0xFF", :number_hex, "0xFF")
    assert has_token?("0b1010", :number_bin, "0b1010")
    assert has_token?("?a", :number_integer, "?a")
  end

  test "heredocs" do
    src = ~S'''
    x = """
    hello
    world
    """
    '''

    tokens = tokenize(src)
    assert Enum.any?(tokens, fn {t, _s} -> t == :string_heredoc end)
  end

  test "string interpolation" do
    tokens = tokenize(~S["hello, #{name}"])
    assert {:string_double, ~s(")} in tokens
    assert {:string_interpol, "\#{"} in tokens
    assert {:name, "name"} in tokens
    assert {:string_interpol, "}"} in tokens
  end

  test "pipe operator" do
    assert has_token?("x |> f()", :operator, "|>")
    assert has_token?("x <- y", :operator, "<-")
    assert has_token?("x -> y", :operator, "->")
  end

  test "comments" do
    assert has_token?("# hi", :comment_single, "# hi")
  end

  test "charlists" do
    assert has_token?(~S('hello'), :string_char, ~S('hello'))
  end

  test "keyword-list atom shorthand" do
    # `style: :monokai` — `style:` is an atom-key, not ident+colon
    assert has_token?("foo(style: :monokai)", :string_symbol, "style:")

    # Real-world example the HTML demo exposed
    src = "Pygments.highlight(body, :elixir, style: :monokai)"
    assert has_token?(src, :string_symbol, "style:")
    assert has_token?(src, :string_symbol, ":monokai")
    assert has_token?(src, :string_symbol, ":elixir")

    # Multiple kwlist keys
    tokens = tokenize("render(foo, title: \"Hi\", body: content)")
    assert {:string_symbol, "title:"} in tokens
    assert {:string_symbol, "body:"} in tokens

    # `::` (type-spec separator) should NOT match the kwlist rule
    tokens = tokenize("@spec render(String.t()) :: String.t()")
    refute Enum.any?(tokens, fn {t, s} -> t == :string_symbol and String.ends_with?(s, ":") end)
  end
end
