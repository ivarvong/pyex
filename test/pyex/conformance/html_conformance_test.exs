defmodule Pyex.Conformance.HTMLTest do
  @moduledoc """
  Live CPython conformance tests for the `html` module.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "html.escape" do
    for {label, input} <- [
          {"plain", ~s|"hello world"|},
          {"ampersand", ~s|"a & b"|},
          {"less than", ~s|"a < b"|},
          {"greater than", ~s|"a > b"|},
          {"single quote", "\"it's\""},
          {"double quote", ~S|'"hi"'|},
          {"mixed", ~s|"<a href=\\"/foo?x=1&y=2\\">bar</a>"|},
          {"empty", ~s|""|},
          {"already escaped", ~s|"&amp;"|}
        ] do
      test "escape #{label}" do
        check!("""
        import html
        print(html.escape(#{unquote(input)}))
        """)
      end
    end

    test "escape with quote=False" do
      check!(~S"""
      import html
      print(html.escape('"hi"', quote=False))
      """)
    end
  end

  describe "html.unescape" do
    for {label, input} <- [
          {"amp", ~s|"&amp;"|},
          {"lt gt", ~s|"&lt;a&gt;"|},
          {"quot", ~s|"&quot;hi&quot;"|},
          {"apos", ~s|"it&#x27;s"|},
          {"numeric", ~s|"&#65;"|},
          {"hex numeric", ~s|"&#x41;"|},
          {"unicode", ~s|"&#228;"|},
          {"mixed", ~s|"&lt;a href=&quot;/foo&quot;&gt;bar&lt;/a&gt;"|},
          {"not an entity", ~s|"& foo"|},
          {"plain", ~s|"hello"|}
        ] do
      test "unescape #{label}" do
        check!("""
        import html
        print(html.unescape(#{unquote(input)}))
        """)
      end
    end
  end

  describe "roundtrip" do
    for input <- [
          "plain text",
          "a & b < c",
          "<script>alert('xss')</script>",
          "\"quoted\"",
          "mixed <>&\" chars"
        ] do
      test "escape -> unescape round-trips: #{input}" do
        check!("""
        import html
        s = #{inspect(unquote(input))}
        print(html.unescape(html.escape(s)) == s)
        """)
      end
    end
  end
end
