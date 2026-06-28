defmodule Pyex.GeneratorProtocolTest do
  @moduledoc """
  Regression tests for generator/coroutine protocol gaps found by a generator
  differential sweep against CPython 3.14. Each fix has a positive test
  (CPython-equal) and a negative test (clean Python exception, never a leaked
  crash).

  Scope of this pass: `gen.send(None)` priming and `StopIteration.value`. The
  deeper coroutine cases (throw-injection into a paused frame, `yield from`
  send/return passthrough, `close()` running `finally` lazily) are now handled
  by the lazy generator engine and asserted in
  `Pyex.LazyGeneratorTest`.
  """

  use ExUnit.Case, async: true

  defp out!(src) do
    {:ok, _v, ctx} = Pyex.run(src)
    String.trim(Pyex.output(ctx))
  end

  describe "gen.send(None) primes a just-started generator (== next)" do
    test "positive: send(None) advances an unstarted generator to its first yield" do
      assert out!("""
             def g():
                 x = yield 1
                 yield x + 10
             it = g()
             print(it.send(None))
             print(it.send(5))
             """) == "1\n15"
    end

    test "positive: send(None) on a generator that consumes the sent value" do
      assert out!("""
             def g():
                 x = yield 1
                 print("got", x)
             it = g()
             print(it.send(None))
             """) == "1"
    end

    test "negative: send(non-None) to a just-started generator is a TypeError" do
      assert out!("""
             def g():
                 yield 1
             it = g()
             try:
                 it.send(5)
             except TypeError:
                 print("TypeError")
             """) == "TypeError"
    end
  end

  describe "StopIteration carries .value" do
    test "positive: the constructor argument is exposed as .value" do
      assert out!("""
             try:
                 raise StopIteration(7)
             except StopIteration as e:
                 print(e.value)
             """) == "7"
    end

    test "positive: .value defaults to None with no argument" do
      assert out!("""
             try:
                 raise StopIteration()
             except StopIteration as e:
                 print(e.value)
             """) == "None"
    end

    test "negative: a different exception still has no .value attribute" do
      assert out!("""
             try:
                 raise ValueError("x").value
             except AttributeError:
                 print("AttributeError")
             """) == "AttributeError"
    end
  end

  describe "existing send/throw behaviour stays correct" do
    test "send(value) resumes a paused generator with the value" do
      assert out!("""
             def g():
                 x = yield 1
                 yield x + 10
             it = g()
             print(next(it))
             print(it.send(5))
             """) == "1\n15"
    end

    test "an uncaught throw propagates out of the generator" do
      assert out!("""
             def g():
                 yield 1
             it = g()
             next(it)
             try:
                 it.throw(KeyError("x"))
             except KeyError:
                 print("propagated")
             """) == "propagated"
    end
  end

  describe "yield from delegates the sub-generator's return value (PEP 380)" do
    test "positive: `r = yield from sub()` binds r to sub's return" do
      assert out!("""
             def sub():
                 yield 1
                 return 7
             def g():
                 r = yield from sub()
                 yield r
             print(list(g()))
             """) == "[1, 7]"
    end

    test "positive: the return value chains through nested yield from" do
      assert out!("""
             def a():
                 yield 1
                 return "A"
             def b():
                 r = yield from a()
                 return r + "B"
             def c():
                 r = yield from b()
                 yield r
             print(list(c()))
             """) == "[1, 'AB']"
    end

    test "negative: a bare `yield from` (return value unused) still iterates fully" do
      assert out!("""
             def sub():
                 yield 1
                 yield 2
                 return 99
             def g():
                 yield from sub()
                 yield 3
             print(list(g()))
             """) == "[1, 2, 3]"
    end
  end
end
