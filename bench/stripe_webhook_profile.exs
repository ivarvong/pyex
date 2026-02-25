# Stripe Webhook Handler Profiling
#
# Profiles the webhook handler to identify performance bottlenecks.
#
# Run with: mix run bench/stripe_webhook_profile.exs

alias Pyex.{Ctx, Interpreter, Lambda}

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


def handle_subscription_created(event):
    sub = event["data"]["object"]
    plan = sub.get("plan", {})
    return {
        "action": "subscription_provisioned",
        "subscription_id": sub.get("id", ""),
        "plan": plan.get("id", "unknown"),
    }


def handle_invoice_paid(event):
    inv = event["data"]["object"]
    return {
        "action": "invoice_recorded",
        "invoice_id": inv.get("id", ""),
        "total": inv.get("total", 0),
        "customer": inv.get("customer", "unknown"),
        "line_count": len(inv.get("lines", [])),
    }


def handle_charge_refunded(event):
    charge = event["data"]["object"]
    return {
        "action": "refund_processed",
        "charge_id": charge.get("id", ""),
        "amount_refunded": charge.get("amount_refunded", 0),
    }


def handle_customer_updated(event):
    cust = event["data"]["object"]
    return {
        "action": "customer_synced",
        "customer_id": cust.get("id", ""),
        "email": cust.get("email", ""),
        "name": cust.get("name", ""),
    }


EVENT_HANDLERS = {
    "payment_intent.succeeded": handle_payment_succeeded,
    "customer.subscription.created": handle_subscription_created,
    "invoice.paid": handle_invoice_paid,
    "charge.refunded": handle_charge_refunded,
    "customer.updated": handle_customer_updated,
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

# ---------- Build test payloads with valid HMAC signatures ----------

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
        "status" => "succeeded",
        "payment_method" => "pm_card_visa"
      }
    }
  })

invoice_body =
  Jason.encode!(%{
    "id" => "evt_inv_1",
    "type" => "invoice.paid",
    "data" => %{
      "object" => %{
        "id" => "in_abc123",
        "customer" => "cus_xyz789",
        "total" => 4999,
        "currency" => "usd",
        "status" => "paid",
        "lines" => [
          %{"id" => "li_1", "amount" => 4999, "description" => "Pro plan"},
          %{"id" => "li_2", "amount" => 0, "description" => "Free trial credit"}
        ]
      }
    }
  })

invalid_body = ~s({"id":"evt_bad","type":"test"})

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
IO.puts("Stripe Webhook Handler Profiling")
IO.puts(String.duplicate("=", 70))
IO.puts("")

# ---------- Profile with interpreter profiling ----------

IO.puts("--- Profiling: payment_intent.succeeded ---")
IO.puts("")

profile_ctx = make_ctx.(payment_body, sign.(payment_body))
profile_ctx = %{profile_ctx | profile: %{line_counts: %{}, call_counts: %{}, call: %{}}}

{us, {:ok, result, ctx_with_profile}} =
  :timer.tc(fn ->
    Pyex.run(handler_source, profile_ctx)
  end)

profile = ctx_with_profile.profile

total_calls = Enum.sum(Map.values(profile.call_counts))
total_func_ms = Enum.sum(Map.values(profile.call))
total_func_us = total_func_ms * 1000
total_lines = Enum.sum(Map.values(profile.line_counts))

IO.puts("Wall time: #{Float.round(us / 1000, 2)} ms")

IO.puts(
  "Lines executed: #{total_lines} | Function calls: #{total_calls} | In-function time: #{total_func_us}μs"
)

IO.puts("")

if map_size(profile.call_counts) > 0 do
  IO.puts(
    "  #{String.pad_trailing("function", 30)} #{String.pad_leading("calls", 6)}  #{String.pad_leading("total μs", 10)}  #{String.pad_leading("avg μs", 8)}  #{String.pad_leading("% time", 8)}"
  )

  IO.puts("  " <> String.duplicate("-", 68))

  profile.call_counts
  |> Enum.sort_by(fn {name, _} -> -Map.get(profile.call, name, 0) * 1000 end)
  |> Enum.each(fn {name, count} ->
    ms_total = Map.get(profile.call, name, 0)
    us_total = ms_total * 1000
    avg = if count > 0, do: Float.round(us_total / count, 1), else: 0.0
    pct = if total_func_us > 0, do: Float.round(us_total / total_func_us * 100, 1), else: 0.0

    IO.puts(
      "  #{String.pad_trailing(name, 30)} #{String.pad_leading(Integer.to_string(count), 6)}  #{String.pad_leading(Float.to_string(us_total), 10)}  #{String.pad_leading(Float.to_string(avg), 8)}  #{String.pad_leading("#{pct}%", 8)}"
    )
  end)
