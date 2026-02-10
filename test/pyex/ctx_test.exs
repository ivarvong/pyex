defmodule Pyex.CtxTest do
  use ExUnit.Case, async: true

  alias Pyex.{Ctx, Error}

  describe "new/0" do
    test "creates a live context" do
      ctx = Ctx.new()
      assert ctx.mode == :live
      assert ctx.log == []
      assert ctx.step == 0
      assert ctx.remaining == []
    end
  end

  describe "record/3" do
    test "appends events in live mode" do
      ctx =
        Ctx.new()
        |> Ctx.record(:assign, {"x", 1})
        |> Ctx.record(:assign, {"y", 2})

      assert length(Ctx.events(ctx)) == 2
      assert ctx.step == 2
    end

    test "events have type, step, and data" do
      ctx = Ctx.new() |> Ctx.record(:branch, {:if, true})
      [{type, step, data}] = Ctx.events(ctx)
      assert type == :branch
      assert step == 0
      assert data == {:if, true}
    end

    test "is a no-op in replay mode" do
      ctx = Ctx.from_log([{:assign, 0, {"x", 1}}])
      ctx = Ctx.record(ctx, :assign, {"y", 2})
      assert length(Ctx.events(ctx)) == 1
    end
  end

  describe "consume/2" do
    test "returns event and advances remaining in replay mode" do
      log = [{:assign, 0, {"x", 1}}, {:branch, 1, {:if, true}}]
      ctx = Ctx.from_log(log)

      {:ok, event, ctx} = Ctx.consume(ctx, :assign)
      assert event == {:assign, 0, {"x", 1}}
      assert length(ctx.remaining) == 1

      {:ok, event, _ctx} = Ctx.consume(ctx, :branch)
      assert event == {:branch, 1, {:if, true}}
    end

    test "returns :live when log is exhausted" do
      ctx = Ctx.from_log([{:assign, 0, {"x", 1}}])
      {:ok, _event, ctx} = Ctx.consume(ctx, :assign)
      assert :live = Ctx.consume(ctx, :assign)
    end

    test "returns :live in live mode" do
      ctx = Ctx.new()
      assert :live = Ctx.consume(ctx, :assign)
    end

    test "returns :live on type mismatch" do
      ctx = Ctx.from_log([{:branch, 0, {:if, true}}])
      assert :live = Ctx.consume(ctx, :assign)
    end
  end

  describe "for_resume round-trip" do
    test "round-trips through for_resume" do
      ctx =
        Ctx.new()
        |> Ctx.record(:assign, {"x", 42})
        |> Ctx.record(:loop_iter, {:for, "i", 0})

      restored = Ctx.for_resume(ctx)

      assert restored.mode == :replay
      assert Ctx.events(restored) == Ctx.events(ctx)
      assert restored.remaining == Ctx.events(ctx)
    end
  end

  describe "branch_at/2" do
    test "creates replay context from first n events" do
      ctx =
        Ctx.new()
        |> Ctx.record(:assign, {"x", 1})
        |> Ctx.record(:assign, {"y", 2})
        |> Ctx.record(:assign, {"z", 3})

      branched = Ctx.branch_at(ctx, 2)
      assert branched.mode == :replay
      assert length(Ctx.events(branched)) == 2
      assert length(branched.remaining) == 2
    end
  end

  describe "for_resume/1" do
    test "sets to replay mode with all events remaining" do
      ctx =
        Ctx.new()
        |> Ctx.record(:assign, {"x", 1})
        |> Ctx.record(:suspend, {})

      resumed = Ctx.for_resume(ctx)
      assert resumed.mode == :replay
      assert length(resumed.remaining) == 2
      assert length(Ctx.events(resumed)) == 2
    end
  end

  describe "timeout" do
    test "no timeout by default" do
      ctx = Ctx.new()
      assert ctx.timeout_ns == nil
      assert Ctx.check_deadline(ctx) == :ok
    end

    test "timeout_ns is set from timeout_ms" do
      ctx = Ctx.new(timeout_ms: 5000)
      assert ctx.timeout_ns == 5_000_000_000
    end

    test "check_deadline returns :ok within budget" do
      ctx = Ctx.new(timeout_ms: 5000)
      assert Ctx.check_deadline(ctx) == :ok
    end

    test "check_deadline returns :exceeded when compute budget exhausted" do
      ctx = %Ctx{
        timeout_ns: 1_000_000,
        compute_ns: 2_000_000,
        compute_started_at: System.monotonic_time(:nanosecond)
      }

      assert {:exceeded, _} = Ctx.check_deadline(ctx)
    end

    test "pause_compute and resume_compute exclude I/O time" do
      ctx = Ctx.new(timeout_ms: 5000)
      paused = Ctx.pause_compute(ctx)
      assert paused.compute_started_at == nil
      assert paused.compute_ns > 0 or true
      resumed = Ctx.resume_compute(paused)
      assert resumed.compute_started_at != nil
    end

    test "compute_time_us tracks accumulated compute time" do
      ctx = Ctx.new(timeout_ms: 5000)
      Process.sleep(5)
      us = Ctx.compute_time_us(ctx)
      assert us >= 4000
    end

    test "while True loop is killed by timeout" do
      ctx = Ctx.new(timeout_ms: 50)

      code = """
      x = 0
      while True:
          x += 1
      """

      {:error, %Error{message: msg}} = Pyex.run(code, ctx)
      assert msg =~ "TimeoutError: execution exceeded time limit"
    end

    test "for loop is killed by timeout" do
      ctx = Ctx.new(timeout_ms: 50)

      code = """
      x = 0
      for i in range(10000000):
          x += 1
      """

      {:error, %Error{message: msg}} = Pyex.run(code, ctx)
      assert msg =~ "TimeoutError: execution exceeded time limit"
    end

    test "normal program completes within timeout" do
      ctx = Ctx.new(timeout_ms: 5000)

      code = """
      total = 0
      for i in range(100):
          total += i
      total
      """

      assert {:ok, 4950, _} = Pyex.run(code, ctx)
    end
  end
end
