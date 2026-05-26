defmodule Pyex.LimitsTest do
  use ExUnit.Case, async: true

  alias Pyex.Limits

  describe "safe-by-default ceilings" do
    test "a bare struct carries the safe finite defaults" do
      assert %Limits{
               timeout: :infinity,
               max_steps: 10_000_000,
               max_memory_bytes: 50_000_000,
               max_output_bytes: 1_000_000
             } = %Limits{}
    end

    test "new/0 matches the bare struct" do
      assert Limits.new() == %Limits{}
    end
  end

  describe "new/1 is additive" do
    test "unspecified fields keep their safe defaults rather than going unbounded" do
      limits = Limits.new(max_steps: 1_000)

      assert limits.max_steps == 1_000
      # The point of safe-by-default: setting one ceiling does not lift the others.
      assert limits.max_memory_bytes == 50_000_000
      assert limits.max_output_bytes == 1_000_000
    end

    test "a single ceiling can be lifted explicitly with :infinity" do
      limits = Limits.new(max_steps: 1_000, max_memory_bytes: :infinity)

      assert limits.max_steps == 1_000
      assert limits.max_memory_bytes == :infinity
      assert limits.max_output_bytes == 1_000_000
    end

    test "rejects unknown keys" do
      assert_raise ArgumentError, ~r/unknown limit options \[:max_foo\]/, fn ->
        Limits.new(max_foo: 1)
      end
    end
  end

  describe "unbounded/0 escape hatch" do
    test "lifts every ceiling" do
      assert %Limits{
               timeout: :infinity,
               max_steps: :infinity,
               max_memory_bytes: :infinity,
               max_output_bytes: :infinity
             } = Limits.unbounded()
    end
  end

  describe "end-to-end through Pyex.run/2" do
    test "default run bounds output (no opts) — a print flood is stopped, not hung" do
      # 1 MB default output ceiling: 200k lines of ~12 bytes each blows past it.
      {:error, %Pyex.Error{kind: :limit, limit: :output}} =
        Pyex.run("for i in range(200000):\n    print('x' * 10)")
    end

    test "limits: :none lifts the default ceilings" do
      # The same flood completes once ceilings are explicitly lifted.
      assert {:ok, _val, ctx} =
               Pyex.run("for i in range(200000):\n    print('x' * 10)", limits: :none)

      # No-budget fast path: steps do not advance.
      assert ctx.steps == 0
    end

    test "partial limits remain additive through run/2" do
      # Output ceiling left at the 1 MB default still trips even though the
      # caller only set a (very high) step limit.
      {:error, %Pyex.Error{kind: :limit, limit: :output}} =
        Pyex.run("for i in range(200000):\n    print('x' * 10)",
          limits: [max_steps: 1_000_000_000]
        )
    end
  end
end
