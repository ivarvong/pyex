defmodule Pyex.Conformance.BuiltinsTest do
  @moduledoc """
  Live CPython conformance tests for Python builtins.

  Covers sorted, min, max, sum, any, all, enumerate, zip, map, filter,
  range, len, abs, round, divmod, pow, and numeric conversion.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "sorted" do
    for {label, expr} <- [
          {"ints ascending", "sorted([3, 1, 4, 1, 5, 9, 2, 6])"},
          {"ints reverse", "sorted([3, 1, 4, 1, 5], reverse=True)"},
          {"strings", ~S|sorted(["banana", "apple", "cherry"])|},
          {"mixed case", ~S|sorted(["Banana", "apple", "Cherry"])|},
          {"by key", "sorted([(1, 'b'), (2, 'a'), (3, 'c')], key=lambda x: x[1])"},
          {"empty", "sorted([])"},
          {"single", "sorted([42])"},
          {"stable sort preserves input order",
           ~S|sorted([(1, "a"), (1, "b"), (1, "c")], key=lambda p: p[0])|},
          {"tuple input", "sorted((5, 3, 1, 4, 2))"},
          {"negative numbers", "sorted([-3, 1, -4, 1, -5, 9])"},
          {"dict keys default", ~S|sorted({"b": 2, "a": 1, "c": 3})|}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "min/max" do
    for {label, expr} <- [
          {"min list", "min([3, 1, 4, 1, 5])"},
          {"max list", "max([3, 1, 4, 1, 5])"},
          {"min varargs", "min(3, 1, 4, 1, 5)"},
          {"max varargs", "max(3, 1, 4, 1, 5)"},
          {"min key", ~S|min(["hello", "a", "world"], key=len)|},
          {"max key", ~S|max(["hello", "a", "world"], key=len)|},
          {"min default empty", "min([], default=0)"},
          {"max default empty", "max([], default=-1)"},
          {"min strings", ~S|min(["banana", "apple", "cherry"])|},
          {"min negative", "min(-3, -1, -4)"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "sum" do
    for {label, expr} <- [
          {"ints", "sum([1, 2, 3, 4, 5])"},
          {"empty", "sum([])"},
          {"empty with start", "sum([], 10)"},
          {"with start", "sum([1, 2, 3], 100)"},
          {"floats", "sum([0.1, 0.2, 0.3])"},
          {"range", "sum(range(1, 11))"},
          {"tuple of tuples with start", "sum([[1, 2], [3, 4]], [])"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "any/all" do
    for {label, expr} <- [
          {"any true", "any([False, False, True])"},
          {"any false", "any([False, False, False])"},
          {"any empty", "any([])"},
          {"all true", "all([True, 1, 'x'])"},
          {"all false", "all([True, 0, 'x'])"},
          {"all empty", "all([])"},
          {"with genexp", "any(x > 5 for x in range(10))"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "enumerate" do
    for {label, expr} <- [
          {"basic", ~S|list(enumerate(["a", "b", "c"]))|},
          {"start=1", ~S|list(enumerate(["a", "b", "c"], start=1))|},
          {"empty", "list(enumerate([]))"},
          {"with range", "list(enumerate(range(3)))"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "zip" do
    for {label, expr} <- [
          {"basic", "list(zip([1, 2, 3], ['a', 'b', 'c']))"},
          {"different lengths (truncates)", "list(zip([1, 2, 3], ['a', 'b']))"},
          {"three args", "list(zip([1, 2], ['a', 'b'], [True, False]))"},
          {"empty", "list(zip([], []))"},
          {"one empty", "list(zip([1, 2], []))"},
          {"with range", "list(zip(range(3), range(3, 6)))"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end

    test "strict=True raises on different lengths" do
      check!("""
      try:
          list(zip([1, 2, 3], ['a', 'b'], strict=True))
          print("no error")
      except ValueError as e:
          print("ValueError")
      """)
    end
  end

  describe "map/filter" do
    for {label, expr} <- [
          {"map single", "list(map(lambda x: x * 2, [1, 2, 3]))"},
          {"map multi-arg", "list(map(lambda x, y: x + y, [1, 2, 3], [10, 20, 30]))"},
          {"filter", "list(filter(lambda x: x > 2, [1, 2, 3, 4, 5]))"},
          {"filter None filters falsy", "list(filter(None, [0, 1, '', 'x', None, [], [1]]))"},
          {"map with str", ~S|list(map(str, [1, 2, 3]))|}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "range" do
    for {label, expr} <- [
          {"stop only", "list(range(5))"},
          {"start, stop", "list(range(2, 8))"},
          {"start, stop, step", "list(range(0, 20, 3))"},
          {"negative step", "list(range(10, 0, -1))"},
          {"empty", "list(range(5, 3))"},
          {"negative empty", "list(range(3, 5, -1))"},
          {"range len", "len(range(0, 100, 7))"},
          {"range in", "5 in range(10)"},
          {"range reversed", "list(reversed(range(5)))"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "len" do
    for {label, expr} <- [
          {"list", "len([1, 2, 3])"},
          {"string", ~S|len("hello")|},
          {"empty string", ~S|len("")|},
          {"unicode string", ~S|len("café")|},
          {"dict", ~S|len({"a": 1, "b": 2})|},
          {"set", "len({1, 2, 3})"},
          {"tuple", "len((1, 2, 3))"},
          {"range", "len(range(100))"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "abs" do
    for {label, expr} <- [
          {"positive int", "abs(5)"},
          {"negative int", "abs(-5)"},
          {"positive float", "abs(3.14)"},
          {"negative float", "abs(-3.14)"},
          {"zero", "abs(0)"},
          {"negative zero float", "abs(-0.0)"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "round" do
    for {label, expr} <- [
          {"int", "round(42)"},
          {"half", "round(2.5)"},
          {"half to even down", "round(2.5)"},
          {"half to even up", "round(3.5)"},
          {"negative half", "round(-2.5)"},
          {"two digits", "round(3.14159, 2)"},
          {"float no digits", "round(3.14)"},
          {"large number", "round(1234567.89, -3)"},
          {"negative digits", "round(12345, -2)"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "divmod" do
    for {label, expr} <- [
          {"positive", "divmod(17, 5)"},
          {"negative dividend", "divmod(-17, 5)"},
          {"negative divisor", "divmod(17, -5)"},
          {"both negative", "divmod(-17, -5)"},
          {"exact", "divmod(15, 5)"},
          {"floats", "divmod(10.5, 3)"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "pow" do
    for {label, expr} <- [
          {"int", "pow(2, 10)"},
          {"negative exp (float)", "pow(2, -1)"},
          {"mod", "pow(3, 5, 7)"},
          {"float base", "pow(2.5, 3)"},
          {"zero base zero exp", "pow(0, 0)"},
          {"one exp", "pow(7, 1)"},
          {"big mod", "pow(123456, 789, 1000)"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "int/float/str conversions" do
    for {label, expr} <- [
          {"int from str", ~S|int("42")|},
          {"int negative", ~S|int("-42")|},
          {"int with base", ~S|int("ff", 16)|},
          {"int binary", ~S|int("101", 2)|},
          {"int oct", ~S|int("777", 8)|},
          {"int from float truncates", "int(3.9)"},
          {"int negative float", "int(-3.9)"},
          {"int from bool", "int(True)"},
          {"float from int", "float(42)"},
          {"float from str", ~S|float("3.14")|},
          {"float sci notation", ~S|float("1e5")|},
          {"float inf", ~S|float("inf")|},
          {"str int", "str(42)"},
          {"str float", "str(3.14)"},
          {"str bool", "str(True)"},
          {"str none", "str(None)"},
          {"str list", "str([1, 2, 3])"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "bool" do
    for expr <- [
          "bool(0)",
          "bool(1)",
          "bool('')",
          "bool('x')",
          "bool([])",
          "bool([0])",
          "bool({})",
          "bool({'a': 1})",
          "bool(None)",
          "bool(0.0)",
          "bool(-0.0)"
        ] do
      test "#{expr}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "hex/oct/bin/chr/ord" do
    for {label, expr} <- [
          {"hex positive", "hex(255)"},
          {"hex zero", "hex(0)"},
          {"hex negative", "hex(-10)"},
          {"oct", "oct(8)"},
          {"oct zero", "oct(0)"},
          {"bin", "bin(5)"},
          {"bin zero", "bin(0)"},
          {"bin negative", "bin(-5)"},
          {"chr", "chr(65)"},
          {"chr unicode", "chr(0x1F600)"},
          {"ord ascii", ~S|ord("A")|},
          {"ord unicode", ~S|ord("é")|}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "repr quoting rules" do
    for {label, expr} <- [
          {"simple string", ~S|repr("hello")|},
          {"string with double quote", ~S|repr('say "hi"')|},
          {"string with single quote", ~S|repr("it's")|},
          {"string with both", ~S|repr("it's \"hi\"")|},
          {"empty string", ~S|repr("")|},
          {"unicode", ~S|repr("café")|},
          {"newline", ~S|repr("a\nb")|},
          {"tab", ~S|repr("a\tb")|},
          {"list of strings", ~S|repr(["a", "b", "c"])|},
          {"nested", ~S|repr([1, [2, 3], "x"])|},
          {"tuple", "repr((1, 2, 3))"},
          {"single tuple", "repr((1,))"},
          {"empty tuple", "repr(())"},
          {"dict", ~S|repr({"a": 1})|},
          {"set", "repr({1, 2, 3})"},
          {"empty set", "repr(set())"},
          {"none", "repr(None)"},
          {"bool", "repr(True)"},
          {"int", "repr(42)"},
          {"float", "repr(3.14)"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "hash" do
    test "hash is consistent for same value" do
      check!("""
      print(hash(42) == hash(42))
      print(hash("hello") == hash("hello"))
      print(hash((1, 2, 3)) == hash((1, 2, 3)))
      """)
    end
  end

  describe "isinstance" do
    for {label, expr} <- [
          {"int", "isinstance(42, int)"},
          {"bool is int", "isinstance(True, int)"},
          {"float not int", "isinstance(3.14, int)"},
          {"str", ~S|isinstance("hi", str)|},
          {"list", "isinstance([], list)"},
          {"dict", "isinstance({}, dict)"},
          {"tuple of types", "isinstance(42, (int, str))"},
          {"tuple of types miss", "isinstance(3.14, (int, str))"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end
end
