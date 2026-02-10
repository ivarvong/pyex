# SSR Blog Profiling
#
# Runs each endpoint with full per-function profiling to identify
# where interpreter time is spent.
#
# Run with: mix run bench/ssr_blog_profile.exs

alias Pyex.{Ctx, Interpreter, Lambda}
alias Pyex.Filesystem.Memory

blog_source = ~S"""
import fastapi
import json
import markdown
from fastapi import HTMLResponse
from jinja2 import Template

app = fastapi.FastAPI()

def read_file(path):
    f = open(path, "r")
    text = f.read()
    f.close()
    return text

def load_template(path):
    return Template(read_file(path))

def load_index():
    return json.loads(read_file("index.json"))

def estimate_reading_time(text):
    words = len(text.split())
    return max(1, words // 200)

@app.get("/posts")
def list_posts():
    base = load_template("templates/base.html")
    frag = load_template("templates/list.html")
    index = load_index()
    inner = frag.render(posts=index)
    html = base.render(title="Archive", content=inner)
    return HTMLResponse(
        html,
        headers={"cache-control": "public, max-age=60"}
    )

@app.get("/posts/{slug}")
def get_post(slug):
    index = load_index()
    for post in index:
        if post["slug"] == slug:
            base = load_template("templates/base.html")
            frag = load_template("templates/post.html")
            md_source = read_file("posts/" + slug + ".md")
            html_body = markdown.markdown(md_source)
            rt = estimate_reading_time(md_source)
            inner = frag.render(
                title=post["title"],
                date=post["date"],
                reading_time=rt,
                body=html_body
            )
            html = base.render(title=post["title"], content=inner)
            return HTMLResponse(
                html,
                headers={"cache-control": "public, max-age=3600"}
            )
    return HTMLResponse("<h1>404 Not Found</h1>", status_code=404)
"""

base_html = ~S"""
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{ title }} - Pyex Blog</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 720px; margin: 0 auto; padding: 2rem; }
    article { line-height: 1.6; }
    pre { background: #f5f5f5; padding: 1rem; overflow-x: auto; border-radius: 4px; }
    code { font-family: 'SF Mono', monospace; font-size: 0.9em; }
    blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 1rem; color: #555; }
    nav { margin-bottom: 2rem; border-bottom: 1px solid #eee; padding-bottom: 1rem; }
    nav a { margin-right: 1rem; color: #0066cc; text-decoration: none; }
    .meta { color: #888; font-size: 0.9em; margin-bottom: 1.5rem; }
    footer { margin-top: 3rem; border-top: 1px solid #eee; padding-top: 1rem; color: #888; font-size: 0.85em; }
  </style>
</head>
<body>
  <nav>
    <a href="/">Home</a>
    <a href="/posts">Archive</a>
    <a href="/about">About</a>
  </nav>
  {{ content | safe }}
  <footer>Powered by Pyex</footer>
</body>
</html>
"""

list_html = ~S"""
<h1>Blog Posts</h1>
{% if posts %}
<ul>
{% for post in posts %}
  <li>
    <a href="/posts/{{ post.slug }}">{{ post.title }}</a>
    <span class="meta"> &mdash; {{ post.date }}</span>
  </li>
{% endfor %}
</ul>
{% else %}
<p>No posts yet.</p>
{% endif %}
"""

post_html = ~S"""
<article>
<h1>{{ title }}</h1>
<div class="meta">{{ date }} &middot; {{ reading_time }} min read</div>
{{ body | safe }}
</article>
<p><a href="/posts">&larr; Back to archive</a></p>
"""

short_md = """
# Getting Started with Pyex

Pyex is a Python 3 interpreter written in Elixir. It's designed as a
capabilities-based sandbox for LLMs to safely run compute.

## Quick Start

```python
result = Pyex.run!("2 + 2")
# => 4
```

That's it. No setup, no dependencies, no escape.
"""

