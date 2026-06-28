defmodule Pyex.LazyGeneratorTest do
  @moduledoc """
  Conformance tests for the lazy generator engine: generators run nothing at
  creation and advance one `yield` at a time on demand, exactly like CPython.

  These cover the four divergences that the previous eager (prime-at-creation /
  lookahead) engine could not express — throw-into-a-paused-frame, `close()`
  running `finally` lazily, `yield from` send/throw/return passthrough — plus
  the side-effect-ordering and infinite-generator guarantees that fall out of
  true laziness. Each case is pinned to CPython 3's observed behaviour.
  """

  use ExUnit.Case, async: true

  defp out!(src) do
    {:ok, _v, ctx} = Pyex.run(src)
    String.trim(Pyex.output(ctx))
  end

  describe "lazy creation: nothing runs until the first advance" do
    test "the body does not execute when the generator object is created" do
      assert out!("""
             def g():
                 print("running")
                 yield 1
                 print("after yield")
                 yield 2
             print("before create")
             it = g()
             print("created")
             print(next(it))
             print("got first")
             print(next(it))
             """) == "before create\ncreated\nrunning\n1\ngot first\nafter yield\n2"
    end

    test "side effects interleave with consumption in a for-loop" do
      assert out!("""
             def gen():
                 print("A")
                 yield 1
                 print("B")
                 yield 2
                 print("C")
             print("start")
             for x in gen():
                 print(f"got {x}")
             print("end")
             """) == "start\nA\ngot 1\nB\ngot 2\nC\nend"
    end

    test "an infinite generator is only advanced as far as it is consumed" do
      assert out!("""
             def count():
                 i = 0
                 while True:
                     yield i
                     i += 1
             c = count()
             print([next(c) for _ in range(5)])
             """) == "[0, 1, 2, 3, 4]"
    end
  end

  describe "throw() into a paused frame" do
    test "exception is caught by the except surrounding the paused yield" do
      assert out!("""
             def g():
                 try:
                     yield 1
                     yield 2
                 except ValueError as e:
                     yield ("caught", str(e))
                 yield "after"
             it = g()
             print(next(it))
             print(it.throw(ValueError("boom")))
             print(next(it))
             """) == "1\n('caught', 'boom')\nafter"
    end

    test "throw when the yield is the last statement in the try ends the generator" do
      # The eager engine ran past this yield at the prior next(), so the throw
      # landed on a finished generator and the ValueError escaped. Lazily, the
      # generator is genuinely paused at `yield 1` inside the try.
      assert out!("""
             def g():
                 try:
                     yield 1
                 except ValueError:
                     pass
             it = g()
             print(next(it))
             try:
                 it.throw(ValueError)
                 print("no exception")
             except StopIteration:
                 print("stopiter")
             except ValueError:
                 print("escaped")
             """) == "1\nstopiter"
    end

    test "an uncaught thrown exception propagates out of the generator" do
      assert out!("""
             def g():
                 yield 1
                 yield 2
             it = g()
             next(it)
             try:
                 it.throw(KeyError("k"))
             except KeyError as e:
                 print("propagated", str(e))
             """) == "propagated 'k'"
    end
  end

  describe "close() runs finally lazily" do
    test "close() throws GeneratorExit so the finally block runs at close time" do
      assert out!("""
             def g():
                 try:
                     yield 1
                     yield 2
                 finally:
                     print("cleanup")
             it = g()
             print(next(it))
             it.close()
             print("closed")
             """) == "1\ncleanup\nclosed"
    end

    test "close() on an exhausted generator is a no-op" do
      assert out!("""
             def g():
                 yield 1
             it = g()
             print(next(it))
             try:
                 next(it)
             except StopIteration:
                 pass
             it.close()
             print("ok")
             """) == "1\nok"
    end
  end

  describe "send() routing" do
    test "send delivers the value into the paused yield expression" do
      assert out!("""
             def g():
                 x = yield 1
                 print(f"got {x}")
                 y = yield 2
                 print(f"got {y}")
             it = g()
             print(next(it))
             print(it.send("a"))
             try:
                 it.send("b")
             except StopIteration:
                 print("stop")
             """) == "1\ngot a\n2\ngot b\nstop"
    end

    test "send into a yield that lives inside a for-loop inside a try" do
      # Regression: the sent value has to thread through both the for-loop and
      # the :cont_try frame to reach the suspended yield.
      assert out!("""
             def g(n):
                 try:
                     for i in range(n):
                         got = yield i
                         print(f"got {got}")
                 finally:
                     print("finally")
             it = g(2)
             print(next(it))
             print(it.send("a"))
             try:
                 it.send("b")
             except StopIteration:
                 print("stop")
             """) == "0\ngot a\n1\ngot b\nfinally\nstop"
    end

    test "send(non-None) to a just-started generator raises TypeError" do
      assert out!("""
             def g():
                 yield 1
             it = g()
             try:
                 it.send("x")
             except TypeError as e:
                 print("typeerror")
             """) == "typeerror"
    end
  end

  describe "yield from passthrough (PEP 380)" do
    test "send routes through delegation into the sub-generator" do
      assert out!("""
             def inner():
                 x = yield 1
                 print(f"inner got {x}")
                 y = yield 2
                 print(f"inner got {y}")
             def outer():
                 yield from inner()
             it = outer()
             print(next(it))
             print(it.send("a"))
             print(next(it, "done"))
             """) == "1\ninner got a\n2\ninner got None\ndone"
    end

    test "the sub-generator's return value becomes the yield-from expression value" do
      assert out!("""
             def sub():
                 yield 1
                 yield 2
                 return 99
             def deleg():
                 r = yield from sub()
                 print(f"got return {r}")
                 yield "done"
             g = deleg()
             print(next(g))
             print(next(g))
             print(next(g))
             """) == "1\n2\ngot return 99\ndone"
    end

    test "throw through delegation is caught inside the sub-generator" do
      assert out!("""
             def sub():
                 try:
                     yield 1
                 except ValueError:
                     yield "caught in sub"
             def deleg():
                 yield from sub()
             g = deleg()
             print(next(g))
             print(g.throw(ValueError))
             """) == "1\ncaught in sub"
    end

    test "send and finally interleave across delegation with a for-loop sub" do
      assert out!("""
             def sub(n):
                 try:
                     for i in range(n):
                         got = yield i
                         print(f"sub got {got}")
                 finally:
                     print("sub finally")
                 return n * 100
             def deleg(n):
                 r = yield from sub(n)
                 print(f"deleg got {r}")
                 yield "done"
             g = deleg(2)
             print(next(g))
             print(g.send("a"))
             print(g.send("b"))
             try:
                 next(g)
             except StopIteration:
                 print("stop")
             """) == "0\nsub got a\n1\nsub got b\nsub finally\ndeleg got 200\ndone\nstop"
    end
  end

  describe "generator expressions are lazy" do
    test "the body does not run until the genexpr is consumed" do
      assert out!("""
             def eff(x):
                 print(f"eff {x}")
                 return x * 2
             gen = (eff(x) for x in range(3))
             print("before consume")
             print(list(gen))
             """) == "before consume\neff 0\neff 1\neff 2\n[0, 2, 4]"
    end

    test "a genexpr over an infinite source can be consumed partially" do
      assert out!("""
             def count():
                 i = 0
                 while True:
                     yield i
                     i += 1
             squares = (x * x for x in count())
             print([next(squares) for _ in range(4)])
             """) == "[0, 1, 4, 9]"
    end
  end
end
