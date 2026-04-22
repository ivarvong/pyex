defmodule Pyex.Highlighter.Formatters.HTMLTest do
  use ExUnit.Case, async: true

  alias Pyex.Highlighter
  alias Pyex.Highlighter.Formatters.HTML
  alias Pyex.Highlighter.Lexer
  alias Pyex.Highlighter.Lexers.Python
  alias Pyex.Highlighter.Style

  defp build(opts) do
    {:ok, o} = HTML.build_opts(opts)
    o
  end

  defp render(src, opts) do
    tokens = Lexer.tokenize(Python, src)
    HTML.format(tokens, build(opts))
  end

  test "wraps tokens in spans with Pygments short classes" do
    html = render("def x(): pass", style: "github-light")

    assert html =~ ~s(<div class="highlight"><pre><code>)
    assert html =~ ~s(<span class="k">def</span>)
    assert html =~ ~s(<span class="nf">x</span>)
    assert html =~ ~s(<span class="k">pass</span>)
    assert html =~ "</code></pre></div>"
  end

  test "escapes HTML metacharacters in source" do
    html = render("x = \"<script>\"", style: "github-light")
    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
  end

  test "cssclass option customizes outer div" do
    html = render("x = 1", cssclass: "my-code", style: "github-light")
    assert html =~ ~s(<div class="my-code">)
    refute html =~ ~s(<div class="highlight">)
  end

  test "nowrap option suppresses outer div and pre" do
    html = render("x = 1", nowrap: true, style: "github-light")
    refute html =~ "<div"
    refute html =~ "<pre"
    assert html =~ ~s(<span class=)
  end

  test "inline line numbers" do
    html = render("a = 1\nb = 2\nc = 3", linenos: :inline, style: "github-light")
    assert html =~ ~s(<span class="lineno">)
    # Three code lines → three numbered rows
    assert length(Regex.scan(~r/class="lineno"/, html)) == 3
  end

  test "table line numbers" do
    html = render("a\nb\nc", linenos: :table, style: "github-light")
    assert html =~ ~s(<table class="linenotable">)
    assert html =~ ~s(<td class="linenos">)
    assert html =~ ~s(<td class="code">)
  end

  describe "Highlighter.css/2" do
    test "built-in style yields CSS with class rules" do
      {:ok, css} = Highlighter.css("monokai")

      # Container rule
      assert css =~ ".highlight {"
      assert css =~ "background: #272822"
      # Keyword color
      assert css =~ ".k { color: #66d9ef"
      # Comment: italic
      assert css =~ ".c { color: #75715e; font-style: italic"
    end

    test "custom selector is respected" do
      {:ok, css} = Highlighter.css("monokai", ".code-block")
      assert css =~ ".code-block {"
      assert css =~ ".code-block .k {"
      refute css =~ ".highlight {"
    end

    test "custom style dict produces CSS" do
      dict = %{
        "Keyword" => "bold #ff0000",
        "Comment" => "italic #888888",
        "Literal.String" => "#00aa00"
      }

      {:ok, css} = Highlighter.css(dict)
      assert css =~ ".k { color: #ff0000; font-weight: bold }"
      assert css =~ ".c { color: #888888; font-style: italic"
      assert css =~ ".s { color: #00aa00"
    end

    test "returns error for unknown style name" do
      assert {:error, _} = Highlighter.css("does-not-exist")
    end
  end

  describe "Highlighter.highlight/3 end-to-end" do
    test "highlights Python with monokai" do
      {:ok, html} = Highlighter.highlight("def f(): return 1", "python", style: "monokai")
      assert html =~ ~s(<span class="k">def</span>)
      assert html =~ ~s(<span class="nf">f</span>)
      assert html =~ ~s(<span class="k">return</span>)
      assert html =~ ~s(<span class="mi">1</span>)
    end

    test "highlights JSON" do
      {:ok, html} = Highlighter.highlight(~s({"n": 1}), "json", style: "github-light")
      # We escape <, >, & — not quotes (they're safe in text content).
      assert html =~ ~s(<span class="nt">"n"</span>)
      assert html =~ ~s(<span class="m">1</span>)
    end

    test "unknown language returns error" do
      assert {:error, msg} = Highlighter.highlight("x", "cobol")
      assert msg =~ "cobol"
    end

    test "custom theme dict as :style option" do
      dict = %{"Keyword" => "#abc123 bold"}
      {:ok, html} = Highlighter.highlight("def f(): pass", "python", style: dict)
      assert html =~ ~s(<span class="k">def</span>)
      # CSS for this theme should match when requested
      {:ok, css} = Highlighter.css(dict)
      assert css =~ "color: #abc123"
      assert css =~ "font-weight: bold"
    end
  end

  describe "custom dict may set background and highlight colors" do
    test "background and highlight via reserved keys" do
      dict = %{
        "background" => "#1a1b26",
        "highlight" => "#33467c",
        "Keyword" => "bold #bb9af7"
      }

      style = Style.from_dict(dict)
      assert style.background_color == "#1a1b26"
      assert style.highlight_color == "#33467c"
      assert style.styles[:keyword].color == "#bb9af7"

      {:ok, css} = Highlighter.css(dict)
      assert css =~ "background: #1a1b26"
      assert css =~ "background-color: #33467c"
    end

    test "hyphen/underscore aliases work for bg" do
      for key <- ["background-color", "background_color"] do
        style = Style.from_dict(%{key => "#000000", "Keyword" => "#fff"})
        assert style.background_color == "#000000"
      end
    end

    test "works end-to-end via the Python-facing API" do
      result =
        Pyex.run!(~S"""
        from pygments.formatters import HTMLFormatter
        theme = {"background": "#112233", "Keyword": "bold #abcdef"}
        HTMLFormatter(style=theme).get_style_defs(".demo")
        """)

      assert result =~ ".demo { background: #112233"
      assert result =~ ".demo .k { color: #abcdef; font-weight: bold }"
    end
  end

  describe "CSS emission walks token ancestry" do
    test "defining only :comment produces CSS rules for all comment sub-types" do
      dict = %{"Comment" => "italic #808080"}
      {:ok, css} = Highlighter.css(dict, ".c-inherit")

      # Parent
      assert css =~ ".c-inherit .c { color: #808080; font-style: italic"
      # Children inherit the color via ancestry
      assert css =~ ".c-inherit .ch { color: #808080; font-style: italic"
      assert css =~ ".c-inherit .c1 { color: #808080; font-style: italic"
      assert css =~ ".c-inherit .cm { color: #808080; font-style: italic"
    end

    test "child override wins over parent" do
      dict = %{
        "Comment" => "#808080",
        "Comment.Hashbang" => "bold #ff0000"
      }

      {:ok, css} = Highlighter.css(dict)

      assert css =~ ".c { color: #808080"
      assert css =~ ".ch { color: #ff0000; font-weight: bold"
      # Siblings still inherit parent
      assert css =~ ".c1 { color: #808080"
    end
  end

  describe "Style.rule_for — inheritance" do
    test "unset child inherits from parent" do
      dict = %{"Literal.String" => "#00ff00"}
      style = Style.from_dict(dict)

      # :string_double inherits from :string → should get green
      rule = Style.rule_for(style, :string_double)
      assert rule.color == "#00ff00"

      # :keyword is in a different branch → no inheritance
      rule2 = Style.rule_for(style, :keyword)
      assert rule2.color == nil
    end
  end
end
