defmodule Pyex.Conformance.HeapqTest do
  @moduledoc """
  Live CPython conformance tests for the `heapq` module.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "heappush and heappop" do
    test "heappush maintains heap invariant" do
      check!("""
      import heapq
      h = []
      for x in [5, 3, 7, 1, 9, 2]:
          heapq.heappush(h, x)
      # smallest element always at index 0
      print(h[0])
      """)
    end

    test "heappop returns smallest" do
      check!("""
      import heapq
      h = [5, 3, 7, 1, 9, 2]
      heapq.heapify(h)
      result = []
      while h:
          result.append(heapq.heappop(h))
      print(result)
      """)
    end

    test "heappushpop more efficient than push+pop" do
      check!("""
      import heapq
      h = [1, 2, 3, 4, 5]
      heapq.heapify(h)
      print(heapq.heappushpop(h, 0))
      print(h)
      """)
    end

    test "heapreplace" do
      check!("""
      import heapq
      h = [1, 2, 3]
      heapq.heapify(h)
      print(heapq.heapreplace(h, 10))
      print(h)
      """)
    end
  end

  describe "heapify" do
    test "converts list to heap" do
      check!("""
      import heapq
      h = [9, 5, 2, 7, 1]
      heapq.heapify(h)
      print(h[0])  # smallest
      """)
    end
  end

  describe "nlargest and nsmallest" do
    test "nlargest" do
      check!("""
      import heapq
      print(heapq.nlargest(3, [1, 8, 2, 23, 7, 4]))
      """)
    end

    test "nsmallest" do
      check!("""
      import heapq
      print(heapq.nsmallest(3, [1, 8, 2, 23, 7, 4]))
      """)
    end

    test "nlargest with key" do
      check!("""
      import heapq
      items = [("a", 5), ("b", 1), ("c", 9), ("d", 3)]
      print(heapq.nlargest(2, items, key=lambda x: x[1]))
      """)
    end

    test "nsmallest with key" do
      check!("""
      import heapq
      items = [("a", 5), ("b", 1), ("c", 9), ("d", 3)]
      print(heapq.nsmallest(2, items, key=lambda x: x[1]))
      """)
    end
  end

  describe "merge" do
    test "merges sorted sequences" do
      check!("""
      import heapq
      result = list(heapq.merge([1, 4, 7], [2, 5, 8], [3, 6, 9]))
      print(result)
      """)
    end
  end
end
