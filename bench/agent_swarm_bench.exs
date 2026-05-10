# Multi-tenant agent swarm benchmark.
#
# Runs N concurrent copies of a real-shape async research agent
# (examples/research_agent.py) in parallel BEAM Tasks.  Each tenant
# is its own Pyex run — fresh ctx, fresh heap, fresh iterator pool
# — exercising the cooperative async runtime: parallel tool calls
# via asyncio.gather, retries, async-generator streaming, async
# list comprehension.
#
# Correctness is verified by snapshot.  Tools are deterministic
# (pure functions of inputs), so every tenant receiving the same
# question MUST produce byte-identical output; if cooperative
# scheduling corrupted shared state or interleaved badly, the
# snapshot diverges and the test fails loudly.
#
# Run with:  mix run bench/agent_swarm_bench.exs

source = File.read!("examples/research_agent.py")

# ────────────────────────────────────────────────────────────────
#  Deterministic mock tools
# ────────────────────────────────────────────────────────────────
#
# These stand in for real production tools (web search, vector DB,
# scoring model, summarizer LLM).  Each is a pure function — same
# input → same output — so the agent's full output is reproducible
# across any number of concurrent tenant runs.

plan_tool = fn [question] when is_binary(question) ->
  question
  |> String.split(~r/[\s\?\.,]+/, trim: true)
  |> Enum.with_index()
  |> Enum.filter(fn {_, i} -> rem(i, 2) == 0 end)
  |> Enum.map(fn {word, i} -> "subq:#{i}:#{String.downcase(word)}" end)
  |> Enum.take(5)
end

search_tool = fn [query] when is_binary(query) ->
  seed = :erlang.phash2(query)

  Enum.map(0..2, fn i ->
    %{
      "id" => "doc-#{seed}-#{i}",
      "title" => "Result #{i} for [#{query}]",
      "snippet" => "snippet-#{seed}-#{i}"
    }
  end)
end

score_tool = fn [hit, question]
                when is_map(hit) and is_binary(question) ->
  :erlang.phash2({hit["id"], question}) / 4_294_967_296.0
end

summarize_tool = fn [hits] when is_list(hits) ->
  titles = Enum.map(hits, fn h -> h["title"] end)
  "Top picks: " <> Enum.join(titles, " | ")
end

agent_tools = %{
  "plan" => {:builtin, plan_tool},
  "search" => {:builtin, search_tool},
  "score" => {:builtin, score_tool},
  "summarize" => {:builtin, summarize_tool}
}

# ────────────────────────────────────────────────────────────────
#  Single-tenant: snapshot the canonical output
# ────────────────────────────────────────────────────────────────

run_one = fn question ->
  modules = %{
    "task" => %{"question" => question},
    "agent_tools" => agent_tools
  }

  Pyex.run!(source, modules: modules)
end

question = "How does cooperative scheduling work for BEAM-hosted Python agents?"

snapshot = run_one.(question)

IO.puts("\n=== Single-tenant snapshot ===")
IO.puts("Question:  #{question}")
IO.puts("Answer:    #{snapshot["answer"]}")
IO.puts("Chunks:    #{snapshot["n_chunks"]}")

# Determinism check: same input must produce identical output
^snapshot = run_one.(question)
IO.puts("✓ Determinism confirmed (same input → byte-identical output)")

# ────────────────────────────────────────────────────────────────
#  Tenant boot benchmark (sequential)
# ────────────────────────────────────────────────────────────────

# Warm up the persistent_term caches and JIT
for _ <- 1..20, do: run_one.(question)

boot_iters = 200

times_us =
  for _ <- 1..boot_iters do
    {us, _} = :timer.tc(fn -> run_one.(question) end)
    us
  end

sorted = Enum.sort(times_us)
n = length(sorted)
mean_us = Enum.sum(sorted) / n
p50_us = Enum.at(sorted, div(n, 2))
p99_us = Enum.at(sorted, min(n - 1, trunc(n * 0.99)))

IO.puts("\n=== Per-tenant latency (sequential, warm) ===")
IO.puts("Iterations:  #{boot_iters}")
IO.puts("Mean:        #{Float.round(mean_us / 1000.0, 2)} ms")
IO.puts("p50:         #{Float.round(p50_us / 1000.0, 2)} ms")
IO.puts("p99:         #{Float.round(p99_us / 1000.0, 2)} ms")

