defmodule Pyex.Stdlib.HeapqTest do
  use ExUnit.Case, async: true

  test "heapq push pop and replace maintain heap semantics" do
    result =
      Pyex.run!("""
      import heapq
      heap = [5, 1, 4]
      heapq.heapify(heap)
      heapq.heappush(heap, 2)
      first = heapq.heappop(heap)
      replaced = heapq.heapreplace(heap, 9)
      (first, replaced, heap)
      """)

    assert result == {:tuple, [1, 2, [4, 5, 9]]}
  end
end
