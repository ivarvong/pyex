# CPython vs Pyex side-by-side comparison
#
# Measures the same programs through both interpreters.
# Run with: mix run bench/cpython_comparison.exs

python3 = System.find_executable("python3") || raise "python3 not found"

# ---------- Programs ----------

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
print(len(result))
"""

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
print(len(primes) + fib(15) + sum(sorted_data))
"""

# ---------- Helpers ----------

defmodule Bench do
  def collect(n, fun) do
    for _ <- 1..n do
      {us, _} = :timer.tc(fun)
      us
    end
  end

  def percentiles(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)

    %{
      avg: Float.round(Enum.sum(sorted) / n, 1),
      p50: Enum.at(sorted, div(n, 2)),
      p99: Enum.at(sorted, min(trunc(n * 0.99), n - 1))
    }
  end

  def fmt(us) when us >= 10_000, do: "#{Float.round(us / 1000, 1)} ms"
  def fmt(us) when us >= 1000, do: "#{Float.round(us / 1000, 2)} ms"
  def fmt(us), do: "#{round(us)} us"

  def row(label, samples) do
    p = percentiles(samples)

    "| #{String.pad_trailing(label, 48)} | #{String.pad_leading(fmt(p.avg), 10)} | #{String.pad_leading(fmt(p.p50), 10)} | #{String.pad_leading(fmt(p.p99), 10)} |"
  end
end

header =
  "| #{String.pad_trailing("", 48)} | #{String.pad_leading("avg", 10)} | #{String.pad_leading("p50", 10)} | #{String.pad_leading("p99", 10)} |"

sep =
  "|#{String.duplicate("-", 50)}|#{String.duplicate("-", 12)}|#{String.duplicate("-", 12)}|#{String.duplicate("-", 12)}|"

{cpython_version, 0} = System.cmd(python3, ["--version"])
cpython_version = String.trim(cpython_version)
otp = :erlang.system_info(:otp_release) |> to_string()
arch = :erlang.system_info(:system_architecture) |> to_string()

IO.puts("CPython vs Pyex -- side-by-side comparison")
IO.puts("Machine: #{arch}, OTP #{otp}, #{cpython_version}")
IO.puts("All times are wall-clock microseconds.\n")

# ---------- Warmup ----------

IO.puts("Warming up...")
for _ <- 1..20, do: Pyex.run!(fizzbuzz)
for _ <- 1..10, do: Pyex.run!(algorithms)
for _ <- 1..5, do: System.cmd(python3, ["-c", "pass"])

n_cold = 100
n_warm = 1000

# ============================================================
# COLD: python3 -c vs Pyex.run! (both from source)
# ============================================================

IO.puts("\n### Cold execution (source string in, result out)\n")
IO.puts("CPython = `python3 -c`. Pyex = `Pyex.run!`. Both include full")
IO.puts("startup/compile/execute. #{n_cold} iterations.\n")

IO.puts(header)
IO.puts(sep)

cpython_cold_fizz =
  Bench.collect(n_cold, fn ->
    System.cmd(python3, ["-c", fizzbuzz])
  end)

IO.puts(Bench.row("CPython cold: FizzBuzz", cpython_cold_fizz))

pyex_cold_fizz = Bench.collect(n_cold, fn -> Pyex.run!(fizzbuzz) end)
IO.puts(Bench.row("Pyex cold: FizzBuzz", pyex_cold_fizz))

cpython_cold_algo =
  Bench.collect(n_cold, fn ->
    System.cmd(python3, ["-c", algorithms])
  end)

IO.puts(Bench.row("CPython cold: Algorithms (~150 LOC)", cpython_cold_algo))

pyex_cold_algo = Bench.collect(n_cold, fn -> Pyex.run!(algorithms) end)
IO.puts(Bench.row("Pyex cold: Algorithms (~150 LOC)", pyex_cold_algo))

IO.puts("")

fizz_cold_ratio =
  Float.round(Bench.percentiles(cpython_cold_fizz).avg / Bench.percentiles(pyex_cold_fizz).avg, 1)

algo_cold_ratio =
  Float.round(Bench.percentiles(cpython_cold_algo).avg / Bench.percentiles(pyex_cold_algo).avg, 1)

IO.puts("Cold ratio (CPython/Pyex): FizzBuzz #{fizz_cold_ratio}x, Algorithms #{algo_cold_ratio}x")
IO.puts("(>1 = Pyex is faster, <1 = CPython is faster)")

# ============================================================
# WARM: in-process CPython vs Pyex (no startup cost)
# ============================================================

IO.puts("\n### Warm execution (no startup cost, pure computation)\n")
IO.puts("CPython = in-process via timeit. Pyex = Pyex.run! (includes lex+parse).")
IO.puts("#{n_warm} iterations.\n")

# For CPython warm measurement, we run a Python script that times internally
# and reports back microseconds
cpython_warm_script = fn code, n ->
  wrapper = """
  import time
  def run():
  #{code |> String.split("\n") |> Enum.map(&("    " <> &1)) |> Enum.join("\n")}

  # warmup
  for _ in range(50):
      run()

  times = []
  for _ in range(#{n}):
      start = time.perf_counter_ns()
      run()
      elapsed = time.perf_counter_ns() - start
      times.append(elapsed / 1000)  # to microseconds

  times.sort()
  n = len(times)
  avg = sum(times) / n
  p50 = times[n // 2]
  p99 = times[int(n * 0.99)]
  print(f"{avg:.1f} {p50:.1f} {p99:.1f}")
  """

  {output, 0} = System.cmd(python3, ["-c", wrapper])
  [avg, p50, p99] = output |> String.trim() |> String.split() |> Enum.map(&String.to_float/1)
  %{avg: avg, p50: p50, p99: p99}