medium_md = """
# Building a REST API with FastAPI

FastAPI is one of the most popular Python web frameworks. In Pyex, we
provide a compatible subset that lets LLMs build HTTP endpoints.

## Route Registration

Routes are registered using decorators:

```python
import fastapi

app = fastapi.FastAPI()

@app.get("/users/{user_id}")
def get_user(user_id):
    return {"id": user_id, "name": "Alice"}
```

## Request Handling

Handlers receive path parameters automatically. For POST/PUT requests,
use the `request` parameter to access the body:

```python
@app.post("/users")
def create_user(request):
    data = request.json()
    return {"created": data["name"]}
```

## Response Types

By default, handlers return JSON. For HTML responses, use `HTMLResponse`:

```python
from fastapi import HTMLResponse

@app.get("/page")
def page():
    return HTMLResponse("<h1>Hello World</h1>")
```

You can also set custom status codes:

```python
@app.get("/not-found")
def not_found():
    return HTMLResponse("<h1>404</h1>", status_code=404)
```

## Path Parameters

Path parameters are coerced to integers when possible:

| Path | Parameter | Type |
|------|-----------|------|
| `/users/42` | `user_id=42` | `int` |
| `/users/alice` | `name="alice"` | `str` |

## Summary

- **Decorators** register routes
- **Path params** are extracted from `{name}` segments
- **Request body** via `request.json()`
- **HTMLResponse** / **JSONResponse** for explicit response control
"""

long_md = """
# The Complete Guide to Sandboxed Python Execution

## Introduction

Running untrusted code is one of the hardest problems in software
engineering. Traditional approaches use OS-level isolation: containers,
VMs, seccomp-bpf, or WebAssembly. These work, but they're heavy,
slow to cold-start, and complex to operate.

Pyex takes a different approach: **interpretation**. Instead of running
Python bytecode on CPython inside a sandbox, we interpret the Python
AST directly in Elixir. This gives us:

1. **Total control** over every operation
2. **No escape** -- there's no native code to exploit
3. **Deterministic replay** via the Ctx event log
4. **Serializable state** -- the entire interpreter state is data

## Architecture

### The Pipeline

```
Source Code -> Lexer -> Parser -> Interpreter -> Result
```

Each stage is a pure function (modulo the Ctx for I/O):

- **Lexer** (`Pyex.Lexer`): NimbleParsec-based tokenizer
- **Parser** (`Pyex.Parser`): recursive descent, produces typed AST
- **Interpreter** (`Pyex.Interpreter`): tree-walking evaluator

### The Context

The `Pyex.Ctx` struct carries all mutable state:

- **Event log**: every side effect is recorded
- **Filesystem**: pluggable backends (Memory, Local, S3)
- **Handles**: open file descriptors
- **Compute budget**: timeout enforcement
- **Mode**: `:live`, `:replay`, or `:noop`

### Environment Model

Variables live in a scope stack (`Pyex.Env`). Each function call pushes
a new scope; closures capture the environment at definition time.

```python
def make_counter(start):
    count = start
    def increment():
        nonlocal count
        count += 1
        return count
    return increment

c = make_counter(10)
c()  # 11
c()  # 12
```

## The Stdlib

We don't try to support existing Python packages. Instead, we build a
focused stdlib that covers what LLMs actually need:

| Module | Purpose |
|--------|---------|
| `json` | Parse and serialize JSON |
| `math` | Mathematical functions |
| `random` | Random number generation |
| `re` | Regular expressions |
| `time` | Sleep, timestamps |
| `datetime` | Date/time operations |
| `collections` | Counter, defaultdict |
| `csv` | CSV reading and writing |
| `html` | HTML escaping |
| `markdown` | Markdown to HTML |
| `jinja2` | Template rendering |
| `uuid` | UUID generation |
| `fastapi` | HTTP route registration |
| `requests` | HTTP client |

## Security Model

### Compute Limits

Every operation increments a nanosecond counter. The Ctx enforces a
configurable timeout.

### Filesystem Isolation

The filesystem is a behaviour with three implementations:

- **Memory**: pure map, fully serializable, zero I/O
- **Local**: sandboxed directory with path traversal protection
- **S3**: remote storage via signed requests

Programs can only access files through the configured backend.

### No Network by Default

HTTP requests via the `requests` module go through the Ctx.

### No Process Spawning

The interpreter is single-threaded by design.

## Performance Characteristics

The tree-walking interpreter is roughly 100-1000x slower than CPython,
depending on the workload. For LLM sandbox use cases, this is fine.

## Conclusion

Pyex is not a general-purpose Python runtime. It's a sandboxed
computation engine designed for one job: letting LLMs write and
execute Python safely, with full observability and deterministic replay.
"""

