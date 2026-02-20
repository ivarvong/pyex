# Stripe Webhook Handler Memory Analysis
#
# Analyzes memory usage patterns and identifies optimization opportunities.
#
# Run with: mix run bench/stripe_webhook_memory.exs

alias Pyex.Ctx

# ---------- Python source: realistic Stripe webhook handler ----------

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

# ---------- Build test payloads ----------

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
IO.puts("Stripe Webhook Handler Memory Analysis")
IO.puts(String.duplicate("=", 70))
IO.puts("")

# ---------- Baseline memory ----------

:erlang.garbage_collect()
baseline = :erlang.memory()

IO.puts("Baseline BEAM memory:")
IO.puts("  total:      #{Float.round(baseline[:total] / 1024 / 1024, 2)} MB")
IO.puts("  processes:  #{Float.round(baseline[:processes] / 1024 / 1024, 2)} MB")
IO.puts("  binary:     #{Float.round(baseline[:binary] / 1024 / 1024, 2)} MB")
IO.puts("  ets:        #{Float.round(baseline[:ets] / 1024 / 1024, 2)} MB")
IO.puts("")

# ---------- Single request memory ----------

ctx = make_ctx.(payment_body, sign.(payment_body))
:erlang.garbage_collect()
before = :erlang.memory()

{:ok, _result, final_ctx} = Pyex.run(handler_source, ctx)

:erlang.garbage_collect()
after_mem = :erlang.memory()

single_delta = %{
  total: after_mem[:total] - before[:total],
  processes: after_mem[:processes] - before[:processes],
  binary: after_mem[:binary] - before[:binary]
}

IO.puts("Single request memory delta:")
IO.puts("  total:      #{Float.round(single_delta[:total] / 1024, 2)} KB")
IO.puts("  processes:  #{Float.round(single_delta[:processes] / 1024, 2)} KB")
IO.puts("  binary:     #{Float.round(single_delta[:binary] / 1024, 2)} KB")
IO.puts("")

# Context size analysis
ctx_external = :erlang.external_size(final_ctx)
IO.puts("Final context external size: #{Float.round(ctx_external / 1024, 2)} KB")
IO.puts("")

# ---------- Compilation vs Runtime memory ----------

IO.puts("--- Compilation vs Runtime breakdown ---")
IO.puts("")

:erlang.garbage_collect()
before_compile = :erlang.memory()

{:ok, ast} = Pyex.compile(handler_source)

:erlang.garbage_collect()
after_compile = :erlang.memory()

compile_delta = after_compile[:total] - before_compile[:total]

IO.puts("Compilation memory (lex+parse+AST):")
IO.puts("  total: #{Float.round(compile_delta / 1024, 2)} KB")
IO.puts("  AST external size: #{Float.round(:erlang.external_size(ast) / 1024, 2)} KB")
IO.puts("")

:erlang.garbage_collect()
before_run = :erlang.memory()

ctx = make_ctx.(payment_body, sign.(payment_body))
{:ok, _, _} = Pyex.run(handler_source, ctx)

:erlang.garbage_collect()
after_run = :erlang.memory()

run_delta = after_run[:total] - before_run[:total]

IO.puts("Runtime memory (with compilation):")
IO.puts("  total: #{Float.round(run_delta / 1024, 2)} KB")
IO.puts("")

IO.puts(
  "Compilation is #{Float.round(compile_delta / run_delta * 100, 1)}% of total runtime memory"
)

IO.puts("")

# ---------- Scaled memory test ----------

IO.puts("--- Scaled memory test (1000 requests) ---")
IO.puts("")

:erlang.garbage_collect()
before_scaled = :erlang.memory()

for i <- 1..1000 do
  ctx = make_ctx.(payment_body, sign.(payment_body))
  {:ok, _, _} = Pyex.run(handler_source, ctx)

  if rem(i, 200) == 0 do
    :erlang.garbage_collect()
    current = :erlang.memory()
    delta = current[:total] - before_scaled[:total]
    per_req = delta / i

    IO.puts(
      "  #{String.pad_leading(Integer.to_string(i), 4)} req: +#{String.pad_leading("#{Float.round(delta / 1024, 1)}", 8)} KB total, #{String.pad_leading("#{Float.round(per_req, 1)}", 6)} bytes/req"
    )
  end
end

:erlang.garbage_collect()
after_scaled = :erlang.memory()

scaled_delta = after_scaled[:total] - before_scaled[:total]

