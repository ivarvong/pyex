defmodule Pyex.BuiltinsTest do
  use ExUnit.Case, async: true

  alias Pyex.Error

  describe "len()" do
    test "returns length of a list" do
      assert Pyex.run!("len([1, 2, 3])") == 3
    end

    test "returns length of an empty list" do
      assert Pyex.run!("len([])") == 0
    end

    test "returns length of a string" do
      assert Pyex.run!("len(\"hello\")") == 5
    end

    test "returns length of a dict" do
      assert Pyex.run!("len({\"a\": 1, \"b\": 2})") == 2
    end

    test "raises TypeError for int" do
      assert_raise RuntimeError, ~r/TypeError.*no len/, fn ->
        Pyex.run!("len(42)")
      end
    end
  end

  describe "range()" do
    test "range with stop only" do
      assert Pyex.run!("list(range(5))") == [0, 1, 2, 3, 4]
    end

    test "range with zero" do
      assert Pyex.run!("list(range(0))") == []
    end

    test "range with start and stop" do
      assert Pyex.run!("list(range(2, 5))") == [2, 3, 4]
    end

    test "range with start >= stop returns empty" do
      assert Pyex.run!("list(range(5, 2))") == []
    end

    test "range with step" do
      assert Pyex.run!("list(range(0, 10, 2))") == [0, 2, 4, 6, 8]
    end

    test "range with negative step" do
      assert Pyex.run!("list(range(10, 0, -2))") == [10, 8, 6, 4, 2]
    end

    test "range with zero step raises ValueError" do
      assert_raise RuntimeError, ~r/ValueError.*must not be zero/, fn ->
        Pyex.run!("range(0, 10, 0)")
      end
    end

    test "range returns lazy object, not list" do
      {:instance, _, %{"__name__" => name}} = Pyex.run!("type(range(5))")
      assert name == "range"
    end

    test "range len is O(1) for large ranges" do
      assert Pyex.run!("len(range(1000000))") == 1_000_000
    end

    test "range membership test (in)" do
      assert Pyex.run!("5 in range(10)") == true
      assert Pyex.run!("10 in range(10)") == false
      assert Pyex.run!("4 in range(0, 10, 2)") == true
      assert Pyex.run!("3 in range(0, 10, 2)") == false
      assert Pyex.run!("'a' in range(5)") == false
    end

    test "range .start, .stop, .step attributes" do
      assert Pyex.run!("range(1, 10, 2).start") == 1
      assert Pyex.run!("range(1, 10, 2).stop") == 10
      assert Pyex.run!("range(1, 10, 2).step") == 2
      assert Pyex.run!("range(5).start") == 0
      assert Pyex.run!("range(5).stop") == 5
      assert Pyex.run!("range(5).step") == 1
    end

    test "range subscript indexing" do
      assert Pyex.run!("range(10)[5]") == 5
      assert Pyex.run!("range(10)[-1]") == 9
      assert Pyex.run!("range(2, 20, 3)[4]") == 14
    end

    test "range subscript out of bounds" do
      assert_raise RuntimeError, ~r/IndexError/, fn ->
        Pyex.run!("range(5)[10]")
      end
    end

    test "range str/repr" do
      assert Pyex.run!("str(range(5))") == "range(0, 5)"
      assert Pyex.run!("str(range(1, 10, 2))") == "range(1, 10, 2)"
    end

    test "range works in for loop" do
      code = """
      result = []
      for i in range(5):
          result.append(i)
      result
      """

      assert Pyex.run!(code) == [0, 1, 2, 3, 4]
    end

    test "range works with list comprehension" do
      assert Pyex.run!("[x * 2 for x in range(5)]") == [0, 2, 4, 6, 8]
    end

    test "range works with enumerate" do
      assert Pyex.run!("list(enumerate(range(3)))") == [
               {:tuple, [0, 0]},
               {:tuple, [1, 1]},
               {:tuple, [2, 2]}
             ]
    end

    test "range works with tuple/set constructors" do
      assert Pyex.run!("tuple(range(3))") == {:tuple, [0, 1, 2]}
      assert Pyex.run!("len(set(range(5)))") == 5
    end

    test "range truthy" do
      assert Pyex.run!("bool(range(5))") == true
      assert Pyex.run!("bool(range(0))") == false
    end

    test "range works with sorted/reversed" do
      assert Pyex.run!("sorted(range(5, 0, -1))") == [1, 2, 3, 4, 5]
      assert Pyex.run!("list(reversed(range(3)))") == [2, 1, 0]
    end

    test "range works with sum/min/max" do
      assert Pyex.run!("sum(range(5))") == 10
      assert Pyex.run!("min(range(1, 6))") == 1
      assert Pyex.run!("max(range(1, 6))") == 5
    end

    test "range works with any/all" do
      assert Pyex.run!("any(range(5))") == true
      assert Pyex.run!("any(range(0))") == false
      assert Pyex.run!("all(range(5))") == false
      assert Pyex.run!("all(range(1, 5))") == true
    end

    test "range works with iter/next" do
      code = """
      it = iter(range(3))
      a = next(it)
      b = next(it)
      c = next(it)
      [a, b, c]
      """

      assert Pyex.run!(code) == [0, 1, 2]
    end

    test "range slicing" do
      assert Pyex.run!("list(range(10)[2:5])") == [2, 3, 4]
    end

    test "range unpacking" do
      assert Pyex.run!("a, b, c = range(3)\n[a, b, c]") == [0, 1, 2]
    end
  end

  describe "print()" do
    test "prints a single value" do
      {:ok, _val, ctx} = Pyex.run("print(42)")
      assert Pyex.output(ctx) == "42"
    end

    test "prints multiple values separated by space" do
      {:ok, _val, ctx} = Pyex.run("print(1, 2, 3)")
      assert Pyex.output(ctx) == "1 2 3"
    end

    test "prints None as None" do
      {:ok, _val, ctx} = Pyex.run("print(None)")
      assert Pyex.output(ctx) == "None"
    end

    test "prints booleans as True/False" do
      {:ok, _val, ctx} = Pyex.run("print(True, False)")
      assert Pyex.output(ctx) == "True False"
    end

    test "returns None" do
      {:ok, val, ctx} = Pyex.run("print(42)")
      assert val == nil
      assert Pyex.output(ctx) == "42"
    end
  end

  describe "str()" do
    test "converts int to string" do
      assert Pyex.run!("str(42)") == "42"
    end

    test "converts float to string" do
      result = Pyex.run!("str(3.14)")
      assert is_binary(result)
      assert result =~ "3.14"
    end

    test "converts None to string" do
      assert Pyex.run!("str(None)") == "None"
    end

    test "converts bool to string" do
      assert Pyex.run!("str(True)") == "True"
    end

    test "converts list to string" do
      assert Pyex.run!("str([1, 2, 3])") == "[1, 2, 3]"
    end
  end

  describe "int()" do
    test "int from int is identity" do
      assert Pyex.run!("int(42)") == 42
    end

    test "int from float truncates" do
      assert Pyex.run!("int(3.9)") == 3
    end

    test "int from string" do
      assert Pyex.run!("int(\"123\")") == 123
    end

    test "int from bool" do
      assert Pyex.run!("int(True)") == 1
      assert Pyex.run!("int(False)") == 0
    end

    test "int from invalid string raises" do
      assert_raise RuntimeError, ~r/ValueError.*invalid literal/, fn ->
        Pyex.run!("int(\"abc\")")
      end
    end
  end

  describe "float()" do
    test "float from float is identity" do
      assert Pyex.run!("float(3.14)") == 3.14
    end

    test "float from int" do
      assert Pyex.run!("float(42)") == 42.0
    end

    test "float from string" do
      assert Pyex.run!("float(\"3.14\")") == 3.14
    end

    test "float from bool" do
      assert Pyex.run!("float(True)") == 1.0
      assert Pyex.run!("float(False)") == 0.0
    end

    test "float from invalid string raises" do
      assert_raise RuntimeError, ~r/ValueError.*could not convert/, fn ->
        Pyex.run!("float(\"abc\")")
      end
    end
  end

  describe "type()" do
    test "returns type of int" do
      {:instance, _, %{"__name__" => name}} = Pyex.run!("type(42)")
      assert name == "int"
    end

    test "returns type of string" do
      {:instance, _, %{"__name__" => name}} = Pyex.run!("type(\"hello\")")
      assert name == "str"
    end

    test "returns type of list" do
      {:instance, _, %{"__name__" => name}} = Pyex.run!("type([])")
      assert name == "list"
    end

    test "returns type of None" do
      {:instance, _, %{"__name__" => name}} = Pyex.run!("type(None)")
      assert name == "NoneType"
    end

    test "returns type of bool" do
      {:instance, _, %{"__name__" => name}} = Pyex.run!("type(True)")
      assert name == "bool"
    end

    test "returns type of dict" do
      {:instance, _, %{"__name__" => name}} = Pyex.run!("type({})")
      assert name == "dict"
    end
  end

  describe "abs()" do
    test "abs of positive" do
      assert Pyex.run!("abs(42)") == 42
    end

    test "abs of negative" do
      assert Pyex.run!("abs(-42)") == 42
    end

    test "abs of float" do
      assert Pyex.run!("abs(-3.14)") == 3.14
    end
  end

  describe "min() and max()" do
    test "min of a list" do
      assert Pyex.run!("min([3, 1, 2])") == 1
    end

    test "max of a list" do
      assert Pyex.run!("max([3, 1, 2])") == 3
    end

    test "min of multiple args" do
      assert Pyex.run!("min(3, 1, 2)") == 1
    end

    test "max of multiple args" do
      assert Pyex.run!("max(3, 1, 2)") == 3
    end

    test "min of empty list raises" do
      assert_raise RuntimeError, ~r/ValueError.*empty sequence/, fn ->
        Pyex.run!("min([])")
      end
    end

    test "max of empty list raises" do
      assert_raise RuntimeError, ~r/ValueError.*empty sequence/, fn ->
        Pyex.run!("max([])")
      end
    end

    test "min with key function" do
      result =
        Pyex.run!("""
        words = ["hello", "hi", "hey", "howdy"]
        min(words, key=lambda w: len(w))
        """)

      assert result == "hi"
    end

    test "max with key function" do
      result =
        Pyex.run!("""
        words = ["hi", "hey", "howdy", "supercalifragilistic"]
        max(words, key=lambda w: len(w))
        """)

      assert result == "supercalifragilistic"
    end

    test "min with key on dicts" do
      result =
        Pyex.run!("""
        items = [{"n": "a", "v": 5}, {"n": "b", "v": 2}, {"n": "c", "v": 8}]
        min(items, key=lambda x: x["v"])["n"]
        """)

      assert result == "b"
    end

    test "max with key on dicts" do
      result =
        Pyex.run!("""
        items = [{"n": "a", "v": 5}, {"n": "b", "v": 2}, {"n": "c", "v": 8}]
        max(items, key=lambda x: x["v"])["n"]
        """)

      assert result == "c"
    end

    test "min and max with key on tuples" do
      result =
        Pyex.run!("""
        pairs = [(1, "z"), (3, "a"), (2, "m")]
        mn = min(pairs, key=lambda p: p[1])
        mx = max(pairs, key=lambda p: p[1])
        [mn[0], mx[0]]
        """)

      assert result == [3, 1]
    end
  end

  describe "sum()" do
    test "sum of a list" do
      assert Pyex.run!("sum([1, 2, 3])") == 6
    end

    test "sum of empty list" do
      assert Pyex.run!("sum([])") == 0
    end
  end

  describe "sorted() and reversed()" do
    test "sorted returns a sorted copy" do
      assert Pyex.run!("sorted([3, 1, 2])") == [1, 2, 3]
    end

    test "reversed returns a reversed copy" do
      assert Pyex.run!("reversed([1, 2, 3])") == [3, 2, 1]
    end
  end

  describe "enumerate()" do
    test "enumerate produces index-value pairs" do
      result =
        Pyex.run!("""
        x = enumerate(["a", "b", "c"])
        x
        """)

      assert result == [{:tuple, [0, "a"]}, {:tuple, [1, "b"]}, {:tuple, [2, "c"]}]
    end
  end

  describe "zip()" do
    test "zip two lists" do
      result =
        Pyex.run!("""
        x = zip([1, 2, 3], ["a", "b", "c"])
        x
        """)

      assert result == [{:tuple, [1, "a"]}, {:tuple, [2, "b"]}, {:tuple, [3, "c"]}]
    end
  end

  describe "bool()" do
    test "bool of truthy value" do
      assert Pyex.run!("bool(1)") == true
    end

    test "bool of falsy value" do
      assert Pyex.run!("bool(0)") == false
    end

    test "bool of empty string" do
      assert Pyex.run!("bool(\"\")") == false
    end

    test "bool of non-empty string" do
      assert Pyex.run!("bool(\"hello\")") == true
    end
  end

  describe "list()" do
    test "list from string" do
      assert Pyex.run!("list(\"abc\")") == ["a", "b", "c"]
    end

    test "list with no args" do
      assert Pyex.run!("list()") == []
    end
  end

  describe "dict()" do
    test "dict with no args" do
      assert Pyex.run!("dict()") == %{}
    end
  end

  describe "isinstance()" do
    test "isinstance checks int" do
      assert Pyex.run!("isinstance(42, \"int\")") == true
    end

    test "isinstance returns false for mismatch" do
      assert Pyex.run!("isinstance(42, \"str\")") == false
    end

    test "isinstance with builtin type str" do
      assert Pyex.run!("isinstance(\"hello\", str)") == true
      assert Pyex.run!("isinstance(42, str)") == false
    end

    test "isinstance with builtin type int" do
      assert Pyex.run!("isinstance(42, int)") == true
      assert Pyex.run!("isinstance(3.14, int)") == false
    end

    test "isinstance with builtin type float" do
      assert Pyex.run!("isinstance(3.14, float)") == true
      assert Pyex.run!("isinstance(42, float)") == false
    end

    test "isinstance with builtin type bool" do
      assert Pyex.run!("isinstance(True, bool)") == true
      assert Pyex.run!("isinstance(0, bool)") == false
    end

    test "isinstance with builtin type list" do
      assert Pyex.run!("isinstance([1, 2], list)") == true
      assert Pyex.run!("isinstance(42, list)") == false
    end

    test "isinstance with builtin type dict" do
      assert Pyex.run!(~s|isinstance({"a": 1}, dict)|) == true
      assert Pyex.run!("isinstance(42, dict)") == false
    end

    test "isinstance with builtin type tuple" do
      assert Pyex.run!("isinstance((1, 2), tuple)") == true
      assert Pyex.run!("isinstance([1, 2], tuple)") == false
    end

    test "isinstance with builtin type set" do
      assert Pyex.run!("isinstance({1, 2}, set)") == true
      assert Pyex.run!("isinstance([1, 2], set)") == false
    end

    test "isinstance with tuple of types" do
      assert Pyex.run!("isinstance(42, (int, str))") == true
      assert Pyex.run!("isinstance(\"hello\", (int, str))") == true
      assert Pyex.run!("isinstance([1], (int, str))") == false
    end

    test "isinstance with class instance and class" do
      code = """
      class Foo:
          pass

      isinstance(Foo(), Foo)
      """

      assert Pyex.run!(code) == true
    end
  end

  describe "round()" do
    test "round to nearest integer" do
      assert Pyex.run!("round(3.7)") == 4
    end

    test "round with ndigits" do
      assert Pyex.run!("round(3.14159, 2)") == 3.14
    end
  end

  describe "builtins used in programs" do
    test "for loop over range" do
      assert Pyex.run!("""
             total = 0
             for i in range(5):
               total = total + i
             total
             """) == 10
    end

    test "len inside conditional" do
      assert Pyex.run!("""
             x = [1, 2, 3]
             if len(x) > 2:
               result = "big"
             else:
               result = "small"
             result
             """) == "big"
    end

    test "nested builtins" do
      assert Pyex.run!("len(range(10))") == 10
    end

    test "str concatenation with int conversion" do
      assert Pyex.run!("str(1) + str(2)") == "12"
    end

    test "sorted with sum" do
      assert Pyex.run!("sum(sorted([3, 1, 2]))") == 6
    end
  end

  describe "any and all" do
    test "any with truthy values" do
      assert Pyex.run!("any([False, 0, 1])") == true
      assert Pyex.run!("any([False, 0, ''])") == false
      assert Pyex.run!("any([])") == false
    end

    test "all with truthy values" do
      assert Pyex.run!("all([1, 2, 3])") == true
      assert Pyex.run!("all([1, 0, 3])") == false
      assert Pyex.run!("all([])") == true
    end
  end

  describe "map and filter" do
    test "map with builtin" do
      assert Pyex.run!("list(map(str, [1, 2, 3]))") == ["1", "2", "3"]
    end

    test "map with user function" do
      assert Pyex.run!("""
             def double(x):
                 return x * 2
             list(map(double, [1, 2, 3]))
             """) == [2, 4, 6]
    end

    test "filter with builtin" do
      assert Pyex.run!("list(filter(bool, [0, 1, '', 'a', None, True]))") == [1, "a", true]
    end

    test "filter with user function" do
      assert Pyex.run!("""
             def is_even(x):
                 return x % 2 == 0
             list(filter(is_even, [1, 2, 3, 4, 5]))
             """) == [2, 4]
    end
  end

  describe "chr and ord" do
    test "chr returns character" do
      assert Pyex.run!("chr(65)") == "A"
      assert Pyex.run!("chr(97)") == "a"
      assert Pyex.run!("chr(48)") == "0"
    end

    test "ord returns codepoint" do
      assert Pyex.run!(~s|ord("A")|) == 65
      assert Pyex.run!(~s|ord("a")|) == 97
    end

    test "chr and ord are inverses" do
      assert Pyex.run!(~s|chr(ord("Z"))|) == "Z"
      assert Pyex.run!(~s|ord(chr(120))|) == 120
    end
  end

  describe "hex, oct, bin" do
    test "hex formatting" do
      assert Pyex.run!("hex(255)") == "0xff"
      assert Pyex.run!("hex(0)") == "0x0"
      assert Pyex.run!("hex(-42)") == "-0x2a"
    end

    test "oct formatting" do
      assert Pyex.run!("oct(8)") == "0o10"
      assert Pyex.run!("oct(0)") == "0o0"
    end

    test "bin formatting" do
      assert Pyex.run!("bin(10)") == "0b1010"
      assert Pyex.run!("bin(0)") == "0b0"
      assert Pyex.run!("bin(-5)") == "-0b101"
    end
  end

  describe "pow" do
    test "two argument pow" do
      assert Pyex.run!("pow(2, 10)") == 1024.0
    end

    test "three argument modular pow" do
      assert Pyex.run!("pow(2, 10, 100)") == 24
    end
  end

  describe "divmod" do
    test "positive integers" do
      assert Pyex.run!("divmod(17, 5)") == {:tuple, [3, 2]}
    end

    test "negative dividend" do
      assert Pyex.run!("divmod(-7, 2)") == {:tuple, [-4, 1]}
    end

    test "zero divisor raises" do
      {:error, %Error{message: msg}} = Pyex.run("divmod(1, 0)")
      assert msg =~ "ZeroDivisionError"
    end
  end

  describe "repr" do
    test "repr of string includes quotes" do
      assert Pyex.run!(~s|repr("hello")|) == "'hello'"
    end

    test "repr of number" do
      assert Pyex.run!("repr(42)") == "42"
    end

    test "repr of None" do
      assert Pyex.run!("repr(None)") == "None"
    end
  end

  describe "callable" do
    test "functions are callable" do
      assert Pyex.run!("""
             def f():
                 pass
             callable(f)
             """) == true
    end

    test "builtins are callable" do
      assert Pyex.run!("callable(len)") == true
    end

    test "non-functions are not callable" do
      assert Pyex.run!("callable(42)") == false
      assert Pyex.run!(~s|callable("hello")|) == false
    end
  end

  describe "int() with base" do
    test "hex string" do
      assert Pyex.run!("int('ff', 16)") == 255
      assert Pyex.run!("int('FF', 16)") == 255
    end

    test "binary string" do
      assert Pyex.run!("int('101', 2)") == 5
      assert Pyex.run!("int('1111', 2)") == 15
    end

    test "octal string" do
      assert Pyex.run!("int('77', 8)") == 63
    end

    test "with prefix" do
      assert Pyex.run!("int('0xff', 16)") == 255
      assert Pyex.run!("int('0b101', 2)") == 5
      assert Pyex.run!("int('0o77', 8)") == 63
    end

    test "base 0 auto-detects" do
      assert Pyex.run!("int('0xff', 0)") == 255
      assert Pyex.run!("int('0b101', 0)") == 5
      assert Pyex.run!("int('0o77', 0)") == 63
      assert Pyex.run!("int('42', 0)") == 42
    end

    test "with underscores" do
      assert Pyex.run!("int('FF_FF', 16)") == 65535
    end

    test "invalid base raises ValueError" do
      {:error, %Error{message: msg}} = Pyex.run("int('0', 1)")
      assert msg =~ "ValueError"
    end

    test "invalid literal raises ValueError" do
      {:error, %Error{message: msg}} = Pyex.run("int('xyz', 10)")
      assert msg =~ "ValueError"
    end
  end

  describe "iter() and next()" do
    test "iter() creates iterator from list" do
      code = """
      it = iter([10, 20, 30])
      a = next(it)
      b = next(it)
      c = next(it)
      [a, b, c]
      """

      assert Pyex.run!(code) == [10, 20, 30]
    end

    test "next() raises StopIteration when exhausted" do
      code = """
      it = iter([1])
      next(it)
      next(it)
      """

      {:error, %Error{message: msg}} = Pyex.run(code)
      assert msg =~ "StopIteration"
    end

    test "next() with default returns default when exhausted" do
      code = """
      it = iter([1])
      next(it)
      next(it, "done")
      """

      assert Pyex.run!(code) == "done"
    end

    test "iter() on string iterates characters" do
      code = """
      it = iter("abc")
      [next(it), next(it), next(it)]
      """

      assert Pyex.run!(code) == ["a", "b", "c"]
    end

    test "iter() on dict iterates keys" do
      code = """
      it = iter({"a": 1, "b": 2})
      a = next(it)
      b = next(it)
      sorted([a, b])
      """

      assert Pyex.run!(code) == ["a", "b"]
    end

    test "iter() on generator" do
      code = """
      def gen():
          yield 1
          yield 2

      it = iter(gen())
      [next(it), next(it)]
      """

      assert Pyex.run!(code) == [1, 2]
    end

    test "iterator in for loop" do
      code = """
      it = iter([1, 2, 3])
      total = 0
      for x in it:
          total += x
      total
      """

      assert Pyex.run!(code) == 6
    end
  end
end
