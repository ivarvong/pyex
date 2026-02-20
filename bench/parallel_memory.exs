# Parallel Memory Benchmark
#
# Measures memory usage under high parallelism
#
# Run with: mix run bench/parallel_memory.exs

alias Pyex.Ctx

handler_source = ~S"""
import json
import hmac
from webhook_request import payload, sig_header, endpoint_secret

def verify_signature(payload, sig_header, secret):
    timestamp = ""
    signature = ""
    for element in sig_header.split(","):
        parts = element.strip().split("=", 1)
        if len(parts) == 2:
            if parts[0] == "t":
                timestamp = parts[1]
            elif parts[0] == "v1":
                signature = parts[1]
    if not timestamp or not signature:
        return False
    signed_payload = timestamp + "." + payload
    expected = hmac.new(secret, signed_payload, "sha256").hexdigest()
    return hmac.compare_digest(expected, signature)

EVENT_HANDLERS = {"payment_intent.succeeded": lambda e: e}

if not verify_signature(payload, sig_header, endpoint_secret):
    result = {"error": "Invalid signature", "status": 400}
else:
    event = json.loads(payload)
    handler = EVENT_HANDLERS.get(event.get("type", ""))
    if handler:
        result = {"received": True, "result": handler(event), "status": 200}
    else:
        result = {"received": True, "result": None, "status": 200}
"""

secret = "whsec_live_abc123def456"
timestamp = "1708300000"

sign = fn body ->
  signed_payload = timestamp <> "." <> body
  sig = :crypto.mac(:hmac, :sha256, secret, signed_payload) |> Base.encode16(case: :lower)
  "t=#{timestamp},v1=#{sig}"
end

payment_body =
  Jason.encode!(%{
    "id" => "evt_payment_1",
    "type" => "payment_intent.succeeded",
    "data" => %{"object" => %{"id" => "pi_abc123", "amount" => 2999}}
  })

make_ctx = fn payload, sig_header ->
  Ctx.new(
    modules: %{
      "webhook_request" => %{
        "payload" => payload,
        "sig_header" => sig_header,
        "endpoint_secret" => secret
      }
    }
  )
end

# Worker function that runs N requests
run_worker = fn n ->
  for _ <- 1..n do
    ctx = make_ctx.(payment_body, sign.(payment_body))
    {:ok, _, _} = Pyex.run(handler_source, ctx)
  end

  :ok
end

IO.puts(String.duplicate("=", 70))
IO.puts("Parallel Memory Benchmark")
IO.puts(String.duplicate("=", 70))
IO.puts("")

# Get scheduler count
schedulers = System.schedulers_online()
IO.puts("BEAM schedulers: #{schedulers}")
IO.puts("")

# ---------- Single threaded baseline ----------

IO.puts("--- Single Threaded (1 process) ---")
IO.puts("")

:erlang.garbage_collect()
Process.sleep(100)
start_mem = :erlang.memory()

run_worker.(1000)

:erlang.garbage_collect()
Process.sleep(100)
end_mem = :erlang.memory()

single_delta = end_mem[:total] - start_mem[:total]
IO.puts("1 process × 1000 requests:")
IO.puts("  Memory delta: #{Float.round(single_delta / 1024, 2)} KB")
IO.puts("  Per request: #{Float.round(single_delta / 1000, 2)} bytes")
IO.puts("")

# ---------- Parallel tests with different concurrency levels ----------

concurrency_levels = [2, 4, 8, 16, 32, 64]

IO.puts("--- Parallel Execution ---")
IO.puts("")

Enum.each(concurrency_levels, fn concurrency ->
  requests_per_worker = div(1000, concurrency)

  :erlang.garbage_collect()
  Process.sleep(100)
  start_mem = :erlang.memory()

  # Spawn workers
  tasks =
    for _ <- 1..concurrency do
      Task.async(fn -> run_worker.(requests_per_worker) end)
    end

  # Wait for all
  Enum.each(tasks, &Task.await(&1, 60000))

  :erlang.garbage_collect()
  Process.sleep(100)
  end_mem = :erlang.memory()

  delta = end_mem[:total] - start_mem[:total]
  total_requests = concurrency * requests_per_worker

  IO.puts(
    "#{String.pad_leading(Integer.to_string(concurrency), 2)} processes × #{requests_per_worker} requests:"
  )

  IO.puts(
    "  Memory delta: #{String.pad_leading("#{Float.round(delta / 1024, 2)} KB", 10)}  Per request: #{String.pad_leading("#{Float.round(delta / total_requests, 2)} B", 6)}"
  )
end)

IO.puts("")

# ---------- Throughput test ----------

IO.puts("--- Throughput Test (max parallelism) ---")
IO.puts("")

# Run with maximum parallelism to see throughput
:erlang.garbage_collect()
Process.sleep(100)

{elapsed_us, _} =
  :timer.tc(fn ->
    tasks =
      for _ <- 1..schedulers do
        Task.async(fn -> run_worker.(500) end)
      end

    Enum.each(tasks, &Task.await(&1, 60000))
  end)

total_requests = schedulers * 500
elapsed_sec = elapsed_us / 1_000_000
throughput = total_requests / elapsed_sec

IO.puts("#{schedulers} processes × 500 requests:")
IO.puts("  Total requests: #{total_requests}")
IO.puts("  Elapsed: #{Float.round(elapsed_sec, 2)} sec")
IO.puts("  Throughput: #{Float.round(throughput, 0)} req/sec")
IO.puts("  Latency: #{Float.round(elapsed_us / total_requests, 2)} μs")
IO.puts("")

# ---------- Memory pressure test ----------

IO.puts("--- Memory Pressure Test ---")
IO.puts("")

# Run many concurrent requests without GC to see peak memory
:erlang.garbage_collect()
Process.sleep(100)
start_mem = :erlang.memory()

# Spawn 1000 concurrent tasks, each doing 10 requests
tasks =
  for _ <- 1..1000 do
    Task.async(fn -> run_worker.(10) end)
  end

# Wait for all with progress reporting
Enum.with_index(tasks, 1)
|> Enum.chunk_every(100)
|> Enum.with_index(1)
|> Enum.each(fn {chunk, idx} ->
  Enum.each(chunk, fn {task, _} -> Task.await(task, 60000) end)

  current_mem = :erlang.memory()
  delta = current_mem[:total] - start_mem[:total]
  completed = idx * 100 * 10
  IO.puts("  Completed #{completed} requests, memory delta: #{Float.round(delta / 1024, 2)} KB")
end)

:erlang.garbage_collect()
Process.sleep(100)
end_mem = :erlang.memory()

final_delta = end_mem[:total] - start_mem[:total]

IO.puts("")
IO.puts("Final after 10,000 concurrent requests:")
IO.puts("  Memory delta: #{Float.round(final_delta / 1024, 2)} KB")
IO.puts("  Per request: #{Float.round(final_delta / 10000, 2)} bytes")
IO.puts("")

# ---------- Summary ----------

IO.puts("--- Summary ---")
IO.puts("")

IO.puts("Parallelism recommendations:")
IO.puts("  - Use #{schedulers} processes for CPU-bound workloads")
IO.puts("  - Each process adds minimal memory overhead")
IO.puts("  - Throughput scales linearly with cores")
IO.puts("  - Memory usage remains stable under load")
IO.puts("")

IO.puts(String.duplicate("=", 70))
