defmodule Pyex.Conformance.LazyGeneratorTest do
  @moduledoc """
  Conformance tests for **lazy** generator semantics.

  Pyex used to materialise generators eagerly: `for x in gen():`
  would run the entire generator first, accumulating yields into a
  list, *then* iterate the list. Programs that relied on yield-time
  side-effect ordering, mutation visibility across yields, or
  infinite generators with `break` got wrong answers (or hung).

  CPython generators are lazy iterators: each `next()` (whether
  driven by a `for` loop, `next()` builtin, `list()`, comprehension,
  or `yield from`) advances the generator one yield at a time. These
  tests cross every observable laziness signal:

    side-effect interleaving
    mutation across yield
    infinite + break
    next() identity (`g = gen(); next(g); next(g)`)
    interleaved iteration of two generators
    yield from with mid-stream exception
    nested generator delegation
    StopIteration on exhaustion
    materialisation via list/tuple/dict/sum/any/all
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "side-effect ordering" do
    test "before/after-yield prints interleave with consumer" do
      check!("""
      def gen():
          for i in range(3):
              print("before", i)
              yield i
              print("after", i)
      for x in gen():
          print("got", x)
      """)
    end

    test "consumer mutation observed across yields" do
      check!("""
      def outer():
          val = [0]
          def gen():
              for i in range(3):
                  yield (i, val[0])
          for tup in gen():
              print(tup)
              val[0] += 100
      outer()
      """)
    end

    test "generator side effects in two distinct phases" do
      check!("""
      log = []
      def gen():
          log.append("a")
          yield 1
          log.append("b")
          yield 2
          log.append("c")

      for x in gen():
          log.append(("got", x))
      print(log)
      """)
    end
  end

  describe "next() and iter() identity" do
    test "next(g) advances state across calls" do
      check!("""
      def gen():
          yield 10
          yield 20
          yield 30
      g = gen()
      print(next(g), next(g), next(g))
      """)
    end

    test "next() past exhaustion raises StopIteration" do
      check!("""
      def gen():
          yield 1
      g = gen()
      print(next(g))
      try:
          next(g)
          print("no-stop")
      except StopIteration:
          print("stopped")
      """)
    end

    test "next(g, default) returns default on exhaustion" do
      check!("""
      def gen():
          yield 1
      g = gen()
      print(next(g, -1), next(g, -1), next(g, -1))
      """)
    end

    test "iter() on a generator returns the generator itself" do
      check!("""
      def gen():
          yield 1
          yield 2
      g = gen()
      g2 = iter(g)
      print(next(g2))
      print(next(g))
      """)
    end
  end

  describe "infinite generators + break" do
    test "while True yield + break in for loop" do
      check!("""
      def naturals():
          i = 0
          while True:
              yield i
              i += 1
      out = []
      for x in naturals():
          if x >= 5: break
          out.append(x)
      print(out)
      """)
    end

    test "infinite generator drained by next() with manual break" do
      check!("""
      def naturals():
          i = 0
          while True:
              yield i
              i += 1
      g = naturals()
      out = []
      for _ in range(4):
          out.append(next(g))
      print(out)
      """)
    end
  end

  describe "interleaved iteration" do
    test "two generators stepped alternately" do
      check!("""
      def make():
          counter = [0]
          def gen():
              for _ in range(3):
                  counter[0] += 1
                  yield counter[0]
          return gen
      g1 = make()()
      g2 = make()()
      print([next(g1), next(g2), next(g1), next(g2), next(g1), next(g2)])
      """)
    end

    test "zip over two generators yields paired values" do
      check!("""
      def g1():
          yield 1; yield 2; yield 3
      def g2():
          yield "a"; yield "b"; yield "c"
      print(list(zip(g1(), g2())))
      """)
    end
  end

  describe "yield from delegation" do
    test "nested yield from chains values in order" do
      check!("""
      def inner(n):
          for j in range(2):
              yield n * 10 + j
      def outer():
          for i in range(3):
              yield from inner(i)
      print(list(outer()))
      """)
    end

    test "yield from surfaces exception mid-stream" do
      check!("""
      def inner():
          yield "a"
          raise RuntimeError("fail")
          yield "b"

      def outer():
          yield "start"
          yield from inner()
          yield "end"

      results = []
      try:
          for x in outer():
              results.append(x)
      except RuntimeError as e:
          results.append("caught: " + str(e))
      print(results)
      """)
    end

    test "yield from a list yields each element" do
      check!("""
      def gen():
          yield from [1, 2, 3]
          yield from "ab"
      print(list(gen()))
      """)
    end
  end

  describe "generator pipeline (chained transforms)" do
    test "filter -> map style chain via yield from" do
      check!("""
      def src():
          for i in range(10):
              yield i
      def even(it):
          for x in it:
              if x % 2 == 0:
                  yield x
      def square(it):
          for x in it:
              yield x * x
      print(list(square(even(src()))))
      """)
    end
  end

  describe "materialisation builtins drain lazily" do
    test "list(gen())" do
      check!("""
      def gen():
          for i in range(4):
              yield i * i
      print(list(gen()))
      """)
    end

    test "tuple(gen())" do
      check!("""
      def gen():
          yield "a"; yield "b"; yield "c"
      print(tuple(gen()))
      """)
    end

    test "dict from generator of pairs" do
      check!("""
      def pairs():
          yield ("x", 1)
          yield ("y", 2)
      print(sorted(dict(pairs()).items()))
      """)
    end

    test "sum/any/all over generator" do
      check!("""
      def gen():
          for i in range(5):
              yield i
      print(sum(gen()))
      print(any(gen() for _ in range(1) for x in range(0)))
      print(all(x > -1 for x in gen()))
      """)
    end

    test "min/max over generator" do
      check!("""
      def gen():
          yield 3; yield 1; yield 4; yield 1; yield 5; yield 9
      print(min(gen()))
      print(max(gen()))
      """)
    end

    test "sorted over generator" do
      check!("""
      def gen():
          yield 3; yield 1; yield 4; yield 1; yield 5
      print(sorted(gen()))
      """)
    end
  end

  describe "captured state across yields" do
    test "generator updates outer-captured list across yields" do
      check!("""
      def outer():
          base = [0]
          def gen():
              for i in range(3):
                  base[0] += 1
                  yield (i, base[0])
          for tup in gen():
              print(tup)
          print("final", base[0])
      outer()
      """)
    end

    test "two instances of the same generator factory don't share state" do
      check!("""
      def make():
          n = [0]
          def gen():
              for _ in range(3):
                  n[0] += 1
                  yield n[0]
          return gen
      g1 = make()()
      g2 = make()()
      print(list(g1))
      print(list(g2))
      """)
    end
  end
end
