defmodule Pyex.Stdlib.HtmlTest do
  use ExUnit.Case, async: true

  describe "html.escape" do
    test "escapes ampersand" do
      assert Pyex.run!(~S|import html; html.escape("AT&T")|) == "AT&amp;T"
    end

    test "escapes angle brackets" do
      assert Pyex.run!(~S|import html; html.escape("<script>alert('xss')</script>")|) ==
               "&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;"
    end

    test "escapes double quotes" do
      assert Pyex.run!(~S|import html; html.escape('a "b" c')|) == ~S|a &quot;b&quot; c|
    end

    test "escapes single quotes" do
      assert Pyex.run!(~S|import html; html.escape("it's")|) == "it&#x27;s"
    end

    test "no-op on safe strings" do
      assert Pyex.run!(~S|import html; html.escape("hello world")|) == "hello world"
    end

    test "empty string" do
      assert Pyex.run!(~S|import html; html.escape("")|) == ""
    end

    test "all five entities at once" do
      assert Pyex.run!(~S|import html; html.escape("&<>\"'")|) ==
               ~S|&amp;&lt;&gt;&quot;&#x27;|
    end

    test "quote=False skips quote escaping" do
      assert Pyex.run!(~S|import html; html.escape('a "b" c', False)|) == ~S|a "b" c|
    end
  end

  describe "html.unescape" do
    test "unescapes all entities" do
      assert Pyex.run!(~S|import html; html.unescape("&amp;&lt;&gt;&quot;&#x27;")|) ==
               "&<>\"'"
    end

    test "unescapes numeric reference" do
      assert Pyex.run!(~S|import html; html.unescape("&#39;")|) == "'"
    end

    test "no-op on plain text" do
      assert Pyex.run!(~S|import html; html.unescape("hello")|) == "hello"
    end

    test "roundtrip" do
      result =
        Pyex.run!(~S"""
        import html
        s = "<h1>\"Hello\" & 'World'</h1>"
        html.unescape(html.escape(s))
        """)

      assert result == "<h1>\"Hello\" & 'World'</h1>"
    end
  end

  describe "from_import" do
    test "from html import escape" do
      assert Pyex.run!(~S|from html import escape; escape("<b>")|) == "&lt;b&gt;"
    end
  end

  describe "error handling" do
    test "escape with non-string raises TypeError" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!(~S|import html; html.escape(42)|)
      end
    end

    test "unescape with non-string raises TypeError" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!(~S|import html; html.unescape(42)|)
      end
    end
  end
end
