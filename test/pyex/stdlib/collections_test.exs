defmodule Pyex.Stdlib.CollectionsTest do
  use ExUnit.Case, async: true

  alias Pyex.Error

  describe "Counter" do
    test "counts list elements" do
      result =
        Pyex.run!("""
        from collections import Counter
        c = Counter([1, 1, 2, 3, 3, 3])
        c[3]
        """)

      assert result == 3
    end

    test "counts string characters" do
      result =
        Pyex.run!("""
        from collections import Counter
        c = Counter("abracadabra")
        c["a"]
        """)

      assert result == 5
    end

    test "empty Counter" do
      result =
        Pyex.run!("""
        from collections import Counter
        c = Counter()
        isinstance(c, "dict")
        """)

      assert result == true
    end

    test "most_common returns sorted tuples" do
      result =
        Pyex.run!("""
        from collections import Counter
        c = Counter([1, 1, 2, 2, 2, 3])
        c.most_common(2)
        """)

      assert is_list(result)
      assert length(result) == 2
      [{:tuple, [first_key, first_count]} | _] = result
      assert first_key == 2
      assert first_count == 3
    end
  end

  describe "Counter advanced" do
    test "Counter from dict" do
      result =
        Pyex.run!("""
        from collections import Counter
        c = Counter({"a": 3, "b": 1})
        c["a"]
        """)

      assert result == 3
    end

    test "Counter missing key raises KeyError" do
      assert {:error, %Error{message: msg}} =
               Pyex.run("""
               from collections import Counter
               c = Counter([1, 2, 2, 3])
               c[99]
               """)

      assert msg =~ "KeyError"
    end

    test "most_common without argument returns all" do
      result =
        Pyex.run!("""
        from collections import Counter
        c = Counter("aabbc")
        all_items = c.most_common()
        len(all_items)
        """)

      assert result == 3
    end

    test "elements returns expanded list" do
      result =
        Pyex.run!("""
        from collections import Counter
        c = Counter({"a": 2, "b": 3})
        elems = c.elements()
        len(elems)
        """)

      assert result == 5
    end

    test "Counter with empty list has only method keys" do
      result =
        Pyex.run!("""
        from collections import Counter
        c = Counter([])
        c
        """)

      assert is_map(result)
    end
  end

  describe "defaultdict" do
    test "creates empty dict" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(int)
        len(d)
        """)

      assert result == 0
    end

    test "works as regular dict for assignment and access" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(int)
        d["a"] = 1
        d["b"] = 2
        (d["a"], d["b"], len(d))
        """)

      assert result == {:tuple, [1, 2, 2]}
    end

    test "defaultdict without factory" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict()
        d["key"] = "value"
        d["key"]
        """)

      assert result == "value"
    end

    test "defaultdict(int) auto-creates zero on missing key" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(int)
        x = d["missing"]
        x
        """)

      assert result == 0
    end

    test "defaultdict(int) with augmented assignment" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(int)
        d["a"] += 1
        d["a"] += 1
        d["b"] += 5
        (d["a"], d["b"], len(d))
        """)

      assert result == {:tuple, [2, 5, 2]}
    end

    test "defaultdict(str) auto-creates empty string" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(str)
        x = d["missing"]
        x
        """)

      assert result == ""
    end

    test "defaultdict factory key hidden from keys/values/items" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(int)
        d["a"] = 1
        (list(d.keys()), list(d.values()), len(d.items()))
        """)

      assert result == {:tuple, [["a"], [1], 1]}
    end

    test "defaultdict factory key hidden from iteration" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(int)
        d["x"] = 10
        d["y"] = 20
        keys = []
        for k in d:
            keys.append(k)
        keys
        """)

      assert result == ["x", "y"]
    end

    test "defaultdict factory key hidden from str/repr" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(int)
        d["a"] = 1
        str(d)
        """)

      assert result == "{'a': 1}"
    end

    test "defaultdict factory key hidden from in operator" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(int)
        d["a"] = 1
        ("a" in d, "__defaultdict_factory__" in d)
        """)

      assert result == {:tuple, [true, false]}
    end

    test "defaultdict clear preserves factory" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(int)
        d["a"] = 1
        d.clear()
        d["b"] += 5
        (len(d), d["b"])
        """)

      assert result == {:tuple, [1, 5]}
    end
  end

  describe "OrderedDict" do
    test "creates empty ordered dict" do
      result =
        Pyex.run!("""
        from collections import OrderedDict
        d = OrderedDict()
        len(d)
        """)

      assert result == 0
    end

    test "creates from list of pairs" do
      result =
        Pyex.run!("""
        from collections import OrderedDict
        d = OrderedDict([(1, "a"), (2, "b")])
        d[1]
        """)

      assert result == "a"
    end

    test "supports key-value storage" do
      result =
        Pyex.run!("""
        from collections import OrderedDict
        d = OrderedDict()
        d["c"] = 3
        d["a"] = 1
        d["b"] = 2
        (d["a"], d["b"], d["c"])
        """)

      assert result == {:tuple, [1, 2, 3]}
    end

    test "OrderedDict supports dict methods" do
      result =
        Pyex.run!("""
        from collections import OrderedDict
        d = OrderedDict([("x", 10), ("y", 20)])
        d.get("x")
        """)

      assert result == 10
    end
  end

  describe "defaultdict with lambda factories" do
    test "defaultdict(lambda: 0) with augmented assignment" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: 0)
        d["a"] += 1
        d["a"] += 1
        d["b"] += 5
        (d["a"], d["b"])
        """)

      assert result == {:tuple, [2, 5]}
    end

    test "defaultdict(lambda: dict) with nested subscript assignment" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: {"count": 0, "total": 0})
        d["a"]["count"] += 1
        d["a"]["total"] += 10
        d["b"]["count"] += 3
        (d["a"]["count"], d["a"]["total"], d["b"]["count"])
        """)

      assert result == {:tuple, [1, 10, 3]}
    end

    test "auto-insert: accessing missing key inserts default" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: 0)
        x = d["a"]
        len(d)
        """)

      assert result == 1
    end

    test "lambda factory preserved across multiple missing-key accesses" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: [])
        d["a"].append(1)
        d["b"].append(2)
        d["b"].append(3)
        (d["a"], d["b"])
        """)

      assert result == {:tuple, [[1], [2, 3]]}
    end

    test "defaultdict(lambda: 0) simple read of missing key returns 0" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: 0)
        d["missing"]
        """)

      assert result == 0
    end

    test "defaultdict(lambda: '') returns empty string for missing key" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: "")
        d["x"]
        """)

      assert result == ""
    end

    test "defaultdict preserves explicitly set keys" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: 0)
        d["a"] = 99
        d["a"]
        """)

      assert result == 99
    end

    test "defaultdict with lambda: 0 counting pattern" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: 0)
        words = ["apple", "banana", "apple", "cherry", "banana", "apple"]
        for w in words:
            d[w] += 1
        (d["apple"], d["banana"], d["cherry"])
        """)

      assert result == {:tuple, [3, 2, 1]}
    end

    test "defaultdict in operator does not auto-insert" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: 0)
        d["a"] = 1
        ("a" in d, "b" in d, len(d))
        """)

      assert result == {:tuple, [true, false, 1]}
    end

    test "defaultdict keys() returns only inserted keys" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: 0)
        d["x"] += 1
        d["y"] += 2
        sorted(list(d.keys()))
        """)

      assert result == ["x", "y"]
    end

    test "defaultdict values() returns current values" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: 0)
        d["a"] += 10
        d["b"] += 20
        sorted(list(d.values()))
        """)

      assert result == [10, 20]
    end

    test "defaultdict iteration yields keys" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: 0)
        d["x"] = 1
        d["y"] = 2
        keys = []
        for k in d:
            keys.append(k)
        sorted(keys)
        """)

      assert result == ["x", "y"]
    end

    test "defaultdict with lambda returning mutable default (each call independent)" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: [1, 2])
        d["a"].append(3)
        d["b"].append(4)
        (d["a"], d["b"])
        """)

      assert result == {:tuple, [[1, 2, 3], [1, 2, 4]]}
    end

    test "defaultdict augmented assignment on existing key" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: 0)
        d["a"] = 10
        d["a"] += 5
        d["a"]
        """)

      assert result == 15
    end

    test "defaultdict nested augmented: d['a']['x'] += 1 on existing outer key" do
      result =
        Pyex.run!("""
        from collections import defaultdict
        d = defaultdict(lambda: {"x": 0, "y": 0})
        d["a"]["x"] += 1
        d["a"]["x"] += 1
        d["a"]["y"] += 10
        (d["a"]["x"], d["a"]["y"])
        """)

      assert result == {:tuple, [2, 10]}
    end
  end
end
