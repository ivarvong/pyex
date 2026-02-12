# SSR Blog Benchmark with Parse/AST breakdown
#
# Shows how much time is spent in lexing/parsing vs execution
# for a real-world FastAPI blog application.
#
# Run with: mix run bench/ssr_blog_parse_bench.exs

alias Pyex.{Lexer, Parser, Ctx, Lambda}
alias Pyex.Filesystem.Memory

# ---------- Source code (same as ssr_blog_bench.exs) ----------

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
  "# Building a REST API with FastAPI\n\nFastAPI is one of the most popular Python web frameworks. In Pyex, we provide a compatible subset.\n\n## Route Registration\n\n```python\nimport fastapi\napp = fastapi.FastAPI()\n\n@app.get(\"/users/{user_id}\")\ndef get_user(user_id):\n    return {\"id\": user_id, \"name\": \"Alice\"}\n```\n\n## Request Handling\n\nHandlers receive path parameters automatically.\n\n## Response Types\n\nBy default, handlers return JSON.\n\n## Summary\n\n- **Decorators** register routes\n- **Path params** extracted from `{name}` segments\n- **Request body** via `request.json()`\n- **HTMLResponse** / **JSONResponse** for explicit response control\n"

long_md =
  "# The Complete Guide to Sandboxed Python Execution\n\n## Introduction\n\nRunning untrusted code is one of the hardest problems in software engineering. Traditional approaches use OS-level isolation.\n\nPyex takes a different approach: **interpretation**. Instead of running Python bytecode on CPython inside a sandbox, we interpret the Python AST directly in Elixir.\n\n## Architecture\n\n### The Pipeline\n\n```\nSource Code -> Lexer -> Parser -> Interpreter -> Result\n```\n\nEach stage is a pure function:\n\n- **Lexer**: NimbleParsec-based tokenizer\n- **Parser**: recursive descent, produces typed AST\n- **Interpreter**: tree-walking evaluator\n\n## The Stdlib\n\nWe don't try to support existing Python packages. Instead, we build a focused stdlib.\n\n| Module | Purpose |\n|--------|---------|\n| `json` | Parse and serialize JSON |\n| `math` | Mathematical functions |\n| `random` | Random number generation |\n| `re` | Regular expressions |\n| `time` | Time operations |\n\n## Performance\n\nFor typical LLM-generated programs (100-500 lines), Pyex executes in single-digit milliseconds. The interpreter is optimized for:\n\n1. **Fast startup** -- no VM initialization\n2. **Deterministic replay** -- event log for suspend/resume\n3. **Serializable state** -- entire interpreter state is data\n\n## Security Model\n\nPyex is designed as a capabilities-based sandbox.\n"

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

ctx = Ctx.new(filesystem: fs)

IO.puts("=" |> String.duplicate(70))
IO.puts("SSR Blog Parse/AST Benchmark")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

source_lines = length(String.split(buffered_source, "\n"))
source_bytes = byte_size(buffered_source)
IO.puts("Source: #{source_lines} lines, #{source_bytes} bytes")
IO.puts("")

# ---------- Phase 1: Lexing ----------

{lex_us, {:ok, tokens}} = :timer.tc(fn -> Lexer.tokenize(buffered_source) end)
lex_ms = Float.round(lex_us / 1000, 3)
token_count = length(tokens)

IO.puts("--- Lexing ---")
IO.puts("  Time:      #{lex_ms} ms")
IO.puts("  Tokens:    #{token_count}")
IO.puts("  Tokens/ms: #{Float.round(token_count / lex_ms, 1)}")
IO.puts("")

# ---------- Phase 2: Parsing ----------

{parse_us, {:ok, ast}} = :timer.tc(fn -> Parser.parse(tokens) end)
parse_ms = Float.round(parse_us / 1000, 3)
ast_size = :erts_debug.size(ast)

IO.puts("--- Parsing ---")
IO.puts("  Time:      #{parse_ms} ms")
IO.puts("  AST size:  #{ast_size} words")
IO.puts("")

# ---------- Phase 3: Total Parse ----------

total_parse_us = lex_us + parse_us
total_parse_ms = Float.round(total_parse_us / 1000, 3)

IO.puts("--- Total Parse (Lex + Parse) ---")
IO.puts("  Time:      #{total_parse_ms} ms")
IO.puts("")

# ---------- Phase 4: Boot (Compile + Execute to extract routes) ----------

{boot_us, {:ok, app}} = :timer.tc(fn -> Lambda.boot(buffered_source, ctx: ctx) end)
boot_ms = Float.round(boot_us / 1000, 3)
execution_us = boot_us - total_parse_us
execution_ms = Float.round(execution_us / 1000, 3)

IO.puts("--- Boot (Compile + Initial Execution) ---")
IO.puts("  Total:     #{boot_ms} ms")
IO.puts("  Parse:     #{total_parse_ms} ms (#{Float.round(total_parse_us / boot_us * 100, 1)}%)")
IO.puts("  Execute:   #{execution_ms} ms (#{Float.round(execution_us / boot_us * 100, 1)}%)")
IO.puts("")

# ---------- Phase 5: Request Handling ----------

IO.puts("--- Request Handling (post-boot) ---")

for {name, slug, size} <- [
      {"short", "getting-started", byte_size(short_md)},
      {"medium", "rest-api", byte_size(medium_md)},
      {"long", "sandboxed-execution", byte_size(long_md)}
    ] do
  {handle_us, {:ok, _resp, _}} =
    :timer.tc(fn ->
      Lambda.handle(app, %{method: "GET", path: "/posts/#{slug}"})
    end)

  handle_ms = Float.round(handle_us / 1000, 3)

  IO.puts(
    "  /posts/#{String.pad_trailing(slug, 22)} #{String.pad_leading(name, 6)} (#{size} B): #{handle_ms} ms"
  )
end

# 404
{handle_us, {:ok, _resp, _}} =
  :timer.tc(fn ->
    Lambda.handle(app, %{method: "GET", path: "/posts/nope"})
  end)

handle_ms = Float.round(handle_us / 1000, 3)
IO.puts("  /posts/#{String.pad_trailing("nope", 22)}   404: #{handle_ms} ms")

IO.puts("")

# ---------- Summary ----------

IO.puts("=" |> String.duplicate(70))
IO.puts("Summary")
IO.puts("=" |> String.duplicate(70))
IO.puts("")
IO.puts("Parse overhead on first request:")
IO.puts("  Lex:       #{lex_ms} ms")
IO.puts("  Parse:     #{parse_ms} ms")

IO.puts(
  "  Total:     #{total_parse_ms} ms (#{Float.round(total_parse_us / boot_us * 100, 1)}% of boot)"
)

IO.puts("")
IO.puts("Amortized parse cost (if caching AST):")
IO.puts("  Subsequent requests use pre-compiled AST")
IO.puts("  Savings:   #{total_parse_ms} ms per request")
IO.puts("")
