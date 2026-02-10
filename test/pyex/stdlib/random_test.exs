defmodule Pyex.Stdlib.RandomTest do
  use ExUnit.Case, async: true

  describe "random.seed + random.randint" do
    test "returns deterministic integers after seed" do
      result =
        Pyex.run!("""
        import random
        random.seed(42)
        random.randint(1, 100)
        """)

      assert is_integer(result)
      assert result >= 1 and result <= 100
    end

    test "returns same value given same seed" do
      code = """
      import random
      random.seed(99)
      random.randint(0, 1000)
      """

      a = Pyex.run!(code)
      b = Pyex.run!(code)
      assert a == b
    end
  end

  describe "random.random" do
    test "returns a float between 0 and 1" do
      result =
        Pyex.run!("""
        import random
        random.seed(1)
        random.random()
        """)

      assert is_float(result)
      assert result >= 0.0 and result < 1.0
    end
  end

  describe "random.choice" do
    test "picks an element from a list" do
      result =
        Pyex.run!("""
        import random
        random.seed(7)
        random.choice([10, 20, 30])
        """)

      assert result in [10, 20, 30]
    end

    test "picks a character from a string" do
      result =
        Pyex.run!("""
        import random
        random.seed(3)
        random.choice("abc")
        """)

      assert result in ["a", "b", "c"]
    end

    test "raises on empty sequence" do
      assert_raise RuntimeError, ~r/IndexError/, fn ->
        Pyex.run!("""
        import random
        random.choice([])
        """)
      end
    end
  end

  describe "random.shuffle" do
    test "returns a shuffled list" do
      result =
        Pyex.run!("""
        import random
        random.seed(5)
        random.shuffle([1, 2, 3, 4, 5])
        """)

      assert is_list(result)
      assert Enum.sort(result) == [1, 2, 3, 4, 5]
    end
  end

  describe "random.randrange" do
    test "single arg returns 0..stop-1" do
      result =
        Pyex.run!("""
        import random
        random.seed(10)
        random.randrange(5)
        """)

      assert is_integer(result)
      assert result >= 0 and result < 5
    end

    test "two args returns start..stop-1" do
      result =
        Pyex.run!("""
        import random
        random.seed(10)
        random.randrange(10, 20)
        """)

      assert is_integer(result)
      assert result >= 10 and result < 20
    end
  end

  describe "random.sample" do
    test "returns k unique elements" do
      result =
        Pyex.run!("""
        import random
        random.seed(0)
        random.sample([1, 2, 3, 4, 5], 3)
        """)

      assert is_list(result)
      assert length(result) == 3
      assert Enum.all?(result, &(&1 in [1, 2, 3, 4, 5]))
      assert result == Enum.uniq(result)
    end

    test "raises when k > population" do
      assert_raise RuntimeError, ~r/ValueError/, fn ->
        Pyex.run!("""
        import random
        random.sample([1, 2], 5)
        """)
      end
    end
  end

  describe "random.uniform" do
    test "returns float in range" do
      result =
        Pyex.run!("""
        import random
        random.seed(1)
        random.uniform(2.0, 5.0)
        """)

      assert is_float(result)
      assert result >= 2.0 and result <= 5.0
    end
  end
end