end

# Wrap fizzbuzz as a function for CPython warm timing
fizzbuzz_fn = """
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
x = len(result)
"""

algorithms_fn = """
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
    left = arr[:mid]
    right = arr[mid:]
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
x = len(primes) + fib(15) + sum(sorted_data)
"""

IO.puts(header)
IO.puts(sep)

cp_warm_fizz = cpython_warm_script.(fizzbuzz_fn, n_warm)

IO.puts(
  "| #{String.pad_trailing("CPython warm: FizzBuzz", 48)} | #{String.pad_leading(Bench.fmt(cp_warm_fizz.avg), 10)} | #{String.pad_leading(Bench.fmt(cp_warm_fizz.p50), 10)} | #{String.pad_leading(Bench.fmt(cp_warm_fizz.p99), 10)} |"
)

# Pyex warm with pre-compiled AST (fairest comparison -- CPython also doesn't re-parse)
{:ok, fizz_ast} = Pyex.compile(fizzbuzz)
pyex_warm_fizz = Bench.collect(n_warm, fn -> Pyex.run!(fizz_ast) end)
IO.puts(Bench.row("Pyex warm: FizzBuzz (pre-compiled)", pyex_warm_fizz))

cp_warm_algo = cpython_warm_script.(algorithms_fn, n_warm)

IO.puts(
  "| #{String.pad_trailing("CPython warm: Algorithms (~150 LOC)", 48)} | #{String.pad_leading(Bench.fmt(cp_warm_algo.avg), 10)} | #{String.pad_leading(Bench.fmt(cp_warm_algo.p50), 10)} | #{String.pad_leading(Bench.fmt(cp_warm_algo.p99), 10)} |"
)

{:ok, algo_ast} = Pyex.compile(algorithms)
pyex_warm_algo = Bench.collect(n_warm, fn -> Pyex.run!(algo_ast) end)
IO.puts(Bench.row("Pyex warm: Algorithms (pre-compiled)", pyex_warm_algo))

IO.puts("")

pyex_fizz_p = Bench.percentiles(pyex_warm_fizz)
pyex_algo_p = Bench.percentiles(pyex_warm_algo)
fizz_warm_ratio = Float.round(pyex_fizz_p.avg / cp_warm_fizz.avg, 1)
algo_warm_ratio = Float.round(pyex_algo_p.avg / cp_warm_algo.avg, 1)
IO.puts("Warm ratio (Pyex/CPython): FizzBuzz #{fizz_warm_ratio}x, Algorithms #{algo_warm_ratio}x")
IO.puts("(how many times slower Pyex is for pure computation)")

# ============================================================
# Lambda: boot + handle
# ============================================================

IO.puts("\n### Lambda (FastAPI HTTP handlers)\n")

alias Pyex.{Ctx, Lambda}
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
            inner = frag.render(title=post["title"], date=post["date"], body=html_body)
            html = base.render(title=post["title"], content=inner)
            return HTMLResponse(html)
    return HTMLResponse("<h1>404</h1>", status_code=404)
"""

base_html = ~S"""
<!DOCTYPE html>
<html><head><title>{{ title }}</title></head>
<body>{{ content | safe }}</body></html>
"""

list_html = ~S"""
<h1>Posts</h1>
<ul>
{% for post in posts %}
<li><a href="/posts/{{ post.slug }}">{{ post.title }}</a></li>
{% endfor %}
</ul>
"""

post_html = ~S"""
<article><h1>{{ title }}</h1><p>{{ date }}</p>{{ body | safe }}</article>
"""

md =
  "# REST APIs\n\nFastAPI provides decorators for route registration.\n\n```python\n@app.get(\"/users\")\ndef list_users():\n    return []\n```\n\n## Summary\n\nRoutes, params, JSON responses.\n"

fs = Memory.new()
posts = [%{"slug" => "rest-api", "title" => "REST APIs", "date" => "2026-01-22"}]
{:ok, fs} = Memory.write(fs, "index.json", Jason.encode!(posts), :write)
{:ok, fs} = Memory.write(fs, "templates/base.html", base_html, :write)
{:ok, fs} = Memory.write(fs, "templates/list.html", list_html, :write)
{:ok, fs} = Memory.write(fs, "templates/post.html", post_html, :write)
{:ok, fs} = Memory.write(fs, "posts/rest-api.md", md, :write)
blog_ctx = Ctx.new(filesystem: fs)

# warmup
{:ok, app} = Lambda.boot(blog_source, ctx: blog_ctx)
for _ <- 1..20, do: Lambda.handle(app, %{method: "GET", path: "/posts/rest-api"})

IO.puts(header)
IO.puts(sep)

boot_samples = Bench.collect(200, fn -> Lambda.boot(blog_source, ctx: blog_ctx) end)
IO.puts(Bench.row("Cold boot (compile + execute routes)", boot_samples))

handle_list =
  Bench.collect(n_warm, fn ->
    Lambda.handle(app, %{method: "GET", path: "/posts"})
  end)

IO.puts(Bench.row("GET /posts (Jinja2 render)", handle_list))

handle_post =
  Bench.collect(n_warm, fn ->
    Lambda.handle(app, %{method: "GET", path: "/posts/rest-api"})
  end)

IO.puts(Bench.row("GET /posts/:slug (markdown + Jinja2)", handle_post))

IO.puts("")
