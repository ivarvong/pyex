# Pyex

Run LLM-generated Python inside your Elixir app. No containers, no
ports, no process isolation — the interpreter is a pure function on
the BEAM.

```elixir
Pyex.run!("sorted([3, 1, 2])")
# => [1, 2, 3]
```

## Why this exists

Pyex exists for one shape of problem: an Elixir application that
needs to execute Python written by a language model, on the hot path,
with capabilities the host controls.

The design constraint is that running the code should be a function
call. Not a request to a sandbox service, not a cold container, not
a serialized round-trip to a worker pool. The capabilities the
program can use — files, network, database, app-specific functions —
should be Elixir values you pass in, not endpoints behind an RPC.

That constraint rules a lot of things in and out:

- It rules out a microVM-class isolation boundary. A Firecracker or
  gVisor sandbox is stronger than a tree-walking interpreter in the
  same address space. Pyex is not trying to replace one.
- It rules in latency and statefulness. A request is a function
  call; an HTTP handler keeps its filesystem across calls; a
  generator is a continuation, not a process.
- It rules out being a CPython replacement. Pyex implements the
  subset of Python an LLM tends to produce for a backend handler —
  not scipy, not C extensions, not the long tail of CPython
  semantics that no model is going to emit anyway.

The compute speed cost is real: pure-CPU Python runs roughly an
order of magnitude slower than CPython. For workloads dominated by
I/O, templating, JSON, and routing, the interpreter is not the
bottleneck.

## Install

```elixir
def deps do
  [{:pyex, "~> 0.1.0"}]
end
```

## Usage

```elixir
{:ok, ast}        = Pyex.compile(source)
{:ok, value, ctx} = Pyex.run(source_or_ast, opts)
value             = Pyex.run!(source_or_ast, opts)
output            = Pyex.output(ctx)
```

Everything the program can see flows through `opts`. Files, env vars,
network, database, custom modules — explicit, capability-shaped, deny
by default.

```elixir
Pyex.run(source,
  filesystem: Pyex.Filesystem.Memory.new(%{"data.json" => json}),
  env: %{"API_KEY" => key},
  modules: %{"db" => %{"query" => {:builtin, &my_query/1}}},
  network: [%{allowed_url_prefix: "https://api.example.com/"}],
  limits: [timeout: 5_000, max_memory_bytes: 50_000_000])
```

## Sandbox model

Pyex is a tree-walking interpreter, not an `eval`. Python source never
reaches a Python runtime; it reaches a function written in Elixir
that decides what each AST node means.

That makes the threat model unusually simple to reason about:

- **No host filesystem.** `open()` reads and writes the
  `Pyex.Filesystem` backend you pass in. Bring `Memory` (in-process
  map), `S3`, or your own. Without a backend, file I/O fails.
- **No subprocess, shell, or `os.exec`.** Not implemented. There is
  no path from Python source to a host process.
- **No native code.** No `ctypes`, no C extension loading, no
  `compile()` of source-to-bytecode. Python's `exec()` and `eval()`
  re-enter the Pyex interpreter — they cannot escape it.
- **Network is allowlisted.** Denied by default. When configured,
  matched by URL prefix and HTTP method, with optional header
  injection so credentials never appear in the Python source.
- **I/O capabilities are explicit.** SQL, S3, and other I/O are
  guarded by named capabilities (`sql: true`, `boto3: true`). A
  program that imports `sql` without the capability fails closed.
- **Resource ceilings are enforced.** Compute time, step count,
  estimated memory, and output bytes are checked at every step
  boundary. I/O latency does not count against the compute budget.
- **Errors are structured.** `%Pyex.Error{kind: :timeout | :python |
  :syntax | :limit | ...}` so you can route on failure mode without
  string matching.

This is defense in depth, not a verdict. Pyex has not been through a
third-party security audit. Treat it as a hardened library, not as
isolation equivalent to a container or VM.

## What it runs

