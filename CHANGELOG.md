# Changelog

## Unreleased

### Async / await

- `async def`, `await`, `async for`, `async with` parse and run.
  Coroutines are tagged sync-or-async on the function value
  (`{:function, ..., :sync | :async}`); calling an async function
  binds parameters and returns a `:coroutine` value without
  executing the body.  `await` and `asyncio.run` drive the
  coroutine via a synchronous trampoline
  (`Pyex.Interpreter.Invocation.drive_coroutine/3`).
- New `asyncio` module: `run`, `gather`, `sleep`, `create_task`,
  `ensure_future`, `wait_for`, `iscoroutine`, `iscoroutinefunction`.
  `gather(return_exceptions=True)` returns real exception
  *instances* (not strings), so `isinstance(r, ValueError)` works
  against gather results.
- `asyncio.create_task` drives the coroutine eagerly and returns a
  Task value with `.result()` / `.done()` / `.cancel()` /
  `.exception()` methods.
- Async generators (`async def` + `yield`) ride the existing
  lazy-iterator machinery; FastAPI streaming patterns work
  unchanged.
- Async methods on classes (instance / `@staticmethod` /
  `@classmethod` / subclass override) return coroutines via the
  bound-method dispatcher.
- `await` and `asyncio.run` are strict on shape: non-awaitable
  arguments raise CPython-shaped TypeError.  `asyncio.run`'s
  TypeError includes a hint about the most common LLM mistake
  (forgetting to call the async function).

Phase 1 divergences from CPython are documented and pinned in
`test/pyex/async_conformance_test.exs`:

- `gather` is sequential, not interleaved at await points
- `create_task` drives eagerly rather than scheduling
- Nested `asyncio.run` is silently allowed (CPython errors)
- Async list comprehensions (`[x async for x in g()]`) not yet
  parsed

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
