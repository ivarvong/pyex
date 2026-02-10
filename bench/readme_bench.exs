# Benchmark for README "How fast is it?" section
#
# Captures real percentile data across nontrivial programs.
# Run with: mix run bench/readme_bench.exs

alias Pyex.{Ctx, Lambda}
alias Pyex.Filesystem.Memory

# ---------- Programs ----------

# 1. FizzBuzz (100 iterations) -- simple loop + branching + string concat
fizzbuzz = """
result = ""
for i in range(1, 101):
    if i % 15 == 0:
        result = result + "FizzBuzz "
    elif i % 3 == 0:
        result = result + "Fizz "
    elif i % 5 == 0:
        result = result + "Buzz "
    else:
        result = result + str(i) + " "
len(result)
"""

# 2. Sieve of Eratosthenes + merge sort + memoized fibonacci + statistics
# ~150 lines, exercises: closures, dicts, list ops, recursion, math
algorithms = """
def sieve(n):
    is_prime = []
    for i in range(n + 1):
        is_prime.append(True)
    is_prime[0] = False
    is_prime[1] = False
    p = 2
    while p * p <= n:
        if is_prime[p]:
            multiple = p * p
            while multiple <= n:
                is_prime[multiple] = False
                multiple = multiple + p
        p = p + 1
    primes = []
    for i in range(n + 1):
        if is_prime[i]:
            primes.append(i)
    return primes

def factorize(n):
    factors = []
    d = 2
    while d * d <= n:
        while n % d == 0:
            factors.append(d)
            n = n // d
        d = d + 1
    if n > 1:
        factors.append(n)
    return factors

def make_fib():
    cache = {}
    def fib(n):
        if n in cache:
            return cache[n]
        if n <= 1:
            result = n
        else:
            result = fib(n - 1) + fib(n - 2)
        cache[n] = result
        return result
    return fib

def mean(nums):
    total = 0
    for x in nums:
        total = total + x
    return total / len(nums)

def variance(nums):
    m = mean(nums)
    total = 0
    for x in nums:
        diff = x - m
        total = total + diff * diff
    return total / len(nums)

def merge_sort(arr):
    if len(arr) <= 1:
        return arr
    mid = len(arr) // 2
    left = []
    right = []
    for i in range(mid):
        left.append(arr[i])
    for i in range(mid, len(arr)):
        right.append(arr[i])
    left = merge_sort(left)
    right = merge_sort(right)
    return merge(left, right)

def merge(left, right):
    result = []
    i = 0
    j = 0
    while i < len(left) and j < len(right):
        if left[i] <= right[j]:
            result.append(left[i])
            i = i + 1
        else:
            result.append(right[j])
            j = j + 1
    while i < len(left):
        result.append(left[i])
        i = i + 1
    while j < len(right):
        result.append(right[j])
        j = j + 1
    return result

primes = sieve(200)
factors_720 = factorize(720)
fib = make_fib()
fib_results = [fib(i) for i in range(20)]
sorted_data = merge_sort([64, 25, 12, 22, 11, 90, 45, 33, 78, 56])
m = mean(primes)
v = variance(primes)
result = len(primes) + fib(15) + sum(sorted_data)
"""

# 3. SSR blog app (FastAPI + Jinja2 + markdown + JSON + file I/O)
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
    return HTMLResponse(html)

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
            return HTMLResponse(html)
    return HTMLResponse("<h1>404 Not Found</h1>", status_code=404)
