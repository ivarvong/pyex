# Stripe Webhook Handler Benchmark
#
# Measures the realistic controller-action path: load a tenant's
# Python source from storage, run it with the Stripe payload
# injected via the :modules option, return the result.
#
# Every iteration is a cold run from source -- no caching.
#
# Run with: mix run bench/stripe_webhook_bench.exs

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
  Pyex.Ctx.new(
    modules: %{
      "webhook_request" => %{
        "payload" => payload,
        "sig_header" => sig_header,
        "endpoint_secret" => secret
      }
    }
  )
end

# ---------- Verify correctness ----------

IO.puts(String.duplicate("=", 70))
IO.puts("Stripe Webhook Handler Benchmark")
IO.puts(String.duplicate("=", 70))
IO.puts("")

IO.puts(
  "Source: #{byte_size(handler_source)} bytes, #{length(String.split(handler_source, "\n"))} lines"
)

IO.puts("")

IO.puts("--- Verification ---")

{:ok, result, _ctx} = Pyex.run(handler_source, make_ctx.(payment_body, sign.(payment_body)))

IO.puts(
  "  #{String.pad_trailing("payment_intent.succeeded", 35)} #{if result["status"] == 200, do: "OK (#{inspect(result["result"])})", else: "FAIL"}"
)

{:ok, result, _ctx} = Pyex.run(handler_source, make_ctx.(invoice_body, sign.(invoice_body)))

IO.puts(
  "  #{String.pad_trailing("invoice.paid", 35)} #{if result["status"] == 200, do: "OK (#{inspect(result["result"])})", else: "FAIL"}"
)

{:ok, result, _ctx} = Pyex.run(handler_source, make_ctx.(invalid_body, "t=1,v1=bad"))

IO.puts(
  "  #{String.pad_trailing("invalid_signature", 35)} #{if result["status"] == 400, do: "OK (rejected)", else: "FAIL"}"
)

IO.puts("")

# ---------- Phase breakdown ----------

IO.puts("--- Phase breakdown (single call) ---")

{compile_us, {:ok, _ast}} = :timer.tc(fn -> Pyex.compile(handler_source) end)
ctx = make_ctx.(payment_body, sign.(payment_body))
{run_us, {:ok, _result, _ctx}} = :timer.tc(fn -> Pyex.run(handler_source, ctx) end)

IO.puts("  compile (lex+parse): #{Float.round(compile_us / 1000, 3)} ms")
IO.puts("  run (full):          #{Float.round(run_us / 1000, 3)} ms")
IO.puts("")

# ---------- Benchmark ----------

IO.puts("--- Benchmark ---")
IO.puts("")

payment_ctx = make_ctx.(payment_body, sign.(payment_body))
invoice_ctx = make_ctx.(invoice_body, sign.(invoice_body))
invalid_ctx = make_ctx.(invalid_body, "t=1,v1=bad")

Benchee.run(
  %{
    "payment_intent.succeeded" => fn ->
      Pyex.run(handler_source, payment_ctx)
    end,
    "invoice.paid" => fn ->
      Pyex.run(handler_source, invoice_ctx)
    end,
    "invalid signature (reject)" => fn ->
      Pyex.run(handler_source, invalid_ctx)
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  print: [configuration: false]
)