Most of the Python an LLM produces. Classes with inheritance and
operator overloading. Generators and `yield from`. `match`/`case`.
Decorators. Comprehensions. `*args`/`**kwargs`. F-strings. `try` /
`except` / `finally`. `with` statements. Walrus operator. Type
annotations (parsed, ignored at runtime, like CPython).

Standard library, implemented in Elixir to match CPython semantics:

```
abc          datetime     html         pathlib     sql
base64       decimal      hmac         pydantic    statistics
bisect       enum         io           pygments    string
boto3        fastapi      itertools    random      sys
collections  fnmatch      jinja2       re          textwrap
contextlib   functools    json         requests    time
copy         glob         markdown     secrets     typing
crypto       hashlib      math         shutil      unittest
csv          heapq        operator     urllib      uuid
dataclasses                                        yaml / zipfile / zoneinfo
```

Pandas is partial but useful for tabular work. Decimal passes
the IBM `dectest` conformance vectors. FastAPI is a list-based
implementation of the route-decorator subset, with streaming
generators.

## HTTP handlers without a server

LLMs write FastAPI. Pyex serves it without bringing up a server:

```python
import fastapi
app = fastapi.FastAPI()

@app.get("/hello/{name}")
def hello(name):
    return {"message": f"hello {name}"}
```

```elixir
{:ok, app}       = Pyex.Lambda.boot(source)
{:ok, resp, app} = Pyex.Lambda.handle(app, %{method: "GET", path: "/hello/world"})
```

Boot once, handle many requests. State threads through — filesystem
mutations persist across calls, exactly as they would on a long-lived
server. Streaming responses use generator continuations driven by
`Stream.resource`, so chunks are produced lazily without spawning
processes.

## How ready is it

Pyex is used in production for a single workload type — LLM-generated
HTTP handlers, behind a compute budget. It is not a general drop-in
for CPython, and it has not been independently audited.

What gives the project confidence:

- **Differential fuzzing against CPython.** 127 properties generate
  random Python programs across arithmetic, strings, collections,
  control flow, classes, generators, comprehensions, `match`/`case`,
  exceptions, and context managers. Each program is run through
  Pyex and CPython; outputs and exception types must match exactly.
  This is the suite that catches the bugs no human would write.

- **CPython conformance suite.** 411 hand-written snippets executed
  through both interpreters; canonical `repr` output is compared
  byte-for-byte. A separate exception-conformance file verifies
  that when Pyex raises `TypeError`, CPython does too.

- **Whole-program fixtures.** A growing set of complete programs
  recorded against CPython and replayed in CI, including programs
  that combine generators, file I/O, regex, classes, and stdlib.

- **IBM `dectest` vectors.** The `decimal` module passes 5,073 of
  the IBM standard-arithmetic test vectors. Skipped vectors are
  subnormal / payload / non-modelled signal cases, documented at
  the test site.

- **Property-based invariants.** 39 properties assert Pyex never
  crashes on random input — valid Python programs, malformed bytes,
  random tokens. Bad input must produce a structured error, never
  an Elixir exception.

- **Real workloads as tests.** End-to-end tests run a portfolio
  rebalancer, a DCF model, a Stripe-shaped webhook handler, an SSR
  blog, and a Tsiolkovsky rocket-equation simulator — programs sized
  and shaped like things customers actually write.

- **Static analysis.** Dialyzer is clean. Every public function has
  `@spec`. CI runs Elixir 1.19 / OTP 27+28 with warnings as errors.

```bash
mix test       # full suite
mix dialyzer   # static types
```

## Architecture

```
Source ──► Pyex.Lexer ──► Pyex.Parser ──► Pyex.Interpreter
                                                 │
                                              Pyex.Ctx
                                  (filesystem, env, modules,
                                   limits, network, capabilities)
```

The interpreter is `(ast, env, ctx) -> (value, env, ctx)`. No
processes, no message passing, no global state, no `throw`/`catch`
for control flow. Generators yield through tagged continuation
frames so a generator can be suspended, serialized in principle, and
resumed lazily.

This shape is deliberate. The library does not own a runtime; the
host application does. Pyex is a value you compute with.

## License

MIT
