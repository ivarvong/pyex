defmodule Pyex.Conformance.ContainerTest do
  @moduledoc """
  Live CPython conformance tests for list, dict, set, and tuple
  methods and operators.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "list methods" do
    for {label, code} <- [
          {"append", "xs = [1, 2, 3]; xs.append(4); print(xs)"},
          {"extend list", "xs = [1, 2]; xs.extend([3, 4]); print(xs)"},
          {"extend generator", "xs = [1, 2]; xs.extend(x*2 for x in range(3)); print(xs)"},
          {"extend str", ~S|xs = ["a"]; xs.extend("bcd"); print(xs)|},
          {"insert middle", "xs = [1, 3]; xs.insert(1, 2); print(xs)"},
          {"insert at 0", "xs = [2, 3]; xs.insert(0, 1); print(xs)"},
          {"insert negative", "xs = [1, 3]; xs.insert(-1, 2); print(xs)"},
          {"insert past end", "xs = [1, 2]; xs.insert(10, 3); print(xs)"},
          {"remove first", "xs = [1, 2, 3, 2]; xs.remove(2); print(xs)"},
          {"pop default", "xs = [1, 2, 3]; v = xs.pop(); print([v, xs])"},
          {"pop index 0", "xs = [1, 2, 3]; v = xs.pop(0); print([v, xs])"},
          {"pop negative", "xs = [1, 2, 3]; v = xs.pop(-2); print([v, xs])"},
          {"index basic", "print([1, 2, 3, 2].index(2))"},
          {"index start stop", "print([1, 2, 3, 2].index(2, 2))"},
          {"count", "print([1, 2, 2, 3, 2].count(2))"},
          {"reverse", "xs = [1, 2, 3]; xs.reverse(); print(xs)"},
          {"sort ascending", "xs = [3, 1, 4, 1, 5]; xs.sort(); print(xs)"},
          {"sort reverse", "xs = [1, 2, 3]; xs.sort(reverse=True); print(xs)"},
          {"sort with key", ~S|xs = ["bb", "a", "ccc"]; xs.sort(key=len); print(xs)|},
          {"clear", "xs = [1, 2, 3]; xs.clear(); print(xs)"},
          {"copy", "xs = [1, 2, 3]; ys = xs.copy(); xs.append(4); print([xs, ys])"}
        ] do
      test "#{label}" do
        check!(unquote(code))
      end
    end

    test "IndexError on pop empty" do
      check!("""
      try:
          [].pop()
          print("no error")
      except IndexError:
          print("IndexError")
      """)
    end

    test "ValueError on remove missing" do
      check!("""
      try:
          [1, 2, 3].remove(99)
          print("no error")
      except ValueError:
          print("ValueError")
      """)
    end
  end

  describe "list operators" do
    for {label, expr} <- [
          {"concat", "[1, 2] + [3, 4]"},
          {"repeat", "[1, 2] * 3"},
          {"repeat zero", "[1, 2] * 0"},
          {"repeat negative", "[1, 2] * -1"},
          {"in operator", "3 in [1, 2, 3]"},
          {"not in", "99 in [1, 2, 3]"},
          {"slice", "[1, 2, 3, 4, 5][1:4]"},
          {"slice step", "[1, 2, 3, 4, 5][::2]"},
          {"slice negative step", "[1, 2, 3, 4, 5][::-1]"},
          {"slice with negative indices", "[1, 2, 3, 4, 5][-3:-1]"},
          {"negative index", "[1, 2, 3][-1]"},
          {"equality", "[1, 2, 3] == [1, 2, 3]"},
          {"less than", "[1, 2] < [1, 3]"},
          {"nested", "[[1, 2], [3, 4]] == [[1, 2], [3, 4]]"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "dict methods" do
    for {label, code} <- [
          {"get default", ~S|d = {"a": 1}; print(d.get("a"))|},
          {"get missing", ~S|d = {"a": 1}; print(d.get("x"))|},
          {"get with default", ~S|d = {"a": 1}; print(d.get("x", 99))|},
          {"keys", ~S|print(sorted({"a": 1, "b": 2}.keys()))|},
          {"values", ~S|print(sorted({"a": 1, "b": 2}.values()))|},
          {"items", ~S|print(sorted({"a": 1, "b": 2}.items()))|},
          {"pop", ~S|d = {"a": 1, "b": 2}; v = d.pop("a"); print([v, d])|},
          {"pop with default", ~S|d = {}; print(d.pop("x", "default"))|},
          {"setdefault new", ~S|d = {}; v = d.setdefault("x", 1); print([v, d])|},
          {"setdefault existing", ~S|d = {"x": 99}; v = d.setdefault("x", 1); print([v, d])|},
          {"update with dict", ~S|d = {"a": 1}; d.update({"b": 2}); print(sorted(d.items()))|},
          {"update with kwargs", ~S|d = {"a": 1}; d.update(b=2, c=3); print(sorted(d.items()))|},
          {"clear", ~S|d = {"a": 1}; d.clear(); print(d)|},
          {"copy",
           ~S|d1 = {"a": 1}; d2 = d1.copy(); d1["b"] = 2; print([sorted(d1.items()), sorted(d2.items())])|}
        ] do
      test "#{label}" do
        check!(unquote(code))
      end
    end

    test "KeyError on missing key" do
      check!("""
      try:
          {"a": 1}["x"]
          print("no error")
      except KeyError:
          print("KeyError")
      """)
    end

    test "dict comprehension" do
      check!("""
      d = {x: x*x for x in range(5)}
      print(sorted(d.items()))
      """)
    end

    test "dict from zip" do
      check!("""
      d = dict(zip(["a", "b", "c"], [1, 2, 3]))
      print(sorted(d.items()))
      """)
    end
  end

  describe "dict operators" do
    for {label, expr} <- [
          {"in operator", ~S|"a" in {"a": 1, "b": 2}|},
          {"not in", ~S|"x" in {"a": 1}|},
          {"equality", ~S|{"a": 1, "b": 2} == {"b": 2, "a": 1}|},
          {"len", ~S|len({"a": 1, "b": 2, "c": 3})|}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end

    test "merge operator |" do
      check!(~S"""
      a = {"x": 1, "y": 2}
      b = {"y": 20, "z": 30}
      merged = a | b
      print(sorted(merged.items()))
      """)
    end
  end

  describe "set methods" do
    for {label, code} <- [
          {"add", "s = {1, 2}; s.add(3); print(sorted(s))"},
          {"add existing", "s = {1, 2}; s.add(2); print(sorted(s))"},
          {"remove", "s = {1, 2, 3}; s.remove(2); print(sorted(s))"},
          {"discard existing", "s = {1, 2}; s.discard(1); print(sorted(s))"},
          {"discard missing", "s = {1, 2}; s.discard(99); print(sorted(s))"},
          {"union", "print(sorted({1, 2} | {2, 3}))"},
          {"intersection", "print(sorted({1, 2, 3} & {2, 3, 4}))"},
          {"difference", "print(sorted({1, 2, 3} - {2, 3, 4}))"},
          {"symmetric difference", "print(sorted({1, 2, 3} ^ {2, 3, 4}))"},
          {"issubset true", "print({1, 2}.issubset({1, 2, 3}))"},
          {"issubset false", "print({1, 4}.issubset({1, 2, 3}))"},
          {"issuperset", "print({1, 2, 3}.issuperset({1, 2}))"},
          {"isdisjoint true", "print({1, 2}.isdisjoint({3, 4}))"},
          {"isdisjoint false", "print({1, 2}.isdisjoint({2, 3}))"},
          {"clear", "s = {1, 2, 3}; s.clear(); print(s)"},
          {"copy", "a = {1, 2}; b = a.copy(); a.add(3); print([sorted(a), sorted(b)])"}
        ] do
      test "#{label}" do
        check!(unquote(code))
      end
    end

    test "KeyError on remove missing" do
      check!("""
      try:
          {1, 2}.remove(99)
          print("no error")
      except KeyError:
          print("KeyError")
      """)
    end

    test "frozenset" do
      check!("""
      fs = frozenset([1, 2, 3, 2, 1])
      print(sorted(fs))
      print(len(fs))
      """)
    end
  end

  describe "tuple operations" do
    for {label, expr} <- [
          {"concat", "(1, 2) + (3, 4)"},
          {"repeat", "(1, 2) * 3"},
          {"index", "(1, 2, 3).index(2)"},
          {"count", "(1, 2, 2, 3).count(2)"},
          {"in", "2 in (1, 2, 3)"},
          {"slice", "(1, 2, 3, 4, 5)[1:4]"},
          {"equality", "(1, 2, 3) == (1, 2, 3)"},
          {"less than", "(1, 2) < (1, 3)"},
          {"nested", "((1, 2), (3, 4))"},
          {"single element tuple", "(42,)"},
          {"empty tuple", "()"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "string operators (for completeness)" do
    for {label, expr} <- [
          {"concat", ~S|"hello" + " " + "world"|},
          {"repeat", ~S|"ab" * 3|},
          {"in operator", ~S|"ell" in "hello"|},
          {"slice", ~S|"hello"[1:4]|},
          {"negative index", ~S|"hello"[-1]|},
          {"equality", ~S|"hello" == "hello"|},
          {"less than", ~S|"abc" < "abd"|},
          {"comparison across lengths", ~S|"abc" < "abcd"|}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "comprehensions" do
    test "list comprehension basic" do
      check!("print([x*2 for x in range(5)])")
    end

    test "list comprehension with filter" do
      check!("print([x for x in range(10) if x % 2 == 0])")
    end

    test "nested list comprehension" do
      check!("print([[i*j for j in range(3)] for i in range(3)])")
    end

    test "set comprehension" do
      check!("print(sorted({x % 3 for x in range(10)}))")
    end

    test "dict comprehension from items" do
      check!("""
      src = {"a": 1, "b": 2}
      swapped = {v: k for k, v in src.items()}
      print(sorted(swapped.items()))
      """)
    end

    test "generator expression with sum" do
      check!("print(sum(x*x for x in range(10)))")
    end
  end

  describe "unpacking" do
    test "star unpacking in list" do
      check!("""
      a = [1, 2, 3]
      b = [*a, 4, 5]
      print(b)
      """)
    end

    test "star unpacking in call" do
      check!("""
      def f(a, b, c): return a + b + c
      args = [1, 2, 3]
      print(f(*args))
      """)
    end

    test "double star in dict" do
      check!("""
      a = {"x": 1, "y": 2}
      b = {**a, "z": 3}
      print(sorted(b.items()))
      """)
    end

    test "double star in call" do
      check!("""
      def f(x, y, z): return x + y + z
      kw = {"x": 1, "y": 2, "z": 3}
      print(f(**kw))
      """)
    end

    test "multiple return values" do
      check!("""
      def pair(): return 1, 2
      a, b = pair()
      print([a, b])
      """)
    end

    test "starred assignment" do
      check!("""
      first, *rest = [1, 2, 3, 4]
      print([first, rest])
      """)
    end

    test "starred middle" do
      check!("""
      a, *middle, b = [1, 2, 3, 4, 5]
      print([a, middle, b])
      """)
    end
  end
end