IO.puts("")
IO.puts("Final after 1000 requests:")
IO.puts("  total increase: #{Float.round(scaled_delta / 1024, 2)} KB")
IO.puts("  per request:    #{Float.round(scaled_delta / 1000, 2)} bytes")
IO.puts("")

# ---------- Binary leak check ----------

IO.puts("--- Binary memory analysis ---")
IO.puts("")

# Force GC and check binary memory
:erlang.garbage_collect()
binary_before = :erlang.memory(:binary)

# Run batch
for _ <- 1..500 do
  ctx = make_ctx.(payment_body, sign.(payment_body))
  {:ok, _, _} = Pyex.run(handler_source, ctx)
end

:erlang.garbage_collect()
binary_after = :erlang.memory(:binary)

IO.puts("Binary memory delta after 500 requests:")
IO.puts("  before: #{Float.round(binary_before / 1024, 2)} KB")
IO.puts("  after:  #{Float.round(binary_after / 1024, 2)} KB")
IO.puts("  delta:  #{Float.round((binary_after - binary_before) / 1024, 2)} KB")
IO.puts("")

# ---------- 10k/sec projection ----------

IO.puts("--- Production projection @ 10k req/sec ---")
IO.puts("")

req_per_sec = 10000
# from benchmark
avg_latency_us = 400
concurrent_reqs = req_per_sec * (avg_latency_us / 1_000_000)

# Using the higher memory estimate from Benchee (1.9 MB)
# bytes
benchee_mem_per_req = 1.9 * 1024 * 1024

# Using our measured delta
measured_mem_per_req = single_delta[:total]

IO.puts("Concurrency model:")
IO.puts("  Request rate:     #{req_per_sec} req/sec")
IO.puts("  Avg latency:      #{avg_latency_us} μs")
IO.puts("  Concurrent reqs:  #{Float.round(concurrent_reqs, 0)}")
IO.puts("")

IO.puts("Memory requirements:")
IO.puts("  Per request (Benchee):   #{Float.round(benchee_mem_per_req / 1024, 2)} KB")
IO.puts("  Per request (measured):  #{Float.round(measured_mem_per_req / 1024, 2)} KB")
IO.puts("")

benchee_working_set = concurrent_reqs * benchee_mem_per_req
measured_working_set = concurrent_reqs * measured_mem_per_req

IO.puts("Working set (concurrent × per-request):")
IO.puts("  Using Benchee:   #{Float.round(benchee_working_set / 1024 / 1024, 2)} MB")
IO.puts("  Using measured:  #{Float.round(measured_working_set / 1024 / 1024, 2)} MB")
IO.puts("")

IO.puts("Recommended memory (2x working set + overhead):")
IO.puts("  Minimum: #{Float.round(benchee_working_set * 2 / 1024 / 1024 + 2048, 0)} MB")
IO.puts("")

# ---------- Optimization recommendations ----------

IO.puts("--- Optimization Opportunities ---")
IO.puts("")

IO.puts("1. AST Caching (HIGH IMPACT)")
IO.puts("   Current: Re-parse #{byte_size(handler_source)} bytes on every request")
IO.puts("   Savings: ~#{Float.round(compile_delta / 1024, 1)} KB per request")
IO.puts("   Implementation: Compile once, store in ETS or persistent_term")
IO.puts("")

IO.puts("2. Context Reuse (MEDIUM IMPACT)")
IO.puts("   Current: Fresh Ctx struct per request")
IO.puts("   Savings: ~#{Float.round(ctx_external / 2 / 1024, 1)} KB per request")
IO.puts("   Implementation: Pool contexts, reset state between uses")
IO.puts("")

IO.puts("3. Binary Substring Optimization (LOW IMPACT)")
IO.puts("   Current: String.split creates sub-binaries")
IO.puts("   Risk: Large payload binaries retained via sub-binary refs")
IO.puts("   Implementation: Use :binary.copy/1 for extracted strings")
IO.puts("")

IO.puts("4. HMAC Result Caching (WORKLOAD DEPENDENT)")
IO.puts("   Current: HMAC computed on every request")
IO.puts("   Savings: Only if same payloads seen repeatedly")
IO.puts("   Implementation: ETS cache with TTL")
IO.puts("")

IO.puts("5. Module Preloading (LOW IMPACT)")
IO.puts("   Current: hmac, json modules loaded per request")
IO.puts("   Savings: Small reduction in module resolution")
IO.puts("   Implementation: Pre-populate imported_modules in Ctx")
IO.puts("")

IO.puts(String.duplicate("=", 70))
