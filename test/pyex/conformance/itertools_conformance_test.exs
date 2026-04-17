defmodule Pyex.Conformance.ItertoolsTest do
  @moduledoc """
  Live CPython conformance tests for the `itertools` module.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "combinatoric iterators" do
    test "product basic" do
      check!("""
      import itertools
      print(list(itertools.product([1, 2], [3, 4])))
      """)
    end

    test "product repeat" do
      check!("""
      import itertools
      print(list(itertools.product([0, 1], repeat=3)))
      """)
    end

    test "permutations basic" do
      check!("""
      import itertools
      print(list(itertools.permutations([1, 2, 3])))
      """)
    end

    test "permutations with r" do
      check!("""
      import itertools
      print(list(itertools.permutations([1, 2, 3, 4], 2)))
      """)
    end

    test "combinations" do
      check!("""
      import itertools
      print(list(itertools.combinations([1, 2, 3, 4], 2)))
      """)
    end

    test "combinations_with_replacement" do
      check!("""
      import itertools
      print(list(itertools.combinations_with_replacement([1, 2, 3], 2)))
      """)
    end
  end

  describe "infinite iterators (bounded with islice/take)" do
    test "count default via islice" do
      check!("""
      import itertools
      print(list(itertools.islice(itertools.count(), 5)))
      """)
    end

    test "count with start and step via islice" do
      check!("""
      import itertools
      print(list(itertools.islice(itertools.count(10, 3), 5)))
      """)
    end

    test "cycle bounded via islice" do
      check!("""
      import itertools
      print(list(itertools.islice(itertools.cycle([1, 2, 3]), 8)))
      """)
    end

    test "repeat with times" do
      check!("""
      import itertools
      print(list(itertools.repeat("x", 4)))
      """)
    end
  end

  describe "terminating iterators" do
    test "accumulate default (sum)" do
      check!("""
      import itertools
      print(list(itertools.accumulate([1, 2, 3, 4])))
      """)
    end

    test "chain" do
      check!("""
      import itertools
      print(list(itertools.chain([1, 2], [3, 4], [5])))
      """)
    end

    test "chain.from_iterable" do
      check!("""
      import itertools
      print(list(itertools.chain.from_iterable([[1, 2], [3, 4], [5]])))
      """)
    end

    test "compress" do
      check!("""
      import itertools
      print(list(itertools.compress("ABCDEF", [1, 0, 1, 0, 1, 1])))
      """)
    end

    test "dropwhile" do
      check!("""
      import itertools
      print(list(itertools.dropwhile(lambda x: x < 3, [1, 2, 3, 4, 1, 2])))
      """)
    end

    test "takewhile" do
      check!("""
      import itertools
      print(list(itertools.takewhile(lambda x: x < 3, [1, 2, 3, 4, 1, 2])))
      """)
    end

    test "filterfalse" do
      check!("""
      import itertools
      print(list(itertools.filterfalse(lambda x: x % 2 == 0, [1, 2, 3, 4, 5])))
      """)
    end

    test "islice stop only" do
      check!("""
      import itertools
      print(list(itertools.islice([1, 2, 3, 4, 5], 3)))
      """)
    end

    test "islice start/stop" do
      check!("""
      import itertools
      print(list(itertools.islice([1, 2, 3, 4, 5], 1, 4)))
      """)
    end

    test "islice start/stop/step" do
      check!("""
      import itertools
      print(list(itertools.islice([1, 2, 3, 4, 5, 6, 7, 8], 1, 7, 2)))
      """)
    end

    test "starmap" do
      check!("""
      import itertools
      print(list(itertools.starmap(lambda x, y: x * y, [(2, 3), (4, 5), (6, 7)])))
      """)
    end

    test "zip_longest" do
      check!("""
      import itertools
      print(list(itertools.zip_longest([1, 2, 3], ["a", "b"], fillvalue="?")))
      """)
    end

    test "groupby" do
      check!("""
      import itertools
      data = [1, 1, 2, 2, 2, 3, 1, 1]
      for key, group in itertools.groupby(data):
          print(key, list(group))
      """)
    end

    test "pairwise" do
      check!("""
      import itertools
      print(list(itertools.pairwise([1, 2, 3, 4, 5])))
      """)
    end
  end

  describe "empty inputs" do
    test "product of empty" do
      check!("""
      import itertools
      print(list(itertools.product([])))
      print(list(itertools.product([1, 2], [])))
      """)
    end

    test "permutations of empty" do
      check!("""
      import itertools
      print(list(itertools.permutations([])))
      print(list(itertools.permutations([1, 2], 0)))
      """)
    end

    test "combinations r > len" do
      check!("""
      import itertools
      print(list(itertools.combinations([1, 2], 5)))
      """)
    end

    test "chain empty" do
      check!("""
      import itertools
      print(list(itertools.chain()))
      print(list(itertools.chain([])))
      """)
    end
  end
end
