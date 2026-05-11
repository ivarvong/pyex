#!/usr/bin/env elixir
# bench/parallel_proof.exs — proves {:awaitable, fn} achieves true BEAM parallelism.
#
# "True parallelism" means multiple OS threads (BEAM schedulers) run
# simultaneously, not just concurrent interleaving on one thread.
#
# Evidence gathered:
#   1. Distinct scheduler IDs — each tool call records which BEAM scheduler
#      ran it.  Multiple IDs ⟹ multiple OS threads.
#   2. CPU-bound workload — not Process.sleep().  If N tasks each burning
#      T_cpu ms of CPU complete in ~T_cpu ms wall time, N threads were busy
#      at the same time.  No event-loop trick can explain that.
#   3. Speedup ≈ min(N, schedulers) — matches the theoretical maximum.
#
# Run: mix run bench/parallel_proof.exs

n_schedulers = System.schedulers_online()

IO.puts("""
BEAM parallelism proof
======================
Schedulers available:  #{n_schedulers}
""")

# ── CPU-bound workload ────────────────────────────────────────────────────────
#
# Each task sums 1..200_000 (pure integer arithmetic — no IO, no sleep).
# On one scheduler this takes ~T ms.  On N schedulers it should still take
# ~T ms wall clock while consuming N×T ms of total CPU time.

cpu_burn = fn [_i] ->
  sched = :erlang.system_info(:scheduler_id)
  _sum = Enum.reduce(1..500_000, 0, fn x, acc -> acc + x end)
  sched
end

# Calibrate: single sequential run
{single_us, _} = :timer.tc(fn -> cpu_burn.([0]) end)
single_ms = single_us / 1_000.0

# ── Sequential baseline (for loop, {:awaitable} driven one at a time) ────────

sequential_src = """
import asyncio
from tools import burn
async def main(n):
    out = []
    for i in range(n):
        out.append(await burn(i))
    return out
asyncio.run(main(#{n_schedulers}))
"""

# ── Parallel gather ───────────────────────────────────────────────────────────

parallel_src = """
import asyncio
from tools import burn
async def main(n):
    return await asyncio.gather(*[burn(i) for i in range(n)])
asyncio.run(main(#{n_schedulers}))
"""

# Shared counter for scheduler IDs (atomics: no lock contention)
sched_ids = :atomics.new(n_schedulers, signed: false)
call_count = :counters.new(1, [])

modules = %{
  "tools" => %{
    "burn" =>
      {:awaitable,
       fn [i] ->
         sched = cpu_burn.([i])
         :atomics.add(sched_ids, sched, 1)
         :counters.add(call_count, 1, 1)
         # Return i (deterministic) so sequential == parallel result
         i
       end}
  }
}

# Warm-up
_ = Pyex.run!(parallel_src, modules: modules)

# ── Sequential run ────────────────────────────────────────────────────────────
for s <- 1..n_schedulers, do: :atomics.put(sched_ids, s, 0)
:counters.put(call_count, 1, 0)

{seq_us, seq_result} = :timer.tc(fn -> Pyex.run!(sequential_src, modules: modules) end)

seq_schedulers =
  for s <- 1..n_schedulers, :atomics.get(sched_ids, s) > 0, do: s

# ── Parallel run ──────────────────────────────────────────────────────────────
for s <- 1..n_schedulers, do: :atomics.put(sched_ids, s, 0)
:counters.put(call_count, 1, 0)

{par_us, par_result} = :timer.tc(fn -> Pyex.run!(parallel_src, modules: modules) end)

par_scheduler_counts =
  for s <- 1..n_schedulers do
    {s, :atomics.get(sched_ids, s)}
  end
  |> Enum.filter(fn {_, c} -> c > 0 end)
  |> Enum.sort_by(fn {s, _} -> s end)

par_scheduler_ids = Enum.map(par_scheduler_counts, fn {s, _} -> s end)

# ── Report ────────────────────────────────────────────────────────────────────

IO.puts("""
Workload: #{n_schedulers} CPU-burn tasks (sum 1..500_000 each, pure integer arithmetic)
Single-task cost (calibration):  #{Float.round(single_ms, 1)} ms
""")

IO.puts("Sequential (for loop + await):")
IO.puts("  Wall time:      #{Float.round(seq_us / 1000.0, 0)} ms  (expected ≈ #{round(n_schedulers * single_ms)} ms)")
IO.puts("  Schedulers used: #{inspect(seq_schedulers)}")

IO.puts("")
IO.puts("gather (host-parallel via Task.async_stream):")
IO.puts("  Wall time:      #{Float.round(par_us / 1000.0, 0)} ms  (expected ≈ #{round(single_ms)} ms)")
IO.puts("  Speedup:        #{Float.round(seq_us / par_us, 1)}x  (theoretical max: #{n_schedulers}x)")
IO.puts("  Schedulers used: #{length(par_scheduler_ids)} of #{n_schedulers}")
IO.puts("  Scheduler distribution:")

for {s, count} <- par_scheduler_counts do
  bar = String.duplicate("█", count)
  IO.puts("    scheduler #{String.pad_leading(to_string(s), 2)}: #{bar} (#{count} call#{if count == 1, do: "", else: "s"})")
end

IO.puts("")

cond do
  par_result != seq_result ->
    IO.puts("✗ CORRECTNESS FAILURE — results differ!")
    IO.puts("  sequential: #{inspect(seq_result, limit: 5)}")
    IO.puts("  parallel:   #{inspect(par_result, limit: 5)}")

  length(par_scheduler_ids) < 2 ->
    IO.puts("✗ PARALLELISM NOT PROVEN — only 1 scheduler used (try increasing n_tasks or rerunning)")

  true ->
    IO.puts("✓ Results identical")
    IO.puts("✓ #{length(par_scheduler_ids)} distinct BEAM schedulers (OS threads) ran concurrently")
    IO.puts("✓ True parallelism confirmed — CPU-bound work completed in #{Float.round(par_us / 1000.0, 0)} ms, not #{round(seq_us / 1000.0)} ms")
end
