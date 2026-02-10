defmodule Pyex.Stdlib.MarkdownTest do
  use ExUnit.Case, async: true

  describe "markdown.markdown" do
    test "converts heading" do
      assert Pyex.run!("""
             import markdown
             markdown.markdown("# Hello")
             """) == "<h1>Hello</h1>"
    end

    test "converts paragraph" do
      assert Pyex.run!("""
             import markdown
             markdown.markdown("Hello world")
             """) == "<p>Hello world</p>"
    end

    test "converts bold text" do
      assert Pyex.run!("""
             import markdown
             markdown.markdown("**bold**")
             """) == "<p><strong>bold</strong></p>"
    end

    test "converts italic text" do
      assert Pyex.run!("""
             import markdown
             markdown.markdown("*italic*")
             """) == "<p><em>italic</em></p>"
    end

    test "converts inline code" do
      assert Pyex.run!("""
             import markdown
             markdown.markdown("`code`")
             """) == "<p><code>code</code></p>"
    end

    test "converts unordered list" do
      result =
        Pyex.run!("""
        import markdown
        markdown.markdown("- a\\n- b\\n- c")
        """)

      assert result =~ "<ul>"
      assert result =~ "<li>a</li>"
      assert result =~ "<li>b</li>"
      assert result =~ "<li>c</li>"
    end

    test "converts ordered list" do
      result =
        Pyex.run!("""
        import markdown
        markdown.markdown("1. first\\n2. second\\n3. third")
        """)

      assert result =~ "<ol>"
      assert result =~ "<li>first</li>"
      assert result =~ "<li>second</li>"
    end

    test "converts link" do
      assert Pyex.run!("""
             import markdown
             markdown.markdown("[click](http://example.com)")
             """) == "<p><a href=\"http://example.com\">click</a></p>"
    end

    test "converts code block" do
      result =
        Pyex.run!("""
        import markdown
        markdown.markdown("```\\nprint('hi')\\n```")
        """)

      assert result =~ "<pre><code>"
      assert result =~ "print(&#39;hi&#39;)" or result =~ "print('hi')"
    end

    test "converts blockquote" do
      result =
        Pyex.run!("""
        import markdown
        markdown.markdown("> quoted text")
        """)

      assert result =~ "<blockquote>"
      assert result =~ "quoted text"
    end

    test "converts horizontal rule" do
      result =
        Pyex.run!("""
        import markdown
        markdown.markdown("---")
        """)

      assert result =~ "<hr"
    end

    test "converts multiple headings" do
      result =
        Pyex.run!("""
        import markdown
        markdown.markdown("# H1\\n\\n## H2\\n\\n### H3")
        """)

      assert result =~ "<h1>H1</h1>"
      assert result =~ "<h2>H2</h2>"
      assert result =~ "<h3>H3</h3>"
    end

    test "converts complex document" do
      result =
        Pyex.run!("""
        import markdown
        text = "# Title\\n\\nSome **bold** and *italic* text.\\n\\n- item1\\n- item2"
        markdown.markdown(text)
        """)

      assert result =~ "<h1>Title</h1>"
      assert result =~ "<strong>bold</strong>"
      assert result =~ "<em>italic</em>"
      assert result =~ "<li>item1</li>"
    end

    test "handles empty string" do
      assert Pyex.run!("""
             import markdown
             markdown.markdown("")
             """) == ""
    end

    test "raises on non-string argument" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!("""
        import markdown
        markdown.markdown(42)
        """)
      end
    end
  end

  describe "from_import" do
    test "from markdown import markdown" do
      assert Pyex.run!("""
             from markdown import markdown
             markdown("# Test")
             """) == "<h1>Test</h1>"
    end
  end
end
