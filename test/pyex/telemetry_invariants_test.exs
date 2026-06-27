defmodule Pyex.TelemetryInvariantsTest do
  @moduledoc """
  Exhaustive integration tests for the telemetry/capability stack, derived from
  a bug hunt over complex end-to-end programs. Property tests assert the core
  invariants over randomized capability/span sequences; targeted tests pin the
  specific findings:

    * A failed turn still surfaces its capability ledger (on the exception event).
    * The run-telemetry metadata key is `:runtime_spans`.
    * Capability denials are recorded with the semconv `error.type`.

  Plus the seams the hunt confirmed correct, kept as regressions: no span-stack
  leak on exceptions, attribute type round-trip, unicode keys, scoped views,
  and validation-before-storage.
  """

  # async: false — these tests attach telemetry handlers, which are GLOBAL; under
  # async, a concurrent test's run would fire our handler and pollute the mailbox.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Pyex.{Builtins, Ctx, Interpreter, Storage}

  # Run keeping the final ctx on BOTH success and error (so we can assert
  # invariants even when a turn raises).
  defp run_keep_ctx(src, opts) do
    {:ok, ast} = Pyex.compile(src)
    ctx = opts |> Ctx.new() |> Ctx.reset_compute()
    env = Builtins.runtime_env(ctx)

    case Interpreter.run_with_ctx_result(ast, env, ctx) do
      {:ok, _v, _e, c} -> {:ok, c}
      {:error, _m, c} -> {:error, c}
    end
  end

  defp capture(event, src, opts) do
    parent = self()
    id = "inv-#{System.unique_integer([:positive])}"
    :telemetry.attach(id, event, fn _e, m, meta, _ -> send(parent, {:tel, m, meta}) end, nil)
    Pyex.run(src, opts)
    :telemetry.detach(id)

    receive do
      {:tel, m, meta} -> {m, meta}
    after
      0 -> {:none, :none}
    end
  end

  # ── generators ──
  defp store_op do
    gen all(
          op <- member_of([:get, :set, :delete, :keys]),
          key <- member_of(["a", "b", "c", "x:1", "x:2"])
        ) do
      case op do
        :get -> {"store.get(#{inspect(key)})", 1}
        :set -> {"store.set(#{inspect(key)}, 1)", 1}
        :delete -> {"store.delete(#{inspect(key)})", 1}
        :keys -> {"store.keys(#{inspect(key)})", 1}
      end
    end
  end

  defp program(op_lines), do: "import store\n" <> Enum.join(op_lines, "\n")

  describe "property: every capability op yields exactly one platform span" do
    property "count matches, all scope=pyex/kind=CLIENT, stacks always empty" do
      check all(ops <- list_of(store_op(), min_length: 1, max_length: 10)) do
        {lines, counts} = Enum.unzip(ops)
        {:ok, ctx} = run_keep_ctx(program(lines), storage: Storage.Memory.new())
        spans = Ctx.runtime_spans(ctx)

        assert length(spans) == Enum.sum(counts)
        assert Enum.all?(spans, &(&1.scope == "pyex" and &1.kind == "CLIENT"))
        # no span leak — the stack and active map always drain
        assert ctx.runtime_span_stack == []
        assert ctx.runtime_span_active == %{}
      end
    end
  end

  describe "property: a failed turn still surfaces every op it managed before crashing" do
    property "the final ctx of a crashed turn keeps all spans done before the raise" do
      check all(ops <- list_of(store_op(), min_length: 0, max_length: 8)) do
        {lines, counts} = Enum.unzip(ops)
        src = program(lines ++ ["raise RuntimeError('boom')"])
        {:error, ctx} = run_keep_ctx(src, storage: Storage.Memory.new())

        assert length(Ctx.runtime_spans(ctx)) == Enum.sum(counts)
      end
    end

    test "the exception telemetry event carries the runtime ledger (host-facing)" do
      {_m, meta} =
        capture(
          [:pyex, :run, :exception],
          program(["store.set('a', 1)", "store.set('b', 2)", "raise RuntimeError('x')"]),
          storage: Storage.Memory.new()
        )

      assert length(Map.get(meta, :runtime_spans)) == 2
    end
  end

  describe "property: guest spans nest cleanly and never cross into the platform channel" do
    property "nested guest spans balance; channels stay disjoint" do
      check all(depth <- integer(1..5)) do
        opens =
          for i <- 0..(depth - 1),
              do: String.duplicate("    ", i) <> "with t.start_as_current_span('s#{i}'):"

        body = String.duplicate("    ", depth) <> "store.set('k', 1)"

        src =
          "from opentelemetry import trace\nimport store\nt = trace.get_tracer('app')\n" <>
            Enum.join(opens ++ [body], "\n")

        {:ok, ctx} = run_keep_ctx(src, storage: Storage.Memory.new())

        # all guest spans accounted for, stack drained
        assert length(ctx.app_spans) == depth
        assert ctx.app_span_stack == []
        # disjoint scopes: guest never "pyex"; platform always "pyex"
        assert Enum.all?(ctx.app_spans, &(&1.scope == "app"))
        assert Enum.all?(Ctx.runtime_spans(ctx), &(&1.scope == "pyex"))
      end
    end
  end

  describe "property: the ASCII render is deterministic" do
    property "same program renders identically" do
      check all(ops <- list_of(store_op(), min_length: 1, max_length: 8)) do
        {lines, _} = Enum.unzip(ops)
        {:ok, ctx} = run_keep_ctx(program(lines), storage: Storage.Memory.new())
        spans = Ctx.runtime_spans(ctx)
        assert Pyex.SpanTree.render(spans) == Pyex.SpanTree.render(spans)
      end
    end
  end

  describe "findings — regression" do
    test "the run :stop metadata key is :runtime_spans" do
      {_m, meta} =
        capture([:pyex, :run, :stop], "import store\nstore.set('k', 1)",
          storage: Storage.Memory.new()
        )

      assert is_list(Map.get(meta, :runtime_spans))
      refute Map.has_key?(meta, :spans)
    end

    test "a denied store write records semconv error.type" do
      {:ok, ctx} =
        run_keep_ctx(
          "import store\ntry:\n    store.set('k', 1)\nexcept Exception:\n    pass",
          storage: Storage.View.readonly(Storage.Memory.new())
        )

      span = Ctx.runtime_spans(ctx) |> Enum.find(&(&1.name == "db.set"))
      assert span.attributes["error.type"] =~ "not permitted"
      refute Map.has_key?(span.attributes, "error")
    end

    test "a failed open records semconv error.type on file.open" do
      # opening a missing file for read fails; the span should carry error.type
      {:ok, ctx} =
        run_keep_ctx(
          "try:\n    open('/nope.txt')\nexcept Exception:\n    pass",
          filesystem: Pyex.FS.new(%{})
        )

      span = Ctx.runtime_spans(ctx) |> Enum.find(&(&1.name == "file.open"))
      assert span.attributes["error.type"] != nil
    end
  end

  describe "seams confirmed correct — regression" do
    test "an exception inside a guest span leaves no active-span leak" do
      {:ok, ctx} =
        run_keep_ctx(
          """
          from opentelemetry import trace
          t = trace.get_tracer('x')
          try:
              with t.start_as_current_span('outer'):
                  with t.start_as_current_span('inner'):
                      raise ValueError('x')
          except ValueError:
              pass
          """,
          []
        )

      assert ctx.app_span_stack == []
      assert ctx.app_span_active == %{}
      assert length(ctx.app_spans) == 2
    end

    test "scoped View.keys() returns only in-scope keys" do
      backend = Storage.Memory.new(%{"t1:a" => "1", "t1:b" => "2", "t2:a" => "3"})

      {:ok, ctx} =
        run_keep_ctx("import store\nprint(store.keys(''))",
          storage: Storage.View.scope(backend, {:prefix, "t1:"})
        )

      assert Pyex.output(ctx) |> String.trim() == "['t1:a', 't1:b']"
    end

    test "a unicode/special key round-trips through the semconv attribute" do
      {:ok, ctx} =
        run_keep_ctx(~S|import store| <> "\n" <> ~S|store.set('café:42 "x"', 1)|,
          storage: Storage.Memory.new()
        )

      span = Ctx.runtime_spans(ctx) |> hd()
      assert span.attributes["db.collection.name"] == ~s|café:42 "x"|
    end
  end
end
