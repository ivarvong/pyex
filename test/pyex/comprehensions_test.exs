defmodule Pyex.ComprehensionsTest do
  use ExUnit.Case, async: true

  describe "list comprehension" do
    test "simple comprehension" do
      assert Pyex.run!("[x * 2 for x in [1, 2, 3]]") == [2, 4, 6]
    end

    test "comprehension with filter" do
      assert Pyex.run!("[x for x in [1, 2, 3, 4, 5] if x > 3]") == [4, 5]
    end

    test "comprehension with expression and filter" do
      assert Pyex.run!("[x * x for x in range(6) if x % 2 == 0]") == [0, 4, 16]
    end

    test "comprehension over string" do
      assert Pyex.run!("[ch for ch in \"hello\"]") == ["h", "e", "l", "l", "o"]
    end

    test "comprehension over range" do
      assert Pyex.run!("[i for i in range(5)]") == [0, 1, 2, 3, 4]
    end

    test "comprehension with function call" do
      result =
        Pyex.run!("""
        def square(n):
            return n * n

        [square(x) for x in [1, 2, 3, 4]]
        """)

      assert result == [1, 4, 9, 16]
    end

    test "comprehension assigned to variable" do
      result =
        Pyex.run!("""
        squares = [x * x for x in range(5)]
        squares
        """)

      assert result == [0, 1, 4, 9, 16]
    end
  end

  describe "dict comprehension" do
    test "basic dict comprehension" do
      assert Pyex.run!("{x: x**2 for x in range(4)}") == %{0 => 0, 1 => 1, 2 => 4, 3 => 9}
    end

    test "dict comprehension with filter" do
      assert Pyex.run!("{x: x**2 for x in range(6) if x % 2 == 0}") ==
               %{0 => 0, 2 => 4, 4 => 16}
    end

    test "dict comprehension with tuple unpacking" do
      assert Pyex.run!(~s|{k: v * 2 for k, v in {"a": 1, "b": 2}.items()}|) ==
               %{"a" => 2, "b" => 4}
    end

    test "dict comprehension from list" do
      assert Pyex.run!(~s|{s: len(s) for s in ["hi", "world"]}|) ==
               %{"hi" => 2, "world" => 5}
    end
  end

  describe "set comprehension" do
    test "basic set comprehension" do
      result = Pyex.run!("{x * 2 for x in [1, 2, 3]}")
      assert result == {:set, MapSet.new([2, 4, 6])}
    end

    test "set comprehension with filter" do
      result = Pyex.run!("{x for x in range(10) if x % 2 == 0}")
      assert result == {:set, MapSet.new([0, 2, 4, 6, 8])}
    end

    test "set comprehension deduplicates" do
      result = Pyex.run!("{x % 3 for x in range(9)}")
      assert result == {:set, MapSet.new([0, 1, 2])}
    end

    test "set comprehension over string" do
      result = Pyex.run!("{ch for ch in \"hello\"}")
      assert result == {:set, MapSet.new(["h", "e", "l", "o"])}
    end

    test "set comprehension with tuple unpacking" do
      result = Pyex.run!(~s|{k for k, v in {"a": 1, "b": 2}.items()}|)
      assert result == {:set, MapSet.new(["a", "b"])}
    end

    test "set comprehension assigned to variable" do
      result =
        Pyex.run!("""
        evens = {x for x in range(10) if x % 2 == 0}
        sorted(evens)
        """)

      assert result == [0, 2, 4, 6, 8]
    end
  end

  describe "nested comprehensions" do
    test "flatten nested list" do
      assert Pyex.run!("[x for row in [[1, 2], [3, 4], [5]] for x in row]") ==
               [1, 2, 3, 4, 5]
    end

    test "nested with filter on inner" do
      assert Pyex.run!("[x for row in [[1, 2, 3], [4, 5, 6]] for x in row if x % 2 == 0]") ==
               [2, 4, 6]
    end

    test "nested with filter on outer" do
      code = "[x for row in [[1, 2], [], [3, 4]] if len(row) > 0 for x in row]"
      assert Pyex.run!(code) == [1, 2, 3, 4]
    end

    test "nested with expression" do
      assert Pyex.run!("[x * 2 for row in [[1, 2], [3]] for x in row]") == [2, 4, 6]
    end

    test "triple nesting" do
      code = """
      matrix = [[[1, 2], [3]], [[4], [5, 6]]]
      [x for plane in matrix for row in plane for x in row]
      """

      assert Pyex.run!(code) == [1, 2, 3, 4, 5, 6]
    end

    test "nested list comp with range" do
      assert Pyex.run!("[(i, j) for i in range(3) for j in range(2)]") ==
               [
                 {:tuple, [0, 0]},
                 {:tuple, [0, 1]},
                 {:tuple, [1, 0]},
                 {:tuple, [1, 1]},
                 {:tuple, [2, 0]},
                 {:tuple, [2, 1]}
               ]
    end

    test "nested dict comprehension" do
      code = ~s|{k: v for d in [{"a": 1}, {"b": 2}] for k, v in d.items()}|
      assert Pyex.run!(code) == %{"a" => 1, "b" => 2}
    end

    test "nested set comprehension" do
      result = Pyex.run!("{x for row in [[1, 2, 2], [3, 1]] for x in row}")
      assert result == {:set, MapSet.new([1, 2, 3])}
    end

    test "nested generator expression" do
      assert Pyex.run!("list(x for row in [[1, 2], [3]] for x in row)") == [1, 2, 3]
    end

    test "nested gen expr as function argument" do
      assert Pyex.run!("sum(x for row in [[1, 2], [3, 4]] for x in row)") == 10
    end

    test "nested comprehension with tuple unpacking" do
      code = """
      pairs = [[(1, "a"), (2, "b")], [(3, "c")]]
      [v for group in pairs for k, v in group]
      """

      assert Pyex.run!(code) == ["a", "b", "c"]
    end

    test "nested comprehension with multiple filters" do
      code = "[x for row in [[1,2,3],[4,5,6]] if len(row) == 3 for x in row if x > 2]"
      assert Pyex.run!(code) == [3, 4, 5, 6]
    end
  end
end
