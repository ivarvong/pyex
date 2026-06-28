defmodule Pyex.OtelAdversarialFuzzTest do
  @moduledoc """
  Adversarial property/fuzz testing for the native `opentelemetry` tracing
  module — the production posture, where a hostile sandboxed guest tries to
  break, exhaust, or escape the telemetry surface.

  Programs are generated from the full guest API (`get_tracer`,
  `start_as_current_span`, `set_attribute(s)`, `add_event`, `set_status`,
  `record_exception`, `is_recording`, `end`, `render`, `get_finished_spans`,
  `flush_spans`) with deliberately hostile argument types — tuples, lists,
  dicts, sets, bytes, `nan`/`inf`, `None`, lambdas, the span/tracer objects
  themselves, nested structures — in every string-typed slot.

  Invariants under test (each a property a production telemetry surface MUST
  hold against any tenant input):

    1. HOST SAFETY — `Pyex.run/2` never raises/throws an Elixir exception; it
       always returns `{:ok, …}` or `{:error, %Pyex.Error{}}`.
    2. HOST RENDER TOTALITY — the host-facing `SpanTree.render/2` over the
       guest's resulting spans always returns a string (never crashes the host
       on a malformed span the guest planted).
    3. BUDGET ENFORCEMENT — span/attribute/event spam under a memory cap always
       trips `LimitError`; it can never run unbounded or return `{:ok}` with
       memory far over budget.
    4. ISOLATION — guest `render()`/`get_finished_spans()` can never observe the
       platform (runtime) capability ledger.
    5. DETERMINISM — identical programs produce byte-identical spans + output.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pyex.{Ctx, SpanTree}

  @prelude """
  from opentelemetry import trace
  from opentelemetry.trace import Status, StatusCode, SpanKind
  import opentelemetry, json
  """

  # Hostile values for any string-typed slot (name/kind/key/status/...). `span`
  # is excluded from top-level slots (it isn't bound until inside the `with`);
  # ops can still reach it via `span.method(...)`.
  defp hostile_value do
    StreamData.member_of([
      "0",
      "-1",
      "3.14",
      "float('nan')",
      "float('inf')",
      "None",
      "True",
      "'s'",
      "''",
      "b'bytes'",
      "(1, 2)",
      "[1, 'a']",
      "{'k': 'v'}",
      "{1, 2}",
      "[[1], [2]]",
      "{'nested': {'deep': [1, 2, 3]}}",
      "tracer",
      "lambda x: x",
      "'x' * 200"
    ])
  end

  # One guest operation, as a Python expression on `span`/`tracer`.
  defp op do
    gen all(k <- hostile_value(), v <- hostile_value(), choice <- StreamData.integer(0..8)) do
      case choice do
        0 -> "span.set_attribute(#{k}, #{v})"
        1 -> "span.set_attributes(#{v})"
        2 -> "span.add_event(#{k}, #{v})"
        3 -> "span.set_status(#{v})"
        4 -> "span.set_status(Status(#{v}))"
        5 -> "span.record_exception(#{v})"
        6 -> "span.is_recording()"
        7 -> "span.end()"
        8 -> "tracer.start_as_current_span(#{k})"
      end
    end
  end

  defp hostile_program do
    gen all(
          tname <- hostile_value(),
          sname <- hostile_value(),
          skind <- hostile_value(),
          ops <- StreamData.list_of(op(), min_length: 1, max_length: 8)
        ) do
      guarded = Enum.map_join(ops, "\n", fn o -> "    try: #{o}\n    except Exception: pass" end)

      @prelude <>
        """
        tracer = trace.get_tracer(#{tname})
        with tracer.start_as_current_span(#{sname}, kind=#{skind}) as span:
        #{guarded}
        R = opentelemetry.render()
        S = opentelemetry.get_finished_spans()
        try: json.dumps(S)
        except Exception: pass
        """
    end
  end

  defp safe_run(program, opts) do
    Pyex.run(program, opts)
  rescue
    e -> {:host_crash, Exception.message(e)}
  catch
    kind, value -> {:host_throw, {kind, value}}
  end

  describe "host safety + render totality under hostile telemetry" do
    property "no hostile program crashes the host; host render stays total" do
      check all(program <- hostile_program(), max_runs: 400) do
        case safe_run(program,
               limits: [max_memory_bytes: 50_000_000, max_steps: 5_000_000, timeout: 5_000]
             ) do
          {:ok, _v, ctx} ->
            # The host renderer must never crash on spans the guest planted.
            assert is_binary(SpanTree.render(ctx.app_spans, title: "app"))
            assert is_binary(SpanTree.render(Ctx.runtime_spans(ctx), title: "runtime"))

          {:error, %Pyex.Error{}} ->
            :ok

          other ->
            flunk("""
            Host crashed / non-error result on adversarial program:

            #{program}
            => #{inspect(other)}
            """)
        end
      end
    end
  end

  describe "budget enforcement (no uncounted telemetry DoS)" do
    test "attribute spam under a memory cap trips LimitError, never runs unbounded" do
      program = """
      from opentelemetry import trace
      tracer = trace.get_tracer("t")
      with tracer.start_as_current_span("s") as span:
          for i in range(1_000_000):
              span.set_attribute("k" + str(i), "v" * 32)
      """

      assert {:error, %Pyex.Error{} = e} =
               safe_run(program,
                 limits: [max_memory_bytes: 1_000_000, max_steps: 100_000_000, timeout: 20_000]
               )

      assert e.exception_type == "LimitError"
    end

    test "event spam under a memory cap trips LimitError" do
      program = """
      from opentelemetry import trace
      tracer = trace.get_tracer("t")
      with tracer.start_as_current_span("s") as span:
          for i in range(1_000_000):
              span.add_event("e", {"k": "v" * 32})
      """

      assert {:error, %Pyex.Error{exception_type: "LimitError"}} =
               safe_run(program,
                 limits: [max_memory_bytes: 1_000_000, max_steps: 100_000_000, timeout: 20_000]
               )
    end

    test "record_exception spam under a memory cap trips LimitError" do
      program = """
      from opentelemetry import trace
      tracer = trace.get_tracer("t")
      err = ValueError("x" * 64)
      with tracer.start_as_current_span("s") as span:
          for i in range(1_000_000):
              span.record_exception(err)
      """

      assert {:error, %Pyex.Error{exception_type: "LimitError"}} =
               safe_run(program,
                 limits: [max_memory_bytes: 1_000_000, max_steps: 100_000_000, timeout: 20_000]
               )
    end

    test "attribute/event accumulation is linear, not quadratic" do
      time = fn n ->
        src = """
        from opentelemetry import trace
        tracer = trace.get_tracer("t")
        with tracer.start_as_current_span("s") as span:
            for i in range(#{n}):
                span.add_event("e")
        """

        {us, _} =
          :timer.tc(fn -> Pyex.run(src, limits: [max_steps: 100_000_000, timeout: 30_000]) end)

        us / 1000
      end

      _warm = time.(4_000)
      ratio = time.(40_000) / time.(10_000)
      # 4x the events should cost ~4x; quadratic would be ~16x.
      assert ratio < 8.0, "add_event scaled #{Float.round(ratio, 2)}x for 4x input (expected ~4x)"
    end
  end

  describe "tenant/platform isolation" do
    test "guest render/get_finished_spans never observe the platform ledger" do
      # Seed a platform (runtime) span carrying a secret, then run guest code
      # that reads/renders its OWN telemetry through the same ctx.
      {ctx, rid} =
        Ctx.open_runtime_span(Ctx.new(), "db.query", %{"api_key" => "sk-SECRET-DO-NOT-LEAK"})

      ctx = Ctx.close_runtime_span(ctx, rid, %{})

      {:ok, ast} =
        Pyex.compile("""
        from opentelemetry import trace
        import opentelemetry
        tracer = trace.get_tracer("guest")
        with tracer.start_as_current_span("work") as span:
            span.set_attribute("ok", 1)
        OUT = opentelemetry.render() + "\\n" + str(opentelemetry.get_finished_spans())
        print(OUT)
        """)

      {:ok, _v, ctx} = Pyex.run(ast, ctx)
      out = Pyex.output(ctx)

      refute out =~ "SECRET"
      refute out =~ "api_key"
      refute out =~ "db.query"
    end
  end

  describe "determinism" do
    test "a hostile program produces identical spans and output across runs" do
      program =
        @prelude <>
          """
          tracer = trace.get_tracer((1, 2))
          with tracer.start_as_current_span([1, 2], kind={'a': 1}) as span:
              span.set_attribute((3, 4), float('nan'))
              span.add_event(None, {1: 2})
              span.set_status(Status(StatusCode.ERROR))
          print(opentelemetry.render())
          print(json.dumps(opentelemetry.get_finished_spans()))
          """

      {:ok, _, c1} = Pyex.run(program)
      {:ok, _, c2} = Pyex.run(program)

      assert Pyex.output(c1) == Pyex.output(c2)
      assert c1.app_spans == c2.app_spans
    end
  end
end
