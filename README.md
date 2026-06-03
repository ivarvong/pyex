# Pyex

A Python 3 interpreter written in Elixir, designed as an execution
substrate for agent loops. The interpreter is a pure function on the
BEAM. Capabilities are values you pass in.

```elixir
Pyex.run!("sorted([3, 1, 2])")
# => [1, 2, 3]
```

> **🤖 Are you an LLM agent, or setting up in a fresh sandbox / CI?**
> Read [**`SETUP.md`**](SETUP.md) before installing anything — use the
> precompiled builds.hex.pm recipe, not `apt` or `asdf`.

## Why this exists

Pyex exists for one shape of problem: running Python written by, or
on behalf of, a language model — including the loop logic itself.
Tool calls, planners, controllers, retries, evaluation harnesses.
The kind of code an agent emits to act on the world, and the kind of
code that decides what the agent does next.

The design constraint is that running this code should be a function
call. Not a request to a sandbox service, not a cold container, not
a serialized round-trip to a worker pool. Capabilities the program
can use — files, network, database, app-specific tools — should be
values the host hands in, not endpoints behind an RPC.

That constraint matters most when the agent is non-interactive. When
no human is reviewing each step, the trust boundary is the only thing
between the model and the host system. Pyex is built so the
boundary is small, statically checkable, and the same shape as the
ordinary BEAM process boundary you already operate.

The shape rules a lot of things in and out:

- It rules out a microVM-class isolation boundary. Firecracker or
  gVisor isolates more strongly than a tree-walking interpreter in
  the same address space. Pyex is not a replacement for that layer
  when adversarial isolation is the requirement.
- It rules in latency, statefulness, and orchestration ergonomics.
  A step is a function call; an agent loop keeps its filesystem and
  in-memory state across calls; a generator is a continuation, not a
  process. Tools are Elixir functions you reference from Python.
- It rules out being a CPython replacement. Pyex implements the
  subset of Python that an agent or LLM tends to produce — not
  scipy, not C extensions, not the long tail of CPython internals.

Compute speed is roughly 10-100× slower than CPython for pure CPU
work. For agent loops dominated by tool I/O, JSON shaping, prompt
assembly, and routing, the interpreter is not the bottleneck.

## A small agent loop

A loop where the controller is Python, the tools are Elixir, and the
sandbox is a function call:

```elixir
tools = %{
  "search"   => {:builtin, fn [q] -> MyApp.Search.run(q) end},
  "fetch"    => {:builtin, fn [url] -> MyApp.HTTP.get(url) end},
  "remember" => {:builtin, fn [k, v] -> MyApp.KV.put(k, v) end}
}

agent_loop = """
import json
from agent import call_model, tools

state = {"steps": []}
for _ in range(10):
    decision = call_model(state)
    if decision["action"] == "stop":
        break
    result = tools[decision["tool"]](*decision["args"])
    state["steps"].append({"tool": decision["tool"], "result": result})
print(json.dumps(state))
"""

{:ok, _value, ctx} = Pyex.run(agent_loop,
  modules: %{"agent" => %{"call_model" => {:builtin, &call_model/1},
                          "tools"      => tools}},
  limits: [timeout: 30_000, max_memory_bytes: 50_000_000])

Pyex.output(ctx)
```

The Python program never reaches a Python runtime. It reaches the
Elixir interpreter, which dispatches `tools["fetch"](url)` to the
Elixir function you registered. There is no IPC, no marshalling
across a process boundary, and no path from the Python source to an
OS process.

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

Pyex is a tree-walking interpreter, not an `eval`. Python source
never reaches a Python runtime; it reaches a function written in
Elixir that decides what each AST node means. That makes the threat
model unusually simple to reason about.

- **No host filesystem.** `open()` reads and writes the
  `Pyex.Filesystem` backend you pass in (`Memory`, `S3`, or your
  own). Without a backend, file I/O fails closed.
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
  program that imports a gated module without the capability fails
  closed.
- **Compute time excludes I/O latency.** The compute budget is the
  Python interpreter's own work. Time spent inside an HTTP call or a
  SQL query doesn't drain it. An agent waiting on a slow tool
  doesn't get killed for it; an agent running an infinite loop does.
- **Resource ceilings are enforced.** Step count, estimated memory,
  output bytes, and call depth are checked at every step boundary.
- **Errors are structured.** `%Pyex.Error{kind: :timeout | :python |
  :syntax | :limit | ...}` so callers route on failure mode without
  string matching. The Python-side exception hierarchy mirrors
  CPython's tree, so `except OSError` catches `FileNotFoundError`
  exactly the way an agent author would expect.

### Statically proven escape boundary

The above guarantees rest on the library not calling host primitives
it shouldn't. Pyex enforces this with a custom static analyzer
(`Pyex.BannedCallTracer`) that walks compiled BEAM abstract code on
every CI run and fails the build if any module under `lib/pyex`
references:

- `File`, `:file`, `Port`, `Node` (filesystem, ports, remote nodes)
- `Process`, `Agent`, `GenServer`, `Supervisor`, `Task` (process
  creation and supervised state)
