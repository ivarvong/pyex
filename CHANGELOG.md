# Changelog

## Unreleased

### Filesystem now runs on the `vfs` package

The home-grown `Pyex.Filesystem` behaviour and its `Memory` backend are
gone. `Pyex.Ctx`'s `:filesystem` now holds any
[`VFS.Mountable`](https://hexdocs.pm/vfs) — a `VFS.Memory`, a `%VFS{}`
mount table, the S3 backend, or your own — so a single filesystem value
can be threaded through Pyex and any other `vfs`-based tool.

- **`filesystem:` accepts a `VFS.Mountable` or a plain `%{path => content}`
  map** (the map is wrapped as a seeded `VFS.Memory`). `ctx.filesystem`
  round-trips as the same backend you passed — hand it to the next tool.
- **Working directory.** `Pyex.Ctx` gains a `:cwd` (default `"/"`).
  Relative Python paths (`open("data.txt")`) resolve against it, and
  `os.chdir`/`os.getcwd` now actually read and update it (previously
  `os.chdir` silently ignored its argument). Set `cwd:` to a shell's cwd
  when sharing a filesystem so `open("rel")` resolves the same way
  `cat rel` does. Absolute paths are unaffected.
- **Faithful state threading.** Every filesystem op — reads included —
  threads the possibly-updated `VFS.Mountable` back into `ctx.filesystem`,
  matching VFS's immutable contract so lazy/caching backends and `%VFS{}`
  mount tables stay coherent.
- **New `Pyex.FS`** is the boundary module: cwd-aware path resolution
  (`resolve/2`), state-threaded primitives, and `%VFS.Error{}` → Python
  exception-string translation. A small root-relative convenience layer
  (`read/2`, `write/4`, `exists?/2`, `list_dir/2`, `delete/2`) is kept for
  seeding fixtures and inspecting final state.
- **`Pyex.Filesystem.S3`** implements `VFS.Mountable` with a structured
  core: directory-aware `stat` (implicit-prefix detection), recursive `rm`,
  and POSIX error kinds. Its bare `read/2`/`write/4`/… functions remain
  for direct use.
- **Removed:** `Pyex.Filesystem`, `Pyex.Filesystem.Memory`. Replace
  `Pyex.Filesystem.Memory.new(map)` with a bare `map` or
  `VFS.Memory.new(%{"/..." => ...})`.

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

## [0.2.0](https://github.com/ivarvong/pyex/compare/v0.1.0...v0.2.0) (2026-07-02)


### Features

* add library-conformance test category, fix pydantic shim drift it surfaced ([#67](https://github.com/ivarvong/pyex/issues/67)) ([6623a04](https://github.com/ivarvong/pyex/commit/6623a041c6ceeaf5cd2d1d32bd824b3de3f60065))
* **api:** carry the capability ledger + footprint on a failed run's error ([#136](https://github.com/ivarvong/pyex/issues/136)) ([af4c078](https://github.com/ivarvong/pyex/commit/af4c0781de0284678745da840e82fbd74664eb95))
* async/await as cooperative coroutines (Phase 1) + lazy itertools.islice ([#58](https://github.com/ivarvong/pyex/issues/58)) ([41509e6](https://github.com/ivarvong/pyex/commit/41509e66fce59a27b7d4e2450a870c0e5b51ee0c))
* **boto3:** DynamoDB transactions, conditions, Query — run a real ledger ([#133](https://github.com/ivarvong/pyex/issues/133)) ([7742fc8](https://github.com/ivarvong/pyex/commit/7742fc88a6576a29d54bcb1860a1a96c0deaa786))
* capstone expense-tracker API + run [@field](https://github.com/field)_validator on request bodies ([#115](https://github.com/ivarvong/pyex/issues/115)) ([e5f4601](https://github.com/ivarvong/pyex/commit/e5f46014aeb7034eaf3c8c58961ae38846651ed0))
* cooperative scheduling — close the four CPython divergences ([#59](https://github.com/ivarvong/pyex/issues/59)) ([1c324f9](https://github.com/ivarvong/pyex/commit/1c324f98a9063f522da9006b68f1fa46ce352f32))
* **determinism:** clock + entropy capability (seed:/clock:) + no cross-turn :rand leak ([#125](https://github.com/ivarvong/pyex/issues/125)) ([175de47](https://github.com/ivarvong/pyex/commit/175de47e56dc8371bb73c6441426b2605499cc3c))
* **filesystem:** copy-on-write Overlay for sound, preview-gated filesystem effects ([#140](https://github.com/ivarvong/pyex/issues/140)) ([fdb6fee](https://github.com/ivarvong/pyex/commit/fdb6feee5b93039da54e93c680349e6238dced53))
* **interpreter:** chained assignment with attribute and subscript targets ([#142](https://github.com/ivarvong/pyex/issues/142)) ([c407f82](https://github.com/ivarvong/pyex/commit/c407f82027d7b6df037e46b97afa3a6c760b6b48))
* **limits:** enable safe-by-default resource ceilings ([#71](https://github.com/ivarvong/pyex/issues/71)) ([95b4799](https://github.com/ivarvong/pyex/commit/95b4799dce469a9f3d64ac27f4bc4afbab4f19a4))
* **otel:** app/runtime channel rename + OTel semconv + scope + ASCII trace renderer ([#122](https://github.com/ivarvong/pyex/issues/122)) ([1523e4d](https://github.com/ivarvong/pyex/commit/1523e4d60e5b6d5d1553f43027a42ac162a6db84))
* **otel:** two-channel telemetry — tenant opentelemetry module + tamper-proof platform capability trace ([#121](https://github.com/ivarvong/pyex/issues/121)) ([23d5e6d](https://github.com/ivarvong/pyex/commit/23d5e6d913e30873b0d1429036be277abf9f48a6))
* **parser:** parenthesized import lists + __future__ no-op imports ([#132](https://github.com/ivarvong/pyex/issues/132)) ([c1b9276](https://github.com/ivarvong/pyex/commit/c1b92769b0b1a7a0368a404eda61669bcd0e5f07))
* **stdlib:** add ast, inspect, logging, traceback shims ([#114](https://github.com/ivarvong/pyex/issues/114)) ([5508ebb](https://github.com/ivarvong/pyex/commit/5508ebbdac744d85c371fa2923c44443a52e53c7))
* **storage:** attenuating membranes for multitenant capabilities ([#117](https://github.com/ivarvong/pyex/issues/117)) ([db28b65](https://github.com/ivarvong/pyex/commit/db28b652c256a7d9812502154adb6fdc12cf0ccb))
* **storage:** copy-on-write Overlay backend for sound, preview-gated effects ([#138](https://github.com/ivarvong/pyex/issues/138)) ([3457129](https://github.com/ivarvong/pyex/commit/34571290261f37105202b800cfb4d084553eec36))
* **storage:** experimental host-provided KV store capability ([#116](https://github.com/ivarvong/pyex/issues/116)) ([32233f8](https://github.com/ivarvong/pyex/commit/32233f82b315e89dc35fba1129094a55429c1b7c))
* **str:** complete the str method surface (burn down parity gaps) ([#92](https://github.com/ivarvong/pyex/issues/92)) ([4baf89b](https://github.com/ivarvong/pyex/commit/4baf89b9612ffd3a0a5339162c60383021085b55))
* **turn:** prove the turn-purity contract + per-turn telemetry footprint ([#118](https://github.com/ivarvong/pyex/issues/118)) ([0903f46](https://github.com/ivarvong/pyex/commit/0903f468e75cb7d1afe718055dbe1c06e653b6d6))


### Bug Fixes

* **banned_call_tracer:** invert :erlang to allowlist + catch fun captures ([#76](https://github.com/ivarvong/pyex/issues/76)) ([ace95fd](https://github.com/ivarvong/pyex/commit/ace95fdbf8f6dc78e58b91d52e8e65974eccbaf3))
* **banned_call_tracer:** treat missing abstract code as a violation ([#75](https://github.com/ivarvong/pyex/issues/75)) ([ddb5569](https://github.com/ivarvong/pyex/commit/ddb55695e279efe7d3c3fce3c75150862d378b8b))
* close common gaps that bite LLM-generated Python ([#88](https://github.com/ivarvong/pyex/issues/88)) ([6587c68](https://github.com/ivarvong/pyex/commit/6587c683e344e98e86e39673b955780a872d7d8d))
* **core:** startswith/endswith indices, no-arg dir(), str.join over str, sum TypeError ([#119](https://github.com/ivarvong/pyex/issues/119)) ([010e2ce](https://github.com/ivarvong/pyex/commit/010e2ce7125da003656e0ec9f53bd51b4e67454d))
* **ctx:** match network allowlist component-wise, not by string prefix ([#72](https://github.com/ivarvong/pyex/issues/72)) ([b64ddc3](https://github.com/ivarvong/pyex/commit/b64ddc33fca06d348ca2029d58b77a450b1329c8))
* **decimal:** regression tests + informative builtin clause errors ([#77](https://github.com/ivarvong/pyex/issues/77)) ([754a34a](https://github.com/ivarvong/pyex/commit/754a34af24e844ea61ff6d2127b2f0a42481cc93))
* **deps:** make pyex installable as a bare dependency ([#139](https://github.com/ivarvong/pyex/issues/139)) ([21581cc](https://github.com/ivarvong/pyex/commit/21581cc0ccbcca5d9b234e39465f9d5f8a5a2b37))
* **generators:** send(None) priming + StopIteration.value ([#120](https://github.com/ivarvong/pyex/issues/120)) ([d2b2b9b](https://github.com/ivarvong/pyex/commit/d2b2b9b6b39969a684f901bd0d5bb70ccbd5df7b))
* **generators:** yield from delegates the sub-generator's return value (PEP 380) ([#127](https://github.com/ivarvong/pyex/issues/127)) ([720fa5b](https://github.com/ivarvong/pyex/commit/720fa5bb5e418dec2cfcd3d3632af312ea70f8ff))
* **interpreter:** fresh mutable containers get heap identity, like literals ([#143](https://github.com/ivarvong/pyex/issues/143)) ([4b83843](https://github.com/ivarvong/pyex/commit/4b83843742b3113abe1148440d2eb31083a7e3d3))
* **json:** preserve object key order on loads + reject sets in dumps ([#124](https://github.com/ivarvong/pyex/issues/124)) ([73c61f0](https://github.com/ivarvong/pyex/commit/73c61f093288a9d33d426b1583d026604ab7ee25))
* **lexer:** complete the bytes-literal prefix matrix + repr quoting ([#85](https://github.com/ivarvong/pyex/issues/85)) ([048263b](https://github.com/ivarvong/pyex/commit/048263bd4261ce9fec37a0ab7fd1bbcc67245c66))
* **lexer:** complete the Python string-prefix matrix (rf/fr, R/F, u/U, raw triples) ([#81](https://github.com/ivarvong/pyex/issues/81)) ([6b3b405](https://github.com/ivarvong/pyex/commit/6b3b4056f299984b18b0e94162b34eec96d8e4a2))
* **otel:** audit a failed turn + semconv error.type + telemetry key; exhaustive invariants ([#123](https://github.com/ivarvong/pyex/issues/123)) ([fac3c63](https://github.com/ivarvong/pyex/commit/fac3c6357ef0236d21d595a59636c4f92c512057))
* **parser:** accept paren tuple targets in comprehension for-clauses ([#68](https://github.com/ivarvong/pyex/issues/68)) ([ebde436](https://github.com/ivarvong/pyex/commit/ebde4364b04ee11b2ecaa0aa4bd97be74b3db11e))
* **pyex:** snapshot and restore caller's Decimal context across run/2 ([#74](https://github.com/ivarvong/pyex/issues/74)) ([ec0dfc4](https://github.com/ivarvong/pyex/commit/ec0dfc4235ed31845a0890adcb7e9b21a40157d7))
* **requests:** apply a host default receive_timeout when caller omits timeout= ([#73](https://github.com/ivarvong/pyex/issues/73)) ([b924a63](https://github.com/ivarvong/pyex/commit/b924a634f479718ca439089eceac7ec7f612fbdb))
* route iterable-consuming builtins through the one coercion ([#96](https://github.com/ivarvong/pyex/issues/96)) ([2e72580](https://github.com/ivarvong/pyex/commit/2e725803febd35b1a91906532d2e818c62436221))
* sorted/list/reversed/tuple shallow-copy their elements ([#93](https://github.com/ivarvong/pyex/issues/93)) ([9fa45b8](https://github.com/ivarvong/pyex/commit/9fa45b86005f5d7997bbeea508e776f29a9f23e1))
* **telemetry:** count spans toward the memory budget (close DoS sink) ([#126](https://github.com/ivarvong/pyex/issues/126)) ([9b03d8d](https://github.com/ivarvong/pyex/commit/9b03d8dc48c5d1ca2bcc914bae7c0ab7bdc23905))
* thread yielded signals through assign + return ([#61](https://github.com/ivarvong/pyex/issues/61)) ([b2964f5](https://github.com/ivarvong/pyex/commit/b2964f5483281484e50db9f124e23ffff2da61c2))
* type-constructor conformance via the product-space sweep ([#98](https://github.com/ivarvong/pyex/issues/98)) ([f7c1472](https://github.com/ivarvong/pyex/commit/f7c1472f952cc123025483d37a907265bdf916fb))


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
