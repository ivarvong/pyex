# SSR Blog Benchmark -- streaming vs non-streaming
#
# Head-to-head comparison of the same blog served two ways:
#   1. Non-streaming: full Jinja2 base template render -> HTMLResponse
#   2. Streaming: yield head immediately -> compute content -> yield body -> yield footer
#
# Run with: mix run bench/ssr_blog_bench.exs

alias Pyex.{Ctx, Lambda}
alias Pyex.Filesystem.Memory

# ---------- Non-streaming source (original) ----------

buffered_source = ~S"""
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

# ---------- Streaming source ----------

streaming_source = ~S"""
import fastapi
import json
import markdown
from fastapi import HTMLResponse, StreamingResponse
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

head_html = read_file("templates/head.html")
foot_html = read_file("templates/foot.html")

@app.get("/posts")
def list_posts():
    def generate():
        yield head_html.replace("{{ title }}", "Archive")
        frag = load_template("templates/list.html")
        index = load_index()
        yield frag.render(posts=index)
        yield foot_html
    return StreamingResponse(
        generate(),
        headers={"content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=60"}
    )

@app.get("/posts/{slug}")
def get_post(slug):
    index = load_index()
    for post in index:
        if post["slug"] == slug:
            title = post["title"]
            def generate():
                yield head_html.replace("{{ title }}", title)
                frag = load_template("templates/post.html")
                md_source = read_file("posts/" + slug + ".md")
                html_body = markdown.markdown(md_source)
                rt = estimate_reading_time(md_source)
                yield frag.render(
                    title=title,
                    date=post["date"],
                    reading_time=rt,
                    body=html_body
                )
                yield foot_html
            return StreamingResponse(
                generate(),
                headers={"content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=60"}
            )
    return HTMLResponse("<h1>404 Not Found</h1>", status_code=404)
"""

# ---------- Template files ----------

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

head_html = ~S"""
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
"""

foot_html = ~S"""
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

# ---------- Markdown content ----------

short_md =
  "# Getting Started with Pyex\n\nPyex is a Python 3 interpreter written in Elixir.\n\n## Quick Start\n\n```python\nresult = Pyex.run!(\"2 + 2\")\n```\n\nThat's it. No setup, no dependencies, no escape.\n"

medium_md =
  "# Building a REST API with FastAPI\n\nFastAPI is one of the most popular Python web frameworks. In Pyex, we provide a compatible subset.\n\n## Route Registration\n\n```python\nimport fastapi\napp = fastapi.FastAPI()\n\n@app.get(\"/users/{user_id}\")\ndef get_user(user_id):\n    return {\"id\": user_id, \"name\": \"Alice\"}\n```\n\n## Request Handling\n\nHandlers receive path parameters automatically.\n\n```python\n@app.post(\"/users\")\ndef create_user(request):\n    data = request.json()\n    return {\"created\": data[\"name\"]}\n```\n\n## Response Types\n\nBy default, handlers return JSON. For HTML responses, use `HTMLResponse`.\n\n```python\nfrom fastapi import HTMLResponse\n@app.get(\"/page\")\ndef page():\n    return HTMLResponse(\"<h1>Hello World</h1>\")\n```\n\n## Path Parameters\n\nPath parameters are coerced to integers when possible:\n\n| Path | Parameter | Type |\n|------|-----------|------|\n| `/users/42` | `user_id=42` | `int` |\n| `/users/alice` | `name=\"alice\"` | `str` |\n\n## Summary\n\n- **Decorators** register routes\n- **Path params** extracted from `{name}` segments\n- **Request body** via `request.json()`\n- **HTMLResponse** / **JSONResponse** for explicit response control\n"