- `System.cmd`, `System.shell`, `:os.cmd`, `:erlang.open_port`
  (OS process spawning)
- `System.get_env`, `System.put_env` (host env leakage)
- `:erlang.spawn`, `:erlang.spawn_link`, `:erlang.spawn_monitor`
- `:erlang.get`, `:erlang.put` (process dictionary)

A short, justified allowlist exists for `Process.sleep/1` (so
`time.sleep` actually blocks), `Task.async/2/yield/shutdown` (regex
timeout), `GenServer.stop/1` (sql connection teardown), and
`:os.system_time/1` (wall clock). The analyzer also resolves
`apply(File, :read, [path])` when the args are literal atoms.

This means the sandbox guarantees aren't a code-review promise.
They're a CI gate on the compiled artifact.

### What it isn't

Pyex has not been through a third-party security audit. Treat it as
a hardened library, not as adversarial isolation equivalent to a
container or microVM. If your threat model is a sophisticated
attacker actively trying to escape, Pyex belongs *inside* a stronger
isolation layer, not in place of one.

## What it runs

The hard parts of Python, implemented to match CPython semantics:

- **Faithful object model.** Heap-based references with aliasing
  (`b = a; b.val = 99` ⇒ `a.val == 99`). Intrusive linked lists
  work. C3 linearization for MRO with cached lookups. Data
  descriptors with `__get__` / `__set__`. `__slots__` enforcement.
  Subclassing built-in types (`list`, `dict`, `str`, `int`) via a
  `__wrapped__` pattern so `class MyList(list)` round-trips through
  iteration, `len`, `isinstance`, and method dispatch. `super()` in
  multi-inheritance trees with the correct MRO.
- **Generators as continuations.** `yield`, `yield from`, generator
  `send()`, two-way communication, lazy iteration. Generators
  suspend through tagged continuation frames so an agent step can be
  paused and resumed without owning a process.
- **`async` / `await` as cooperative coroutines.** `async def`
  produces a coroutine; `await` is yield-from over the inner
  iterator, so yields propagate up to the surrounding trampoline
  (`asyncio.run`, `asyncio.gather`, or another `await`). Observable
  interleaving matches CPython:
  `gather(step("A"), step("B"))` over coroutines that
  `await asyncio.sleep(0)` between mutations produces ABABAB.
  `asyncio.create_task` is lazy — the body runs when the Task is
  awaited, with `Task.result()` / `.done()` / `.cancel()` /
  `.exception()`. Nested `asyncio.run` raises `RuntimeError`.
  Async list comprehensions (`[x async for x in g()]`) parse and
  run. `await` on a non-awaitable raises CPython-shaped TypeError.
  Async generators ride the same lazy-iterator machinery sync
  generators use, so FastAPI streaming patterns work unchanged.
- **Exception fidelity.** The full CPython exception hierarchy
  (`BaseException` → `Exception` → `OSError` → `FileNotFoundError`,
  etc.). `try` / `except` / `finally` / `else`, exception groups,
  `raise from`, traceback chaining. `isinstance(e, OSError)`
  resolves through the tree exactly as CPython does.
- **Modern syntax.** `match` / `case` with class, sequence, and
  mapping patterns. Walrus operator. Type annotations (parsed,
  ignored at runtime, like CPython). F-strings with format specs.
  `*args` / `**kwargs`, keyword-only parameters, decorators,
  comprehensions, context managers.
- **Dict and set semantics.** Custom `__eq__` / `__hash__` resolves
  correctly as a dict key. Insertion order is preserved as in
  CPython 3.7+.
- **Decimal arithmetic** that passes 5,073 of the IBM `dectest`
  conformance vectors. Skipped vectors are subnormal, payload, and
  non-modelled signal cases, documented at the test site.

Standard library, implemented in Elixir to match CPython semantics:

```
abc          datetime     html         pathlib     sql
asyncio      decimal      hmac         pydantic    statistics
base64       enum         io           pygments    string
bisect       fastapi      itertools    random      sys
boto3        fnmatch      jinja2       re          textwrap
collections  functools    json         requests    time
contextlib   glob         markdown     secrets     typing
copy         hashlib      math         shutil      unittest
crypto       heapq        operator     urllib      uuid
csv                                                yaml
dataclasses                                        zipfile / zoneinfo
```

`pandas` is partial. `pydantic` does `BaseModel`, `Field`, and
type coercion. `fastapi` is a list-based implementation of the
route-decorator subset, with streaming generators.

## HTTP handlers without a server

Pyex also serves FastAPI directly, without a server process. This
is useful for agent-emitted handlers and for traditional
LLM-generated webapps:

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

Boot once, handle many requests. State threads through —
filesystem mutations persist across calls, exactly as they would on
a long-lived server. Streaming responses use generator
continuations driven by `Stream.resource`, so chunks are produced
lazily without spawning processes.

## How fast is it

Measured on Apple Silicon (M-series, OTP 28, 1000-iteration
samples), wall-clock end-to-end including lex + parse + interpret:

