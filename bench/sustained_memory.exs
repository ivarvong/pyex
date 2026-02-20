# Sustained Memory Benchmark
#
# Measures total memory usage over sustained load to find leaks
# and actual working set size.
#
# Run with: mix run bench/sustained_memory.exs

alias Pyex.Ctx

# ---------- Python source ----------

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


def handle_payment_succeeded(event):
    pi = event["data"]["object"]
    return {
        "action": "payment_recorded",
        "amount": pi.get("amount", 0),
        "currency": pi.get("currency", "usd"),
        "customer": pi.get("customer", "unknown"),
    }


EVENT_HANDLERS = {
    "payment_intent.succeeded": handle_payment_succeeded,
}

if not verify_signature(payload, sig_header, endpoint_secret):
    result = {"error": "Invalid signature", "status": 400}
else:
    event = json.loads(payload)
    event_type = event.get("type", "")
    handler = EVENT_HANDLERS.get(event_type)
    if handler:
        result = {"received": True, "result": handler(event), "status": 200}
    else:
        result = {"received": True, "unhandled": event_type, "status": 200}
"""

# ---------- Build test payload ----------

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
    "data" => %{
      "object" => %{
        "id" => "pi_abc123",
        "amount" => 2999,
        "currency" => "usd",
        "customer" => "cus_xyz789",
        "status" => "succeeded"
      }
    }
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
IO.puts("Sustained Memory Benchmark - Compile→Eval Pipeline")
IO.puts(String.duplicate("=", 70))
IO.puts("")

# ---------- Single request memory measurement ----------

IO.puts("--- Single Request Memory Breakdown ---")
IO.puts("")

# Force clean state
:erlang.garbage_collect()
Process.sleep(100)

# Measure baseline
baseline = :erlang.memory()

# Compile phase
:erlang.garbage_collect()
before_compile = :erlang.memory()
{:ok, ast} = Pyex.compile(handler_source)
:erlang.garbage_collect()
after_compile = :erlang.memory()

compile_delta = %{
  total: after_compile[:total] - before_compile[:total],
  processes: after_compile[:processes] - before_compile[:processes],
  binary: after_compile[:binary] - before_compile[:binary]
}

# Eval phase
ctx = make_ctx.(payment_body, sign.(payment_body))
:erlang.garbage_collect()
before_eval = :erlang.memory()
{:ok, _result, final_ctx} = Pyex.run(ast, ctx)
:erlang.garbage_collect()
after_eval = :erlang.memory()

eval_delta = %{
  total: after_eval[:total] - before_eval[:total],
  processes: after_eval[:processes] - before_eval[:processes],
  binary: after_eval[:binary] - before_eval[:binary]
}

# Total pipeline
:erlang.garbage_collect()
before_total = :erlang.memory()
ctx = make_ctx.(payment_body, sign.(payment_body))
{:ok, _result, _} = Pyex.run(handler_source, ctx)
:erlang.garbage_collect()
after_total = :erlang.memory()

total_delta = %{
  total: after_total[:total] - before_total[:total],
  processes: after_total[:processes] - before_total[:processes],
  binary: after_total[:binary] - before_total[:binary]
}

IO.puts("Compile phase (lex + parse + AST):")

IO.puts(
  "  Total:     #{String.pad_leading("#{Float.round(compile_delta[:total] / 1024, 2)} KB", 10)}"
)

IO.puts(
  "  Processes: #{String.pad_leading("#{Float.round(compile_delta[:processes] / 1024, 2)} KB", 10)}"
)

IO.puts(
  "  Binary:    #{String.pad_leading("#{Float.round(compile_delta[:binary] / 1024, 2)} KB", 10)}"
)

IO.puts("")

IO.puts("Eval phase (AST → result):")

IO.puts(
  "  Total:     #{String.pad_leading("#{Float.round(eval_delta[:total] / 1024, 2)} KB", 10)}"
)

IO.puts(
  "  Processes: #{String.pad_leading("#{Float.round(eval_delta[:processes] / 1024, 2)} KB", 10)}"
)

IO.puts(
  "  Binary:    #{String.pad_leading("#{Float.round(eval_delta[:binary] / 1024, 2)} KB", 10)}"
)

IO.puts("")

IO.puts("Total pipeline (compile + eval):")

IO.puts(
  "  Total:     #{String.pad_leading("#{Float.round(total_delta[:total] / 1024, 2)} KB", 10)}"
)

IO.puts(
  "  Processes: #{String.pad_leading("#{Float.round(total_delta[:processes] / 1024, 2)} KB", 10)}"
)

IO.puts(
  "  Binary:    #{String.pad_leading("#{Float.round(total_delta[:binary] / 1024, 2)} KB", 10)}"
)

IO.puts("")

# Context size
ctx_size = :erlang.external_size(final_ctx)
IO.puts("Final context external size: #{Float.round(ctx_size / 1024, 3)} KB")
IO.puts("")

# ---------- Sustained load test ----------

IO.puts("--- Sustained Load Test ---")
IO.puts("")

# Run 10k requests and measure memory at intervals
intervals = [100, 500, 1000, 2000, 5000, 10000]

# Force clean slate
:erlang.garbage_collect()
Process.sleep(100)
start_mem = :erlang.memory()

IO.puts("Running 10,000 requests...")
IO.puts("")

IO.puts(
  "  #{String.pad_leading("requests", 10)} #{String.pad_leading("total Δ", 12)} #{String.pad_leading("proc Δ", 12)} #{String.pad_leading("binary Δ", 12)} #{String.pad_leading("per req", 10)}"
)

IO.puts("  " <> String.duplicate("-", 62))

results =
  Enum.reduce(1..10000, [], fn i, acc ->
    ctx = make_ctx.(payment_body, sign.(payment_body))
    {:ok, _, _} = Pyex.run(handler_source, ctx)

    if i in intervals do
      :erlang.garbage_collect()
      current = :erlang.memory()

      delta_total = current[:total] - start_mem[:total]
      delta_proc = current[:processes] - start_mem[:processes]
      delta_bin = current[:binary] - start_mem[:binary]
      per_req = delta_total / i

      IO.puts(
        "  #{String.pad_leading(Integer.to_string(i), 10)} #{String.pad_leading("#{Float.round(delta_total / 1024, 1)} KB", 12)} #{String.pad_leading("#{Float.round(delta_proc / 1024, 1)} KB", 12)} #{String.pad_leading("#{Float.round(delta_bin / 1024, 1)} KB", 12)} #{String.pad_leading("#{Float.round(per_req, 1)} B", 10)}"
      )

      [{i, delta_total, per_req} | acc]
    else
      acc
    end
  end)

# Final measurement
:erlang.garbage_collect()
Process.sleep(100)
final_mem = :erlang.memory()

final_delta = final_mem[:total] - start_mem[:total]
avg_per_req = final_delta / 10000

IO.puts("")
IO.puts("Final after 10,000 requests:")
IO.puts("  Total increase: #{Float.round(final_delta / 1024, 2)} KB")
IO.puts("  Average per request: #{Float.round(avg_per_req, 2)} bytes")
IO.puts("")

# ---------- Memory leak detection ----------

IO.puts("--- Memory Leak Detection ---")
IO.puts("")

# Check if memory growth is linear or if it plateaus
[{_, first_delta, _} | _] = Enum.reverse(results)

if final_delta > first_delta * 10 do
  IO.puts("WARNING: Possible memory leak detected!")
  IO.puts("  First interval delta: #{Float.round(first_delta / 1024, 2)} KB")
  IO.puts("  Final delta: #{Float.round(final_delta / 1024, 2)} KB")
  IO.puts("  Growth ratio: #{Float.round(final_delta / first_delta, 1)}x")
else
  IO.puts("OK: No significant memory leak detected")
  IO.puts("  Memory appears to be reclaimed by GC")
  IO.puts("  Growth ratio: #{Float.round(final_delta / first_delta, 1)}x")
end

IO.puts("")

# ---------- 10k/sec projection ----------

IO.puts("--- Production @ 10k req/sec Projection ---")
IO.puts("")

req_rate = 10000
latency_us = 400
concurrent = req_rate * (latency_us / 1_000_000)

IO.puts("Parameters:")
IO.puts("  Request rate: #{req_rate} req/sec")
IO.puts("  Latency: #{latency_us} μs")
IO.puts("  Concurrent requests: #{Float.round(concurrent, 1)}")
IO.puts("")

# Use the measured per-request allocation
measured_per_req = avg_per_req

IO.puts("Memory allocation rate:")
IO.puts("  Per request: #{Float.round(measured_per_req, 2)} bytes")
IO.puts("  Per second: #{Float.round(measured_per_req * req_rate / 1024 / 1024, 2)} MB/sec")
IO.puts("  Per minute: #{Float.round(measured_per_req * req_rate * 60 / 1024 / 1024, 2)} MB/min")
IO.puts("")

# Working set (memory that must be held during concurrent processing)
# This is the memory that can't be GC'd while requests are in flight
working_set = concurrent * total_delta[:total]

IO.puts("Working set (concurrent × per-request):")
IO.puts("  #{Float.round(working_set / 1024 / 1024, 2)} MB")
IO.puts("")

IO.puts("Recommended memory (3x working set + overhead):")
IO.puts("  Minimum: #{Float.round(working_set * 3 / 1024 / 1024 + 512, 0)} MB")
IO.puts("")

IO.puts(String.duplicate("=", 70))