# ---------- Build filesystem ----------

fs = Memory.new()

posts = [
  %{"slug" => "getting-started", "title" => "Getting Started with Pyex", "date" => "2026-01-15"},
  %{"slug" => "rest-api", "title" => "Building a REST API with FastAPI", "date" => "2026-01-22"},
  %{
    "slug" => "sandboxed-execution",
    "title" => "The Complete Guide to Sandboxed Python Execution",
    "date" => "2026-02-01"
  }
]

{:ok, fs} = Memory.write(fs, "index.json", Jason.encode!(posts), :write)
{:ok, fs} = Memory.write(fs, "templates/base.html", base_html, :write)
{:ok, fs} = Memory.write(fs, "templates/list.html", list_html, :write)
{:ok, fs} = Memory.write(fs, "templates/post.html", post_html, :write)
{:ok, fs} = Memory.write(fs, "posts/getting-started.md", short_md, :write)
{:ok, fs} = Memory.write(fs, "posts/rest-api.md", medium_md, :write)
{:ok, fs} = Memory.write(fs, "posts/sandboxed-execution.md", long_md, :write)

ctx = Ctx.new(filesystem: fs, fs_module: Memory, profile: true)

IO.puts("=" |> String.duplicate(70))
IO.puts("SSR Blog Profile")
IO.puts("=" |> String.duplicate(70))

# ---------- Boot with profiling ----------

{boot_us, {:ok, app}} = :timer.tc(fn -> Lambda.boot(blog_source, ctx: ctx) end)
boot_profile = Pyex.profile(app.ctx)

IO.puts("\n--- Boot (#{Float.round(boot_us / 1000, 2)} ms) ---\n")

if boot_profile do
  IO.puts("Function calls during boot:")

  boot_profile.call_counts
  |> Enum.sort_by(fn {_, count} -> -count end)
  |> Enum.each(fn {name, count} ->
    us = Map.get(boot_profile.call_us, name, 0)

    IO.puts(
      "  #{String.pad_trailing(name, 30)} #{String.pad_leading(Integer.to_string(count), 5)}x  #{String.pad_leading(Integer.to_string(us), 8)}μs"
    )
  end)
end

# ---------- Profile each endpoint ----------

endpoints = [
  {"GET /posts", %{method: "GET", path: "/posts"}},
  {"GET /posts/getting-started (short)", %{method: "GET", path: "/posts/getting-started"}},
  {"GET /posts/rest-api (medium)", %{method: "GET", path: "/posts/rest-api"}},
  {"GET /posts/sandboxed-execution (long)", %{method: "GET", path: "/posts/sandboxed-execution"}},
  {"GET /posts/nonexistent (404)", %{method: "GET", path: "/posts/nonexistent"}}
]

