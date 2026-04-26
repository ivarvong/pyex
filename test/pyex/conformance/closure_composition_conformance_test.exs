defmodule Pyex.Conformance.ClosureCompositionTest do
  @moduledoc """
  Conformance tests for the *composition* of user-function calls with
  caller-side state mutation.

  The motivating bug: a closure call refreshed only the bottom (global)
  scope of the captured env, so middle scopes were stale snapshots from
  `def` time. Calling the closure from inside a nested for-loop in the
  enclosing function then propagated the stale snapshot back to the
  caller — wiping every binding the loop had added (e.g. `i`, `x`).

  Per-axis tests for closures, loops, and mutation each passed in
  isolation. The bug only appeared when all three were combined. These
  tests deliberately *cross* the axes:

    closure / class method / __init__ / generator / recursion
                                ×
    for / while / list comp / dict comp / gen comp / with / try
                                ×
    "caller's locals must still be intact after the call returns"

  Slow axis at the top (kind of callable), fast axis at the bottom
  (call-site context). Any divergence from CPython is a real bug.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "closure called inside caller-side iteration" do
    test "nested for-loop with f-string after closure call" do
      check!("""
      def outer():
          captured = 1
          def inner(): return captured
          for i in [1, 2]:
              for x in ['a', 'b']:
                  r = inner()
                  print(f"{i}:{x}:{r}")
      outer()
      """)
    end

    test "while loop with closure call" do
      check!("""
      def outer():
          val = 10
          def get(): return val
          n = 0
          while n < 3:
              y = get()
              print((n, y))
              n += 1
      outer()
      """)
    end

    test "list comprehension calling closure" do
      check!("""
      def outer():
          val = 10
          def get(): return val
          out = [(i, get()) for i in range(3)]
          print(out)
      outer()
      """)
    end

    test "dict comprehension calling closure" do
      check!("""
      def outer():
          val = 10
          def get(): return val
          out = {i: get() for i in range(3)}
          print(sorted(out.items()))
      outer()
      """)
    end

    test "generator expression calling closure" do
      check!("""
      def outer():
          val = 10
          def get(): return val
          out = list(get() + i for i in range(3))
          print(out)
      outer()
      """)
    end

    test "three levels of nested loops with closure call" do
      check!("""
      def outer():
          cap = 7
          def inner(): return cap
          for i in range(2):
              for j in range(2):
                  for k in range(2):
                      print((i, j, k, inner()))
      outer()
      """)
    end
  end

  describe "caller's local state mutates between closure calls" do
    test "captured list mutates while caller iterates" do
      check!("""
      def outer():
          val = [1]
          def get(): return val[0]
          acc = []
          for i in range(3):
              acc.append((i, get()))
              val[0] += 10
          print(acc)
      outer()
      """)
    end

    test "closure mutates captured list across nested loops" do
      check!("""
      def outer():
          items = [0]
          def push(v): items.append(v)
          for i in range(3):
              push(i)
              for j in range(2):
                  push(i * 10 + j)
          print(items)
      outer()
      """)
    end

    test "nonlocal write from closure called in nested loop" do
      check!("""
      def outer():
          total = 0
          def add(n):
              nonlocal total
              total += n
          for i in range(3):
              for j in range(2):
                  add(i * 10 + j)
          print(total)
      outer()
      """)
    end
  end

  describe "closure call wrapped in caller-side control flow" do
    test "try/except around closure call in loop" do
      check!("""
      def outer():
          val = 10
          def get(): return val
          for i in range(2):
              try:
                  y = get()
              except Exception:
                  y = -1
              print((i, y))
      outer()
      """)
    end

    test "with block around closure call in loop" do
      check!("""
      class Ctx:
          def __enter__(self): return self
          def __exit__(self, *a): return False
      def outer():
          val = 10
          def get(): return val
          for i in range(2):
              with Ctx() as c:
                  y = get()
              print((i, y))
      outer()
      """)
    end
  end

  describe "non-closure callables also exercise the same scope path" do
    test "class method called in nested loop preserves caller locals" do
      check!("""
      class Bag:
          def __init__(self): self.items = []
          def add(self, x): self.items.append(x)
      def outer():
          b = Bag()
          for i in [1, 2]:
              for x in ['a', 'b']:
                  b.add((i, x))
          print(b.items)
      outer()
      """)
    end

    test "__init__ called in nested loop preserves caller locals" do
      check!("""
      class Thing:
          def __init__(self, n):
              self.n = n
      def outer():
          things = []
          for i in range(2):
              for x in ['a', 'b']:
                  things.append((i, x, Thing(i).n))
          print(things)
      outer()
      """)
    end

    test "recursive function called from loop preserves loop var" do
      check!("""
      def outer():
          def fact(n):
              if n <= 1: return 1
              return n * fact(n - 1)
          for i in range(1, 5):
              print((i, fact(i)))
      outer()
      """)
    end

    test "generator function iterated in nested loop preserves outer loop var" do
      check!("""
      def outer():
          base = 100
          def gen():
              yield base
              yield base + 1
          for i in range(2):
              for x in gen():
                  print((i, x))
      outer()
      """)
    end
  end

  describe "captured mutable state shared across method calls" do
    test "class method aug-subscript-assigns shared captured list" do
      # Regression: `counter[0] += 1` inside a class method went through
      # `Env.put_at_source` on the *name* `counter` instead of writing
      # back to the heap. For regular closures this was masked by
      # `update_closure_env` patching the function's stored closure_env;
      # class methods have no such patch path, so every method call saw
      # a fresh `counter = [0]` from the def-time snapshot.
      check!("""
      def outer():
          counter = [0]
          class C:
              def tick(self):
                  counter[0] += 1
                  return counter[0]
          return C
      C = outer()
      a = C()
      b = C()
      print(a.tick())
      print(b.tick())
      print(a.tick())
      """)
    end

    test "two classes from same factory have independent captured state" do
      check!("""
      def make_cls(label):
          counter = [0]
          class C:
              def __init__(self, name):
                  self.name = name
              def tick(self):
                  counter[0] += 1
                  return (label, self.name, counter[0])
          return C

      CA = make_cls("A")
      CB = make_cls("B")
      a1 = CA("a1")
      a2 = CA("a2")
      b1 = CB("b1")
      out = [a1.tick(), b1.tick(), a2.tick(), a1.tick(), b1.tick()]
      print(out)
      """)
    end

    test "method aug-assigns captured dict counter" do
      check!("""
      def outer():
          counts = {"hits": 0}
          class C:
              def hit(self):
                  counts["hits"] += 1
                  return counts["hits"]
          return C
      C = outer()
      a = C()
      print(a.hit())
      print(a.hit())
      print(a.hit())
      """)
    end
  end

  describe "closure scope isolation under loop pressure" do
    test "closure shadows loop variable without leaking" do
      check!("""
      def outer():
          captured = 1
          def inner():
              i = 999
              return captured + i
          for i in [10, 20]:
              y = inner()
              print((i, y))
      outer()
      """)
    end

    test "closure's local does not leak into caller scope" do
      check!("""
      def outer():
          def inner():
              new_local = 42
              return new_local
          for i in range(2):
              y = inner()
              try:
                  _ = new_local
                  print("BUG: leaked")
              except NameError:
                  print((i, y, "ok"))
      outer()
      """)
    end

    test "closure returned from already-exited function called in loop" do
      check!("""
      def make():
          captured = 99
          def f(): return captured
          return f
      def outer():
          g = make()
          for i in range(2):
              for x in range(2):
                  print((i, x, g()))
      outer()
      """)
    end
  end
end
