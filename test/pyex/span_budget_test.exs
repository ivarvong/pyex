defmodule Pyex.SpanBudgetTest do
  @moduledoc """
  Spans count toward the memory budget, so a program cannot turn the telemetry
  channels into an unbounded, uncounted memory sink (the P2 review finding: a
  guest span in a hot loop accumulated 50k spans under a 1 MB limit).
  """

  use ExUnit.Case, async: true

  describe "guest (opentelemetry) spans are bounded by the memory limit" do
    test "a tight span loop trips LimitError instead of accumulating unbounded" do
      src = """
      from opentelemetry import trace
      t = trace.get_tracer("x")
      for i in range(200000):
          with t.start_as_current_span("s"):
              pass
      print("done")
      """

      assert {:error, %Pyex.Error{message: msg}} =
               Pyex.run(src, limits: [max_memory_bytes: 1_000_000])

      assert msg =~ "LimitError"
    end

    test "ordinary span usage is unaffected under the default budget" do
      src = """
      from opentelemetry import trace
      t = trace.get_tracer("x")
      for i in range(20):
          with t.start_as_current_span("s"):
              pass
      print("ok")
      """

      assert {:ok, _v, ctx} = Pyex.run(src)
      assert Pyex.output(ctx) |> String.trim() == "ok"
    end
  end

  describe "platform (capability) spans also count toward the budget" do
    test "a store op loop is bounded (spans + values both counted)" do
      src = """
      import store
      for i in range(200000):
          store.set("k", i)
      print("done")
      """

      assert {:error, %Pyex.Error{message: msg}} =
               Pyex.run(src,
                 storage: Pyex.Storage.Memory.new(),
                 limits: [max_memory_bytes: 1_000_000]
               )

      assert msg =~ "LimitError"
    end
  end

  describe "the memory budget now accounts for span allocation" do
    test "creating spans raises measured memory" do
      few =
        Pyex.run!("from opentelemetry import trace\nt=trace.get_tracer('x')\nx=1", [])

      _ = few

      {:ok, _v, c0} = Pyex.run("x = 1")

      {:ok, _v, c1} =
        Pyex.run("""
        from opentelemetry import trace
        t = trace.get_tracer("x")
        for i in range(100):
            with t.start_as_current_span("s"):
                pass
        """)

      assert c1.memory_bytes > c0.memory_bytes
    end
  end
end
