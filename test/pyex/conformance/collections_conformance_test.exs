defmodule Pyex.Conformance.CollectionsTest do
  @moduledoc """
  Live CPython conformance tests for the `collections` module.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "Counter" do
    test "Counter from iterable" do
      check!("""
      from collections import Counter
      c = Counter("aabbcccd")
      print(sorted(c.items()))
      """)
    end

    test "Counter from dict" do
      check!("""
      from collections import Counter
      c = Counter({"a": 3, "b": 1})
      print(c["a"])
      print(c["b"])
      """)
    end

    test "Counter missing key returns 0" do
      check!("""
      from collections import Counter
      c = Counter("abc")
      print(c["z"])
      """)
    end

    test "Counter.most_common" do
      check!("""
      from collections import Counter
      c = Counter("aabbccccd")
      print(c.most_common(2))
      """)
    end

    test "Counter.most_common all" do
      check!("""
      from collections import Counter
      c = Counter("aabbbccd")
      print(sorted(c.most_common(), key=lambda kv: (-kv[1], kv[0])))
      """)
    end

    test "Counter arithmetic: +" do
      check!("""
      from collections import Counter
      a = Counter("aab")
      b = Counter("abc")
      result = a + b
      print(sorted(result.items()))
      """)
    end

    test "Counter update from iterable" do
      check!("""
      from collections import Counter
      c = Counter()
      c.update("aab")
      c.update("bc")
      print(sorted(c.items()))
      """)
    end
  end

  describe "defaultdict" do
    test "defaultdict with int default" do
      check!("""
      from collections import defaultdict
      d = defaultdict(int)
      d["a"] += 1
      d["a"] += 1
      d["b"] += 3
      print(d["a"], d["b"], d["missing"])
      """)
    end

    test "defaultdict with list default" do
      check!("""
      from collections import defaultdict
      d = defaultdict(list)
      d["a"].append(1)
      d["a"].append(2)
      d["b"].append(3)
      print(sorted(d.items()))
      """)
    end

    test "defaultdict preserves iteration order" do
      check!("""
      from collections import defaultdict
      d = defaultdict(int)
      d["z"] = 1
      d["a"] = 2
      d["m"] = 3
      print(list(d.keys()))
      """)
    end
  end

  describe "OrderedDict" do
    test "OrderedDict preserves insertion order" do
      check!("""
      from collections import OrderedDict
      d = OrderedDict()
      d["z"] = 1
      d["a"] = 2
      d["m"] = 3
      print(list(d.keys()))
      """)
    end

    test "OrderedDict from pairs" do
      check!("""
      from collections import OrderedDict
      d = OrderedDict([("a", 1), ("b", 2), ("c", 3)])
      print(list(d.items()))
      """)
    end
  end

  describe "deque" do
    test "deque from iterable" do
      check!("""
      from collections import deque
      d = deque([1, 2, 3])
      print(list(d))
      """)
    end

    test "deque append and appendleft" do
      check!("""
      from collections import deque
      d = deque([2, 3])
      d.append(4)
      d.appendleft(1)
      print(list(d))
      """)
    end

    test "deque pop and popleft" do
      check!("""
      from collections import deque
      d = deque([1, 2, 3, 4, 5])
      print(d.pop())
      print(d.popleft())
      print(list(d))
      """)
    end

    test "deque maxlen" do
      check!("""
      from collections import deque
      d = deque([1, 2, 3], maxlen=3)
      d.append(4)
      print(list(d))
      """)
    end

    test "deque extend" do
      check!("""
      from collections import deque
      d = deque([1, 2])
      d.extend([3, 4, 5])
      print(list(d))
      """)
    end

    test "deque extendleft reverses" do
      check!("""
      from collections import deque
      d = deque([3, 4])
      d.extendleft([1, 2])
      print(list(d))
      """)
    end

    test "deque rotate" do
      check!("""
      from collections import deque
      d = deque([1, 2, 3, 4, 5])
      d.rotate(2)
      print(list(d))
      d.rotate(-2)
      print(list(d))
      """)
    end

    test "deque len" do
      check!("""
      from collections import deque
      d = deque([1, 2, 3, 4])
      print(len(d))
      """)
    end
  end
end
