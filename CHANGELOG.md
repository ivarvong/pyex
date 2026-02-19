# Changelog

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
- Append-only event log in `Pyex.Ctx`
