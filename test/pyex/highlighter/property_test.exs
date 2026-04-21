defmodule Pyex.Highlighter.PropertyTest do
  @moduledoc """
  Property-based tests for the syntax highlighter.

  Asserted invariants (per lexer unless noted):

    * **Lossless round-trip** — concatenating every token's text
      reconstructs the original source byte-for-byte.
    * **Never crashes** — on any printable / UTF-8 / random-byte input.
    * **Idempotent** — tokenizing the same input twice is identical.
    * **HTML balance** — the rendered HTML has matching `<span>…</span>`
      pairs and never leaks a raw `<`, `>`, or `&` in token content.
    * **Style dict robustness** — arbitrary string-keyed maps never
      crash `Style.from_dict/1`, `Highlighter.css/1-2`, or
      `Style.rule_for/2`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pyex.Highlighter
  alias Pyex.Highlighter.{Lexer, Style, Token}

  # {module, name-used-in-test-labels}. Name is baked in at compile time
  # so it can be interpolated inside `property` macros.
  @lexers [
    {Pyex.Highlighter.Lexers.Python, "Python"},
    {Pyex.Highlighter.Lexers.Json, "Json"},
    {Pyex.Highlighter.Lexers.Bash, "Bash"},
    {Pyex.Highlighter.Lexers.Javascript, "Javascript"},
    {Pyex.Highlighter.Lexers.Typescript, "Typescript"},
    {Pyex.Highlighter.Lexers.Jsx, "Jsx"},
    {Pyex.Highlighter.Lexers.Tsx, "Tsx"},
    {Pyex.Highlighter.Lexers.Elixir, "Elixir"}
  ]

  describe "lossless round-trip" do
    for {lexer, name} <- @lexers do
      @tag lexer: lexer
      property "#{name}: printable input round-trips losslessly" do
        lexer = unquote(lexer)

        check all(source <- string(:printable, max_length: 400), max_runs: 150) do
          tokens = Lexer.tokenize(lexer, source)
          reconstructed = tokens |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()

          assert reconstructed == source,
                 "round-trip failure for #{inspect(source)}:\n#{inspect(tokens, limit: 20)}"
        end
      end

      property "#{name}: arbitrary UTF-8 input round-trips losslessly" do
        lexer = unquote(lexer)

        check all(source <- string(:utf8, max_length: 200), max_runs: 100) do
          tokens = Lexer.tokenize(lexer, source)
          reconstructed = tokens |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
          assert reconstructed == source
        end
      end
    end
  end

  describe "never crashes" do
    for {lexer, name} <- @lexers do
      property "#{name}: random printable input" do
        lexer = unquote(lexer)

        check all(source <- string(:printable, max_length: 400), max_runs: 100) do
          assert is_list(Lexer.tokenize(lexer, source))
        end
      end

      property "#{name}: random UTF-8 input" do
        lexer = unquote(lexer)

        check all(source <- string(:utf8, max_length: 200), max_runs: 100) do
          assert is_list(Lexer.tokenize(lexer, source))
        end
      end

      property "#{name}: alphanumeric input" do
        lexer = unquote(lexer)

        check all(source <- string(:alphanumeric, max_length: 300), max_runs: 50) do
          assert is_list(Lexer.tokenize(lexer, source))
        end
      end
    end
  end

  describe "idempotence" do
    for {lexer, name} <- @lexers do
      property "#{name}: tokenizing the same input twice is identical" do
        lexer = unquote(lexer)

        check all(source <- string(:printable, max_length: 200), max_runs: 50) do
          assert Lexer.tokenize(lexer, source) == Lexer.tokenize(lexer, source)
        end
      end
    end
  end

  describe "HTML well-formedness" do
    for {lexer, name} <- @lexers do
      property "#{name}: spans are balanced" do
        lexer = unquote(lexer)
        lang = hd(lexer.aliases())

        check all(source <- string(:printable, max_length: 300), max_runs: 50) do
          {:ok, html} = Highlighter.highlight(source, lang, style: "default")
          open = count_matches(html, ~r/<span\b[^>]*>/)
          close = count_matches(html, ~r/<\/span>/)

          assert open == close,
                 "unbalanced spans (#{open} open, #{close} close) for #{inspect(source)}"
        end
      end

      property "#{name}: no raw <, >, or unescaped & in token content" do
        lexer = unquote(lexer)
        lang = hd(lexer.aliases())

        check all(source <- string(:printable, max_length: 300), max_runs: 50) do
          {:ok, html} = Highlighter.highlight(source, lang, style: "default")
          # Extract content between `>` (end of tag) and `<` (start of tag):
          # that's the token text region. Assert nothing in there looks
          # like a raw HTML char.
          content =
            ~r/>([^<]*)</
            |> Regex.scan(html, capture: :all_but_first)
            |> List.flatten()
            |> Enum.join()

          refute content =~ ~r/[<>]/,
                 "raw < or > leaked into content for #{inspect(source)}"

          # Unescaped `&` is a different smell — every `&` should be
          # followed by `amp;`, `lt;`, `gt;`, `quot;`, or `#...`
          unescaped =
            Regex.scan(~r/&(?![a-z]+;|#\d+;|#x[0-9a-fA-F]+;)/, content)

          assert unescaped == [],
                 "unescaped & in content for #{inspect(source)}: #{inspect(unescaped)}"
        end
      end
    end
  end

  describe "style dict robustness" do
    property "arbitrary string-keyed maps never crash Style.from_dict" do
      gen =
        map_of(
          string(:printable, max_length: 30),
          string(:printable, max_length: 60),
          max_length: 10
        )

      check all(dict <- gen, max_runs: 100) do
        assert %Style{} = Style.from_dict(dict)
      end
    end

    property "arbitrary style dicts yield valid CSS (balanced braces)" do
      gen =
        map_of(
          string(:alphanumeric, max_length: 20),
          string(:alphanumeric, max_length: 40),
          max_length: 10
        )

      check all(dict <- gen, max_runs: 100) do
        assert {:ok, css} = Highlighter.css(dict)
        open = count_bytes(css, ?{)
        close = count_bytes(css, ?})
        assert open == close, "unbalanced CSS braces"
      end
    end

    property "Style.rule_for accepts every token atom and returns a map" do
      style = Style.from_dict(%{"Keyword" => "bold #f00", "Comment" => "italic"})

      check all(type <- member_of(Token.all()), max_runs: 100) do
        rule = Style.rule_for(style, type)
        assert is_map(rule)
      end
    end

    property "any style input → string name, dict, or Style struct — resolves without raising" do
      gen =
        one_of([
          string(:alphanumeric, max_length: 20),
          map_of(string(:printable, max_length: 20), string(:printable, max_length: 40),
            max_length: 5
          )
        ])

      check all(input <- gen, max_runs: 60) do
        case Style.resolve(input) do
          {:ok, %Style{}} -> :ok
          {:error, _msg} -> :ok
        end
      end
    end
  end

  # ---- helpers ----------------------------------------------------

  defp count_matches(s, re), do: length(Regex.scan(re, s))

  defp count_bytes(s, byte) do
    s |> :binary.bin_to_list() |> Enum.count(&(&1 == byte))
  end
end
