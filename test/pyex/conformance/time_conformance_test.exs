defmodule Pyex.Conformance.TimeTest do
  @moduledoc """
  Conformance tests for the `time` module.

  Time values differ between Pyex and CPython by definition, so these
  tests assert bounds, types, and monotonicity rather than byte-equal
  output.
  """

  use ExUnit.Case, async: true

  describe "time.time" do
    test "returns a positive float" do
      result =
        Pyex.run!("""
        import time
        t = time.time()
        [isinstance(t, float), t > 0]
        """)

      assert result == [true, true]
    end

    test "increases monotonically across successive calls (usually)" do
      result =
        Pyex.run!("""
        import time
        a = time.time()
        b = time.time()
        b >= a
        """)

      assert result == true
    end
  end

  describe "time.monotonic" do
    test "returns a float and is non-decreasing" do
      result =
        Pyex.run!("""
        import time
        a = time.monotonic()
        b = time.monotonic()
        [isinstance(a, float), b >= a]
        """)

      assert result == [true, true]
    end
  end

  describe "time.time_ns" do
    test "returns an int" do
      result =
        Pyex.run!("""
        import time
        t = time.time_ns()
        [isinstance(t, int), t > 0]
        """)

      assert result == [true, true]
    end
  end

  describe "time.sleep" do
    test "sleep(0) returns None" do
      result =
        Pyex.run!("""
        import time
        time.sleep(0)
        """)

      assert result == nil
    end

    test "sleep(0.001) elapses at least ~1ms" do
      result =
        Pyex.run!("""
        import time
        a = time.time()
        time.sleep(0.01)
        b = time.time()
        (b - a) >= 0.005
        """)

      assert result == true
    end
  end

  describe "time.perf_counter" do
    test "returns a float and is non-decreasing" do
      result =
        Pyex.run!("""
        import time
        a = time.perf_counter()
        b = time.perf_counter()
        [isinstance(a, float), b >= a]
        """)

      assert result == [true, true]
    end
  end
end
