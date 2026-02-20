# Peak Memory Benchmark
#
# Measures peak memory usage during sustained load without GC interference
#
# Run with: mix run bench/peak_memory.exs

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

IO.puts(String.duplicate("=", 70))
IO.puts("Peak Memory Benchmark")
IO.puts(String.duplicate("=", 70))
IO.puts("")

# ---------- Measure without GC ----------

IO.puts("--- Single Request (no GC) ---")
IO.puts("")

# Run once to warm up
ctx = make_ctx.(payment_body, sign.(payment_body))
{:ok, _, _} = Pyex.run(handler_source, ctx)

# Now measure with explicit before/after
:erlang.garbage_collect()
Process.sleep(50)

before_mem = :erlang.memory()

ctx = make_ctx.(payment_body, sign.(payment_body))
{:ok, result, final_ctx} = Pyex.run(handler_source, ctx)

after_mem = :erlang.memory()

delta = %{
  total: after_mem[:total] - before_mem[:total],
  processes: after_mem[:processes] - before_mem[:processes],
  binary: after_mem[:binary] - before_mem[:binary]
}

IO.puts("Memory delta per request:")
IO.puts("  Total:     #{Float.round(delta[:total] / 1024, 2)} KB")
IO.puts("  Processes: #{Float.round(delta[:processes] / 1024, 2)} KB")
IO.puts("  Binary:    #{Float.round(delta[:binary] / 1024, 2)} KB")
IO.puts("")

# Context analysis
ctx_external = :erlang.external_size(final_ctx)
IO.puts("Context analysis:")
IO.puts("  External size: #{Float.round(ctx_external / 1024, 3)} KB")
IO.puts("")

# ---------- Burst test ----------

IO.puts("--- Burst Test (100 requests, no GC) ---")
IO.puts("")

:erlang.garbage_collect()
Process.sleep(50)

start_mem = :erlang.memory()

# Run 100 requests without GC
for _ <- 1..100 do
  ctx = make_ctx.(payment_body, sign.(payment_body))
  {:ok, _, _} = Pyex.run(handler_source, ctx)
end

peak_mem = :erlang.memory()

# Calculate delta
burst_delta = %{
  total: peak_mem[:total] - start_mem[:total],
  processes: peak_mem[:processes] - start_mem[:processes],
  binary: peak_mem[:binary] - start_mem[:binary]
}

IO.puts("Peak memory after 100 requests (no GC):")
IO.puts("  Total:     #{Float.round(burst_delta[:total] / 1024, 2)} KB")
IO.puts("  Processes: #{Float.round(burst_delta[:processes] / 1024, 2)} KB")
IO.puts("  Binary:    #{Float.round(burst_delta[:binary] / 1024, 2)} KB")
IO.puts("  Per request: #{Float.round(burst_delta[:total] / 100, 2)} bytes")
IO.puts("")

# Now GC and see what's retained
:erlang.garbage_collect()
Process.sleep(50)

after_gc_mem = :erlang.memory()

retained = %{
  total: after_gc_mem[:total] - start_mem[:total],
  processes: after_gc_mem[:processes] - start_mem[:processes],
  binary: after_gc_mem[:binary] - start_mem[:binary]
}

IO.puts("Retained after GC:")
IO.puts("  Total:     #{Float.round(retained[:total] / 1024, 2)} KB")
IO.puts("  Processes: #{Float.round(retained[:processes] / 1024, 2)} KB")
IO.puts("  Binary:    #{Float.round(retained[:binary] / 1024, 2)} KB")
IO.puts("  Per request: #{Float.round(retained[:total] / 100, 2)} bytes")
IO.puts("")

# ---------- 10k/sec simulation ----------

IO.puts("--- 10k/sec Simulation ---")
IO.puts("")

# Simulate 4 concurrent requests (what 10k/sec @ 400μs looks like)
:erlang.garbage_collect()
Process.sleep(50)

start_10k = :erlang.memory()

# Spawn 4 processes, each doing requests
tasks =
  for _ <- 1..4 do
    Task.async(fn ->
      for _ <- 1..100 do
        ctx = make_ctx.(payment_body, sign.(payment_body))
        {:ok, _, _} = Pyex.run(handler_source, ctx)
      end

      :ok
    end)
  end

Enum.each(tasks, &Task.await(&1, 30000))

peak_10k = :erlang.memory()

concurrent_delta = %{
  total: peak_10k[:total] - start_10k[:total],
  processes: peak_10k[:processes] - start_10k[:processes],
  binary: peak_10k[:binary] - start_10k[:binary]
}

IO.puts("Peak memory (4 concurrent × 100 requests):")
IO.puts("  Total:     #{Float.round(concurrent_delta[:total] / 1024, 2)} KB")
IO.puts("  Processes: #{Float.round(concurrent_delta[:processes] / 1024, 2)} KB")
IO.puts("  Binary:    #{Float.round(concurrent_delta[:binary] / 1024, 2)} KB")
IO.puts("  Per request: #{Float.round(concurrent_delta[:total] / 400, 2)} bytes")
IO.puts("")

:erlang.garbage_collect()
Process.sleep(50)

after_10k_gc = :erlang.memory()

retained_10k = %{
  total: after_10k_gc[:total] - start_10k[:total],
  processes: after_10k_gc[:processes] - start_10k[:processes],
  binary: after_10k_gc[:binary] - start_10k[:binary]
}

IO.puts("Retained after GC:")
IO.puts("  Total:     #{Float.round(retained_10k[:total] / 1024, 2)} KB")
IO.puts("  Per request: #{Float.round(retained_10k[:total] / 400, 2)} bytes")
IO.puts("")

# ---------- Summary ----------

IO.puts("--- Summary for 10k req/sec ---")
IO.puts("")

# Conservative estimate: use burst test numbers
mem_per_request = burst_delta[:total]
concurrent_requests = 4

working_set = concurrent_requests * mem_per_request

IO.puts("Memory per request: #{Float.round(mem_per_request / 1024, 2)} KB")
IO.puts("Concurrent requests: #{concurrent_requests}")
IO.puts("Working set: #{Float.round(working_set / 1024, 2)} KB")
IO.puts("")

allocation_rate = mem_per_request * 10000
IO.puts("Allocation rate @ 10k/sec:")
IO.puts("  #{Float.round(allocation_rate / 1024 / 1024, 2)} MB/sec")
IO.puts("  #{Float.round(allocation_rate * 60 / 1024 / 1024, 2)} MB/min")
IO.puts("")

IO.puts("Recommended memory:")
IO.puts("  Working set: #{Float.round(working_set / 1024, 2)} KB")
IO.puts("  + GC overhead (2x): #{Float.round(working_set * 2 / 1024, 2)} KB")
IO.puts("  + BEAM overhead: 512 MB")
IO.puts("  = Total: #{Float.round(working_set * 3 / 1024 / 1024 + 512, 0)} MB")
IO.puts("")

IO.puts(String.duplicate("=", 70))
