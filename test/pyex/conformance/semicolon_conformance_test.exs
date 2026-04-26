defmodule Pyex.Conformance.SemicolonTest do
  @moduledoc """
  Conformance tests for `;` as a small-statement separator.

  Python permits `;` to chain small statements on a single physical
  line, both at the top level (`a = 1; b = 2`) and as the inline body
  of any compound statement (`def f(): a; b`, `if cond: a; b`, etc.).

  Pyex's lexer used to rewrite `;` to `\\n + current-line-indent`,
  which silently broke compound statements: `def f(): return 1;
  print("never")` parsed `print("never")` as a *sibling* of `def f`,
  so the `return 1` exited early and `print("never")` ran at the
  surrounding scope. Lethal because programs ran without error but
  produced wrong answers.

  These tests cross every compound statement that accepts an inline
  body with multi-statement `;` chaining.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "semicolons at module level" do
    test "two small stmts on one line" do
      check!("a = 1; b = 2; print(a, b)\n")
    end

    test "trailing semicolon" do
      check!("a = 1; b = 2;\nprint(a, b)\n")
    end

    test "many stmts, mixed kinds" do
      check!("""
      x = 0; x += 1; x *= 3; x -= 2
      print(x)
      """)
    end
  end

  describe "semicolons inside multi-line block" do
    test "in if body" do
      check!("""
      if True:
          a = 1; b = 2
          print(a, b)
      """)
    end

    test "in def body" do
      check!("""
      def f():
          a = 1; b = 2
          return a + b
      print(f())
      """)
    end
  end

  describe "single-line compound statements" do
    test "def with two-stmt inline body" do
      check!("""
      def f(): a = 1; return a + 10
      print(f())
      """)
    end

    test "def whose inline body is return-then-unreachable" do
      # The bug: Pyex used to lift `print("never")` out of the def's
      # body into the surrounding block. CPython treats it as part of
      # f's body — unreachable after `return`.
      check!("""
      def f(): return 1; print("never")
      print(f())
      """)
    end

    test "def with mutating closure body across two stmts" do
      check!("""
      def outer():
          base = [0]
          def bump(): base[0] += 1; return base[0]
          print(bump())
          print(bump())
          print(bump())
      outer()
      """)
    end

    test "if with two-stmt inline body, condition true" do
      check!("if True: a = 1; b = 2; print(a, b)\n")
    end

    test "if with two-stmt inline body, condition false" do
      check!("""
      if False: a = 1; b = 2; print("nope")
      print("after")
      """)
    end

    test "if/else inline both branches multi-stmt" do
      check!("""
      x = 5
      if x > 0: a = "pos"; b = x
      else: a = "neg"; b = -x
      print(a, b)
      """)
    end

    test "elif inline multi-stmt" do
      check!("""
      def classify(n):
          if n < 0: kind = "neg"; mag = -n
          elif n == 0: kind = "zero"; mag = 0
          else: kind = "pos"; mag = n
          return (kind, mag)
      print(classify(-5))
      print(classify(0))
      print(classify(7))
      """)
    end

    test "for inline multi-stmt body" do
      check!("for i in range(3): a = i*10; print(a)\n")
    end

    test "while inline multi-stmt body" do
      check!("""
      n = 0
      while n < 3: x = n*n; print(x); n += 1
      """)
    end

    test "class with inline multi-stmt body" do
      check!("""
      class C: x = 1; y = 2
      print(C.x, C.y)
      """)
    end

    # Inline-body forms for `try` and `with` are not supported by Pyex's
    # parser (separate feature gap, predates the semicolon fix). Tests
    # for those two would belong in a feature-coverage suite, not here.

    test "match case inline multi-stmt" do
      check!("""
      def f(x):
          match x:
              case 1: a = "one"; b = 1
              case 2: a = "two"; b = 2
              case _: a = "other"; b = -1
          return (a, b)
      print(f(1))
      print(f(2))
      print(f(99))
      """)
    end

    test "nested inline def inside outer def with semis" do
      check!("""
      def outer():
          def inner(): a = 10; return a + 5
          return inner() + 100
      print(outer())
      """)
    end
  end

  describe "edge cases that previously hid the bug" do
    test "trailing semicolon on inline body" do
      check!("""
      def f(): return 42;
      print(f())
      """)
    end

    test "semicolon then unreachable raise" do
      check!("""
      def f(): return 1; raise ValueError("never")
      print(f())
      """)
    end

    test "semicolons across nested compound statements" do
      check!("""
      def outer():
          if True: a = 1; b = 2
          if a == 1: c = a + b; print(c)
      outer()
      """)
    end

    test "augmented assigns and subscript assigns mixed via semicolons" do
      check!("""
      lst = [0, 0, 0]
      d = {"k": 0}
      lst[0] = 1; lst[1] += 10; d["k"] += 5
      print(lst, sorted(d.items()))
      """)
    end
  end
end
