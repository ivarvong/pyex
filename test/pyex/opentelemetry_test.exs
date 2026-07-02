defmodule Pyex.OpentelemetryTest do
  @moduledoc """
  Adversarial tests for the native `opentelemetry` module.

  Spans live entirely in `Pyex.Ctx` (`app_span_seq`, `app_span_stack`, `app_span_active`,
  `app_spans`), so every test runs through `run_with_ctx_result/3` to keep
  the final ctx even when the program ends in an unhandled exception — letting
  us assert the stack-integrity invariants directly against ctx.
  """
  use ExUnit.Case, async: true

  alias Pyex.{Builtins, Ctx, Interpreter}

  # Runs `source`, returning `{result, final_ctx}` where result is
  # `{:ok, value}` or `{:error, msg}`. The ctx is preserved on both paths.
  defp run_otel(source, opts \\ []) do
    {:ok, ast} = Pyex.compile(source)
    ctx = opts |> Ctx.new() |> Ctx.reset_compute()
    env = Builtins.runtime_env(ctx)

    case Interpreter.run_with_ctx_result(ast, env, ctx) do
      {:ok, value, _env, ctx} -> {{:ok, value}, ctx}
      {:error, msg, ctx} -> {{:error, msg}, ctx}
    end
  end

  # The single load-bearing invariant: no run may leak an active span — the
  # stack must be empty and nothing left in-progress.
  defp assert_stack_empty!(ctx) do
    assert ctx.app_span_stack == [], "app_span_stack leaked: #{inspect(ctx.app_span_stack)}"

    assert ctx.app_span_active == %{},
           "app_span_active leaked: #{inspect(Map.keys(ctx.app_span_active))}"
  end

  defp finished_by_name(ctx, name) do
    Enum.find(ctx.app_spans, &(&1.name == name))
  end

  # ── basics ────────────────────────────────────────────────────────────────

  test "single span with attributes is finished with correct name/attributes" do
    {{:ok, _}, ctx} =
      run_otel("""
      from opentelemetry import trace
      tracer = trace.get_tracer("svc")
      with tracer.start_as_current_span("parse") as span:
          span.set_attribute("lines", 42)
          span.set_attribute("ok", True)
      """)

    assert_stack_empty!(ctx)
    assert [span] = ctx.app_spans
    assert span.name == "parse"
    assert span.parent_id == nil
    assert span.attributes == %{"lines" => 42, "ok" => true}
    assert span.status == "UNSET"
    assert span.trace_id == span.id
    assert span.start_seq < span.end_seq
  end

  test "start_as_current_span honors the attributes= kwarg" do
    {{:ok, _}, ctx} =
      run_otel("""
      from opentelemetry import trace
      tracer = trace.get_tracer("svc")
      with tracer.start_as_current_span("fetch", attributes={"url": "/api", "retries": 2}):
          pass
      """)

    assert_stack_empty!(ctx)
    span = finished_by_name(ctx, "fetch")
    assert span.attributes == %{"url" => "/api", "retries" => 2}
  end

  test "attributes= kwarg merges with set_attribute calls inside the span" do
    {{:ok, _}, ctx} =
      run_otel("""
      from opentelemetry import trace
      tracer = trace.get_tracer("svc")
      with tracer.start_as_current_span("work", attributes={"phase": "start"}) as span:
          span.set_attribute("rows", 7)
      """)

    assert_stack_empty!(ctx)
    span = finished_by_name(ctx, "work")
    assert span.attributes == %{"phase" => "start", "rows" => 7}
  end

  test "set_status records the status code" do
    {{:ok, _}, ctx} =
      run_otel("""
      from opentelemetry import trace
      from opentelemetry.trace import Status, StatusCode
      tracer = trace.get_tracer("svc")
      with tracer.start_as_current_span("work") as span:
          span.set_status(Status(StatusCode.OK))
      """)

    assert_stack_empty!(ctx)
    assert finished_by_name(ctx, "work").status == "OK"
  end

  test "SpanKind is carried onto the span" do
    {{:ok, _}, ctx} =
      run_otel("""
      from opentelemetry import trace
      from opentelemetry.trace import SpanKind
      tracer = trace.get_tracer("svc")
      with tracer.start_as_current_span("rpc", kind=SpanKind.SERVER) as span:
          pass
      """)

    assert finished_by_name(ctx, "rpc").kind == "SERVER"
  end

  # ── imports ─────────────────────────────────────────────────────────────--

  test "submodule import forms all resolve" do
    {{:ok, value}, _ctx} =
      run_otel("""
      from opentelemetry import trace
      from opentelemetry.trace import SpanKind, Status, StatusCode
      import opentelemetry
      results = [
          SpanKind.INTERNAL,
          StatusCode.OK,
          Status(StatusCode.ERROR).status_code,
          type(trace.get_tracer("x")).__name__,
      ]
      print(results)
      """)

    assert value == nil
  end

  test "get_finished_spans is reachable as a python list of dicts" do
    {{:ok, _}, _ctx} =
      run_otel("""
      from opentelemetry import trace
      import opentelemetry
      tracer = trace.get_tracer("svc")
      with tracer.start_as_current_span("a") as s:
          s.set_attribute("x", 1)
      spans = opentelemetry.get_finished_spans()
      assert len(spans) == 1
      assert spans[0]["name"] == "a"
      assert spans[0]["attributes"]["x"] == 1
      assert spans[0]["parent_id"] is None
      assert spans[0]["status"] == "UNSET"
      """)
  end

  # ── nesting ─────────────────────────────────────────────────────────────--

  test "nested spans: child.parent_id == parent.id and seq nesting holds" do
    {{:ok, _}, ctx} =
      run_otel("""
      from opentelemetry import trace
      tracer = trace.get_tracer("svc")
      with tracer.start_as_current_span("parent") as p:
          with tracer.start_as_current_span("child") as c:
              c.set_attribute("d", 1)
      """)

    assert_stack_empty!(ctx)
    parent = finished_by_name(ctx, "parent")
    child = finished_by_name(ctx, "child")

    assert child.parent_id == parent.id
    assert parent.parent_id == nil
    assert child.trace_id == parent.trace_id
    assert child.trace_id == parent.id
    assert child.start_seq > parent.start_seq
    assert child.end_seq < parent.end_seq
  end

  # ── recursion ─────────────────────────────────────────────────────────────

  test "recursive instrumented function builds a well-formed tree" do
    {{:ok, _}, ctx} =
      run_otel("""
      from opentelemetry import trace
      from opentelemetry.trace import SpanKind, Status, StatusCode
      tracer = trace.get_tracer("t")
      def f(n):
          with tracer.start_as_current_span("f", kind=SpanKind.INTERNAL) as s:
              s.set_attribute("n", n)
              if n > 0:
                  f(n - 1)
              s.set_status(Status(StatusCode.OK))
      with tracer.start_as_current_span("root") as r:
          f(5)
      """)

    assert_stack_empty!(ctx)
    # root + 6 calls (f(5)..f(0))
    assert length(ctx.app_spans) == 7

    ids = MapSet.new(ctx.app_spans, & &1.id)
    roots = Enum.filter(ctx.app_spans, &(&1.parent_id == nil))
    assert length(roots) == 1
    [root] = roots

    # Every span's parent chain reaches the single root.
    for span <- ctx.app_spans do
      assert reaches_root?(span, ctx.app_spans, root.id)
      if span.parent_id != nil, do: assert(MapSet.member?(ids, span.parent_id))
      assert span.trace_id == root.id
    end

    assert MapSet.size(ids) == length(ctx.app_spans), "span ids must be unique"
  end

  defp reaches_root?(%{id: id}, _all, root_id) when id == root_id, do: true
  defp reaches_root?(%{parent_id: nil}, _all, _root_id), do: true

  defp reaches_root?(%{parent_id: pid}, all, root_id) do
    case Enum.find(all, &(&1.id == pid)) do
      nil -> false
      parent -> reaches_root?(parent, all, root_id)
    end
  end

  # ── exception safety (the critical one) ───────────────────────────────────

  test "unhandled raise: span still finished as ERROR, exception propagates, stack empty" do
    {{:error, msg}, ctx} =
      run_otel("""
      from opentelemetry import trace
      tracer = trace.get_tracer("svc")
      with tracer.start_as_current_span("boom") as s:
          s.set_attribute("before", 1)
          raise ValueError("kaboom")
      """)

    assert msg =~ "ValueError"
    assert_stack_empty!(ctx)
    span = finished_by_name(ctx, "boom")
    assert span.status == "ERROR"
    assert span.end_seq != nil
    # the exception event was recorded
    assert Enum.any?(span.events, &(&1.name == "exception"))
    # the attribute set before the raise survives
    assert span.attributes["before"] == 1
  end

  test "raise at depth>1 caught by outer: inner ERROR, outer present, stack empty" do
    {{:ok, _}, ctx} =
      run_otel("""
      from opentelemetry import trace
      from opentelemetry.trace import Status, StatusCode
      tracer = trace.get_tracer("svc")
      with tracer.start_as_current_span("outer") as o:
          try:
              with tracer.start_as_current_span("inner") as i:
                  raise RuntimeError("inner failed")
          except RuntimeError:
              pass
          o.set_status(Status(StatusCode.OK))
      """)

    assert_stack_empty!(ctx)
    inner = finished_by_name(ctx, "inner")
    outer = finished_by_name(ctx, "outer")

    assert inner.status == "ERROR"
    assert inner.parent_id == outer.id
    assert outer.status == "OK"
    assert outer.parent_id == nil
    assert inner.end_seq < outer.end_seq
  end

  # ── bounds / adversarial ──────────────────────────────────────────────────

  test "5000 spans complete and are all finished" do
    {{:ok, _}, ctx} =
      run_otel("""
      from opentelemetry import trace
      import opentelemetry
      tracer = trace.get_tracer("t")
      for i in range(5000):
          with tracer.start_as_current_span("s") as s:
              s.set_attribute("i", i)
      print(len(opentelemetry.get_finished_spans()))
      """)

    assert_stack_empty!(ctx)
    assert length(ctx.app_spans) == 5000
    assert Enum.all?(ctx.app_spans, &(&1.end_seq != nil))
  end

  test "set_attribute on a span after its `with` exited is a safe no-op" do
    {{:ok, _}, ctx} =
      run_otel("""
      from opentelemetry import trace
      tracer = trace.get_tracer("t")
      with tracer.start_as_current_span("a") as s:
          s.set_attribute("inside", 1)
      # span has exited; these must not crash
      s.set_attribute("outside", 2)
      s.set_status("OK")
      assert s.is_recording() == False
      """)

    assert_stack_empty!(ctx)
    span = finished_by_name(ctx, "a")
    assert span.attributes == %{"inside" => 1}
    assert span.status == "UNSET"
  end

  # ── isolation ─────────────────────────────────────────────────────────────

  test "two separate runs see only their own spans" do
    src = fn name ->
      """
      from opentelemetry import trace
      tracer = trace.get_tracer("t")
      with tracer.start_as_current_span("#{name}") as s:
          pass
      """
    end

    {{:ok, _}, ctx1} = run_otel(src.("alpha"))
    {{:ok, _}, ctx2} = run_otel(src.("beta"))

    assert Enum.map(ctx1.app_spans, & &1.name) == ["alpha"]
    assert Enum.map(ctx2.app_spans, & &1.name) == ["beta"]
  end

  test "concurrent runs are fully isolated (no global state)" do
    program = fn label, depth ->
      """
      from opentelemetry import trace
      tracer = trace.get_tracer("t")
      def f(n):
          with tracer.start_as_current_span("#{label}") as s:
              s.set_attribute("n", n)
              if n > 0:
                  f(n - 1)
      f(#{depth})
      """
    end

    tasks =
      for {label, depth} <- [{"red", 10}, {"green", 25}, {"blue", 7}, {"gold", 40}] do
        Task.async(fn ->
          {{:ok, _}, ctx} = run_otel(program.(label, depth))
          {label, depth + 1, ctx}
        end)
      end

    for {label, expected_count, ctx} <- Task.await_many(tasks, 30_000) do
      assert_stack_empty!(ctx)
      names = ctx.app_spans |> Enum.map(& &1.name) |> Enum.uniq()
      assert names == [label], "run for #{label} saw foreign spans: #{inspect(names)}"
      assert length(ctx.app_spans) == expected_count
    end
  end

  # ── platform / tenant separation (security boundary) ──────────────────────

  # The tenant (sandboxed Python) telemetry MUST be fully isolated from the
  # platform's host-side telemetry (Ctx.open_runtime_span/close_span/spans). Sandboxed
  # code must not be able to inject into, parent onto, or read the platform
  # trace. Even with a platform span OPEN around the run, the guest span must:
  #   - land in app_spans, never the platform's app_spans;
  #   - be a root (parent_id == nil), never parented onto the platform span;
  #   - and get_finished_spans() must return ONLY tenant spans.
  test "tenant spans are isolated from the platform trace (no inject/parent/read)" do
    {:ok, ast} =
      Pyex.compile("""
      from opentelemetry import trace
      tracer = trace.get_tracer("svc")
      with tracer.start_as_current_span("guest") as s:
          s.set_attribute("a", 1)
      import opentelemetry
      # guest can only ever read tenant spans; assert it does not see the host
      assert [x["name"] for x in opentelemetry.get_finished_spans()] == ["guest"]
      assert opentelemetry.get_finished_spans()[0]["parent_id"] is None
      """)

    ctx = Ctx.new() |> Ctx.reset_compute()
    # a platform span is OPEN around the whole run (the host's turn span)
    {ctx, hid} = Ctx.open_runtime_span(ctx, "host_root", %{"layer" => "elixir"})
    env = Builtins.runtime_env(ctx)

    # the in-guest asserts above would raise if it could see/parent-onto the host
    {:ok, _v, _env, ctx} = Interpreter.run_with_ctx_result(ast, env, ctx)
    ctx = Ctx.close_runtime_span(ctx, hid)

    assert_stack_empty!(ctx)
    # platform trace: ONLY the host span (the perl rename must not touch this one)
    assert ctx.runtime_spans |> Enum.map(& &1.name) == ["host_root"]
    # tenant trace: ONLY the guest span, and it is a root (no cross-parenting)
    assert ctx.app_spans |> Enum.map(& &1.name) == ["guest"]
    assert [%{parent_id: nil}] = ctx.app_spans
  end

  # ── VFS flush ─────────────────────────────────────────────────────────────

  test "flush_spans writes greppable JSONL into the VFS" do
    {{:ok, _}, ctx} =
      run_otel(
        """
        from opentelemetry import trace
        import opentelemetry
        tracer = trace.get_tracer("t")
        with tracer.start_as_current_span("a") as a:
            a.set_attribute("x", 1)
            with tracer.start_as_current_span("b") as b:
                b.set_attribute("y", 2)
        opentelemetry.flush_spans("/otel/spans.jsonl")
        """,
        filesystem: %{}
      )

    assert {:ok, content} = Pyex.FS.read(ctx.filesystem, "/otel/spans.jsonl")
    lines = content |> String.split("\n", trim: true)
    assert length(lines) == length(ctx.app_spans)
    assert length(lines) == 2

    decoded = Enum.map(lines, &Jason.decode!/1)
    # each line is a valid JSON object with the documented keys
    for obj <- decoded do
      assert Map.has_key?(obj, "name")
      assert Map.has_key?(obj, "span_id")
      assert Map.has_key?(obj, "parent_id")
      assert Map.has_key?(obj, "trace_id")
      assert Map.has_key?(obj, "attributes")
    end

    # b completes before a, so it is written first
    assert Enum.map(decoded, & &1["name"]) == ["b", "a"]
  end

  test "flush_spans defaults to /otel/spans.jsonl" do
    {{:ok, _}, ctx} =
      run_otel(
        """
        from opentelemetry import trace
        import opentelemetry
        tracer = trace.get_tracer("t")
        with tracer.start_as_current_span("only") as s:
            pass
        opentelemetry.flush_spans()
        """,
        filesystem: %{}
      )

    assert {:ok, content} = Pyex.FS.read(ctx.filesystem, "/otel/spans.jsonl")
    assert content |> String.split("\n", trim: true) |> length() == 1
  end

  # ── render / robustness ───────────────────────────────────────────────────

  # Regression: a non-string span name (e.g. start_as_current_span(123) or None)
  # must NOT crash the host — SpanTree.render did binary-concat on the raw name.
  # The name is coerced to a string at the source, so render/serialize are safe.
  test "non-string span name is coerced and render never crashes the host" do
    {{:ok, _}, ctx} =
      run_otel("""
      from opentelemetry import trace
      import opentelemetry
      tracer = trace.get_tracer("t")
      with tracer.start_as_current_span(123):
          pass
      with tracer.start_as_current_span(None):
          pass
      RENDER = opentelemetry.render()
      NAME0 = opentelemetry.get_finished_spans()[0]["name"]
      """)

    assert_stack_empty!(ctx)
    # names coerced to strings everywhere
    assert Enum.all?(ctx.app_spans, &is_binary(&1.name))
    assert (finished_by_name(ctx, "123") || finished_by_name(ctx, "")) != nil
  end

  # ── property / fuzz ───────────────────────────────────────────────────────

  test "fuzz: 150 random nested-with programs all satisfy the invariants" do
    for seed <- 1..150 do
      :rand.seed(:exsss, {seed, seed * 2_654_435_761 + 1, seed * 40_503 + 7})
      {source, expected_count} = gen_program()

      {result, ctx} = run_otel(source)

      assert match?({:ok, _}, result),
             "seed #{seed} did not complete cleanly (all raises are locally caught): " <>
               "#{inspect(result)}\n\n#{source}"

      # stack-integrity: nothing leaked
      assert ctx.app_span_stack == [], "seed #{seed}: stack leaked\n#{source}"
      assert ctx.app_span_active == %{}, "seed #{seed}: active leaked\n#{source}"

      # started == finished
      assert length(ctx.app_spans) == expected_count,
             "seed #{seed}: expected #{expected_count} spans, got " <>
               "#{length(ctx.app_spans)}\n#{source}"

      validate_tree!(ctx.app_spans, seed, source)
    end
  end

  defp validate_tree!(spans, seed, source) do
    ids = MapSet.new(spans, & &1.id)
    by_id = Map.new(spans, &{&1.id, &1})

    assert MapSet.size(ids) == length(spans), "seed #{seed}: duplicate span ids\n#{source}"

    for span <- spans do
      assert span.end_seq != nil, "seed #{seed}: span #{span.id} never finalized\n#{source}"

      assert span.start_seq < span.end_seq,
             "seed #{seed}: span #{span.id} seq inverted\n#{source}"

      case span.parent_id do
        nil ->
          assert span.trace_id == span.id

        pid ->
          assert MapSet.member?(ids, pid),
                 "seed #{seed}: span #{span.id} parent #{pid} missing\n#{source}"

          parent = Map.fetch!(by_id, pid)
          # strict seq nesting: child opens after and closes before its parent
          assert span.start_seq > parent.start_seq,
                 "seed #{seed}: child #{span.id} started before parent #{pid}\n#{source}"

          assert span.end_seq < parent.end_seq,
                 "seed #{seed}: child #{span.id} ended after parent #{pid}\n#{source}"

          assert span.trace_id == parent.trace_id,
                 "seed #{seed}: child #{span.id} trace_id differs from parent\n#{source}"
      end
    end
  end

  # Random program generator. Every `with` it emits is guaranteed to execute
  # exactly once (raises are always wrapped in a local try/except right where
  # they happen), so the emitted node count is the exact expected finished
  # span count even on the exception paths.
  defp gen_program do
    preamble = "from opentelemetry import trace\ntracer = trace.get_tracer('t')\n"
    roots = :rand.uniform(3)

    {lines, count} =
      Enum.reduce(1..roots, {[], 0}, fn _, {acc, c} ->
        {l, n} = emit_node(0, 3)
        {acc ++ l, c + n}
      end)

    {preamble <> Enum.join(lines, "\n") <> "\n", count}
  end

  # Emit a `with` node at `indent`, returning {lines, span_count}.
  defp emit_node(indent, budget) do
    pad = String.duplicate("    ", indent)
    var = "s#{System.unique_integer([:positive])}"
    name = "n#{System.unique_integer([:positive])}"

    header = "#{pad}with tracer.start_as_current_span(#{inspect(name)}) as #{var}:"
    attr = "#{pad}    #{var}.set_attribute(\"k\", #{:rand.uniform(1000)})"

    {children, child_count} =
      if budget <= 0 do
        {[], 0}
      else
        num = :rand.uniform(4) - 1

        Enum.reduce(0..num, {[], 0}, fn i, {acc, c} ->
          if i == 0 do
            {acc, c}
          else
            {l, n} = emit_child(indent + 1, budget - 1)
            {acc ++ l, c + n}
          end
        end)
      end

    {[header, attr | children], 1 + child_count}
  end

  # A child is either a plain node or a node that raises at the end, wrapped in
  # a try/except so execution continues and the count stays predictable.
  defp emit_child(indent, budget) do
    if :rand.uniform(3) == 1 do
      pad = String.duplicate("    ", indent)
      {node_lines, count} = emit_node(indent + 1, budget)
      raise_line = "#{String.duplicate("    ", indent + 2)}raise ValueError(\"boom\")"

      wrapped =
        ["#{pad}try:"] ++
          node_lines ++ [raise_line, "#{pad}except Exception:", "#{pad}    pass"]

      {wrapped, count}
    else
      emit_node(indent, budget)
    end
  end
end
