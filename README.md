# Pyex

Run LLM-generated Python inside your Elixir app. No containers,
no ports, no process isolation -- just a function call on the BEAM.

> **Experimental.** Under active development. Not audited for production use.

```elixir
Pyex.run!("sorted([3, 1, 2])")
# => [1, 2, 3]
```

## Why

LLMs write Python. If your backend is Elixir, you need a way to execute
it. The options are: spin up a Docker container per request, maintain a
pool of Python processes, or interpret it directly.

Pyex interprets it directly. The tradeoff is speed (12-70x slower than
CPython on pure computation), but for most LLM workloads -- data
transformation, API handlers, template rendering -- the interpreter
isn't the bottleneck. Your database and network calls are.

## Install

```elixir
def deps do
  [{:pyex, "~> 0.1.0"}]
end
```

Requires a C compiler for the [cmark](https://hex.pm/packages/cmark)
Markdown NIF.

## API

Four public functions:

```elixir
{:ok, ast} = Pyex.compile(source)
{:ok, value, ctx} = Pyex.run(source_or_ast, opts)
value = Pyex.run!(source_or_ast, opts)
output_string = Pyex.output(ctx)
```

`run/2` accepts either a source string or a pre-compiled AST. The second
argument is a `Pyex.Ctx` struct or a keyword list of options.

## Getting Data In

Everything flows through the context. Python code can only access what
you explicitly provide.

### Environment variables

```elixir
{:ok, result, _ctx} = Pyex.run(
  "import os\nos.environ['API_KEY']",
  env: %{"API_KEY" => "sk-..."}
)
```

### Filesystem

```elixir
alias Pyex.Filesystem.Memory

fs = Memory.new(%{"data.json" => ~s({"users": ["alice", "bob"]})})
{:ok, result, _ctx} = Pyex.run(source, filesystem: fs)
```

Two backends: `Memory` (in-memory map) and `S3` (S3-backed via Req).

### Custom modules

Inject your app's capabilities as importable Python modules:

```elixir
Pyex.run!(source,
  modules: %{
    "auth" => %{"get_user" => {:builtin, fn [] -> "alice" end}},
    "db"   => %{"query" => {:builtin, fn [sql] -> do_query(sql) end}}
  })
```

The LLM writes `import auth` and calls `auth.get_user()`. You control
what it can access.

## Sandbox Controls

### Compute budget

```elixir
Pyex.run(source, timeout_ms: 5_000)
# => {:error, %Pyex.Error{kind: :timeout}}
```

### Network access

All network access is denied by default:

```elixir
Pyex.run(source, network: [allowed_hosts: ["api.example.com"]])
```

### I/O capabilities

SQL and S3 require explicit opt-in:

```elixir
Pyex.run(source, sql: true, env: %{"DATABASE_URL" => "postgres://..."})
Pyex.run(source, boto3: true)
```

## Error Handling

Errors are structured with a `kind` field for programmatic handling:

```elixir
case Pyex.run(source) do
  {:ok, result, ctx} -> handle_result(result)
  {:error, %Pyex.Error{kind: :timeout}} -> send_resp(504, "Timeout")
  {:error, %Pyex.Error{kind: :python}} -> send_resp(500, "Runtime error")
  {:error, %Pyex.Error{kind: :syntax}} -> send_resp(400, "Bad Python")
end
```

Kinds: `:syntax`, `:python`, `:timeout`, `:import`, `:io`,
`:route_not_found`, `:internal`.

## Print Output

```elixir
{:ok, _val, ctx} = Pyex.run("for i in range(3):\n    print(i)")
Pyex.output(ctx)
# => "0\n1\n2"
```

## FastAPI / Lambda

LLMs write HTTP handlers in Python. You serve them from Elixir:

```python
import fastapi
app = fastapi.FastAPI()

@app.get("/hello/{name}")
def hello(name):
    return {"message": f"hello {name}"}
```

```elixir
{:ok, app} = Pyex.Lambda.boot(source, ctx: ctx)
{:ok, resp, app} = Pyex.Lambda.handle(app, %{method: "GET", path: "/hello/world"})
# resp.status => 200, resp.body => %{"message" => "hello world"}
```

Boot once, handle many requests. State threads through -- the
filesystem persists across calls, exactly like a real server.

POST with a JSON body:

```elixir
{:ok, resp, _app} = Pyex.Lambda.handle(app, %{
  method: "POST",
  path: "/items",
  body: ~s({"name": "widget", "qty": 3})
})
```

The handler reads `request.json()` just like real FastAPI.

### Streaming

Generators yield chunks lazily:

```elixir
{:ok, resp, _app} = Pyex.Lambda.handle_stream(app, %{method: "GET", path: "/events"})
Enum.take(resp.chunks, 3)
# => ["data: 0\n\n", "data: 1\n\n", "data: 2\n\n"]
```

## What Python Does It Support

Classes with inheritance and operator overloading. Generators and
`yield from`. `match`/`case`. Decorators. List/dict/set comprehensions.
`*args`/`**kwargs`. F-strings. `try`/`except`/`finally`. `with`
statements. Type annotations (parsed, silently ignored). Walrus
operator. Most things an LLM would write.

### Stdlib

| Module | What it does |
|--------|-------------|
| `json` | loads, dumps |
| `math` | trig, sqrt, log, ceil, floor, pi, e |
| `random` | randint, choice, shuffle, sample |
| `re` | match, search, findall, sub, split |
| `time` | time, sleep, monotonic |
| `datetime` | datetime.now, date.today, timedelta |
| `collections` | Counter, defaultdict, OrderedDict |
| `csv` | reader, DictReader, writer, DictWriter |
| `itertools` | chain, product, permutations, combinations, ... |
| `html` | escape, unescape |
| `markdown` | markdown to HTML |
| `jinja2` | template engine with loops, conditionals, includes |
| `uuid` | uuid4, uuid7 |
| `unittest` | TestCase with assertions |
| `fastapi` | route registration, HTMLResponse, JSONResponse, StreamingResponse |
| `pydantic` | BaseModel, Field validation, type coercion |
| `requests` | get, post, put, patch, delete (network-gated) |
| `sql` | parameterized queries against PostgreSQL (capability-gated) |
| `boto3` | S3 client (capability-gated) |

## Performance

Tree-walking interpreter. Pure computation is 12-70x slower than
CPython. Cold startup is 7-83x faster (no process to spawn).

| Benchmark | CPython cold | Pyex cold |
|-----------|-------------|-----------|
| FizzBuzz (100 iter) | 16.3 ms | 197 us |
| Algorithms (~150 LOC) | 16.8 ms | 2.3 ms |

For HTTP handler workloads (the Lambda path), per-request latency is
66-90 us after boot. The interpreter isn't the bottleneck.

`mix run bench/cpython_comparison.exs` to run benchmarks yourself.

## Architecture

```
Source  ->  Pyex.Lexer  ->  Pyex.Parser  ->  Pyex.Interpreter
                                                    |
                                                 Pyex.Ctx
                                           (filesystem, env,
                                            compute budget, modules)
```

No processes, no message passing, no global state. The interpreter is a
pure function: `(ast, env, ctx) -> (value, env, ctx)`.

## Verification

2,577 tests and 160 property-based tests across 63 files, organized into
five layers that reinforce each other.

```bash
mix test          # ~150s, all layers
mix dialyzer      # static types
```

### Layer 1: Pipeline unit tests

Each stage of the interpreter pipeline has isolated tests. The lexer
tests tokenize strings and assert token sequences. The parser tests
feed tokens and assert AST node shapes. These catch regressions at
the lowest level without running Python end-to-end.

`test/pyex/lexer_test.exs` (62 tests), `test/pyex/parser_test.exs`
(83 tests)

### Layer 2: Feature tests

The bulk of the suite. Each Python feature has a dedicated file that
runs real Python through `Pyex.run!` and asserts on the return value.
Classes, generators, comprehensions, try/except, match/case, augmented
assignment, and string/list/dict methods all have standalone files.
Error boundary tests verify that bad input produces the right
`Pyex.Error` with the right kind, message, and line number -- error
quality matters because LLMs use error messages to self-correct.

`test/pyex/interpreter_test.exs` (282 tests),
`test/pyex/builtins_test.exs` (153 tests),
`test/pyex/methods_test.exs` (120 tests),
`test/pyex/classes_test.exs` (60 tests),
`test/pyex/error_boundary_test.exs` (67 tests),
23 stdlib test files, and others

### Layer 3: CPython conformance

335 hand-written snippets run through both Pyex and CPython (via
`System.cmd("python3", ...)`). Each snippet uses `print(repr(...))`
so output is compared as canonical Python strings. If `python3` isn't
on PATH, these skip gracefully.

A separate file (54 tests) verifies exception types: when Pyex raises
`TypeError`, CPython raises `TypeError` too.

`test/pyex/conformance_test.exs` (335 tests),
`test/pyex/error_conformance_test.exs` (54 tests)

### Layer 4: Property-based testing and fuzzing

Three files use StreamData to generate random inputs and assert
invariants rather than specific values.

**Robustness properties** (39 properties): generate random valid Python
programs -- arithmetic, collections, classes, generators, comprehensions,
stdlib calls -- and assert Pyex never crashes. It may return an error,
but it must never raise an Elixir exception. Also feeds random bytes to
the lexer and parser to verify they reject garbage gracefully.

**Differential fuzzing** (79 properties): generate random Python programs,
run through both Pyex and CPython, assert identical output. When both
error, asserts they raise the same exception type. This is the strongest
correctness guarantee -- it finds edge cases no human would write.

**Math oracle** (42 properties): generate random numeric datasets, compute
statistics (sum, mean, median, variance, stddev) in Python, cross-check
against Polars via Explorer. A three-way oracle: Elixir generates data,
Python computes, Polars verifies.

`test/pyex/property_test.exs`,
`test/pyex/differential_fuzz_test.exs`,
`test/pyex/math_oracle_test.exs`

### Layer 5: Integration and sandbox tests

End-to-end tests that exercise the full stack including sandbox
controls. These use `Pyex.Ctx` to configure compute timeouts,
network policies, filesystem backends, and capability gates, then
run realistic programs against them.

The Lambda tests boot FastAPI apps and dispatch HTTP requests,
including streaming responses via generators. Capability tests verify
that boto3, SQL, and network access are denied by default and produce
clear error messages when unconfigured. Filesystem tests cover both
the Memory backend and the S3 backend (42 Bypass-mocked unit tests
plus 8 real R2 integration tests, excluded by default). The README
tests run every code example from this file.

`test/pyex_test.exs`, `test/pyex/lambda_test.exs`,
`test/pyex/streaming_test.exs`, `test/pyex/capabilities_test.exs`,
`test/pyex/filesystem/s3_test.exs`, `test/pyex/readme_test.exs`,
`test/pyex/llm_programs_test.exs`

### How the layers work together

A bug in string slicing would be caught by the unit test for slicing
(layer 2), by any conformance test that slices a string (layer 3), and
by differential fuzzing if it generates a slice expression (layer 4).
A security issue like unbounded `itertools.product` would be caught by
the DoS protection tests (layer 2) and by the sandbox integration
tests (layer 5). The layers overlap deliberately -- each one catches
classes of bugs the others might miss.

### Static analysis

Dialyzer runs on every change. All public functions have `@spec`
annotations. The `.dialyzer_ignore.exs` file suppresses 30 known
warnings from NimbleParsec-generated code; real warnings are zero.

## Development

Requires Elixir ~> 1.19 and OTP 28.

```bash
mix deps.get
mix test
mix format
mix dialyzer
```

## License

MIT
