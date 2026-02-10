defmodule Pyex.Stdlib.ItertoolsTest do
  use ExUnit.Case, async: true

  describe "chain" do
    test "chains multiple iterables" do
      result =
        Pyex.run!("""
        from itertools import chain
        list(chain([1, 2], [3, 4], [5]))
        """)

      assert result == [1, 2, 3, 4, 5]
    end

    test "chains strings" do
      result =
        Pyex.run!("""
        from itertools import chain
        list(chain("ab", "cd"))
        """)

      assert result == ["a", "b", "c", "d"]
    end

    test "chains empty iterables" do
      result =
        Pyex.run!("""
        from itertools import chain
        list(chain([], [1], []))
        """)

      assert result == [1]
    end

    test "chain with no args" do
      result =
        Pyex.run!("""
        from itertools import chain
        list(chain())
        """)

      assert result == []
    end
  end

  describe "chain_from_iterable" do
    test "flattens iterable of iterables" do
      result =
        Pyex.run!("""
        from itertools import chain_from_iterable
        list(chain_from_iterable([[1, 2], [3, 4], [5]]))
        """)

      assert result == [1, 2, 3, 4, 5]
    end
  end

  describe "islice" do
    test "slices with stop only" do
      result =
        Pyex.run!("""
        from itertools import islice
        list(islice([0, 1, 2, 3, 4], 3))
        """)

      assert result == [0, 1, 2]
    end

    test "slices with start and stop" do
      result =
        Pyex.run!("""
        from itertools import islice
        list(islice([0, 1, 2, 3, 4], 1, 4))
        """)

      assert result == [1, 2, 3]
    end

    test "slices with start, stop, and step" do
      result =
        Pyex.run!("""
        from itertools import islice
        list(islice(range(10), 0, 10, 2))
        """)

      assert result == [0, 2, 4, 6, 8]
    end

    test "islice with None stop" do
      result =
        Pyex.run!("""
        from itertools import islice
        list(islice([0, 1, 2, 3], 2, None))
        """)

      assert result == [2, 3]
    end
  end

  describe "product" do
    test "cartesian product of two lists" do
      result =
        Pyex.run!("""
        from itertools import product
        list(product([1, 2], [3, 4]))
        """)

      assert result == [
               {:tuple, [1, 3]},
               {:tuple, [1, 4]},
               {:tuple, [2, 3]},
               {:tuple, [2, 4]}
             ]
    end

    test "product with repeat" do
      result =
        Pyex.run!("""
        from itertools import product
        list(product([0, 1], repeat=2))
        """)

      assert result == [
               {:tuple, [0, 0]},
               {:tuple, [0, 1]},
               {:tuple, [1, 0]},
               {:tuple, [1, 1]}
             ]
    end

    test "product of single iterable" do
      result =
        Pyex.run!("""
        from itertools import product
        list(product("ab"))
        """)

      assert result == [{:tuple, ["a"]}, {:tuple, ["b"]}]
    end

    test "product with empty iterable" do
      result =
        Pyex.run!("""
        from itertools import product
        list(product([1, 2], []))
        """)

      assert result == []
    end
  end

  describe "permutations" do
    test "full permutations" do
      result =
        Pyex.run!("""
        from itertools import permutations
        list(permutations([1, 2, 3]))
        """)

      assert length(result) == 6
      assert {:tuple, [1, 2, 3]} in result
      assert {:tuple, [3, 2, 1]} in result
    end

    test "r-length permutations" do
      result =
        Pyex.run!("""
        from itertools import permutations
        list(permutations([1, 2, 3], 2))
        """)

      assert length(result) == 6
      assert {:tuple, [1, 2]} in result
      assert {:tuple, [2, 1]} in result
    end

    test "permutations with r > n" do
      result =
        Pyex.run!("""
        from itertools import permutations
        list(permutations([1, 2], 3))
        """)

      assert result == []
    end
  end

  describe "combinations" do
    test "2-combinations of 4 items" do
      result =
        Pyex.run!("""
        from itertools import combinations
        list(combinations([1, 2, 3, 4], 2))
        """)

      assert length(result) == 6
      assert {:tuple, [1, 2]} in result
      assert {:tuple, [3, 4]} in result
    end

    test "combinations with r=0" do
      result =
        Pyex.run!("""
        from itertools import combinations
        list(combinations([1, 2], 0))
        """)

      assert result == [{:tuple, []}]
    end

    test "combinations with r > n" do
      result =
        Pyex.run!("""
        from itertools import combinations
        list(combinations([1, 2], 3))
        """)

      assert result == []
    end
  end

  describe "combinations_with_replacement" do
    test "2-combinations with replacement from 3 items" do
      result =
        Pyex.run!("""
        from itertools import combinations_with_replacement
        list(combinations_with_replacement([1, 2, 3], 2))
        """)

      assert {:tuple, [1, 1]} in result
      assert {:tuple, [1, 2]} in result
      assert {:tuple, [2, 2]} in result
      assert length(result) == 6
    end
  end

  describe "repeat" do
    test "repeat with count" do
      result =
        Pyex.run!("""
        from itertools import repeat
        list(repeat(42, 3))
        """)

      assert result == [42, 42, 42]
    end

    test "repeat with zero count" do
      result =
        Pyex.run!("""
        from itertools import repeat
        list(repeat("x", 0))
        """)

      assert result == []
    end
  end

  describe "compress" do
    test "filters by selectors" do
      result =
        Pyex.run!("""
        from itertools import compress
        list(compress("ABCDEF", [1, 0, 1, 0, 1, 1]))
        """)

      assert result == ["A", "C", "E", "F"]
    end

    test "compress with boolean selectors" do
      result =
        Pyex.run!("""
        from itertools import compress
        list(compress([10, 20, 30], [True, False, True]))
        """)

      assert result == [10, 30]
    end
  end

  describe "pairwise" do
    test "adjacent pairs" do
      result =
        Pyex.run!("""
        from itertools import pairwise
        list(pairwise([1, 2, 3, 4]))
        """)

      assert result == [
               {:tuple, [1, 2]},
               {:tuple, [2, 3]},
               {:tuple, [3, 4]}
             ]
    end

    test "pairwise of short list" do
      result =
        Pyex.run!("""
        from itertools import pairwise
        list(pairwise([1]))
        """)

      assert result == []
    end
  end

  describe "zip_longest" do
    test "pads shorter iterables with None" do
      result =
        Pyex.run!("""
        from itertools import zip_longest
        list(zip_longest([1, 2, 3], [4, 5]))
        """)

      assert result == [
               {:tuple, [1, 4]},
               {:tuple, [2, 5]},
               {:tuple, [3, nil]}
             ]
    end

    test "pads with custom fillvalue" do
      result =
        Pyex.run!("""
        from itertools import zip_longest
        list(zip_longest([1, 2, 3], [4], fillvalue=0))
        """)

      assert result == [
               {:tuple, [1, 4]},
               {:tuple, [2, 0]},
               {:tuple, [3, 0]}
             ]
    end
  end

  describe "accumulate" do
    test "running sum" do
      result =
        Pyex.run!("""
        from itertools import accumulate
        list(accumulate([1, 2, 3, 4, 5]))
        """)

      assert result == [1, 3, 6, 10, 15]
    end

    test "accumulate with function" do
      result =
        Pyex.run!("""
        from itertools import accumulate
        list(accumulate([1, 2, 3, 4], lambda x, y: x * y))
        """)

      assert result == [1, 2, 6, 24]
    end

    test "accumulate with initial value" do
      result =
        Pyex.run!("""
        from itertools import accumulate
        list(accumulate([1, 2, 3], initial=10))
        """)

      assert result == [10, 11, 13, 16]
    end

    test "accumulate empty" do
      result =
        Pyex.run!("""
        from itertools import accumulate
        list(accumulate([]))
        """)

      assert result == []
    end
  end

  describe "count" do
    test "count from 0" do
      result =
        Pyex.run!("""
        from itertools import count, islice
        list(islice(count(), 5))
        """)

      assert result == [0, 1, 2, 3, 4]
    end

    test "count from start" do
      result =
        Pyex.run!("""
        from itertools import count, islice
        list(islice(count(10), 3))
        """)

      assert result == [10, 11, 12]
    end

    test "count with step" do
      result =
        Pyex.run!("""
        from itertools import count, islice
        list(islice(count(0, 2), 4))
        """)

      assert result == [0, 2, 4, 6]
    end
  end

  describe "cycle" do
    test "cycle with islice" do
      result =
        Pyex.run!("""
        from itertools import cycle, islice
        list(islice(cycle([1, 2, 3]), 7))
        """)

      assert result == [1, 2, 3, 1, 2, 3, 1]
    end
  end

  describe "starmap" do
    test "applies function to unpacked args" do
      result =
        Pyex.run!("""
        from itertools import starmap
        list(starmap(pow, [(2, 5), (3, 2), (10, 3)]))
        """)

      assert result == [32, 9, 1000]
    end

    test "starmap with lambda" do
      result =
        Pyex.run!("""
        from itertools import starmap
        list(starmap(lambda x, y: x + y, [(1, 2), (3, 4), (5, 6)]))
        """)

      assert result == [3, 7, 11]
    end
  end

  describe "takewhile" do
    test "takes while predicate is true" do
      result =
        Pyex.run!("""
        from itertools import takewhile
        list(takewhile(lambda x: x < 5, [1, 3, 5, 2, 4]))
        """)

      assert result == [1, 3]
    end

    test "takewhile all true" do
      result =
        Pyex.run!("""
        from itertools import takewhile
        list(takewhile(lambda x: x > 0, [1, 2, 3]))
        """)

      assert result == [1, 2, 3]
    end
  end

  describe "dropwhile" do
    test "drops while predicate is true" do
      result =
        Pyex.run!("""
        from itertools import dropwhile
        list(dropwhile(lambda x: x < 5, [1, 3, 5, 2, 4]))
        """)

      assert result == [5, 2, 4]
    end
  end

  describe "filterfalse" do
    test "keeps items where predicate is false" do
      result =
        Pyex.run!("""
        from itertools import filterfalse
        list(filterfalse(lambda x: x % 2, range(10)))
        """)

      assert result == [0, 2, 4, 6, 8]
    end
  end

  describe "groupby" do
    test "groups consecutive equal elements" do
      result =
        Pyex.run!("""
        from itertools import groupby
        [(k, list(g)) for k, g in groupby([1, 1, 2, 2, 2, 3])]
        """)

      assert result == [
               {:tuple, [1, [1, 1]]},
               {:tuple, [2, [2, 2, 2]]},
               {:tuple, [3, [3]]}
             ]
    end

    test "groupby with key function" do
      result =
        Pyex.run!("""
        from itertools import groupby
        data = ["aa", "ab", "bc", "bd", "ca"]
        [(k, list(g)) for k, g in groupby(data, lambda x: x[0])]
        """)

      assert result == [
               {:tuple, ["a", ["aa", "ab"]]},
               {:tuple, ["b", ["bc", "bd"]]},
               {:tuple, ["c", ["ca"]]}
             ]
    end
  end

  describe "tee" do
    test "duplicates an iterable" do
      result =
        Pyex.run!("""
        from itertools import tee
        a, b = tee([1, 2, 3])
        (list(a), list(b))
        """)

      assert result == {:tuple, [[1, 2, 3], [1, 2, 3]]}
    end

    test "tee with n" do
      result =
        Pyex.run!("""
        from itertools import tee
        copies = tee([1, 2], 3)
        len(copies)
        """)

      assert result == 3
    end
  end

  describe "import styles" do
    test "import itertools" do
      result =
        Pyex.run!("""
        import itertools
        list(itertools.chain([1], [2]))
        """)

      assert result == [1, 2]
    end

    test "from itertools import multiple" do
      result =
        Pyex.run!("""
        from itertools import chain, islice, repeat
        list(islice(chain(repeat(1, 3), repeat(2, 3)), 5))
        """)

      assert result == [1, 1, 1, 2, 2]
    end
  end
end
