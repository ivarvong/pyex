# Changelog

## 1.0.0 (2026-04-14)


### Performance Improvements

* complete py_list refactor — 300 → 0 test failures, clean dialyzer ([52adaae](https://github.com/ivarvong/pyex/commit/52adaae08ed0ad73a9349d04c2c86e359eabfc93))
* complete py_list refactor — zero test failures, clean dialyzer ([d188b88](https://github.com/ivarvong/pyex/commit/d188b88fa7157bd338d84b7a382843e10bec954c))
* remove event log to reduce memory allocation by 99.4% ([c2546e6](https://github.com/ivarvong/pyex/commit/c2546e62d6f11c6733791ca046d8248d3560b151))

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
