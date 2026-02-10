# Multi-tenant SaaS Scaling Analysis
#
# Models 100,000 customers each with their own Python code.
# Measures memory footprint and proposes architecture.
#
# Run with: mix run bench/multitenant_scaling_bench.exs

alias Pyex.{Lexer, Parser, Ctx, Lambda}
alias Pyex.Filesystem.Memory

# ---------- Sample tenant programs of varying complexity ----------

# Tiny: Simple API endpoint (~10 lines)
tiny_source = """
import fastapi
app = fastapi.FastAPI()

@app.get("/")
def home():
    return {"message": "Hello"}
"""

# Small: Blog post listing (~30 lines)
small_source = """
import fastapi
import json
from fastapi import HTMLResponse

app = fastapi.FastAPI()

def load_data():
    return json.loads('{"posts": [{"title": "A"}, {"title": "B"}]}')

@app.get("/")
def home():
    data = load_data()
    return HTMLResponse(f"<h1>{len(data['posts'])} posts</h1>")

@app.get("/api/posts")
def api_posts():
    return load_data()
"""

# Medium: The SSR blog from earlier (~60 lines)
medium_source = ~S"""
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
    index = load_index()
    html = base.render(title="Archive", content=str(len(index)) + " posts")
    return HTMLResponse(html)

@app.get("/posts/{slug}")
def get_post(slug):
    index = load_index()
    for post in index:
        if post["slug"] == slug:
            return HTMLResponse("<h1>" + post["title"] + "</h1>")
    return HTMLResponse("<h1>404</h1>", status_code=404)
"""

# Large: Complex app with many routes (~150 lines)
large_source = """
import fastapi
import json
import re
from fastapi import HTMLResponse, JSONResponse

app = fastapi.FastAPI()

# Config
config = {"items_per_page": 10, "max_items": 1000}

def validate_email(email):
    return re.match(r"^[\w\.-]+@[\w\.-]+\.\w+$", email) is not None

def load_users():
    return [{"id": 1, "name": "Alice", "email": "alice@example.com"},
            {"id": 2, "name": "Bob", "email": "bob@example.com"}]

def load_items():
    items = []
    for i in range(20):
        items.append({"id": i, "name": f"Item {i}", "price": i * 10})
    return items

@app.get("/")
def home():
    return HTMLResponse("<h1>Welcome</h1>")

@app.get("/api/users")
def list_users():
    return JSONResponse(load_users())

@app.get("/api/users/{user_id}")
def get_user(user_id):
    users = load_users()
    for u in users:
        if u["id"] == user_id:
            return JSONResponse(u)
    return JSONResponse({"error": "Not found"}, status_code=404)

@app.post("/api/users")
def create_user(request):
    data = request.json()
    if not validate_email(data.get("email", "")):
        return JSONResponse({"error": "Invalid email"}, status_code=400)
    return JSONResponse({"id": 3, "name": data["name"]}, status_code=201)

@app.get("/api/items")
def list_items():
    items = load_items()
    return JSONResponse({"items": items[:config["items_per_page"]]})

@app.get("/api/items/{item_id}")
def get_item(item_id):
    items = load_items()
    for item in items:
        if item["id"] == item_id:
            return JSONResponse(item)
    return JSONResponse({"error": "Not found"}, status_code=404)

@app.get("/api/search")
def search(q):
    if not q:
        return JSONResponse({"results": []})
    items = load_items()
    results = []
    for item in items:
        if q.lower() in item["name"].lower():
            results.append(item)
    return JSONResponse({"results": results})

@app.get("/health")
def health():
    return JSONResponse({"status": "ok", "version": "1.0.0"})
"""

IO.puts("=" |> String.duplicate(70))
IO.puts("Multi-tenant SaaS Scaling Analysis")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# ---------- Measure each tier ----------

tiers = [
  %{"name" => "tiny", "lines" => 10, "source" => tiny_source},
  %{"name" => "small", "lines" => 30, "source" => small_source},
  %{"name" => "medium", "lines" => 60, "source" => medium_source},
  %{"name" => "large", "lines" => 150, "source" => large_source}
]

