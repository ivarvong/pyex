defmodule Pyex.Conformance.OperatorTest do
  @moduledoc """
  Live CPython conformance tests for the `operator` module.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "arithmetic functions" do
    for {label, expr} <- [
          {"add", "operator.add(3, 4)"},
          {"sub", "operator.sub(10, 3)"},
          {"mul_int", "operator.mul(3, 5)"},
          {"mul_str", ~S|operator.mul("ab", 3)|},
          {"truediv", "operator.truediv(10, 4)"},
          {"floordiv", "operator.floordiv(10, 3)"},
          {"floordiv_neg", "operator.floordiv(-10, 3)"},
          {"mod", "operator.mod(10, 3)"},
          {"pow", "operator.pow(2, 10)"},
          {"neg", "operator.neg(5)"},
          {"abs", "operator.abs(-7)"}
        ] do
      test "#{label}" do
        check!("import operator\nprint(#{unquote(expr)})")
      end
    end
  end

  describe "bitwise functions" do
    for {label, expr} <- [
          {"and_", "operator.and_(0b1100, 0b1010)"},
          {"or_", "operator.or_(0b1100, 0b1010)"},
          {"xor", "operator.xor(0b1100, 0b1010)"},
          {"invert", "operator.invert(5)"},
          {"lshift", "operator.lshift(1, 5)"},
          {"rshift", "operator.rshift(32, 2)"}
        ] do
      test "#{label}" do
        check!("import operator\nprint(#{unquote(expr)})")
      end
    end
  end

  describe "comparison functions" do
    for {label, expr} <- [
          {"lt", "operator.lt(3, 5)"},
          {"le equal", "operator.le(3, 3)"},
          {"eq", "operator.eq(3, 3)"},
          {"ne", "operator.ne(3, 4)"},
          {"gt", "operator.gt(5, 3)"},
          {"ge", "operator.ge(3, 3)"}
        ] do
      test "#{label}" do
        check!("import operator\nprint(#{unquote(expr)})")
      end
    end
  end

  describe "container functions" do
    test "contains" do
      check!("import operator\nprint(operator.contains([1, 2, 3], 2))")
    end

    test "contains miss" do
      check!("import operator\nprint(operator.contains([1, 2, 3], 99))")
    end

    test "countOf" do
      check!("import operator\nprint(operator.countOf([1, 2, 2, 3, 2], 2))")
    end

    test "indexOf" do
      check!("import operator\nprint(operator.indexOf([10, 20, 30], 20))")
    end

    test "getitem list" do
      check!("import operator\nprint(operator.getitem([10, 20, 30], 1))")
    end

    test "getitem dict" do
      check!(~S|import operator
print(operator.getitem({"a": 1, "b": 2}, "a"))|)
    end

    test "concat" do
      check!("import operator\nprint(operator.concat([1, 2], [3, 4]))")
    end
  end

  describe "factories" do
    test "itemgetter single" do
      check!("""
      import operator
      g = operator.itemgetter(1)
      print(g([10, 20, 30]))
      """)
    end

    test "itemgetter multiple" do
      check!("""
      import operator
      g = operator.itemgetter(0, 2)
      print(g([10, 20, 30]))
      """)
    end

    test "attrgetter" do
      check!("""
      import operator

      class Point:
          def __init__(self, x, y):
              self.x = x
              self.y = y

      p = Point(3, 4)
      g = operator.attrgetter("x")
      print(g(p))
      """)
    end

    test "sorted with itemgetter key" do
      check!("""
      import operator
      pairs = [(1, "banana"), (3, "apple"), (2, "cherry")]
      print(sorted(pairs, key=operator.itemgetter(1)))
      """)
    end
  end
end