long_md =
  "# The Complete Guide to Sandboxed Python Execution\n\n## Introduction\n\nRunning untrusted code is one of the hardest problems in software engineering. Traditional approaches use OS-level isolation: containers, VMs, seccomp-bpf, or WebAssembly.\n\nPyex takes a different approach: **interpretation**. Instead of running Python bytecode on CPython inside a sandbox, we interpret the Python AST directly in Elixir. This gives us:\n\n1. **Total control** over every operation\n2. **No escape** -- there's no native code to exploit\n3. **Deterministic replay** via the Ctx event log\n4. **Serializable state** -- the entire interpreter state is data\n\n## Architecture\n\n### The Pipeline\n\n```\nSource Code -> Lexer -> Parser -> Interpreter -> Result\n```\n\nEach stage is a pure function (modulo the Ctx for I/O):\n\n- **Lexer** (`Pyex.Lexer`): NimbleParsec-based tokenizer\n- **Parser** (`Pyex.Parser`): recursive descent, produces typed AST\n- **Interpreter** (`Pyex.Interpreter`): tree-walking evaluator\n\n### The Context\n\nThe `Pyex.Ctx` struct carries all mutable state:\n\n- **Event log**: every side effect is recorded\n- **Filesystem**: pluggable backends (Memory, Local, S3)\n- **Handles**: open file descriptors\n- **Compute budget**: timeout enforcement\n- **Mode**: `:live`, `:replay`, or `:noop`\n\n### Environment Model\n\nVariables live in a scope stack. Each function call pushes a new scope; closures capture the environment at definition time.\n\n```python\ndef make_counter(start):\n    count = start\n    def increment():\n        nonlocal count\n        count += 1\n        return count\n    return increment\n\nc = make_counter(10)\nc()  # 11\nc()  # 12\n```\n\n## The Stdlib\n\nWe don't try to support existing Python packages. Instead, we build a focused stdlib.\n\n| Module | Purpose |\n|--------|---------|\n| `json` | Parse and serialize JSON |\n| `math` | Mathematical functions |\n| `random` | Random number generation |\n| `re` | Regular expressions |\n| `time` | Sleep, timestamps |\n| `datetime` | Date/time operations |\n| `collections` | Counter, defaultdict |\n| `csv` | CSV reading and writing |\n| `html` | HTML escaping |\n| `markdown` | Markdown to HTML |\n| `jinja2` | Template rendering |\n| `uuid` | UUID generation |\n| `fastapi` | HTTP route registration |\n| `requests` | HTTP client |\n\n## Security Model\n\n### Compute Limits\n\nEvery operation increments a nanosecond counter. The Ctx enforces a configurable timeout.\n\n### Filesystem Isolation\n\nThe filesystem is a behaviour with three implementations:\n\n- **Memory**: pure map, fully serializable, zero I/O\n- **Local**: sandboxed directory with path traversal protection\n- **S3**: remote storage via signed requests\n\nPrograms can only access files through the configured backend.\n\n### No Process Spawning\n\nThe interpreter is single-threaded by design.\n\n## Performance Characteristics\n\nThe tree-walking interpreter is roughly 100-1000x slower than CPython, depending on the workload. For LLM sandbox use cases, this is fine.\n\n## Conclusion\n\nPyex is not a general-purpose Python runtime. It's a sandboxed computation engine designed for one job: letting LLMs write and execute Python safely, with full observability and deterministic replay.\n"

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
{:ok, fs} = Memory.write(fs, "templates/head.html", head_html, :write)
{:ok, fs} = Memory.write(fs, "templates/foot.html", foot_html, :write)
{:ok, fs} = Memory.write(fs, "templates/list.html", list_html, :write)
{:ok, fs} = Memory.write(fs, "templates/post.html", post_html, :write)
{:ok, fs} = Memory.write(fs, "posts/getting-started.md", short_md, :write)
{:ok, fs} = Memory.write(fs, "posts/rest-api.md", medium_md, :write)
{:ok, fs} = Memory.write(fs, "posts/sandboxed-execution.md", long_md, :write)

ctx = Ctx.new(filesystem: fs)

IO.puts("=" |> String.duplicate(70))
IO.puts("SSR Blog Benchmark -- streaming vs buffered")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

IO.puts(
  "Content: short (#{byte_size(short_md)} B), medium (#{byte_size(medium_md)} B), long (#{byte_size(long_md)} B)"
)

IO.puts("")

# ---------- Boot both ----------

{buf_us, {:ok, buf_app}} = :timer.tc(fn -> Lambda.boot(buffered_source, ctx: ctx) end)
{str_us, {:ok, str_app}} = :timer.tc(fn -> Lambda.boot(streaming_source, ctx: ctx) end)

IO.puts(
  "Boot: buffered #{Float.round(buf_us / 1000, 2)} ms | streaming #{Float.round(str_us / 1000, 2)} ms"
)

IO.puts("")

# ---------- Verify both produce same content ----------

IO.puts("--- Verification ---")

for slug <- ~w(getting-started rest-api sandboxed-execution) do
  {:ok, buf_resp, _} = Lambda.handle(buf_app, %{method: "GET", path: "/posts/#{slug}"})
  {:ok, str_resp, _} = Lambda.handle_stream(str_app, %{method: "GET", path: "/posts/#{slug}"})
  str_body = Enum.join(str_resp.chunks)

  match =
    if buf_resp.body == str_body,
      do: "OK",
      else: "MISMATCH (buf=#{byte_size(buf_resp.body)} str=#{byte_size(str_body)})"

  IO.puts("  /posts/#{String.pad_trailing(slug, 22)} #{match}")
end

IO.puts("")

# ---------- Benchee: head-to-head ----------

IO.puts("--- Benchmark: buffered (handle) vs streaming (handle_stream + consume) ---")
IO.puts("")

Benchee.run(
  %{
    "list    | buffered" => fn -> Lambda.handle(buf_app, %{method: "GET", path: "/posts"}) end,
    "list    | stream" => fn ->
      {:ok, r, _} = Lambda.handle_stream(str_app, %{method: "GET", path: "/posts"})
      Enum.to_list(r.chunks)
    end,
    "short   | buffered" => fn ->
      Lambda.handle(buf_app, %{method: "GET", path: "/posts/getting-started"})
    end,
    "short   | stream" => fn ->
      {:ok, r, _} =
        Lambda.handle_stream(str_app, %{method: "GET", path: "/posts/getting-started"})

      Enum.to_list(r.chunks)
    end,
    "medium  | buffered" => fn ->
      Lambda.handle(buf_app, %{method: "GET", path: "/posts/rest-api"})
    end,
    "medium  | stream" => fn ->
      {:ok, r, _} = Lambda.handle_stream(str_app, %{method: "GET", path: "/posts/rest-api"})
      Enum.to_list(r.chunks)
    end,
    "long    | buffered" => fn ->
      Lambda.handle(buf_app, %{method: "GET", path: "/posts/sandboxed-execution"})
    end,
    "long    | stream" => fn ->
      {:ok, r, _} =
        Lambda.handle_stream(str_app, %{method: "GET", path: "/posts/sandboxed-execution"})

      Enum.to_list(r.chunks)
    end,
    "404     | buffered" => fn ->
      Lambda.handle(buf_app, %{method: "GET", path: "/posts/nope"})
    end,
    "404     | stream" => fn ->
      {:ok, r, _} = Lambda.handle_stream(str_app, %{method: "GET", path: "/posts/nope"})
      Enum.to_list(r.chunks)
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  print: [configuration: false]
)