"""

base_html = ~S"""
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{{ title }} - Blog</title>
  <style>body{font-family:system-ui;max-width:720px;margin:0 auto;padding:2rem}article{line-height:1.6}nav{margin-bottom:2rem;border-bottom:1px solid #eee;padding-bottom:1rem}nav a{margin-right:1rem}.meta{color:#888;font-size:0.9em}footer{margin-top:3rem;border-top:1px solid #eee;padding-top:1rem;color:#888}</style>
</head>
<body>
  <nav><a href="/">Home</a><a href="/posts">Archive</a></nav>
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
  <li><a href="/posts/{{ post.slug }}">{{ post.title }}</a> <span class="meta">&mdash; {{ post.date }}</span></li>
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

## Summary

- **Decorators** register routes
- **Path params** extracted from `{name}` segments
- **Request body** via `request.json()`
"""

# ---------- Build blog filesystem ----------

fs = Memory.new()

posts = [
  %{"slug" => "getting-started", "title" => "Getting Started with Pyex", "date" => "2026-01-15"},
  %{"slug" => "rest-api", "title" => "Building a REST API", "date" => "2026-01-22"}
]

{:ok, fs} = Memory.write(fs, "index.json", Jason.encode!(posts), :write)
{:ok, fs} = Memory.write(fs, "templates/base.html", base_html, :write)
{:ok, fs} = Memory.write(fs, "templates/list.html", list_html, :write)
{:ok, fs} = Memory.write(fs, "templates/post.html", post_html, :write)
{:ok, fs} = Memory.write(fs, "posts/rest-api.md", medium_md, :write)

blog_ctx = Ctx.new(filesystem: fs, fs_module: Memory)

# ---------- Helpers ----------

defmodule Bench do
  def collect(n, fun) do
    for _ <- 1..n do
      {us, _} = :timer.tc(fun)
      us
    end
    |> Enum.sort()
  end

  def percentiles(samples) do
    n = length(samples)
    sorted = Enum.sort(samples)

    %{
      min: Enum.at(sorted, 0),
      p50: Enum.at(sorted, div(n, 2)),
      p95: Enum.at(sorted, trunc(n * 0.95)),
      p99: Enum.at(sorted, min(trunc(n * 0.99), n - 1)),
      max: Enum.at(sorted, n - 1),
      avg: Float.round(Enum.sum(sorted) / n, 1)
    }
  end

  def report(label, samples) do
    p = percentiles(samples)

    IO.puts(
      "  #{String.pad_trailing(label, 42)}" <>
        "#{String.pad_leading(fmt(p.avg), 9)}" <>
        "#{String.pad_leading(fmt(p.p50), 9)}" <>
        "#{String.pad_leading(fmt(p.p99), 9)}" <>
        "#{String.pad_leading(fmt(p.max), 9)}"
    )
  end

  def fmt(us) when us >= 1000, do: "#{Float.round(us / 1000, 2)} ms"
  def fmt(us), do: "#{round(us)} us"
end

# ---------- Warmup ----------

IO.puts("Warming up...")
for _ <- 1..50, do: Pyex.run!(fizzbuzz)
for _ <- 1..20, do: Pyex.run!(algorithms)
{:ok, blog_app} = Lambda.boot(blog_source, ctx: blog_ctx)
for _ <- 1..20, do: Lambda.handle(blog_app, %{method: "GET", path: "/posts/rest-api"})

n = 1000

IO.puts("")
IO.puts("#{n} iterations per benchmark. All times are wall-clock microseconds.")

IO.puts(
  "Machine: #{:erlang.system_info(:system_architecture) |> to_string()}, OTP #{:erlang.system_info(:otp_release)}, #{System.schedulers_online()} cores"
)

IO.puts("")

header =
  "  #{String.pad_trailing("", 42)}" <>
    "#{String.pad_leading("avg", 9)}" <>
    "#{String.pad_leading("p50", 9)}" <>
    "#{String.pad_leading("p99", 9)}" <>
    "#{String.pad_leading("max", 9)}"

# ---------- 1. End-to-end: source string in, result out ----------

IO.puts("End-to-end (source string -> result)")
IO.puts(header)
IO.puts("  " <> String.duplicate("-", 78))

fizz_samples = Bench.collect(n, fn -> Pyex.run!(fizzbuzz) end)
Bench.report("FizzBuzz (100 iterations)", fizz_samples)

algo_samples = Bench.collect(n, fn -> Pyex.run!(algorithms) end)
Bench.report("Algorithms (~150 LOC, sieve+sort+fib+stats)", algo_samples)

IO.puts("")

# ---------- 2. Compile-once, run-many ----------

IO.puts("Pre-compiled (AST cached, skip lex+parse)")
IO.puts(header)
IO.puts("  " <> String.duplicate("-", 78))

{:ok, fizz_ast} = Pyex.compile(fizzbuzz)
{:ok, algo_ast} = Pyex.compile(algorithms)

fizz_cached = Bench.collect(n, fn -> Pyex.run!(fizz_ast) end)
Bench.report("FizzBuzz (pre-compiled)", fizz_cached)

algo_cached = Bench.collect(n, fn -> Pyex.run!(algo_ast) end)
Bench.report("Algorithms (pre-compiled)", algo_cached)

IO.puts("")

# ---------- 3. Compile cost ----------

IO.puts("Compile cost (lex + parse only)")
IO.puts(header)
IO.puts("  " <> String.duplicate("-", 78))

fizz_compile = Bench.collect(n, fn -> Pyex.compile(fizzbuzz) end)
Bench.report("FizzBuzz compile", fizz_compile)

algo_compile = Bench.collect(n, fn -> Pyex.compile(algorithms) end)
Bench.report("Algorithms compile", algo_compile)

IO.puts("")

# ---------- 4. Lambda: boot + handle ----------

IO.puts("Lambda (FastAPI blog -- boot once, handle many)")
IO.puts(header)
IO.puts("  " <> String.duplicate("-", 78))

boot_samples = Bench.collect(200, fn -> Lambda.boot(blog_source, ctx: blog_ctx) end)
Bench.report("Cold boot (compile + execute routes)", boot_samples)

handle_list =
  Bench.collect(n, fn ->
    Lambda.handle(blog_app, %{method: "GET", path: "/posts"})
  end)

Bench.report("GET /posts (list, Jinja2 render)", handle_list)

handle_post =
  Bench.collect(n, fn ->
    Lambda.handle(blog_app, %{method: "GET", path: "/posts/rest-api"})
  end)

Bench.report("GET /posts/rest-api (markdown + Jinja2)", handle_post)

handle_404 =
  Bench.collect(n, fn ->
    Lambda.handle(blog_app, %{method: "GET", path: "/posts/nope"})
  end)

Bench.report("GET /posts/nope (404)", handle_404)

IO.puts("")

# ---------- 5. Context ----------

IO.puts("Notes:")

fizz_p = Bench.percentiles(fizz_samples)
fizz_cached_p = Bench.percentiles(fizz_cached)
algo_p = Bench.percentiles(algo_samples)
algo_cached_p = Bench.percentiles(algo_cached)

IO.puts(
  "  Pre-compilation saves #{round(fizz_p.avg - fizz_cached_p.avg)} us/call on FizzBuzz, #{round(algo_p.avg - algo_cached_p.avg)} us/call on Algorithms"
)

handle_post_p = Bench.percentiles(handle_post)

IO.puts(
  "  Blog post render: #{Float.round(handle_post_p.avg / 1000, 2)} ms avg (#{Float.round(handle_post_p.p99 / 1000, 2)} ms p99)"
)

IO.puts("  This is a tree-walking interpreter -- roughly 10-100x slower than CPython.")
IO.puts("  The tradeoff: no containers, no VMs, deterministic replay, serializable state.")
IO.puts("")