| Workload                                   | p50    | p99    |
| ------------------------------------------ | ------ | ------ |
| FizzBuzz (100 iterations)                  | 182 µs | 238 µs |
| Algorithms (~150 LOC: sieve + sort + fib + stats) | 1.67 ms | 2.04 ms |
| FastAPI cold boot                          | 221 µs | 302 µs |
| FastAPI route — list + Jinja2 render       | 108 µs | 166 µs |
| FastAPI route — markdown + Jinja2 render   | 140 µs | 202 µs |
| FastAPI route — 404                        |   9 µs |  19 µs |

Pre-compiled AST execution skips lex + parse and saves 59 µs on
FizzBuzz, 236 µs on the algorithms suite. Reproduce with
`mix run bench/readme_bench.exs`.

For comparison, a CPython container cold start is on the order of
seconds. A Pyex tenant boot is on the order of microseconds.

## How ready is it

Pyex is the runtime behind production webapps and is the substrate
the author is using for non-interactive agent research. It is not a
general drop-in for CPython, and it has not been independently
audited.

What gives the project confidence:

- **Differential fuzzing against CPython.** Hundreds of properties
  generate random Python programs across arithmetic, strings,
  collections, control flow, classes, generators, comprehensions,
  `match` / `case`, exceptions, and context managers. Each program
  is run through Pyex and CPython; outputs and exception types must
  match exactly. This is the suite that catches the bugs no human
  would write.

- **CPython conformance suite.** Hundreds of hand-written snippets
  executed through both interpreters; canonical `repr` output is
  compared byte-for-byte. A separate exception-conformance file
  verifies that when Pyex raises `TypeError`, CPython does too.

- **Whole-program fixtures.** A growing set of complete programs
  recorded against CPython and replayed in CI, including programs
  that combine generators, file I/O, regex, classes, and stdlib.

- **IBM `dectest` vectors.** The `decimal` module passes 5,073 IBM
  standard-arithmetic test vectors. Skipped vectors are subnormal,
  payload, and non-modelled signal cases.

- **Property-based invariants.** Properties assert Pyex never
  crashes on random input — valid Python programs, malformed bytes,
  random tokens. Bad input must produce a structured error, never
  an Elixir exception.

- **Statically-proven escape boundary.** `Pyex.BannedCallTracer`
  walks the compiled BEAM artifact every CI run and fails the build
  if any banned host primitive is referenced. See the sandbox
  section above.

- **Real workloads as tests.** End-to-end tests run a portfolio
  rebalancer, a DCF model, a Stripe-shaped webhook handler, an SSR
  blog, a Tsiolkovsky rocket-equation simulator, and a multi-tenant
  scaling benchmark for 100K hypothetical tenants — programs sized
  and shaped like the actual distribution.

- **Static analysis.** Dialyzer is clean. Every public function has
  `@spec`. CI runs Elixir 1.19 / OTP 27+28 with warnings as errors.

```bash
mix test       # full suite
mix dialyzer   # static types
```

## Operating it

Pyex emits `:telemetry` events at the lifecycle boundaries that
matter:

- `[:pyex, :run, :start | :stop | :exception]` for every program
- `[:pyex, :request, :start | :stop]` for every HTTP request issued
  by sandboxed code (after the network policy approves it)
- `[:pyex, :query, :start | :stop]` for every SQL query issued by
  sandboxed code

`Pyex.Trace.attach()` collects these into a span tree for
debugging. `Pyex.Lambda.handle/2` returns per-request telemetry
(compute time, total time, file ops, event count) inline on the
response.

Multi-tenant operation is a design property, not an extension. A
booted FastAPI app is a struct (`%{routes, env, ctx}`); a tenant is
a value. There are no per-tenant processes or pools to size,
because the runtime doesn't own state on the tenant's behalf — the
caller does. Tenants serialize, migrate, and run concurrently
under the BEAM scheduler the same way any other value does.

## Architecture

```
Source ──► Pyex.Lexer ──► Pyex.Parser ──► Pyex.Interpreter
                                                 │
                                              Pyex.Ctx
                                  (filesystem, env, modules,
                                   limits, network, capabilities,
                                   heap, iterators)
```

The interpreter is `(ast, env, ctx) -> (value, env, ctx)`. No
processes, no message passing, no global state, no `throw`/`catch`
for control flow. Generators yield through tagged continuation
frames so a generator can be suspended, serialized in principle,
and resumed lazily.

The interpreter itself is decomposed into 22 submodules under
`lib/pyex/interpreter/` — assignments, binary ops, calls, class
lookup, control flow, dunder protocols, exceptions, format,
imports, iteration, match, statements — each a small file with one
responsibility. The pure-functional core is what makes the static
analyzer's job tractable.

This shape is deliberate. The library does not own a runtime; the
host application does. Pyex is a value you compute with.

## Development

Requires Elixir `~> 1.19` on OTP 28. For local work, the repo pins exact
versions in `.tool-versions` (use `asdf` or `mise`). For a cold environment
(fresh sandbox, CI, new container), follow [`SETUP.md`](SETUP.md) — precompiled
builds.hex.pm binaries, not `apt` or `asdf`.

## License

MIT