end

IO.puts("")

# ---------- Call counting with :cprof ----------

IO.puts("--- Call counting (cprof) ---")
IO.puts("")

# Use cprof to count function calls
:cprof.start()

# Run the handler
ctx = make_ctx.(payment_body, sign.(payment_body))
{:ok, _, _} = Pyex.run(handler_source, ctx)

call_counts = :cprof.analyse()
:cprof.stop()

# Sort by count and show top 30
sorted_calls =
  call_counts
  |> Enum.sort_by(fn {_, _, count} -> -count end)
  |> Enum.take(30)

IO.puts("Top 30 most called functions:")

IO.puts(
  "  #{String.pad_trailing("module", 25)} #{String.pad_trailing("function", 25)} #{String.pad_leading("count", 10)}"
)

IO.puts("  " <> String.duplicate("-", 65))

Enum.each(sorted_calls, fn {mod, fun, count} ->
  mod_str = String.pad_trailing(inspect(mod), 25)
  fun_str = String.pad_trailing(to_string(fun), 25)
  IO.puts("  #{mod_str} #{fun_str} #{String.pad_leading(Integer.to_string(count), 10)}")
end)

IO.puts("")

# Run fprof on a single execution
:ok = :fprof.trace([:start, {:file, '/tmp/fprof.trace'}, {:procs, :all}])

# Run the handler
ctx = make_ctx.(payment_body, sign.(payment_body))
{:ok, _, _} = Pyex.run(handler_source, ctx)

:ok = :fprof.trace(:stop)
:ok = :fprof.profile({:file, '/tmp/fprof.trace'})

# Print top 20 functions by time
IO.puts("Top functions by accumulated time:")
:ok = :fprof.analyse([{:dest, '/tmp/fprof.analysis'}, {:cols, 120}])

# Parse and display the analysis
analysis = File.read!("/tmp/fprof.analysis")

# Extract and display the top functions
lines = String.split(analysis, "\n")

# Find the section with function times
in_function_section = fn line ->
  String.contains?(line, "FUNCTION") and String.contains?(line, "CNT")
end

# Print header
IO.puts(
  "  #{String.pad_trailing("function", 50)} #{String.pad_leading("cnt", 8)} #{String.pad_leading("acc", 12)} #{String.pad_leading("own", 12)}"
)

IO.puts("  " <> String.duplicate("-", 86))

# Extract top functions (skip header lines)
function_lines =
  lines
  |> Enum.drop_while(&(not in_function_section.(&1)))
  |> Enum.drop(2)
  |> Enum.take(20)

Enum.each(function_lines, fn line ->
  # Parse fprof output format
  parts = String.split(line, ~r/\s+/, trim: true)

  if length(parts) >= 4 do
    [cnt, acc, own | func_parts] = parts
    func_name = Enum.join(func_parts, " ")

    if String.length(func_name) > 0 do
      IO.puts(
        "  #{String.pad_trailing(func_name, 50)} #{String.pad_leading(cnt, 8)} #{String.pad_leading(acc, 12)} #{String.pad_leading(own, 12)}"
      )
    end
  end
end)

IO.puts("")

# ---------- Memory profiling ----------

IO.puts("--- Memory analysis ---")
IO.puts("")

# Detailed memory breakdown
:erlang.garbage_collect()
initial = :erlang.memory()

IO.puts("Initial memory:")
IO.puts("  total:      #{Float.round(initial[:total] / 1024 / 1024, 2)} MB")
IO.puts("  processes:  #{Float.round(initial[:processes] / 1024 / 1024, 2)} MB")
IO.puts("  binary:     #{Float.round(initial[:binary] / 1024 / 1024, 2)} MB")
IO.puts("  ets:        #{Float.round(initial[:ets] / 1024 / 1024, 2)} MB")
IO.puts("")

