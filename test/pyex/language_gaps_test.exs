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

  defp file_out!(src) do
    {:ok, _v, ctx} = Pyex.run(src, filesystem: Pyex.FS.new())
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

  describe "NotImplemented singleton and the binop reflection protocol" do
    test "NotImplemented has the right repr, type, and truthiness" do
      assert out!("""
             print(repr(NotImplemented))
             print(type(NotImplemented).__name__)
             print(bool(NotImplemented))
             """) == "NotImplemented\nNotImplementedType\nTrue"
    end

    test "a left dunder returning NotImplemented defers to the right __r-dunder" do
      assert out!("""
             class A:
                 def __add__(self, other):
                     return NotImplemented
             class B:
                 def __radd__(self, other):
                     return "right-handled"
             print(A() + B())
             """) == "right-handled"
    end

    test "both operands declining with NotImplemented raises TypeError" do
      assert out!("""
             class A:
                 def __add__(self, other):
                     return NotImplemented
             class B:
                 def __radd__(self, other):
                     return NotImplemented
             try:
                 A() + B()
             except TypeError:
                 print("TypeError")
             """) == "TypeError"
    end

    test "a builtin left operand falls back to the instance __r-dunder" do
      assert out!("""
             class Money:
                 def __radd__(self, other):
                     return other + 100
             print(5 + Money())
             """) == "105"
    end

    test "__eq__ returning NotImplemented defers to the other operand's __eq__" do
      assert out!("""
             class A:
                 def __eq__(self, other):
                     return NotImplemented
             class B:
                 def __eq__(self, other):
                     return True
             print(A() == B())
             """) == "True"
    end
  end

  describe "file object query and positioning methods" do
    test "readable / writable / seekable reflect the open mode" do
      assert file_out!("""
             f = open("a.txt", "w")
             print(f.writable(), f.readable(), f.seekable())
             f.write("data")
             f.close()
             g = open("a.txt")
             print(g.readable(), g.writable())
             """) == "True False True\nTrue False"
    end

    test "tell reports the write byte count, then the read cursor" do
      assert file_out!("""
             f = open("a.txt", "w")
             f.write("hello")
             print(f.tell())
             f.close()
             g = open("a.txt")
             g.read(2)
             print(g.tell())
             """) == "5\n2"
    end

    test "seek with all three whence modes repositions the read cursor" do
      assert file_out!("""
             f = open("a.txt", "w")
             f.write("abcdef")
             f.close()
             g = open("a.txt")
             g.seek(2)
             print(g.read())
             g.seek(0)
             g.seek(2, 1)
             print(g.read())
             g.seek(-2, 2)
             print(g.read())
             """) == "cdef\ncdef\nef"
    end

    test "writelines concatenates an iterable of strings without separators" do
      assert file_out!("""
             f = open("a.txt", "w")
             f.writelines(["a", "b", "c"])
             f.writelines(("d", "e"))
             f.close()
             print(open("a.txt").read())
             """) == "abcde"
    end

    test "truncate resizes the buffer and flush is a no-op returning None" do
      assert file_out!("""
             f = open("a.txt", "w")
             f.write("abcdef")
             print(f.flush())
             f.truncate(3)
             f.close()
             print(open("a.txt").read())
             """) == "None\nabc"
    end
  end

  describe "file data attributes (name, mode, closed)" do
    test "name and mode echo the open arguments" do
      assert file_out!("""
             f = open("notes.txt", "w")
             print(f.name, f.mode)
             f.write("x")
             f.close()
             g = open("notes.txt")
             print(g.name, g.mode)
             a = open("notes.txt", "a")
             print(a.mode)
             """) == "notes.txt w\nnotes.txt r\na"
    end

    test "closed flips from False to True after close()" do
      assert file_out!("""
             f = open("a.txt", "w")
             print(f.closed)
             f.close()
             print(f.closed)
             """) == "False\nTrue"
    end

    test "dir(file) surfaces the data attributes alongside the methods" do
      assert file_out!("""
             f = open("a.txt", "w")
             names = dir(f)
             print(all(a in names for a in ["closed", "mode", "name"]))
             print(all(m in names for m in ["read", "write", "seek", "tell"]))
             """) == "True\nTrue"
    end
  end
end
