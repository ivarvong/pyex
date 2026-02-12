defmodule Pyex.ProfileTest do
  @moduledoc """
  Tests for opt-in execution profiling.

  When `profile: true` is passed, the returned context
  contains per-line execution counts and per-function
  call counts with timing.
  """
  use ExUnit.Case, async: true

  describe "profiling disabled (default)" do
    test "profile is nil when not requested" do
      {:ok, _val, ctx} = Pyex.run("x = 1 + 2")
      assert ctx.profile == nil
    end
  end

  describe "line counts" do
    test "counts each line execution" do
      {:ok, _val, ctx} =
        Pyex.run(
          """
          x = 1
          y = 2
          z = x + y
          """,
          profile: true
        )

      %{line_counts: lines} = ctx.profile
      assert lines[1] == 1
      assert lines[2] == 1
      assert lines[3] == 1
    end

    test "loop body lines count multiple times" do
      {:ok, _val, ctx} =
        Pyex.run(
          """
          total = 0
          for i in range(5):
              total += i
          """,
          profile: true
        )

      %{line_counts: lines} = ctx.profile
      assert lines[1] == 1
      assert lines[3] >= 5
    end

    test "if/else only counts taken branch" do
      {:ok, _val, ctx} =
        Pyex.run(
          """
          x = 10
          if x > 5:
              result = "big"
          else:
              result = "small"
          """,
          profile: true
        )

      %{line_counts: lines} = ctx.profile
      assert lines[3] == 1
      assert Map.get(lines, 5, 0) == 0
    end
  end

  describe "function call counts and timing" do
    test "counts function calls" do
      {:ok, _val, ctx} =
        Pyex.run(
          """
          def add(a, b):
              return a + b
          add(1, 2)
          add(3, 4)
          add(5, 6)
          """,
          profile: true
        )

      %{call_counts: calls} = ctx.profile
      assert calls["add"] == 3
    end

    test "tracks timing per function" do
      {:ok, _val, ctx} =
        Pyex.run(
          """
          def work(n):
              total = 0
              for i in range(n):
                  total += i
              return total
          work(100)
          """,
          profile: true
        )

      %{call_us: timing} = ctx.profile
      assert is_integer(timing["work"])
      assert timing["work"] >= 0
    end

    test "accumulates time across multiple calls" do
      {:ok, _val, ctx} =
        Pyex.run(
          """
          def compute(n):
              total = 0
              for i in range(n):
                  total += i
              return total
          for _ in range(10):
              compute(50)
          """,
          profile: true
        )

      %{call_counts: calls, call_us: timing} = ctx.profile
      assert calls["compute"] == 10
      assert timing["compute"] > 0
    end

    test "tracks nested function calls separately" do
      {:ok, _val, ctx} =
        Pyex.run(
          """
          def inner():
              return 42
          def outer():
              return inner()
          outer()
          """,
          profile: true
        )

      %{call_counts: calls} = ctx.profile
      assert calls["inner"] == 1
      assert calls["outer"] == 1
    end
  end

  describe "profile data structure" do
    test "has all expected keys" do
      {:ok, _val, ctx} = Pyex.run("x = 1", profile: true)
      profile = ctx.profile
      assert is_map(profile)
      assert Map.has_key?(profile, :line_counts)
      assert Map.has_key?(profile, :call_counts)
      assert Map.has_key?(profile, :call_us)
    end

    test "empty program has empty call maps" do
      {:ok, _val, ctx} = Pyex.run("x = 1", profile: true)
      %{call_counts: calls, call_us: timing} = ctx.profile
      assert calls == %{}
      assert timing == %{}
    end
  end

  describe "no overhead when disabled" do
    test "profile stays nil through complex execution" do
      {:ok, _val, ctx} =
        Pyex.run("""
        def fib(n):
            if n < 2:
                return n
            return fib(n - 1) + fib(n - 2)
        fib(10)
        """)

      assert ctx.profile == nil
    end
  end
end
