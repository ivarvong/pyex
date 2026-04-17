defmodule Pyex.Conformance.FstringTest do
  @moduledoc """
  Live CPython conformance tests for f-strings.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "basic interpolation" do
    test "simple variable" do
      check!(~S"""
      name = "world"
      print(f"hello {name}")
      """)
    end

    test "expression" do
      check!(~S"""
      print(f"{1 + 2}")
      """)
    end

    test "method call" do
      check!(~S"""
      s = "hello"
      print(f"{s.upper()}")
      """)
    end

    test "attribute access" do
      check!(~S"""
      class X: pass
      x = X()
      x.value = 42
      print(f"{x.value}")
      """)
    end

    test "subscript" do
      check!(~S"""
      d = {"k": "v"}
      print(f"{d['k']}")
      """)
    end

    test "multiple values" do
      check!(~S"""
      a, b = 1, 2
      print(f"{a} and {b}")
      """)
    end
  end

  describe "format specs" do
    for {label, expr} <- [
          {"fixed decimals", ~S|f"{3.14159:.2f}"|},
          {"fixed decimals 0", ~S|f"{42:.0f}"|},
          {"width padded", ~S|f"{42:5d}"|},
          {"width zero padded", ~S|f"{42:05d}"|},
          {"width string right", ~S|f"{'hi':>10}"|},
          {"width string left", ~S|f"{'hi':<10}"|},
          {"width string center", ~S|f"{'hi':^10}"|},
          {"width with fill", ~S|f"{'hi':*^10}"|},
          {"hex", ~S|f"{255:x}"|},
          {"hex upper", ~S|f"{255:X}"|},
          {"hex with 0x", ~S|f"{255:#x}"|},
          {"octal", ~S|f"{8:o}"|},
          {"binary", ~S|f"{5:b}"|},
          {"binary with 0b", ~S|f"{5:#b}"|},
          {"comma thousands", ~S|f"{1234567:,}"|},
          {"underscore thousands", ~S|f"{1234567:_}"|},
          {"percent", ~S|f"{0.25:.0%}"|},
          {"scientific", ~S|f"{1234.5:.2e}"|},
          {"general g", ~S|f"{1234.5:g}"|},
          {"sign plus", ~S|f"{42:+}"|},
          {"sign space", ~S|f"{42: }"|}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "conversion flags" do
    for {label, expr} <- [
          {"!r repr", ~S|f"{'hello'!r}"|},
          {"!s str", ~S|f"{42!s}"|},
          {"!r on list", ~S|f"{[1, 2, 3]!r}"|},
          {"!r on unicode string", ~S|f"{'café'!r}"|}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "nested format specs" do
    # Nested format spec braces (like f"{42:{w}d}") require the spec to
    # itself be parsed as an f-string.  Pyex doesn't support this yet;
    # see TODO.txt.  Tests live here as a future target.
    @tag :skip
    test "dynamic width" do
      check!(~S"""
      w = 8
      print(f"{42:{w}d}")
      """)
    end

    @tag :skip
    test "dynamic precision" do
      check!(~S"""
      p = 3
      print(f"{3.14159:.{p}f}")
      """)
    end
  end

  describe "self-documenting debug form" do
    test "= form basic" do
      check!(~S"""
      x = 42
      print(f"{x=}")
      """)
    end

    test "= with spec" do
      check!(~S"""
      x = 3.14159
      print(f"{x=:.2f}")
      """)
    end

    test "= with expression" do
      check!(~S"""
      a, b = 3, 4
      print(f"{a + b=}")
      """)
    end
  end

  describe "escaping" do
    test "literal braces via double" do
      check!(~S"""
      print(f"{{literal}}")
      """)
    end

    test "mixed literal and interp" do
      check!(~S"""
      x = 42
      print(f"{{x = {x}}}")
      """)
    end
  end

  describe "concatenation" do
    test "adjacent f-strings" do
      check!(~S"""
      name = "world"
      print(f"hello " f"{name}")
      """)
    end
  end

  describe "numeric formatting edge cases" do
    for {label, expr} <- [
          {"integer float", ~S|f"{3.0}"|},
          {"negative width", ~S|f"{-42:5}"|},
          {"float default", ~S|f"{3.14}"|},
          {"very small float", ~S|f"{0.0001}"|},
          {"very large float", ~S|f"{1e20}"|},
          {"zero", ~S|f"{0}"|},
          {"negative zero", ~S|f"{-0.0}"|}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end
end
