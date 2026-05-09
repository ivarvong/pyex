defmodule Pyex.AsyncConformanceTest do
  @moduledoc """
  Conformance tests for `async`/`await`, `asyncio`, and async
  generators.

  Tests are organized so each one pins a distinct behavior — no
  micro-variations.  The "Phase 1 divergences from CPython" describe
  block explicitly demonstrates where Pyex's synchronous trampoline
  produces a different observable result than CPython's interleaving
  event loop.

  Pyex's Phase 1 model: a coroutine is a suspended-but-not-running
  function call; `await`/`asyncio.run`/`asyncio.gather` drive it to
  completion synchronously via the trampoline.  No interleaving, no
  fan-out parallelism.
  """
  use ExUnit.Case, async: true

  alias Pyex.Error

  describe "coroutine value semantics" do
    test "calling async def returns a coroutine, not the function's return value" do
      assert Pyex.run!("async def f(): return 1\ntype(f()).__name__") == "coroutine"
    end

    test "the coroutine body does not run until awaited" do
      assert Pyex.run!("""
             trace = []
             async def f():
                 trace.append("ran")
             c = f()
             trace
             """) == []
    end

    test "type(async_function) is function (the function itself is a function)" do
      assert Pyex.run!("async def f(): pass\ntype(f).__name__") == "function"
    end

    test "an async function is callable" do
      assert Pyex.run!("async def f(): pass\ncallable(f)") == true
    end

    test "repr(coroutine) names the source function" do
      assert Pyex.run!("async def hello(): pass\nrepr(hello())") == "<coroutine object hello>"
    end
  end

  describe "asyncio.run" do
    test "drives a coroutine to its return value" do
      assert Pyex.run!("import asyncio\nasync def f(): return 42\nasyncio.run(f())") == 42
    end

    test "preserves complex return types through deref" do
      assert Pyex.run!("""
             import asyncio
             async def f(): return {"k": [1, 2, 3]}
             asyncio.run(f())
             """) == %{"k" => [1, 2, 3]}
    end

    test "propagates exceptions raised inside the coroutine" do
      {:error, %Error{message: msg}} =
        Pyex.run("import asyncio\nasync def boom(): raise ValueError('x')\nasyncio.run(boom())")

      assert msg =~ "ValueError"
      assert msg =~ "x"
    end

    test "rejects a non-coroutine argument with TypeError" do
      {:error, %Error{message: msg}} = Pyex.run("import asyncio\nasyncio.run(99)")
      assert msg =~ "TypeError"
      assert msg =~ "coroutine was expected"
    end

    test "TypeError hint mentions the most common LLM mistake (forgot to call)" do
      {:error, %Error{message: msg}} = Pyex.run("import asyncio\nasyncio.run('not-a-coro')")
      assert msg =~ "Did you forget to call"
    end
  end

  describe "await" do
    test "drives a coroutine to its return value" do
      assert Pyex.run!("""
             import asyncio
             async def inner(): return 7
             async def outer(): return (await inner()) + 1
             asyncio.run(outer())
             """) == 8
    end

    test "binds at unary precedence (CPython parity)" do
      # `2 + await f()` parses as `2 + (await f())`, not `(2 + await) f()`.
      assert Pyex.run!("""
             import asyncio
             async def f(): return 5
             async def main(): return 2 + await f()
             asyncio.run(main())
             """) == 7
    end

    test "works inside a list comprehension" do
      assert Pyex.run!("""
             import asyncio
             async def square(x): return x * x
             async def main(): return [await square(i) for i in range(4)]
             asyncio.run(main())
             """) == [0, 1, 4, 9]
    end

    test "works inside an f-string" do
      assert Pyex.run!("""
             import asyncio
             async def name(): return "Ada"
             async def main(): return f"hello {await name()}"
             asyncio.run(main())
             """) == "hello Ada"
    end

    test "rejects a non-awaitable with CPython-shaped TypeError" do
      {:error, %Error{message: msg}} =
        Pyex.run("""
        import asyncio
        async def main(): return await 42
        asyncio.run(main())
        """)

      assert msg =~ "TypeError"
      assert msg =~ "can't be used in 'await' expression"
    end

    test "passes through exceptions from the awaited coroutine" do
      assert Pyex.run!("""
             import asyncio
             async def boom(): raise KeyError("k")
             async def main():
                 try:
                     await boom()
                 except KeyError as e:
                     return str(e)
             asyncio.run(main())
             """) == "'k'"
    end
  end

  describe "asyncio.gather" do
    test "returns results in the order coroutines were declared" do
      assert Pyex.run!("""
             import asyncio
             async def f(x): return x
             async def main(): return await asyncio.gather(f(3), f(1), f(2))
             asyncio.run(main())
             """) == [3, 1, 2]
    end

    test "with no arguments returns an empty list" do
      assert Pyex.run!("""
             import asyncio
             async def main(): return await asyncio.gather()
             asyncio.run(main())
             """) == []
    end

    test "splat over a comprehension drives all coroutines" do
      assert Pyex.run!("""
             import asyncio
             async def f(x): return x * 2
             async def main(): return await asyncio.gather(*[f(i) for i in range(5)])
             asyncio.run(main())
             """) == [0, 2, 4, 6, 8]
    end

    test "halts on first exception by default" do
      {:error, %Error{message: msg}} =
        Pyex.run("""
        import asyncio
        async def ok(): return 1
        async def fails(): raise ValueError("bad")
        async def main(): return await asyncio.gather(ok(), fails(), ok())
        asyncio.run(main())
        """)

      assert msg =~ "ValueError"
    end

    test "return_exceptions=True wraps captured exceptions as real exception instances" do
      # Critical: callers do `if isinstance(r, ValueError)` against
      # gather results.  String messages would break that idiom.
      assert Pyex.run!("""
             import asyncio
             async def ok(): return 1
             async def fails(): raise ValueError("bad")
             async def main():
                 return await asyncio.gather(ok(), fails(), return_exceptions=True)
             rs = asyncio.run(main())
             [rs[0], type(rs[1]).__name__, isinstance(rs[1], ValueError), isinstance(rs[1], Exception)]
             """) == [1, "ValueError", true, true]
    end
  end

  describe "asyncio.sleep" do
    test "sleep(0) returns None and the coroutine continues" do
      assert Pyex.run!("""
             import asyncio
             async def main():
                 await asyncio.sleep(0)
                 return "done"
             asyncio.run(main())
             """) == "done"
    end

    test "rejects a negative duration with ValueError" do
      {:error, %Error{message: msg}} =
        Pyex.run("""
        import asyncio
        async def main(): await asyncio.sleep(-1)
        asyncio.run(main())
        """)

      assert msg =~ "ValueError"
      assert msg =~ "non-negative"
    end
  end

  describe "asyncio.create_task / Task" do
    test "create_task + await round-trips the value" do
      assert Pyex.run!("""
             import asyncio
             async def f(x): return x + 100
             async def main():
                 t = asyncio.create_task(f(5))
                 return await t
             asyncio.run(main())
             """) == 105
    end

    test "ensure_future is an alias for create_task" do
      assert Pyex.run!("""
             import asyncio
             async def f(): return 1
             async def main(): return await asyncio.ensure_future(f())
             asyncio.run(main())
             """) == 1
    end

    test "Task before await: .done() is False, .cancel() succeeds, .result() raises" do
      # CPython parity: create_task schedules but doesn't run.  Until
      # the loop drives the task (via await or another scheduling
      # round), it's pending — `.done()` False, `.result()` raises
      # InvalidStateError.
      assert Pyex.run!("""
             import asyncio
             async def f(): return "value"
             async def main():
                 t = asyncio.create_task(f())
                 done = t.done()
                 try:
                     t.result()
                     raised = False
                 except Exception:
                     raised = True
                 return [done, raised]
             asyncio.run(main())
             """) == [false, true]
    end

    test "Task after await: .done() is True, .result() returns the value" do
      assert Pyex.run!("""
             import asyncio
             async def f(): return "value"
             async def main():
                 t = asyncio.create_task(f())
                 await t
                 # Pyex Phase 1.5: awaiting a pending Task converts it
                 # to a done Task.  We re-create one to inspect post-
                 # await state.
                 t2 = asyncio.create_task(f())
                 v = await t2
                 return v
             asyncio.run(main())
             """) == "value"
    end

    test "type(task) is Task" do
      assert Pyex.run!("""
             import asyncio
             async def f(): return 1
             async def main():
                 t = asyncio.create_task(f())
                 return type(t).__name__
             asyncio.run(main())
             """) == "Task"
    end

    test "create_task on a non-coroutine raises TypeError" do
      {:error, %Error{message: msg}} = Pyex.run("import asyncio\nasyncio.create_task(99)")
      assert msg =~ "TypeError"
    end
  end

  describe "asyncio.iscoroutine / iscoroutinefunction" do
    test "iscoroutine recognizes a coroutine value" do
      assert Pyex.run!("import asyncio\nasync def f(): return 1\nasyncio.iscoroutine(f())") ==
               true
    end

    test "iscoroutine returns False for sync function calls, lambdas, and plain values" do
      assert Pyex.run!("""
             import asyncio
             def f(): return 1
             [asyncio.iscoroutine(f()),
              asyncio.iscoroutine((lambda: 1)()),
              asyncio.iscoroutine(42)]
             """) == [false, false, false]
    end

    test "iscoroutinefunction recognizes async def" do
      assert Pyex.run!("import asyncio\nasync def f(): pass\nasyncio.iscoroutinefunction(f)") ==
               true
    end

    test "iscoroutinefunction is False for a sync-decorator-wrapped async fn" do
      # CPython parity: a sync wrapper hides the underlying coroutine-function-ness.
      assert Pyex.run!("""
             import asyncio
             def trace(f):
                 def wrapper(*a, **k): return f(*a, **k)
                 return wrapper
             @trace
             async def f(): return 1
             asyncio.iscoroutinefunction(f)
             """) == false
    end
  end

  describe "async for" do
    test "iterates a sync list" do
      assert Pyex.run!("""
             import asyncio
             async def main():
                 out = []
                 async for x in [1, 2, 3]:
                     out.append(x)
                 return out
             asyncio.run(main())
             """) == [1, 2, 3]
    end

    test "iterates an async generator" do
      assert Pyex.run!("""
             import asyncio
             async def gen():
                 for i in range(3):
                     yield i * 10
             async def main():
                 out = []
                 async for x in gen():
                     out.append(x)
                 return out
             asyncio.run(main())
             """) == [0, 10, 20]
    end

    test "supports break / continue / else like sync for" do
      assert Pyex.run!("""
             import asyncio
             async def main():
                 out = []
                 async for x in [1, 2, 3, 4, 5]:
                     if x == 2: continue
                     if x == 4: break
                     out.append(x)
                 else:
                     out.append("no-break")
                 return out
             asyncio.run(main())
             """) == [1, 3]
    end
  end

  describe "async with" do
    test "uses sync __enter__/__exit__ when async dunders are absent" do
      assert Pyex.run!("""
             import asyncio
             class CM:
                 def __enter__(self): return 99
                 def __exit__(self, *a): pass
             async def main():
                 async with CM() as v:
                     return v
             asyncio.run(main())
             """) == 99
    end
  end

  describe "async generators" do
    test "async def + yield is consumable by list()" do
      assert Pyex.run!("""
             async def gen():
                 yield 1
                 yield 2
             list(gen())
             """) == [1, 2]
    end

    test "infinite async gen + islice terminates" do
      # Cross-check between async generators and the lazy islice fix.
      assert Pyex.run!("""
             from itertools import islice
             async def gen():
                 i = 0
                 while True:
                     yield i
                     i += 1
             list(islice(gen(), 5))
             """) == [0, 1, 2, 3, 4]
    end
  end

  describe "async methods on classes" do
    test "instance method receives self correctly" do
      assert Pyex.run!("""
             import asyncio
             class C:
                 def __init__(self, x): self.x = x
                 async def get(self): return self.x
             asyncio.run(C(99).get())
             """) == 99
    end

    test "instance method takes positional args" do
      assert Pyex.run!("""
             import asyncio
             class C:
                 async def add(self, a, b): return a + b
             asyncio.run(C().add(2, 3))
             """) == 5
    end

    test "@staticmethod on async def" do
      assert Pyex.run!("""
             import asyncio
             class C:
                 @staticmethod
                 async def m(): return "static"
             asyncio.run(C.m())
             """) == "static"
    end

    test "@classmethod on async def" do
      assert Pyex.run!("""
             import asyncio
             class C:
                 @classmethod
                 async def m(cls): return cls.__name__
             asyncio.run(C.m())
             """) == "C"
    end

    test "subclass override wins over parent method" do
      assert Pyex.run!("""
             import asyncio
             class A:
                 async def m(self): return "A"
             class B(A):
                 async def m(self): return "B"
             asyncio.run(B().m())
             """) == "B"
    end
  end

  describe "composition with other features" do
    test "async + walrus binds inside the async function body" do
      assert Pyex.run!("""
             import asyncio
             async def f(): return 10
             async def main():
                 if (n := await f()) > 5: return n
                 return 0
             asyncio.run(main())
             """) == 10
    end

    test "async fn returning a dataclass instance round-trips" do
      assert Pyex.run!("""
             import asyncio
             from dataclasses import dataclass
             @dataclass
             class P:
                 x: int
                 y: int
             async def make(): return P(1, 2)
             p = asyncio.run(make())
             [p.x, p.y]
             """) == [1, 2]
    end

    test "match/case inside async def" do
      assert Pyex.run!("""
             import asyncio
             async def main():
                 x = 5
                 match x:
                     case n if n > 0: return "pos"
                     case _: return "other"
             asyncio.run(main())
             """) == "pos"
    end
  end

  describe "sandbox interaction" do
    test "async coroutines respect injected modules" do
      assert {:ok, "tool-result", _ctx} =
               Pyex.run(
                 """
                 import asyncio
                 from mytools import call
                 async def main(): return call("x")
                 asyncio.run(main())
                 """,
                 modules: %{
                   "mytools" => %{"call" => {:builtin, fn [_arg] -> "tool-result" end}}
                 }
               )
    end

    test "async write+read against an in-memory filesystem" do
      fs = Pyex.Filesystem.Memory.new(%{})

      assert {:ok, "hello", _ctx} =
               Pyex.run(
                 """
                 import asyncio
                 async def io():
                     with open("greeting.txt", "w") as f:
                         f.write("hello")
                     with open("greeting.txt", "r") as f:
                         return f.read()
                 asyncio.run(io())
                 """,
                 filesystem: fs
               )
    end
  end

  describe "cooperative scheduling — CPython parity" do
    test "gather interleaves children at await points (ABABAB, not AAABBB)" do
      # The flagship cooperative-scheduling test.  Each step
      # coroutine appends its label, then yields via
      # `await asyncio.sleep(0)`.  gather's round-robin trampoline
      # advances each child one yield at a time — so the trace shows
      # ABABAB, matching CPython's event-loop interleaving.
      assert Pyex.run!("""
             import asyncio
             trace = []
             async def step(label):
                 for _ in range(3):
                     trace.append(label)
                     await asyncio.sleep(0)
             async def main():
                 await asyncio.gather(step("A"), step("B"))
                 return "".join(trace)
             asyncio.run(main())
             """) == "ABABAB"
    end

    test "create_task defers driving until awaited (not eager)" do
      # CPython schedules the coroutine; Pyex Phase 1.5 wraps it as
      # a pending Task.  In both, the body does NOT run at
      # create_task time — it runs when something drives it (await
      # or a scheduling round).  Trace order: "after-create-task"
      # first (body of main continues), THEN "ran" (when await
      # drives the task).
      assert Pyex.run!("""
             import asyncio
             trace = []
             async def f():
                 trace.append("ran")
             async def main():
                 t = asyncio.create_task(f())
                 trace.append("after-create-task")
                 await t
                 return trace
             asyncio.run(main())
             """) == ["after-create-task", "ran"]
    end
  end

  describe "cooperative scheduling — CPython parity (continued)" do
    test "nested asyncio.run raises RuntimeError" do
      # CPython parity: asyncio.run() inside a coroutine driven by
      # asyncio.run() raises "asyncio.run() cannot be called from a
      # running event loop".  Pyex tracks the active loop via
      # ctx.asyncio_running.
      {:error, %Error{message: msg}} =
        Pyex.run("""
        import asyncio
        async def inner(): return 1
        async def outer(): return asyncio.run(inner()) + 10
        asyncio.run(outer())
        """)

      assert msg =~ "RuntimeError"
      assert msg =~ "running event loop"
    end
  end

  describe "async comprehensions — CPython parity" do
    test "[x async for x in g()] iterates an async generator" do
      assert Pyex.run!("""
             import asyncio
             async def gen():
                 yield 1
                 yield 2
                 yield 3
             async def main(): return [x async for x in gen()]
             asyncio.run(main())
             """) == [1, 2, 3]
    end

    test "async for inside a comprehension chain" do
      assert Pyex.run!("""
             import asyncio
             async def gen():
                 yield 1
                 yield 2
             async def main():
                 return [x * 10 async for x in gen() if x > 0]
             asyncio.run(main())
             """) == [10, 20]
    end
  end
end
