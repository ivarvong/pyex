defmodule Pyex.Conformance.TextwrapTest do
  @moduledoc """
  Live CPython conformance tests for the `textwrap` module.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "dedent" do
    test "removes common leading whitespace" do
      check!(~S"""
      import textwrap
      s = "    line1\n    line2\n    line3"
      print(repr(textwrap.dedent(s)))
      """)
    end

    test "handles mixed indent correctly" do
      check!(~S"""
      import textwrap
      s = "  a\n    b\n  c"
      print(repr(textwrap.dedent(s)))
      """)
    end

    test "empty lines do not count as indent" do
      check!(~S"""
      import textwrap
      s = "  a\n\n  b"
      print(repr(textwrap.dedent(s)))
      """)
    end

    test "no common indent leaves text unchanged" do
      check!(~S"""
      import textwrap
      s = "a\n  b\n    c"
      print(repr(textwrap.dedent(s)))
      """)
    end
  end

  describe "indent" do
    test "prefixes each non-empty line" do
      check!(~S"""
      import textwrap
      s = "a\nb\nc"
      print(repr(textwrap.indent(s, "> ")))
      """)
    end

    test "skips blank lines by default" do
      check!(~S"""
      import textwrap
      s = "a\n\nb"
      print(repr(textwrap.indent(s, "> ")))
      """)
    end
  end

  describe "fill" do
    test "wraps text into paragraph" do
      check!("""
      import textwrap
      s = "The quick brown fox jumps over the lazy dog"
      print(textwrap.fill(s, width=20))
      """)
    end
  end

  describe "wrap" do
    test "wraps into list of lines" do
      check!("""
      import textwrap
      s = "hello world this is a test of wrapping"
      print(textwrap.wrap(s, width=15))
      """)
    end
  end

  describe "shorten" do
    test "truncates long text with placeholder" do
      check!("""
      import textwrap
      s = "Hello world, this is some long text"
      print(textwrap.shorten(s, width=20))
      """)
    end
  end
end
