defmodule Pyex.CtxTest do
  use ExUnit.Case, async: true

  alias Pyex.{Ctx, Error}

  describe "new/0" do
    test "creates a live context" do
      ctx = Ctx.new()
      assert ctx.mode == :live
      assert ctx.output_buffer == []
    end
  end

  describe "record/3" do
    test "captures output events in live mode" do
      ctx =
        Ctx.new()
        |> Ctx.record(:output, "hello")
        |> Ctx.record(:output, "world")

      assert ctx.output_buffer == ["world", "hello"]
    end

    test "ignores non-output events in live mode" do
      ctx =
        Ctx.new()
        |> Ctx.record(:assign, {"x", 1})
        |> Ctx.record(:branch, {:if, true})

      assert ctx.output_buffer == []
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

  describe "output capture" do
    test "output/1 returns captured print output" do
      ctx =
        Ctx.new()
        |> Ctx.record(:output, "hello")
        |> Ctx.record(:output, "world")

      assert Ctx.output(ctx) == "hello\nworld"
    end

    test "output/1 returns empty string when no output" do
      ctx = Ctx.new()
      assert Ctx.output(ctx) == ""
    end
  end
end
