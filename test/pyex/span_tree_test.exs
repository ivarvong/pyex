defmodule Pyex.SpanTreeTest do
  @moduledoc """
  Tests the ASCII trace renderer: determinism (logical clock → identical
  render every run), nesting/waterfall structure, and the security boundary —
  the guest's `opentelemetry.render()` can only show its own spans, never the
  platform's runtime ledger.
  """

  use ExUnit.Case, async: true

  alias Pyex.SpanTree

  defp spans do
    [
      %{
        id: 0,
        parent_id: nil,
        name: "root",
        start_seq: 0,
        end_seq: 7,
        kind: "SERVER",
        attributes: %{"id" => "A1"}
      },
      %{
        id: 1,
        parent_id: 0,
        name: "child",
        start_seq: 1,
        end_seq: 2,
        kind: "INTERNAL",
        status: "OK",
        attributes: %{}
      }
    ]
  end

  describe "SpanTree.render/2" do
    test "is deterministic — identical input renders identically" do
      assert SpanTree.render(spans()) == SpanTree.render(spans())
    end

    test "shows names, nests children under parents, and renders a title" do
      out = SpanTree.render(spans(), title: "trace")
      assert out =~ "── trace · 2 spans ──"
      assert out =~ "root"
      # child is indented deeper than root
      [root_line] = for l <- String.split(out, "\n"), l =~ "root", do: l
      [child_line] = for l <- String.split(out, "\n"), l =~ "child", do: l
      assert leading_label_indent(child_line) > leading_label_indent(root_line)
      assert out =~ "SERVER"
      assert out =~ "OK"
    end

    test "an empty trace renders cleanly" do
      assert SpanTree.render([], title: "trace") == "── trace · 0 spans ──\n(no spans)"
    end
  end

  describe "host render (Pyex.Turn.render)" do
    test "renders the runtime capability ledger (ground truth) by default" do
      {:ok, _v, ctx} =
        Pyex.run("import store\nstore.set('order:1', {'amt': 5})",
          storage: Pyex.Storage.Memory.new()
        )

      out = Pyex.Turn.render(ctx)
      assert out =~ "runtime · scope=pyex"
      assert out =~ "db.set"
      assert out =~ ~s|db.collection.name="order:1"|
    end
  end

  describe "guest render (opentelemetry.render) is walled to the program's own spans" do
    test "renders the program's spans but never the platform capability ledger" do
      {:ok, _v, ctx} =
        Pyex.run(
          """
          from opentelemetry import trace
          import opentelemetry, store
          with trace.get_tracer("app").start_as_current_span("handle"):
              store.set("secret", 1)        # a real capability op (platform span)
          print(opentelemetry.render())
          """,
          storage: Pyex.Storage.Memory.new()
        )

      rendered = Pyex.output(ctx)
      # The guest sees its own span...
      assert rendered =~ "handle"
      # ...but the capability op it performed is NOT in its render — the runtime
      # ledger is unreachable from inside the sandbox.
      refute rendered =~ "db.set"
      refute rendered =~ "secret"

      # The host, however, sees the real op in the runtime ledger.
      assert Pyex.Turn.render(ctx) =~ "db.set"
    end
  end

  # indentation of the label (the run of spaces before the span name)
  defp leading_label_indent(line) do
    # strip the waterfall column, then count leading spaces before the name
    case String.split(line, " ", parts: 2) do
      [_bar, rest] -> String.length(rest) - String.length(String.trim_leading(rest))
      _ -> 0
    end
  end
end
