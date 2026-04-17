defmodule Pyex.Conformance.RandomTest do
  @moduledoc """
  Conformance tests for the `random` module.

  Pyex's `random` uses Erlang's `:rand`, which doesn't produce
  byte-identical output against CPython's Mersenne Twister even with
  the same seed.  So these tests assert *properties* that must hold
  across implementations: ranges, types, membership, and the shape of
  return values.  Wherever possible we test against CPython too, using
  constraints rather than exact matches.
  """

  use ExUnit.Case, async: true

  describe "randint bounds" do
    test "randint(a, b) returns value in [a, b] inclusive" do
      result =
        Pyex.run!("""
        import random
        vals = [random.randint(1, 10) for _ in range(1000)]
        [min(vals), max(vals), all(isinstance(v, int) for v in vals)]
        """)

      [mn, mx, all_int] = result
      assert mn >= 1
      assert mx <= 10
      assert all_int == true
    end

    test "randint(5, 5) always returns 5" do
      result =
        Pyex.run!("""
        import random
        set(random.randint(5, 5) for _ in range(50))
        """)

      assert result == {:set, MapSet.new([5])}
    end
  end

  describe "randrange bounds" do
    test "randrange(n) returns value in [0, n)" do
      result =
        Pyex.run!("""
        import random
        vals = [random.randrange(10) for _ in range(1000)]
        [min(vals), max(vals)]
        """)

      [mn, mx] = result
      assert mn >= 0
      assert mx < 10
    end

    test "randrange(start, stop, step) respects step" do
      result =
        Pyex.run!("""
        import random
        vals = [random.randrange(0, 20, 3) for _ in range(500)]
        all(v % 3 == 0 and 0 <= v < 20 for v in vals)
        """)

      assert result == true
    end
  end

  describe "choice" do
    test "choice returns an element from the sequence" do
      result =
        Pyex.run!("""
        import random
        items = ["a", "b", "c", "d"]
        picks = [random.choice(items) for _ in range(200)]
        all(p in items for p in picks)
        """)

      assert result == true
    end

    test "choice of single element always returns it" do
      result =
        Pyex.run!("""
        import random
        set(random.choice([42]) for _ in range(50))
        """)

      assert result == {:set, MapSet.new([42])}
    end

    test "choice from empty raises IndexError" do
      {:error, err} =
        Pyex.run("""
        import random
        random.choice([])
        """)

      assert err.message =~ "IndexError"
    end
  end

  describe "shuffle" do
    test "shuffle preserves elements" do
      result =
        Pyex.run!("""
        import random
        items = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        random.shuffle(items)
        [sorted(items), len(items)]
        """)

      assert result == [[1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 10]
    end

    test "shuffle is usually reordering (not always identity)" do
      result =
        Pyex.run!("""
        import random
        original = list(range(20))
        items = list(original)
        random.shuffle(items)
        # Extremely unlikely to stay exactly identical.
        items != original
        """)

      assert result == true
    end
  end

  describe "sample" do
    test "sample returns k distinct elements" do
      result =
        Pyex.run!("""
        import random
        s = random.sample(range(100), 10)
        [len(s), len(set(s)), all(0 <= x < 100 for x in s)]
        """)

      assert result == [10, 10, true]
    end

    test "sample from list preserves membership" do
      result =
        Pyex.run!("""
        import random
        items = ["a", "b", "c", "d", "e"]
        s = random.sample(items, 3)
        [len(s), all(x in items for x in s), len(set(s))]
        """)

      assert result == [3, true, 3]
    end

    test "sample k > len raises ValueError" do
      {:error, err} =
        Pyex.run("""
        import random
        random.sample([1, 2, 3], 5)
        """)

      assert err.message =~ "ValueError"
    end
  end

  describe "uniform" do
    test "uniform(a, b) returns float in [a, b]" do
      result =
        Pyex.run!("""
        import random
        vals = [random.uniform(0.0, 1.0) for _ in range(500)]
        [min(vals) >= 0.0, max(vals) <= 1.0, all(isinstance(v, float) for v in vals)]
        """)

      assert result == [true, true, true]
    end
  end

  describe "random()" do
    test "random() returns float in [0, 1)" do
      result =
        Pyex.run!("""
        import random
        vals = [random.random() for _ in range(500)]
        [min(vals) >= 0.0, max(vals) < 1.0, all(isinstance(v, float) for v in vals)]
        """)

      assert result == [true, true, true]
    end
  end

  describe "seed determinism (Pyex only)" do
    # CPython and Pyex use different PRNGs, so we can't compare values.
    # But within Pyex, seeding with the same value should produce
    # reproducible sequences.
    test "same seed produces same sequence" do
      a =
        Pyex.run!("""
        import random
        random.seed(42)
        [random.random() for _ in range(5)]
        """)

      b =
        Pyex.run!("""
        import random
        random.seed(42)
        [random.random() for _ in range(5)]
        """)

      assert a == b
    end

    test "different seeds produce different sequences" do
      a =
        Pyex.run!("""
        import random
        random.seed(1)
        [random.random() for _ in range(5)]
        """)

      b =
        Pyex.run!("""
        import random
        random.seed(2)
        [random.random() for _ in range(5)]
        """)

      assert a != b
    end
  end
end
