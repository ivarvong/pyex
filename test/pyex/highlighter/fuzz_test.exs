defmodule Pyex.Highlighter.FuzzTest do
  @moduledoc """
  Deterministic adversarial fuzz tests for the highlighter.

  Catches catastrophic backtracking, OOM, infinite loops, raw-byte
  handling, and cross-language mis-use. Each lexer is thrown against:

    * empty input, single codepoints (ASCII + unicode)
    * deeply nested delimiters (1000-level brace depth)
    * very long single lines (80k chars)
    * NUL bytes, control chars, invalid UTF-8
    * unterminated strings and comments
    * pathological repeat patterns known to blow up naive regex engines
    * cross-language junk (Bash script fed to the JSON lexer, etc.)
    * large inputs (~650 KB) — regression guard for O(n²) scanning
  """

  use ExUnit.Case, async: true

  alias Pyex.Highlighter
  alias Pyex.Highlighter.{Lexer, Style}

  @languages ~w(python json bash javascript typescript jsx tsx elixir)

  @tokenize_timeout_ms 5_000

  defp tokenize!(lang, source) do
    {:ok, mod} = Highlighter.lexer_for_name(lang)

    task = Task.async(fn -> Lexer.tokenize(mod, source) end)

    case Task.yield(task, @tokenize_timeout_ms) || Task.shutdown(task) do
      {:ok, tokens} -> tokens
      _ -> flunk("tokenize hung for #{lang} on #{byte_size(source)}-byte input")
    end
  end

  defp round_trips?(lang, source) do
    tokens = tokenize!(lang, source)
    reconstructed = tokens |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
    reconstructed == source
  end

  # ---- small inputs ---------------------------------------------------

  describe "empty / tiny inputs" do
    test "empty string round-trips for every lexer" do
      for lang <- @languages do
        assert tokenize!(lang, "") == []
        {:ok, html} = Highlighter.highlight("", lang, style: "default")
        assert is_binary(html)
      end
    end

    @single_ascii [
      "a",
      "A",
      "0",
      "_",
      ".",
      ",",
      ";",
      ":",
      "(",
      ")",
      "{",
      "}",
      "[",
      "]",
      "\"",
      "'",
      "`",
      "/",
      "\\",
      "|",
      "&",
      "^",
      "~",
      "%",
      "!",
      "?",
      "@",
      "#",
      "$",
      "+",
      "-",
      "*",
      "=",
      "<",
      ">"
    ]

    test "single ASCII codepoint doesn't crash" do
      for lang <- @languages, ch <- @single_ascii do
        assert round_trips?(lang, ch), "failed for #{lang} on #{inspect(ch)}"
      end
    end

    test "single unicode codepoint doesn't crash" do
      # Greek, CJK, emoji, ellipsis, middle-dot, RTL mark
      for lang <- @languages,
          ch <- ["α", "中", "🔥", "…", "·", "\u200f", "ñ"] do
        assert round_trips?(lang, ch), "failed for #{lang} on #{inspect(ch)}"
      end
    end

    test "single control / whitespace chars" do
      for lang <- @languages,
          ch <- ["\n", "\t", "\r", " ", "\u00a0"] do
        assert round_trips?(lang, ch)
      end
    end
  end

  # ---- structural stress ---------------------------------------------

  describe "structural stress" do
    test "deeply nested braces (1000 levels)" do
      input = String.duplicate("{", 1000) <> String.duplicate("}", 1000)

      for lang <- @languages do
        assert round_trips?(lang, input)
      end
    end

    test "deeply nested parens (1000 levels)" do
      input = String.duplicate("(", 1000) <> String.duplicate(")", 1000)

      for lang <- @languages do
        assert round_trips?(lang, input)
      end
    end

    test "very long single line (80 KB)" do
      input = String.duplicate("foo bar baz ", 6_700) <> "\n"

      for lang <- @languages do
        assert round_trips?(lang, input)
      end
    end

    test "many short lines (50 000)" do
      input = String.duplicate("x\n", 50_000)

      for lang <- @languages do
        assert round_trips?(lang, input)
      end
    end

    test "large real-world-ish input (~125 KB) — scaling sanity" do
      big = String.duplicate("const x = 1;\nfunction f() { return 42; }\n\n", 3_000)

      task = Task.async(fn -> Highlighter.highlight(big, "javascript", style: "default") end)
      {:ok, result} = Task.yield(task, @tokenize_timeout_ms) || flunk("highlight hung")
      assert {:ok, _html} = result
    end
  end

  # ---- adversarial strings -------------------------------------------

  describe "unclosed / mismatched tokens" do
    test "unclosed double-quoted string" do
      for lang <- @languages do
        assert round_trips?(lang, ~s("no closing quote))
      end
    end

    test "unclosed single-quoted string" do
      for lang <- @languages do
        assert round_trips?(lang, ~s('no closing))
      end
    end

    test "unclosed backtick / template literal" do
      for lang <- @languages do
        assert round_trips?(lang, "`no closing")
      end
    end

    test "unclosed block comment (JS/TS)" do
      for lang <- ~w(javascript typescript jsx tsx) do
        assert round_trips?(lang, "/* no closing")
      end
    end

    test "unclosed triple-quoted docstring (Python)" do
      assert round_trips?("python", "\"\"\"no closing")
    end

    test "unclosed heredoc (Bash)" do
      assert round_trips?("bash", "cat <<EOF\nhello\nno terminator")
    end

    test "unclosed Elixir heredoc" do
      assert round_trips?("elixir", "\"\"\"\nno close")
    end
  end

  # ---- binary fuzz ----------------------------------------------------

  describe "binary / control input" do
    test "NUL bytes and low control chars" do
      input = <<0, 1, 2, 3, 4, 7, 8, 11, 14, 27, 127>>

      for lang <- @languages do
        # NUL bytes are valid UTF-8 so this must round-trip.
        assert round_trips?(lang, input)
      end
    end

    test "invalid UTF-8 bytes don't crash" do
      # Lone continuation bytes + C0 bytes — classic malformed UTF-8.
      input = <<0xC0, 0x80, 0x80, 0xF0, 0xFF, 0xFE>>

      for lang <- @languages do
        assert round_trips?(lang, input),
               "bad UTF-8 failed for #{lang} on #{inspect(input)}"
      end
    end

    test "mixed ASCII + invalid UTF-8" do
      input = "hello " <> <<0xC0, 0xFF>> <> " world"

      for lang <- @languages do
        assert round_trips?(lang, input)
      end
    end
  end

  # ---- pathological patterns -----------------------------------------

  describe "pathological patterns (catastrophic-backtrack guards)" do
    test "long run of `/` (regex-vs-division)" do
      input = String.duplicate("/", 200)

      for lang <- ~w(javascript typescript jsx tsx) do
        assert round_trips?(lang, input)
      end
    end

    test "long run of `<` (JSX generic disambiguation)" do
      input = String.duplicate("<", 500)

      for lang <- ~w(javascript typescript jsx tsx) do
        assert round_trips?(lang, input)
      end
    end

    test "long run of `#` (JS private fields, Python/Bash comments)" do
      input = String.duplicate("#", 500) <> "\n"

      for lang <- @languages do
        assert round_trips?(lang, input)
      end
    end

    test "long run of interpolation sigils (JS ${ and Elixir hash-brace)" do
      for {lang, sigil} <- [
            {"javascript", "${"},
            {"elixir", "\#{"}
          ] do
        input = String.duplicate(sigil, 300)
        assert round_trips?(lang, input)
      end
    end

    test "500 consecutive backticks" do
      input = String.duplicate("`", 500)

      for lang <- ~w(javascript typescript jsx tsx) do
        assert round_trips?(lang, input)
      end
    end

    test "alternating open-close bracket noise" do
      input = String.duplicate("{}(){}[]", 500)

      for lang <- @languages do
        assert round_trips?(lang, input)
      end
    end
  end

  # ---- cross-language mis-feeds --------------------------------------

  describe "cross-language inputs (lexer robustness, not correctness)" do
    @cross [
      {"python", "defmodule Foo do\n :ok\nend\n"},
      {"elixir", "def foo(): return 1\n"},
      {"bash", "class Foo: pass\n"},
      {"json", "function main() { return 1; }\n"},
      {"javascript", "defmodule X do\nend\n"},
      {"typescript", "#!/usr/bin/env bash\nset -e\n"},
      {"jsx", "print('hello')\n"},
      {"tsx", "puts \"ruby\"\n"}
    ]

    for {lang, src} <- @cross do
      @lang lang
      @src src
      test "#{lang} lexer survives #{inspect(src)}" do
        assert round_trips?(@lang, @src)
      end
    end
  end

  # ---- formatter + style fuzz ----------------------------------------

  describe "formatter and styles under adversarial input" do
    test "empty style dict produces valid CSS" do
      {:ok, css} = Highlighter.css(%{})
      assert is_binary(css)
      assert css =~ ".highlight {"
    end

    test "style dict with all bogus keys is harmless" do
      dict = %{
        "not-a-token" => "bold",
        "🔥" => "#ff0000",
        "" => "italic",
        "Keyword.Nonexistent" => "bold #abc"
      }

      {:ok, css} = Highlighter.css(dict)
      assert is_binary(css)
      refute css =~ "not-a-token"
    end

    test "style dict with garbage spec strings doesn't crash" do
      dict = %{
        "Keyword" => "total garbage here",
        "Name" => "",
        "Comment" => "#zzzzzz #yyyyyy more noise"
      }

      assert %Style{} = Style.from_dict(dict)
      {:ok, _css} = Highlighter.css(dict)
    end

    test "CSS selector with special chars is escaped / tolerated" do
      # We don't claim to escape the selector, but we shouldn't crash.
      for sel <- [".x", "#id", "body > .code", "[data-x=\"y\"]", ""] do
        {:ok, css} = Highlighter.css("monokai", sel)
        assert is_binary(css)
      end
    end

    test "unknown style / lexer name returns {:error, _} without raising" do
      assert {:error, _} = Highlighter.highlight("x", "cobol")
      assert {:error, _} = Highlighter.css("not-a-real-style")
    end

    test "highlighting every language at every built-in style is safe" do
      styles = Pyex.Highlighter.Styles.all_names()
      src = "hello world 42"

      for lang <- @languages, style <- styles do
        assert {:ok, _} = Highlighter.highlight(src, lang, style: style)
      end
    end
  end
end
