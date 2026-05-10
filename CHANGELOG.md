# Changelog

## Unreleased

### Async / await — cooperative scheduling

`async def`, `await`, `async for`, `async with`, async list
comprehensions, and the `asyncio` module — implemented as
cooperative coroutines on top of the existing generator-as-
continuation machinery.

Coroutines are tagged generators (`{:function, ..., :sync |
:async}`).  Calling an async function returns a coroutine value
that wraps a `:gen_unstarted` iter-pool entry; the body runs when
something drives it.  `await EXPR` is yield-from on the inner
iterator: each yield propagates up to the surrounding trampoline,
and the inner's `StopIteration` value (PEP 380) becomes the
await's result.  `asyncio.sleep(t)` yields an `{:asyncio_sleep,
ms}` sentinel that the trampoline interprets.

Observable interleaving matches CPython:

  - `gather(step("A"), step("B"))` over coroutines that
    `await asyncio.sleep(0)` between mutations produces ABABAB,
    not AAABBB.
  - `create_task` is lazy — the body runs when the Task is
    awaited, with `Task.result()` / `.done()` / `.cancel()` /
    `.exception()` methods.  An undriven Task reports `done() =
    False` and `result()` raises `InvalidStateError`.
  - Nested `asyncio.run` raises `RuntimeError`
    ("asyncio.run() cannot be called from a running event loop").
  - Async list comprehensions (`[x async for x in g()]`) parse
    and run.
  - `await` on a non-awaitable raises CPython-shaped `TypeError`.

`asyncio` surface: `run`, `gather`, `sleep`, `create_task`,
`ensure_future`, `wait_for`, `iscoroutine`,
`iscoroutinefunction`.  `gather(return_exceptions=True)` returns
real exception *instances* (built via the same machinery as
`raise ValueError(...)`), so `isinstance(r, ValueError)` works
against gather results.

Async methods on classes (instance / `@staticmethod` /
`@classmethod` / subclass override) return coroutines via the
bound-method dispatcher.  Async generators (`async def` + `yield`)
ride the existing lazy-iterator machinery, so FastAPI streaming
patterns work unchanged.

### itertools.islice

- `list(islice(infinite_generator, n))` now terminates with the
  first `n` items.  Previously the iterator was materialized into a
  list before islice ran, which never finished.  islice is
  registered in the no-drain set; the implementation returns an
  `:islice_call` signal evaluated by a bounded-step iterator
  handler in `Pyex.Interpreter.BuiltinResults`.

### Refactor

- The `:function` pyvalue grew a `kind` field
  (`{:function, name, params, body, env, is_generator, kind}`) so
  one set of patterns dispatches polymorphically across sync and
  async functions.  Replaces the parallel `:async_function` tag
  that would have required N parallel pattern-match clauses.

## 0.1.0 — 2026-02-13

Initial release.

### Core

- Lexer, parser, and tree-walking interpreter for Python 3
- Classes with inheritance, MRO, and operator overloading
- Generators, `yield from`, and continuation-based streaming
- `match`/`case` with destructuring and guards
- Decorators, `*args`/`**kwargs`, walrus operator
- List/dict/set/generator comprehensions
- `try`/`except`/`finally`, `with` statements
- F-strings, type annotations (parsed, silently ignored)

### Sandbox

- Compute budget via `timeout_ms`
- Network access policy (deny-by-default, allowlist hosts/prefixes)
- Capability gates for SQL and S3 (deny-by-default)
- Pluggable filesystem backends (Memory, S3)

### Stdlib modules

base64, boto3, collections, csv, datetime, fastapi, hashlib,
hmac, html, itertools, jinja2, json, markdown, math, os,
pandas, pydantic, random, re, requests, secrets, sql, time,
unittest, uuid

### Lambda

- `Pyex.Lambda.boot/2` — compile FastAPI routes
- `Pyex.Lambda.handle/2` — stateful request dispatch
- `Pyex.Lambda.handle_stream/2` — lazy streaming via continuations

### Observability

- `:telemetry` events for `run`, `request`, and `query`
- `Pyex.Trace` — dev tool that attaches to telemetry events and prints a timing tree
- Structured `Pyex.Error` with kind-based classification
- Output capture and execution counters in `Pyex.Ctx`