# Run single request and measure
ctx = make_ctx.(payment_body, sign.(payment_body))
:erlang.garbage_collect()
before_single = :erlang.memory()

{:ok, _, final_ctx} = Pyex.run(handler_source, ctx)

:erlang.garbage_collect()
after_single = :erlang.memory()

single_increase = after_single[:total] - before_single[:total]

IO.puts("Single request memory delta:")
IO.puts("  total:      #{Float.round(single_increase / 1024, 2)} KB")

IO.puts(
  "  processes:  #{Float.round((after_single[:processes] - before_single[:processes]) / 1024, 2)} KB"
)

IO.puts(
  "  binary:     #{Float.round((after_single[:binary] - before_single[:binary]) / 1024, 2)} KB"
)

IO.puts("")

# Analyze context size
ctx_size = :erlang.external_size(final_ctx)
IO.puts("Final context external size: #{Float.round(ctx_size / 1024, 2)} KB")
IO.puts("")

# Binary analysis - look for large binaries
IO.puts("--- Binary memory analysis ---")
IO.puts("")

# Get all processes and their binary usage
processes = Process.list()

process_binaries =
  Enum.map(processes, fn pid ->
    case Process.info(pid, [:binary, :memory, :dictionary, :registered_name]) do
      [{:binary, bins}, {:memory, mem}, {:dictionary, dict}, {:registered_name, name}]
      when is_list(bins) ->
        total_bin = Enum.reduce(bins, 0, fn {_, size, _}, acc -> acc + size end)
        {pid, name, mem, total_bin, length(bins)}

      _ ->
        nil
    end
  end)
  |> Enum.reject(&is_nil/1)
  |> Enum.sort_by(fn {_, _, _, bin_size, _} -> -bin_size end)
  |> Enum.take(10)

IO.puts("Top processes by binary memory:")

IO.puts(
  "  #{String.pad_trailing("name/pid", 25)} #{String.pad_leading("memory", 12)} #{String.pad_leading("binary", 12)} #{String.pad_leading("bin count", 10)}"
)

IO.puts("  " <> String.duplicate("-", 65))

Enum.each(process_binaries, fn {pid, name, mem, bin_size, bin_count} ->
  name_str = if name == [], do: inspect(pid), else: inspect(name)

  IO.puts(
    "  #{String.pad_trailing(name_str, 25)} #{String.pad_leading("#{Float.round(mem / 1024, 1)} KB", 12)} #{String.pad_leading("#{Float.round(bin_size / 1024, 1)} KB", 12)} #{String.pad_leading(Integer.to_string(bin_count), 10)}"
  )
end)

IO.puts("")

# Recon leak detection simulation
IO.puts("--- Binary leak detection ---")
IO.puts("")

# Run 1000 requests and measure growth
:erlang.garbage_collect()
before_many = :erlang.memory()

for i <- 1..1000 do
  ctx = make_ctx.(payment_body, sign.(payment_body))
  {:ok, _, _} = Pyex.run(handler_source, ctx)

  if rem(i, 250) == 0 do
    :erlang.garbage_collect()
    mem = :erlang.memory(:total)
    delta = mem - before_many[:total]
    IO.puts("  After #{i} requests: +#{Float.round(delta / 1024, 2)} KB total")
  end
end

:erlang.garbage_collect()
after_many = :erlang.memory()

total_delta = after_many[:total] - before_many[:total]
IO.puts("")
IO.puts("Total increase after 1000 requests: #{Float.round(total_delta / 1024, 2)} KB")
IO.puts("Average per request: #{Float.round(total_delta / 1000, 2)} bytes")
IO.puts("")

# ---------- Optimization recommendations ----------

IO.puts("--- Optimization Recommendations ---")
IO.puts("")

IO.puts("Based on profiling results:")
IO.puts("")
IO.puts("1. HMAC operations are already using native :crypto.mac/4 - optimal")
IO.puts("2. String operations (split, strip) are Python-level - consider optimizing")
IO.puts("3. JSON parsing uses Jason - already optimized NIF")
IO.puts("4. Dictionary operations are frequent - ensure efficient map access")
IO.puts("")
IO.puts("Potential improvements:")
IO.puts("- Cache compiled AST instead of re-parsing on each run")
IO.puts("- Use persistent_term for frequently accessed constants")
IO.puts("- Consider ETS for signature cache if verifying same payloads")
IO.puts("")