results =
  for tier <- tiers do
    source = tier["source"]

    # Tokenize
    {lex_us, {:ok, tokens}} = :timer.tc(fn -> Lexer.tokenize(source) end)

    # Parse
    {parse_us, {:ok, ast}} = :timer.tc(fn -> Parser.parse(tokens) end)

    # Measure memory
    ast_size_words = :erts_debug.size(ast)
    # 64-bit words
    ast_size_bytes = ast_size_words * 8

    # Full boot (includes filesystem setup)
    fs = Memory.new()
    ctx = Ctx.new(filesystem: fs, fs_module: Memory)
    {boot_us, {:ok, app}} = :timer.tc(fn -> Lambda.boot(source, ctx: ctx) end)

    # Measure app size (AST + env + routes)
    app_size_words = :erts_debug.size(app)
    app_size_bytes = app_size_words * 8

    # Request time (hot)
    {req_us, _} =
      :timer.tc(fn ->
        Lambda.handle(app, %{method: "GET", path: "/"})
      end)

    total_parse_us = lex_us + parse_us

    %{
      name: tier["name"],
      lines: tier["lines"],
      tokens: length(tokens),
      lex_ms: lex_us / 1000,
      parse_ms: parse_us / 1000,
      total_parse_ms: total_parse_us / 1000,
      boot_ms: boot_us / 1000,
      exec_ms: (boot_us - total_parse_us) / 1000,
      hot_req_ms: req_us / 1000,
      ast_bytes: ast_size_bytes,
      app_bytes: app_size_bytes
    }
  end

# ---------- Print per-tier results ----------

IO.puts("Per-Tenant Memory & Timing:")
IO.puts("")

for r <- results do
  IO.puts("#{String.upcase(r.name)} (#{r.lines} lines, #{r.tokens} tokens):")

  IO.puts(
    "  Cold parse:    #{Float.round(r.total_parse_ms, 2)} ms (lex #{Float.round(r.lex_ms, 2)} + parse #{Float.round(r.parse_ms, 2)})"
  )

  IO.puts(
    "  Cold boot:     #{Float.round(r.boot_ms, 2)} ms total (#{Float.round(r.exec_ms, 2)} ms exec)"
  )

  IO.puts("  Hot request:   #{Float.round(r.hot_req_ms, 2)} ms")
  IO.puts("  AST memory:    #{Float.round(r.ast_bytes / 1024, 1)} KB")
  IO.puts("  App memory:    #{Float.round(r.app_bytes / 1024, 1)} KB")
  IO.puts("")
end

# ---------- Scale to 100k tenants ----------

IO.puts("=" |> String.duplicate(70))
IO.puts("Scaling to 100,000 Tenants")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Assume distribution: 50% tiny, 30% small, 15% medium, 5% large
distribution = [
  {0.50, Enum.find(results, &(&1.name == "tiny"))},
  {0.30, Enum.find(results, &(&1.name == "small"))},
  {0.15, Enum.find(results, &(&1.name == "medium"))},
  {0.05, Enum.find(results, &(&1.name == "large"))}
]

# Calculate weighted averages
weighted_ast_kb = Enum.sum(for {pct, r} <- distribution, do: pct * r.ast_bytes / 1024)
weighted_app_kb = Enum.sum(for {pct, r} <- distribution, do: pct * r.app_bytes / 1024)
weighted_parse_ms = Enum.sum(for {pct, r} <- distribution, do: pct * r.total_parse_ms)
weighted_boot_ms = Enum.sum(for {pct, r} <- distribution, do: pct * r.boot_ms)
weighted_hot_ms = Enum.sum(for {pct, r} <- distribution, do: pct * r.hot_req_ms)

IO.puts("Assumed distribution: 50% tiny, 30% small, 15% medium, 5% large")
IO.puts("")

# Scenario 1: Keep all apps hot in memory
all_hot_memory_gb = weighted_app_kb * 100_000 / 1024 / 1024
IO.puts("SCENARIO 1: All 100k tenants hot in memory")
IO.puts("  Memory needed: #{Float.round(all_hot_memory_gb, 1)} GB")
IO.puts("  Avg cold boot:  #{Float.round(weighted_boot_ms, 2)} ms per tenant")
IO.puts("  Avg hot req:   #{Float.round(weighted_hot_ms, 2)} ms")
IO.puts("  This is #{if all_hot_memory_gb > 64, do: "NOT ", else: ""}feasible on a single node")
IO.puts("")

# Scenario 2: LRU cache with 10k hot, rest cold
lru_size = 10_000
cold_tenants = 100_000 - lru_size
lru_memory_gb = weighted_app_kb * lru_size / 1024 / 1024
IO.puts("SCENARIO 2: LRU cache (10k hot, 90k cold)")
IO.puts("  Hot memory:    #{Float.round(lru_memory_gb, 1)} GB (#{lru_size} tenants)")

