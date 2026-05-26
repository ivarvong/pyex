# ReLU net training-loop benchmark.
#
# Runs `test/fixtures/programs/relu_net_learns_sin/main.py` — a complete
# tree-walking interpreter test of the shape that defines every neural-net
# trainer: tight indexed reads (slopes[j], biases[j], activations[j]) in
# nested loops, module-level reads of math / range / zip / sum / max from
# inside the hot loop, augmented assignment into per-parameter gradient
# accumulators, sequenced math.sin / math.sqrt / ** operations.
#
# 1000 epochs × 100 samples × 8 hidden units ≈ 8M sequenced float ops with
# no library to hide behind.  The fixture test asserts byte-identical match
# with CPython; this bench measures how long that's taking.
#
# Run with:  mix run bench/relu_net_bench.exs

source = File.read!("test/fixtures/programs/relu_net_learns_sin/main.py")
{:ok, ast} = Pyex.compile(source)

# Disable the compute deadline so a slow CI box doesn't time out mid-bench.
opts = [limits: [timeout: :infinity]]

# ── Phase breakdown for a single run ────────────────────────────────

IO.puts(String.duplicate("=", 70))
IO.puts("ReLU net training — phase breakdown (single run)")
IO.puts(String.duplicate("=", 70))

{compile_us, {:ok, _}} = :timer.tc(fn -> Pyex.compile(source) end)
{cold_us, {:ok, _, _}} = :timer.tc(fn -> Pyex.run(source, opts) end)
{warm_us, {:ok, _, _}} = :timer.tc(fn -> Pyex.run(ast, opts) end)

IO.puts("  compile (lex+parse): #{Float.round(compile_us / 1000, 2)} ms")
IO.puts("  cold (source → result):            #{Float.round(cold_us / 1000, 2)} ms")
IO.puts("  warm (AST → result):               #{Float.round(warm_us / 1000, 2)} ms")
IO.puts("")

# ── Sequential timing over multiple warm iterations ────────────────

for _ <- 1..3, do: Pyex.run!(ast, opts)

iters = 5
samples_us =
  for _ <- 1..iters do
    {us, {:ok, _, _}} = :timer.tc(fn -> Pyex.run(ast, opts) end)
    us
  end

sorted = Enum.sort(samples_us)
mean = Enum.sum(samples_us) / iters
min_us = Enum.at(sorted, 0)
p50 = Enum.at(sorted, div(iters, 2))
max_us = Enum.at(sorted, iters - 1)

# Pull the training-loop dimensions back out of the script so the
# per-epoch / per-sample-pass numbers don't drift if someone tunes
# N_EPOCHS later.
[_, n_epochs_str] = Regex.run(~r/N_EPOCHS\s*=\s*(\d+)/, source)
[_, n_samples_str] = Regex.run(~r/N_SAMPLES\s*=\s*(\d+)/, source)
[_, n_hidden_str] = Regex.run(~r/N_HIDDEN\s*=\s*(\d+)/, source)
n_epochs = String.to_integer(n_epochs_str)
n_samples = String.to_integer(n_samples_str)
n_hidden = String.to_integer(n_hidden_str)

IO.puts(String.duplicate("=", 70))
IO.puts("Sequential timing (#{iters} warm iterations)")
IO.puts(String.duplicate("=", 70))
IO.puts("  mean: #{Float.round(mean / 1000, 2)} ms")
IO.puts("  min:  #{Float.round(min_us / 1000, 2)} ms")
IO.puts("  p50:  #{Float.round(p50 / 1000, 2)} ms")
IO.puts("  max:  #{Float.round(max_us / 1000, 2)} ms")
IO.puts("")
IO.puts("  per epoch (mean):              #{Float.round(mean / n_epochs, 2)} µs")
IO.puts("  per (epoch × sample) (mean):   #{Float.round(mean / n_epochs / n_samples, 3)} µs")
IO.puts("")

total_unit_evals = n_epochs * n_samples * n_hidden
IO.puts("  Training shape: #{n_epochs} epochs × #{n_samples} samples × #{n_hidden} hidden units")

IO.puts(
  "                  = #{total_unit_evals} unit-evaluations per run " <>
    "(#{Float.round(total_unit_evals / mean, 2)} µs/eval)"
)
IO.puts("")

# ── Parallel timing — independent training runs on separate cores ──

parallel_n = 4

{par_us, par_results} =
  :timer.tc(fn ->
    1..parallel_n
    |> Task.async_stream(
      fn _ -> Pyex.run!(ast, opts) end,
      max_concurrency: parallel_n,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, r} -> r end)
  end)

parallel_n = length(par_results)

IO.puts(String.duplicate("=", 70))
IO.puts("Parallel timing (#{parallel_n} concurrent training runs)")
IO.puts(String.duplicate("=", 70))
IO.puts("  wall: #{Float.round(par_us / 1000, 2)} ms")

IO.puts(
  "  speedup over sequential: " <>
    "#{Float.round(mean * parallel_n / par_us, 2)}× (ideal = #{parallel_n}×)"
)

IO.puts("")
IO.puts(String.duplicate("=", 70))