for {label, request} <- endpoints do
  profile_ctx = %{app.ctx | profile: %{line_counts: %{}, call_counts: %{}, call_us: %{}}}
  profile_app = %{app | ctx: profile_ctx}

  Interpreter.init_profile(profile_ctx)

  {us, {:ok, resp, _updated_app}} =
    :timer.tc(fn ->
      Lambda.handle(profile_app, request)
    end)

  profile = %{
    line_counts: Process.get(:pyex_line_counts, %{}),
    call_counts: Process.get(:pyex_call_counts, %{}),
    call_us: Process.get(:pyex_call_us, %{})
  }

  Process.delete(:pyex_profile)
  Process.delete(:pyex_line_counts)
  Process.delete(:pyex_call_counts)
  Process.delete(:pyex_call_us)

  total_calls = Enum.sum(Map.values(profile.call_counts))
  total_func_us = Enum.sum(Map.values(profile.call_us))
  total_lines = Enum.sum(Map.values(profile.line_counts))

  IO.puts("\n--- #{label} (#{resp.status}) ---")

  IO.puts(
    "Wall time: #{Float.round(us / 1000, 2)} ms | Body: #{byte_size(to_string(resp.body))} B"
  )

  IO.puts(
    "Lines executed: #{total_lines} | Function calls: #{total_calls} | In-function time: #{total_func_us}μs\n"
  )

  if map_size(profile.call_counts) > 0 do
    IO.puts(
      "  #{String.pad_trailing("function", 30)} #{String.pad_leading("calls", 6)}  #{String.pad_leading("total μs", 10)}  #{String.pad_leading("avg μs", 8)}  #{String.pad_leading("% time", 8)}"
    )

    IO.puts("  " <> String.duplicate("-", 68))

    profile.call_counts
    |> Enum.sort_by(fn {name, _} -> -Map.get(profile.call_us, name, 0) end)
    |> Enum.each(fn {name, count} ->
      us_total = Map.get(profile.call_us, name, 0)
      avg = if count > 0, do: Float.round(us_total / count, 1), else: 0.0
      pct = if total_func_us > 0, do: Float.round(us_total / total_func_us * 100, 1), else: 0.0

      IO.puts(
        "  #{String.pad_trailing(name, 30)} #{String.pad_leading(Integer.to_string(count), 6)}  #{String.pad_leading(Integer.to_string(us_total), 10)}  #{String.pad_leading(Float.to_string(avg), 8)}  #{String.pad_leading("#{pct}%", 8)}"
      )
    end)
  end
end

# ---------- Timing breakdown: cold vs warm ----------

IO.puts("\n\n--- Timing: cold boot + first request vs warm handle ---\n")

n = 200

IO.puts(
  "  #{String.pad_trailing("endpoint", 45)} #{String.pad_leading("cold (boot+handle)", 20)} #{String.pad_leading("warm (handle only)", 20)}"
)

IO.puts("  " <> String.duplicate("-", 87))

for {label, request} <- endpoints do
  {cold_total_us, _} =
    :timer.tc(fn ->
      for _ <- 1..n do
        {:ok, a} = Lambda.boot(blog_source, ctx: ctx)
        Lambda.handle(a, request)
      end
    end)

  cold_avg = Float.round(cold_total_us / n, 1)

  {warm_total_us, _} =
    :timer.tc(fn ->
      for _ <- 1..n, do: Lambda.handle(app, request)
    end)

  warm_avg = Float.round(warm_total_us / n, 1)

  IO.puts(
    "  #{String.pad_trailing(label, 45)} #{String.pad_leading("#{cold_avg}μs", 20)} #{String.pad_leading("#{warm_avg}μs", 20)}"
  )
end

# ---------- Warm handle at scale ----------

IO.puts("\n\n--- Warm handle (avg of 2000 calls) ---\n")

n2 = 2000

for {label, request} <- endpoints do
  {total_us, _} =
    :timer.tc(fn ->
      for _ <- 1..n2, do: Lambda.handle(app, request)
    end)

  avg_us = Float.round(total_us / n2, 1)
  ips = Float.round(1_000_000 / avg_us, 0)

  IO.puts(
    "  #{String.pad_trailing(label, 45)} #{String.pad_leading("#{avg_us}μs", 10)} (#{String.pad_leading("#{trunc(ips)}", 7)} req/s)"
  )
end

IO.puts("")
