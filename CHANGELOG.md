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

## [0.2.0](https://github.com/ivarvong/pyex/compare/v0.1.0...v0.2.0) (2026-06-11)


### Features

* add library-conformance test category, fix pydantic shim drift it surfaced ([#67](https://github.com/ivarvong/pyex/issues/67)) ([6623a04](https://github.com/ivarvong/pyex/commit/6623a041c6ceeaf5cd2d1d32bd824b3de3f60065))
* async/await as cooperative coroutines (Phase 1) + lazy itertools.islice ([#58](https://github.com/ivarvong/pyex/issues/58)) ([41509e6](https://github.com/ivarvong/pyex/commit/41509e66fce59a27b7d4e2450a870c0e5b51ee0c))
* cooperative scheduling — close the four CPython divergences ([#59](https://github.com/ivarvong/pyex/issues/59)) ([1c324f9](https://github.com/ivarvong/pyex/commit/1c324f98a9063f522da9006b68f1fa46ce352f32))
* **limits:** enable safe-by-default resource ceilings ([#71](https://github.com/ivarvong/pyex/issues/71)) ([95b4799](https://github.com/ivarvong/pyex/commit/95b4799dce469a9f3d64ac27f4bc4afbab4f19a4))


### Bug Fixes

* **banned_call_tracer:** invert :erlang to allowlist + catch fun captures ([#76](https://github.com/ivarvong/pyex/issues/76)) ([ace95fd](https://github.com/ivarvong/pyex/commit/ace95fdbf8f6dc78e58b91d52e8e65974eccbaf3))
* **banned_call_tracer:** treat missing abstract code as a violation ([#75](https://github.com/ivarvong/pyex/issues/75)) ([ddb5569](https://github.com/ivarvong/pyex/commit/ddb55695e279efe7d3c3fce3c75150862d378b8b))
* **ctx:** match network allowlist component-wise, not by string prefix ([#72](https://github.com/ivarvong/pyex/issues/72)) ([b64ddc3](https://github.com/ivarvong/pyex/commit/b64ddc33fca06d348ca2029d58b77a450b1329c8))
* **decimal:** regression tests + informative builtin clause errors ([#77](https://github.com/ivarvong/pyex/issues/77)) ([754a34a](https://github.com/ivarvong/pyex/commit/754a34af24e844ea61ff6d2127b2f0a42481cc93))
* **lexer:** complete the bytes-literal prefix matrix + repr quoting ([#85](https://github.com/ivarvong/pyex/issues/85)) ([048263b](https://github.com/ivarvong/pyex/commit/048263bd4261ce9fec37a0ab7fd1bbcc67245c66))
* **lexer:** complete the Python string-prefix matrix (rf/fr, R/F, u/U, raw triples) ([#81](https://github.com/ivarvong/pyex/issues/81)) ([6b3b405](https://github.com/ivarvong/pyex/commit/6b3b4056f299984b18b0e94162b34eec96d8e4a2))
* **parser:** accept paren tuple targets in comprehension for-clauses ([#68](https://github.com/ivarvong/pyex/issues/68)) ([ebde436](https://github.com/ivarvong/pyex/commit/ebde4364b04ee11b2ecaa0aa4bd97be74b3db11e))
* **pyex:** snapshot and restore caller's Decimal context across run/2 ([#74](https://github.com/ivarvong/pyex/issues/74)) ([ec0dfc4](https://github.com/ivarvong/pyex/commit/ec0dfc4235ed31845a0890adcb7e9b21a40157d7))
* **requests:** apply a host default receive_timeout when caller omits timeout= ([#73](https://github.com/ivarvong/pyex/issues/73)) ([b924a63](https://github.com/ivarvong/pyex/commit/b924a634f479718ca439089eceac7ec7f612fbdb))
* thread yielded signals through assign + return ([#61](https://github.com/ivarvong/pyex/issues/61)) ([b2964f5](https://github.com/ivarvong/pyex/commit/b2964f5483281484e50db9f124e23ffff2da61c2))


### Performance Improvements

* default-limits short-circuit, list-index cache, scope resolution ([#69](https://github.com/ivarvong/pyex/issues/69)) ([07b0850](https://github.com/ivarvong/pyex/commit/07b08508833f918da80ce36a51eb8df293a138fb))
* fix O(n²) list.append, dict insert, zipfile.writestr, and deque.append ([#55](https://github.com/ivarvong/pyex/issues/55)) ([80b2f55](https://github.com/ivarvong/pyex/commit/80b2f55210d107e9269e25a0979611bddc0bd93c))

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
