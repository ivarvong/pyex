defmodule Pyex.LanguageGapsTest do
  @moduledoc """
  Regression tests for Python language-feature gaps found by a differential
  sweep against CPython 3 (valid Python that pyex parsed wrong, evaluated
  wrong, or crashed on). Each case is pinned to CPython's behaviour.
  """

  use ExUnit.Case, async: true

  defp out!(src) do
    {:ok, _v, ctx} = Pyex.run(src)
    String.trim(Pyex.output(ctx))
  end

  describe "the instance is the first parameter, whatever it's named" do
    test "attribute set via a non-`self` first param persists" do
      assert out!("""
             class C:
                 def __init__(s):
                     s.n = 1
             c = C()
             print(c.n)
             """) == "1"
    end

    test "augmented attribute assignment through a non-`self` param" do
      assert out!("""
             class C:
                 def __init__(this):
                     this.total = 10
                 def add(me, x):
                     me.total += x
             c = C()
             c.add(5)
             print(c.total)
             """) == "15"
    end
  end

  describe "attribute targets in tuple unpacking" do
    test "self.a, self.b = ... inside a method" do
      assert out!("""
             class P:
                 def __init__(self, x, y):
                     self.x, self.y = x, y
             p = P(3, 4)
             print(p.x, p.y)
             """) == "3 4"
    end

    test "mixed name and attribute targets" do
      assert out!("""
             class C:
                 pass
             c = C()
             a, c.b = 1, 2
             print(a, c.b)
             """) == "1 2"
    end

    test "swap through attributes" do
      assert out!("""
             class C:
                 pass
             c = C()
             c.a, c.b = 1, 2
             c.a, c.b = c.b, c.a
             print(c.a, c.b)
             """) == "2 1"
    end

    test "subscript and attribute targets together" do
      assert out!("""
             class C:
                 pass
             c = C()
             d = {}
             c.x, d["k"] = 7, 8
             print(c.x, d["k"])
             """) == "7 8"
    end
  end

  describe "del with multiple targets" do
    test "names" do
      assert out!("""
             a, b, c = 1, 2, 3
             del a, c
             print(b)
             try:
                 print(a)
             except NameError:
                 print("a gone")
             """) == "2\na gone"
    end

    test "subscripts and attributes, with trailing comma" do
      assert out!("""
             class C:
                 pass
             c = C()
             c.x = 1
             d = {"k": 1, "j": 2}
             del c.x, d["k"],
             print(d)
             print(hasattr(c, "x"))
             """) == "{'j': 2}\nFalse"
    end
  end

  describe "matmul operator @" do
    test "unsupported operands raise a clean TypeError (not a host crash)" do
      assert out!("""
             try:
                 print(3 @ 4)
             except TypeError as e:
                 print("TypeError")
             """) == "TypeError"
    end

    test "dispatches to __matmul__ / __rmatmul__" do
      assert out!("""
             class M:
                 def __init__(self, v):
                     self.v = v
                 def __matmul__(self, other):
                     return self.v * other.v
             print(M(3) @ M(4))
             """) == "12"
    end
  end
end
