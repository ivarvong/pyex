defmodule Pyex.GeneratorDifferentialTest do
  @moduledoc """
  Trace-level differential + metamorphic + complexity tests for the generator
  engine, built on `Pyex.Test.GeneratorOracle`.

  Unlike the value-level differential fuzzer, this drives the full generator
  protocol (`next`/`send`/`throw`/`close`) against randomly generated bodies
  and compares the *interleaved trace* of side effects and op results against
  CPython — the observable that the eager engine's bugs (ordering, throw at a
  boundary, `send` through `yield from`) actually showed up in.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pyex.Test.GeneratorOracle, as: GO

  @moduletag :requires_python3

  setup_all do
    if GO.python3_available?() do
      :ok
    else
      {:skip, "python3 not found on PATH"}
    end
  end

  describe "trace-level differential vs CPython" do
    property "random body x random driver produce identical interleaved traces" do
      check all(body <- GO.gen_body(), driver <- GO.gen_driver(), max_runs: 250) do
        GO.assert_trace_conforms(GO.render(body, driver))
      end
    end
  end

  describe "metamorphic equivalence (oracle-free engine invariant + vs CPython)" do
    property "list(g) == [x for x in g] == manual next-loop" do
      check all(body <- GO.gen_pure_body(), max_runs: 200) do
        GO.assert_metamorphic(body)
      end
    end
  end

  describe "seeded regressions (the four divergences that motivated the lazy engine)" do
    test "side-effect ordering: nothing before the first yield runs at creation" do
      body = [{:log, 1}, {:yield, 2}, {:log, 3}, {:yield, 4}]
      GO.assert_trace_conforms(GO.render(body, [:next, :next, :next]))
    end

    test "throw lands in the except around the paused yield (incl. last-in-try)" do
      body = [{:try_except, "ValueError", [{:yield, 1}], [{:yield, 99}]}]
      GO.assert_trace_conforms(GO.render(body, [:next, {:throw, "ValueError"}, :next]))
    end

    test "close runs finally lazily" do
      body = [{:try_finally, [{:yield, 1}, {:yield, 2}], [{:log, 99}]}]
      GO.assert_trace_conforms(GO.render(body, [:next, :close]))
    end

    test "send routes through yield from into the sub-generator" do
      body = [{:yield_from, [{:recv, 1}, {:recv, 2}], 7}]
      GO.assert_trace_conforms(GO.render(body, [:next, {:send, 10}, {:send, 20}, :next]))
    end

    test "send threads through a for-loop inside a try to the paused yield" do
      body = [{:try_finally, [{:for, 2, [{:recv, 0}]}], [{:log, 9}]}]
      GO.assert_trace_conforms(GO.render(body, [:next, {:send, 1}, {:send, 2}, :next]))
    end
  end

  describe "complexity invariant: draining N items is linear in N" do
    # A super-linear step count means the engine is re-executing work per step
    # (the eager-lookahead failure mode). Comparing step *ratios* across sizes
    # is runner-independent — unlike the wall-clock timeout that flaked on CI.
    defp linear_ratio(make_src) do
      s1 = GO.drain_steps(make_src.(250))
      s2 = GO.drain_steps(make_src.(1000))
      s2 / s1
    end

    test "flat generator drained by a for-loop" do
      ratio =
        linear_ratio(fn n ->
          """
          def g():
              for i in range(#{n}):
                  yield i
          total = 0
          for x in g():
              total += x
          print(total)
          """
        end)

      # 4x the work should cost ~4x the steps; assert well under quadratic (16x).
      assert ratio < 6.0,
             "step count scaled #{Float.round(ratio, 2)}x for 4x input (expected ~4x)"
    end

    test "yield-from delegation drained by a for-loop" do
      ratio =
        linear_ratio(fn n ->
          """
          def inner(n):
              for i in range(n):
                  yield i
          def outer(n):
              yield from inner(n)
          total = 0
          for x in outer(#{n}):
              total += x
          print(total)
          """
        end)

      assert ratio < 6.0,
             "yield-from scaled #{Float.round(ratio, 2)}x for 4x input (expected ~4x)"
    end
  end
end