# ────────────────────────────────────────────────────────────────
#  Multi-tenant swarm — concurrent BEAM Tasks
# ────────────────────────────────────────────────────────────────
#
# This is the differentiator.  Pyex itself never spawns; the
# *host* (this benchmark, an Elixir application) launches one Task
# per tenant.  Each Task runs Pyex.run! independently — fresh ctx,
# isolated heap, no shared mutable state.
#
# To verify isolation we use 5 distinct questions cycled across N
# tenants and assert that every {question, output} pair matches a
# pre-computed snapshot.  If two tenants stomped on each other's
# state, we'd see crossed outputs.

questions =
  for i <- 0..4 do
    "Multi-tenant question variant #{i}: how does cooperative scheduling shape BEAM-hosted Python agent #{i}?"
  end

# Pre-compute the per-question snapshots
question_snapshots =
  for q <- questions, into: %{} do
    {q, run_one.(q)}
  end

IO.puts("\n=== Concurrent swarm (N tenants in parallel BEAM Tasks) ===")
IO.puts("Schedulers:  #{System.schedulers_online()}")
IO.puts("")

header =
  String.pad_trailing("Tenants", 12) <>
    String.pad_trailing("Total ms", 12) <>
    String.pad_trailing("Per tenant ms", 18) <>
    String.pad_trailing("Tenants/sec", 14) <>
    "Correctness"

IO.puts(header)
IO.puts(String.duplicate("─", String.length(header)))

for n <- [10, 100, 1_000, 5_000] do
  # Cycle through the 5 distinct questions
  tenant_questions =
    for i <- 0..(n - 1) do
      Enum.at(questions, rem(i, length(questions)))
    end

  {time_us, results} =
    :timer.tc(fn ->
      tenant_questions
      |> Task.async_stream(
        fn q -> {q, run_one.(q)} end,
        max_concurrency: System.schedulers_online() * 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, pair} -> pair end)
    end)

  total_ms = time_us / 1_000.0
  per_tenant_ms = total_ms / n
  throughput = n / (total_ms / 1_000.0)

  # Correctness: every tenant's output must equal the snapshot for
  # the question it received
  bad_tenants =
    Enum.count(results, fn {q, output} ->
      output != question_snapshots[q]
    end)

  correctness =
    if bad_tenants == 0,
      do: "✓ all #{n} match snapshots",
      else: "✗ #{bad_tenants} mismatches"

  IO.puts(
    String.pad_trailing("#{n}", 12) <>
      String.pad_trailing("#{Float.round(total_ms, 1)}", 12) <>
      String.pad_trailing("#{Float.round(per_tenant_ms, 3)}", 18) <>
      String.pad_trailing("#{Float.round(throughput, 0)}", 14) <>
      correctness
  )
end

# ────────────────────────────────────────────────────────────────
#  Memory per tenant
# ────────────────────────────────────────────────────────────────
#
# Capture the heap delta of holding N completed tenant ctxs in
# memory.  Approximate but useful for sizing — "how many of these
# can I keep warm in one BEAM process?"

# Use Pyex.run/2 (returns the ctx) instead of run!
run_one_with_ctx = fn question ->
  modules = %{
    "task" => %{"question" => question},
    "agent_tools" => agent_tools
  }

  {:ok, _value, ctx} = Pyex.run(source, modules: modules)
  ctx
end

:erlang.garbage_collect()
mem_before = :erlang.memory(:total)

retained_count = 1_000

ctxs =
  for i <- 1..retained_count do
    q = Enum.at(questions, rem(i, length(questions)))
    run_one_with_ctx.(q)
  end

# Force the references to stay live until the measurement
_ = length(ctxs)

mem_after = :erlang.memory(:total)
delta = mem_after - mem_before
per_tenant_kb = delta / retained_count / 1024.0

IO.puts("\n=== Memory footprint (#{retained_count} retained tenant ctxs) ===")
IO.puts("Total delta:  #{Float.round(delta / 1024.0 / 1024.0, 2)} MB")
IO.puts("Per tenant:   #{Float.round(per_tenant_kb, 1)} KB")

# Keep the list reachable through the measurement
_ = ctxs

IO.puts("\n=== Done ===")
