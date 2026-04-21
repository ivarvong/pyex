defmodule Pyex.Stdlib.PygmentsTest do
  use ExUnit.Case, async: true

  describe "basic Pygments-compatible API from Python" do
    test "import pygments + highlight(code, lexer, formatter)" do
      result =
        Pyex.run!(~S"""
        from pygments import highlight
        from pygments.lexers import PythonLexer
        from pygments.formatters import HTMLFormatter

        code = "def f(): return 1"
        highlight(code, PythonLexer(), HTMLFormatter(style="monokai"))
        """)

      assert is_binary(result)
      assert result =~ ~s(<span class="k">def</span>)
      assert result =~ ~s(<span class="nf">f</span>)
      assert result =~ ~s(<span class="k">return</span>)
    end

    test "HTMLFormatter.get_style_defs returns CSS scoped to selector" do
      result =
        Pyex.run!(~S"""
        from pygments.formatters import HTMLFormatter
        fmt = HTMLFormatter(style="monokai")
        fmt.get_style_defs(".highlight")
        """)

      assert is_binary(result)
      assert result =~ ".highlight {"
      assert result =~ "background: #272822"
      assert result =~ ".highlight .k"
      assert result =~ ".highlight .c"
    end

    test "HTMLFormatter.get_style_defs() without args uses cssclass" do
      result =
        Pyex.run!(~S"""
        from pygments.formatters import HTMLFormatter
        fmt = HTMLFormatter(style="monokai", cssclass="my-code")
        fmt.get_style_defs()
        """)

      assert result =~ ".my-code {"
      assert result =~ ".my-code .k"
    end

    test "get_lexer_by_name" do
      result =
        Pyex.run!(~S"""
        from pygments import highlight
        from pygments.lexers import get_lexer_by_name
        from pygments.formatters import HTMLFormatter

        highlight("print(1)", get_lexer_by_name("python"), HTMLFormatter())
        """)

      assert result =~ ~s(<span class="nb">print</span>)
    end

    test "get_style_by_name returns style metadata" do
      result =
        Pyex.run!(~S"""
        from pygments.styles import get_style_by_name
        s = get_style_by_name("monokai")
        s["name"]
        """)

      assert result == "monokai"
    end
  end

  describe "all supported languages work through the Pygments API" do
    for {lang, ctor, code, expected_class} <- [
          {"python", "PythonLexer", "def f(): pass", "k"},
          {"json", "JSONLexer", ~s({"n": 1}), "nt"},
          {"bash", "BashLexer", "echo hi", "nb"},
          {"javascript", "JavascriptLexer", "const x = 1", "k"},
          {"typescript", "TypescriptLexer", "type X = number", "kd"},
          {"jsx", "JSXLexer", "<div>hi</div>", "nt"},
          {"tsx", "TSXLexer", "const El = () => <div />", "k"},
          {"elixir", "ElixirLexer", "def foo(), do: :ok", "kd"}
        ] do
      test "#{lang} highlights with class .#{expected_class}" do
        result =
          Pyex.run!(~s"""
          from pygments import highlight
          from pygments.lexers import #{unquote(ctor)}
          from pygments.formatters import HTMLFormatter
          highlight(#{inspect(unquote(code))}, #{unquote(ctor)}(), HTMLFormatter(style="github-light"))
          """)

        assert result =~ ~s(class="#{unquote(expected_class)}"),
               "expected class=\"#{unquote(expected_class)}\" in:\n#{result}"
      end
    end
  end

  describe "custom themes" do
    test "HTMLFormatter accepts a dict as style" do
      result =
        Pyex.run!(~S"""
        from pygments import highlight
        from pygments.lexers import PythonLexer
        from pygments.formatters import HTMLFormatter

        my_theme = {
            "Keyword": "bold #ff00ff",
            "Comment": "italic #888888",
            "Name.Function": "#00aaff"
        }
        fmt = HTMLFormatter(style=my_theme)
        fmt.get_style_defs(".demo")
        """)

      assert result =~ ".demo .k { color: #ff00ff; font-weight: bold }"
      assert result =~ ".demo .c { color: #888888; font-style: italic"
      assert result =~ ".demo .nf { color: #00aaff"
    end

    test "custom theme dict actually used to highlight" do
      result =
        Pyex.run!(~S"""
        from pygments import highlight
        from pygments.lexers import PythonLexer
        from pygments.formatters import HTMLFormatter

        theme = {"Keyword": "bold #ff0000"}
        highlight("def f(): pass", PythonLexer(), HTMLFormatter(style=theme))
        """)

      # The output HTML should wrap 'def' in a span with class 'k'
      assert result =~ ~s(<span class="k">def</span>)
    end
  end

  describe "formatter options" do
    test "cssclass customizes outer div" do
      result =
        Pyex.run!(~S"""
        from pygments import highlight
        from pygments.lexers import PythonLexer
        from pygments.formatters import HTMLFormatter

        highlight("x = 1", PythonLexer(), HTMLFormatter(cssclass="post-code"))
        """)

      assert result =~ ~s(<div class="post-code">)
    end

    test "linenos = 'inline' produces line number spans" do
      result =
        Pyex.run!(~S"""
        from pygments import highlight
        from pygments.lexers import PythonLexer
        from pygments.formatters import HTMLFormatter

        highlight("a = 1\nb = 2", PythonLexer(), HTMLFormatter(linenos="inline"))
        """)

      assert result =~ ~s(<span class="lineno">)
    end
  end

  describe "error handling" do
    test "unknown lexer name" do
      assert_raise RuntimeError, ~r/no lexer for "cobol"/, fn ->
        Pyex.run!(~S"""
        from pygments.lexers import get_lexer_by_name
        get_lexer_by_name("cobol")
        """)
      end
    end

    test "unknown style name" do
      assert_raise RuntimeError, ~r/unknown style/, fn ->
        Pyex.run!(~S"""
        from pygments.formatters import HTMLFormatter
        HTMLFormatter(style="unknown-style")
        """)
      end
    end
  end

  describe "SSR blog integration" do
    test "highlights a code block and embeds it in a page" do
      result =
        Pyex.run!(~S"""
        from pygments import highlight
        from pygments.lexers import PythonLexer
        from pygments.formatters import HTMLFormatter

        snippet = "def greet(name):\n    return f'Hello, {name}'"
        fmt = HTMLFormatter(style="github-light", cssclass="highlight")
        code_html = highlight(snippet, PythonLexer(), fmt)
        css = fmt.get_style_defs(".highlight")

        f"<style>{css}</style>\n{code_html}"
        """)

      assert result =~ "<style>.highlight {"
      assert result =~ ~s(<div class="highlight"><pre><code>)
      assert result =~ ~s(<span class="k">def</span>)
      assert result =~ ~s(<span class="nf">greet</span>)
    end
  end
end
