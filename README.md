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
  environ: %{"API_KEY" => "sk-..."}
)
```

### Filesystem

```elixir
alias Pyex.Filesystem.Memory

fs = Memory.new(%{"data.json" => ~s({"users": ["alice", "bob"]})})
{:ok, result, _ctx} = Pyex.run(source, filesystem: fs, fs_module: Memory)
```

Three backends: `Memory` (in-memory map), `Local` (sandboxed directory),
`S3` (S3-backed via Req).

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
Pyex.run(source, sql: true, environ: %{"DATABASE_URL" => "postgres://..."})
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
{:ok, _val, ctx} = Pyex.run("for i in range(3): print(i)")
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
                                          (filesystem, environ,
                                           compute budget, modules)
```

No processes, no message passing, no global state. The interpreter is a
pure function: `(ast, env, ctx) -> (value, env, ctx)`.

## Tests

2,400+ tests, 160 property-based tests, 262 CPython conformance tests.
Zero failures, zero Dialyzer warnings.

```bash
mix test
mix dialyzer
```

## Development

Requires Elixir ~> 1.19, OTP 28. Uses asdf (`.tool-versions` in root).

```bash
mix deps.get
mix test
mix format
mix dialyzer
```

## License

MIT