IO.puts(
  "  Cold tenants:  #{cold_tenants} (pay #{Float.round(weighted_boot_ms, 0)}ms parse+exec on access)"
)

IO.puts("  This is feasible but cold requests are slow")
IO.puts("")

# Scenario 3: Compile-on-demand, no caching
IO.puts("SCENARIO 3: No caching (compile every request)")
IO.puts("  Memory:        Minimal (just request-scoped)")

IO.puts(
  "  Per-request:   #{Float.round(weighted_parse_ms + weighted_hot_ms, 2)} ms (parse + exec)"
)

IO.puts(
  "  Throughput:    ~#{Float.round(1000 / (weighted_parse_ms + weighted_hot_ms), 0)} req/sec per core"
)

IO.puts("  This is too slow for production")
IO.puts("")

# Scenario 4: Tiered - keep AST only, not full app state
IO.puts("SCENARIO 4: Cache AST only (not full app state)")
ast_only_memory_gb = weighted_ast_kb * 100_000 / 1024 / 1024
IO.puts("  AST memory:    #{Float.round(ast_only_memory_gb, 1)} GB (100k tenants)")
IO.puts("  Per-request:   #{Float.round(weighted_hot_ms, 2)} ms (just exec, no parse)")
IO.puts("  Throughput:    ~#{Float.round(1000 / weighted_hot_ms, 0)} req/sec per core")

IO.puts(
  "  This is #{if ast_only_memory_gb < 32, do: "feasible", else: "challenging"} on a single node"
)

IO.puts("")

# ---------- Phoenix integration considerations ----------

IO.puts("=" |> String.duplicate(70))
IO.puts("Phoenix Integration Challenges")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

IO.puts("Current Lambda.handle_stream spawns a linked process per request.")
IO.puts("At 100k tenants with burst traffic, this would:")
IO.puts("  - Create process spawn overhead (~1-5ms)")
IO.puts("  - Risk process table exhaustion under load")
IO.puts("  - Make observability harder (many short-lived processes)")
IO.puts("")

IO.puts("Recommended Architecture:")

IO.puts("""
  1. Tenant Isolation:
     - Each tenant gets a unique identifier (tenant_id)
     - Code stored in S3/DB, loaded on first request
  
  2. Caching Strategy:
     - Global LRU cache: tenant_id -> {ast, compiled_routes}
     - Cache size: 50k-100k tenants (20-40GB RAM)
     - TTL: 1 hour idle eviction
  
  3. Request Path:
     - Check cache for tenant_id
     - Cache hit: Lambda.handle_with_ast(ast, routes, request)
     - Cache miss: compile -> cache -> handle
  
  4. Stateless Execution:
     - No persistent app state between requests (use DB)
     - Fresh Ctx per request (filesystem from S3)
     - This eliminates the need for process spawning
  
  5. Clustering:
     - Each Phoenix node has local LRU cache
     - Compile-on-demand at each node
     - No distributed state needed
""")

IO.puts("")

# ---------- Performance targets ----------

IO.puts("=" |> String.duplicate(70))
IO.puts("Realistic Targets")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

IO.puts("With AST caching (no process spawn):")
target_throughput = Float.round(1000 / weighted_hot_ms)
IO.puts("  - Single core: ~#{target_throughput} req/sec")
IO.puts("  - 16-core node: ~#{target_throughput * 16} req/sec")
IO.puts("  - p99 latency: ~#{Float.round(weighted_hot_ms * 2, 1)} ms")
IO.puts("")

IO.puts("With cold compile (cache miss):")
cold_throughput = Float.round(1000 / (weighted_parse_ms + weighted_hot_ms))
IO.puts("  - Single core: ~#{cold_throughput} req/sec")
IO.puts("  - This should be <1% of requests with good cache hit rate")
IO.puts("")

IO.puts("Memory budget per node (64GB RAM):")
IO.puts("  - AST cache: ~40GB (50k tenants)")
IO.puts("  - Phoenix/BEAM: ~8GB")
IO.puts("  - Buffer/OS: ~16GB")
IO.puts("")

IO.puts("To serve 100k active tenants:")
nodes_needed = Float.ceil(100_000 / 50_000)
IO.puts("  - Need ~#{trunc(nodes_needed)} nodes with 64GB RAM each")
IO.puts("  - Or use Redis for AST cache, nodes stateless")
IO.puts("")
