defmodule Pyex.Stdlib.TimeTest do
  use ExUnit.Case, async: true

  describe "time.time" do
    test "returns a float" do
      result =
        Pyex.run!("""
        import time
        time.time()
        """)

      assert is_float(result)
      assert result > 1_000_000_000
    end
  end

  describe "time.time_ns" do
    test "returns an integer in nanoseconds" do
      result =
        Pyex.run!("""
        import time
        time.time_ns()
        """)

      assert is_integer(result)
      assert result > 1_000_000_000_000_000_000
    end
  end

  describe "time.monotonic" do
    test "returns a float" do
      result =
        Pyex.run!("""
        import time
        time.monotonic()
        """)

      assert is_float(result)
    end
  end

  describe "time.sleep" do
    test "sleeps and returns None" do
      result =
        Pyex.run!("""
        import time
        time.sleep(0.001)
        """)

      assert result == nil
    end
  end

  describe "time ordering" do
    test "time() increases between calls" do
      result =
        Pyex.run!("""
        import time
        t1 = time.time()
        time.sleep(0.01)
        t2 = time.time()
        t2 > t1
        """)

      assert result == true
    end

    test "monotonic() increases between calls" do
      result =
        Pyex.run!("""
        import time
        t1 = time.monotonic()
        time.sleep(0.01)
        t2 = time.monotonic()
        t2 > t1
        """)

      assert result == true
    end

    test "time_ns() increases between calls" do
      result =
        Pyex.run!("""
        import time
        t1 = time.time_ns()
        time.sleep(0.01)
        t2 = time.time_ns()
        t2 > t1
        """)

      assert result == true
    end
  end
end
