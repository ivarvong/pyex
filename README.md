# Pyex

A Python 3 interpreter written in Elixir.

LLMs generate Python. This runs it as a function call inside your Elixir app --
no container, no VM, no process isolation. The LLM doesn't need pip install;
it writes self-contained programs using stdlib modules, and Pyex interprets them
directly on the BEAM.

## Quick Start

```elixir
Pyex.run!("2 + 3")
# => 5

{:ok, result, _ctx} = Pyex.run("sorted([3, 1, 2])")
# result => [1, 2, 3]
```

## A Real Example

The LLM writes a TODO API in Python:

```python
import fastapi
import json
import uuid

app = fastapi.FastAPI()

def load_todos():
    try:
        f = open("todos.json")
        data = json.loads(f.read())
        f.close()
        return data
    except:
        return []

def save_todos(todos):
    f = open("todos.json", "w")
    f.write(json.dumps(todos))
    f.close()

@app.post("/todos")
def create_todo(request):
    body = request.json()
    todo = {"id": str(uuid.uuid4()), "title": body["title"], "done": False}
    todos = load_todos()
    todos.append(todo)
    save_todos(todos)
    return todo

@app.get("/todos")
def list_todos():
    return load_todos()

@app.get("/todos/{todo_id}")
def get_todo(todo_id):
    for todo in load_todos():
        if todo["id"] == todo_id:
            return todo
    return None

@app.put("/todos/{todo_id}")
def update_todo(todo_id, request):
    body = request.json()
    todos = load_todos()
    for i in range(len(todos)):
        if todos[i]["id"] == todo_id:
            if "title" in body:
                todos[i]["title"] = body["title"]
            if "done" in body:
                todos[i]["done"] = body["done"]
            save_todos(todos)
            return todos[i]
    return None

@app.delete("/todos/{todo_id}")
def delete_todo(todo_id):
    todos = load_todos()
    new_todos = [t for t in todos if t["id"] != todo_id]
    if len(new_todos) == len(todos):
        return {"deleted": False}
    save_todos(new_todos)
    return {"deleted": True}
```

You serve it from Elixir:

```elixir
alias Pyex.{Ctx, Lambda}
alias Pyex.Filesystem.Memory

ctx = Ctx.new(filesystem: Memory.new(), fs_module: Memory)
{:ok, app} = Lambda.boot(source, ctx: ctx)

{:ok, resp, app} = Lambda.handle(app, %{method: "POST", path: "/todos", body: ~s|{"title": "Buy milk"}|})
# resp.status => 200
# resp.body => %{"id" => "a1b2c3...", "title" => "Buy milk", "done" => false}

{:ok, resp, app} = Lambda.handle(app, %{method: "GET", path: "/todos"})
# resp.body => [%{"id" => "a1b2c3...", "title" => "Buy milk", "done" => false}]
```

Boot once, handle many requests. State threads through -- the in-memory
filesystem persists across calls, exactly like a real server.

## Streaming

Generators yield chunks lazily. The interpreter doesn't buffer -- each `yield`
produces a chunk that your Phoenix endpoint can send immediately:

```python
from fastapi import StreamingResponse

@app.get("/stream")
def stream():
    def gen():
        for i in range(100):
            yield f"data: {i}\n\n"
    return StreamingResponse(gen(), media_type="text/event-stream")
```

```elixir
{:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/stream"})

# resp.chunks is a lazy Stream -- nothing runs until you consume it
Enum.take(resp.chunks, 3)
# => ["data: 0\n\n", "data: 1\n\n", "data: 2\n\n"]

# Phoenix integration:
conn = Plug.Conn.send_chunked(conn, resp.status)

Enum.reduce_while(resp.chunks, conn, fn chunk, conn ->
  case Plug.Conn.chunk(conn, chunk) do
    {:ok, conn} -> {:cont, conn}
    {:error, :closed} -> {:halt, conn}
  end
end)
```

## What Python Does It Support

Classes with inheritance and operator overloading. Generators and `yield from`.
`match`/`case`. Decorators. List/dict/set comprehensions. `*args`/`**kwargs`.
F-strings. `try`/`except`/`finally`. `with` statements. Type annotations
(parsed, silently ignored). Walrus operator. Most things an LLM would write.

262 CPython conformance tests verify output parity.

### Stdlib Modules

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
| `requests` | get, post |
| `sql` | parameterized queries against PostgreSQL |
| `boto3` | S3 client |

## Platform Features

### Custom Modules

Inject your app's capabilities as Python modules:

```elixir
Pyex.run!(source,
  modules: %{
    "auth" => %{"get_user" => {:builtin, fn [] -> "alice" end}},
    "db"   => %{"save" => {:builtin, fn [record] -> persist(record) end}}
  })
```

The LLM writes `import auth` and calls `auth.get_user()`. You control
what it can access.

### Filesystem Isolation

Each tenant gets its own filesystem. Three backends:

- `Pyex.Filesystem.Memory` -- in-memory map, fully serializable
- `Pyex.Filesystem.Local` -- sandboxed directory with path traversal protection
- `Pyex.Filesystem.S3` -- S3-backed via Req

### Suspend and Resume

Programs can pause execution. The entire state serializes to a binary
snapshot -- store it in Postgres, resume it days later:

```elixir
{:suspended, ctx} = Pyex.run(source, Pyex.Ctx.new())
snapshot = Pyex.snapshot(ctx)
# ... store snapshot, restart server, whatever ...
{:ok, result, _ctx} = Pyex.resume(source, ctx)
```

### Compute Budgets

```elixir
Pyex.run(source, timeout: 5_000)
# => {:error, "TimeoutError: execution exceeded time limit"}
```

### Profiling

```elixir
{:ok, _val, ctx} = Pyex.run(source, profile: true)
Pyex.profile(ctx)
# => %{line_counts: %{3 => 100}, call_counts: %{"fib" => 177}, call_us: %{"fib" => 4521}}
```

### Compile Once, Run Many

```elixir
{:ok, ast} = Pyex.compile(source)
{:ok, result1, _ctx} = Pyex.run(ast, ctx1)
{:ok, result2, _ctx} = Pyex.run(ast, ctx2)
```

Skip lexing and parsing on repeated execution. The AST is a plain Elixir
term -- cache it in ETS, store it wherever.

## Architecture

```
Source code
    |
    v
Pyex.Lexer        NimbleParsec tokenizer (significant whitespace, indent/dedent)
    |
    v
Pyex.Parser       Recursive descent, produces {node_type, [line: n], children} AST
    |
    v
Pyex.Interpreter  Tree-walking evaluator with threaded env + ctx
    |
    v
Pyex.Ctx          Event-sourced execution context (suspend, resume, replay)
```

No processes, no message passing, no global state. The interpreter is a
pure function of `(ast, env, ctx) -> (value, env, ctx)`.

## Tests

2,142 tests, 39 property-based tests, 0 failures. 262 CPython conformance
tests. 57 continuation stress tests for generators. 37 streaming tests.

```bash
mix test     # 5 seconds
mix dialyzer # clean
```

## Development

Requires Elixir ~> 1.19 and OTP 28. Uses asdf (`.tool-versions` in root).

```bash
mix deps.get
mix test
mix format
mix dialyzer
```

## License

MIT
