defmodule Pyex.MethodsTest do
  use ExUnit.Case, async: true

  alias Pyex.Error

  describe "string.upper()" do
    test "converts to uppercase" do
      assert Pyex.run!("\"hello\".upper()") == "HELLO"
    end
  end

  describe "string.lower()" do
    test "converts to lowercase" do
      assert Pyex.run!("\"HELLO\".lower()") == "hello"
    end
  end

  describe "string.strip()" do
    test "strips whitespace" do
      assert Pyex.run!("\"  hello  \".strip()") == "hello"
    end
  end

  describe "string.lstrip()" do
    test "strips leading whitespace" do
      assert Pyex.run!("\"  hello  \".lstrip()") == "hello  "
    end
  end

  describe "string.rstrip()" do
    test "strips trailing whitespace" do
      assert Pyex.run!("\"  hello  \".rstrip()") == "  hello"
    end
  end

  describe "string.split()" do
    test "split on whitespace" do
      assert Pyex.run!("\"hello world\".split()") == ["hello", "world"]
    end

    test "split on separator" do
      assert Pyex.run!("\"a,b,c\".split(\",\")") == ["a", "b", "c"]
    end
  end

  describe "string.join()" do
    test "join a list" do
      assert Pyex.run!("\", \".join([\"a\", \"b\", \"c\"])") == "a, b, c"
    end

    test "join with empty string" do
      assert Pyex.run!("\"\".join([\"a\", \"b\", \"c\"])") == "abc"
    end
  end

  describe "string.replace()" do
    test "replaces substring" do
      assert Pyex.run!("\"hello world\".replace(\"world\", \"python\")") == "hello python"
    end

    test "replaces all occurrences" do
      assert Pyex.run!("\"aaa\".replace(\"a\", \"b\")") == "bbb"
    end
  end

  describe "string.startswith()" do
    test "returns True when prefix matches" do
      assert Pyex.run!("\"hello\".startswith(\"hel\")") == true
    end

    test "returns False when prefix does not match" do
      assert Pyex.run!("\"hello\".startswith(\"xyz\")") == false
    end
  end

  describe "string.endswith()" do
    test "returns True when suffix matches" do
      assert Pyex.run!("\"hello\".endswith(\"llo\")") == true
    end

    test "returns False when suffix does not match" do
      assert Pyex.run!("\"hello\".endswith(\"xyz\")") == false
    end
  end

  describe "string.find()" do
    test "returns index of substring" do
      assert Pyex.run!("\"hello\".find(\"ll\")") == 2
    end

    test "returns -1 when not found" do
      assert Pyex.run!("\"hello\".find(\"xyz\")") == -1
    end

    test "with start argument" do
      assert Pyex.run!("\"hello hello\".find(\"hello\", 1)") == 6
    end

    test "with start argument - frontmatter repro" do
      code = ~s|s = "---\\nkey: value\\n---\\nbody\\n"\ns.find("\\n---\\n", 4)|
      assert Pyex.run!(code) == 14
    end

    test "with start and end arguments" do
      assert Pyex.run!("\"abcabc\".find(\"abc\", 1, 5)") == -1
      assert Pyex.run!("\"abcabc\".find(\"abc\", 1, 7)") == 3
    end

    test "with negative start" do
      assert Pyex.run!("\"hello world\".find(\"world\", -5)") == 6
    end
  end

  describe "string.count()" do
    test "counts occurrences" do
      assert Pyex.run!("\"hello\".count(\"l\")") == 2
    end

    test "returns 0 when not found" do
      assert Pyex.run!("\"hello\".count(\"z\")") == 0
    end
  end

  describe "string.isdigit()" do
    test "returns True for digits" do
      assert Pyex.run!("\"123\".isdigit()") == true
    end

    test "returns False for non-digits" do
      assert Pyex.run!("\"12a\".isdigit()") == false
    end

    test "returns False for empty string" do
      assert Pyex.run!("\"\".isdigit()") == false
    end
  end

  describe "string.isalpha()" do
    test "returns True for alpha" do
      assert Pyex.run!("\"hello\".isalpha()") == true
    end

    test "returns False for non-alpha" do
      assert Pyex.run!("\"hello1\".isalpha()") == false
    end

    test "returns False for empty string" do
      assert Pyex.run!("\"\".isalpha()") == false
    end
  end

  describe "string.title()" do
    test "title cases string" do
      assert Pyex.run!("\"hello world\".title()") == "Hello World"
    end
  end

  describe "string.capitalize()" do
    test "capitalizes first character" do
      assert Pyex.run!("\"hello world\".capitalize()") == "Hello world"
    end

    test "handles empty string" do
      assert Pyex.run!("\"\".capitalize()") == ""
    end
  end

  describe "string.zfill()" do
    test "pads with zeros" do
      assert Pyex.run!("\"42\".zfill(5)") == "00042"
    end

    test "no padding when already long enough" do
      assert Pyex.run!("\"12345\".zfill(3)") == "12345"
    end
  end

  describe "string.format()" do
    test "positional format" do
      assert Pyex.run!("\"{0} {1}\".format(\"hello\", \"world\")") == "hello world"
    end
  end

  describe "string method chaining" do
    test "chain upper and strip" do
      assert Pyex.run!("\"  hello  \".strip().upper()") == "HELLO"
    end

    test "split then join" do
      assert Pyex.run!("\"-\".join(\"a b c\".split())") == "a-b-c"
    end
  end

  describe "list methods" do
    test "list.append returns None (Python semantics)" do
      assert Pyex.run!("[1, 2].append(3)") == nil
    end

    test "list.append mutates the list in place" do
      code = """
      x = [1, 2]
      x.append(3)
      x
      """

      assert Pyex.run!(code) == [1, 2, 3]
    end

    test "list.append in a loop accumulates values" do
      code = """
      result = []
      for i in range(5):
          result.append(i)
      result
      """

      assert Pyex.run!(code) == [0, 1, 2, 3, 4]
    end

    test "list.index finds element" do
      assert Pyex.run!("[10, 20, 30].index(20)") == 1
    end

    test "list.index raises on missing element" do
      assert_raise RuntimeError, ~r/ValueError.*not in list/, fn ->
        Pyex.run!("[1, 2, 3].index(99)")
      end
    end

    test "list.count counts occurrences" do
      assert Pyex.run!("[1, 2, 2, 3, 2].count(2)") == 3
    end

    test "list.copy returns a copy" do
      assert Pyex.run!("[1, 2, 3].copy()") == [1, 2, 3]
    end
  end

  describe "method on variable" do
    test "string method on variable" do
      assert Pyex.run!("""
             x = "hello world"
             x.upper()
             """) == "HELLO WORLD"
    end

    test "list method on variable" do
      assert Pyex.run!("""
              x = [1, 2, 3]
             x.index(2)
             """) == 1
    end
  end

  describe "dict.get()" do
    test "returns value for existing key" do
      result =
        Pyex.run!("""
        d = {"a": 1, "b": 2}
        d.get("a")
        """)

      assert result == 1
    end

    test "returns None for missing key" do
      result =
        Pyex.run!("""
        d = {"a": 1}
        d.get("z")
        """)

      assert result == nil
    end

    test "returns default for missing key" do
      result =
        Pyex.run!("""
        d = {"a": 1}
        d.get("z", 42)
        """)

      assert result == 42
    end
  end

  describe "dict.keys()" do
    test "returns list of keys" do
      result =
        Pyex.run!("""
        d = {"x": 1, "y": 2}
        d.keys()
        """)

      assert Enum.sort(result) == ["x", "y"]
    end
  end

  describe "dict.values()" do
    test "returns list of values" do
      result =
        Pyex.run!("""
        d = {"x": 1, "y": 2}
        d.values()
        """)

      assert Enum.sort(result) == [1, 2]
    end
  end

  describe "dict.items()" do
    test "returns list of key-value pairs" do
      result =
        Pyex.run!("""
        d = {"x": 1, "y": 2}
        d.items()
        """)

      assert Enum.sort(result) == [{:tuple, ["x", 1]}, {:tuple, ["y", 2]}]
    end
  end

  describe "dict.pop()" do
    test "removes and returns value" do
      result =
        Pyex.run!("""
        d = {"a": 1, "b": 2}
        val = d.pop("a")
        val
        """)

      assert result == 1
    end
  end

  describe "list.extend()" do
    test "extends list in place" do
      result =
        Pyex.run!("""
        x = [1, 2]
        x.extend([3, 4])
        x
        """)

      assert result == [1, 2, 3, 4]
    end
  end

  describe "list.insert()" do
    test "inserts at index" do
      result =
        Pyex.run!("""
        x = [1, 3]
        x.insert(1, 2)
        x
        """)

      assert result == [1, 2, 3]
    end

    test "insert at beginning" do
      result =
        Pyex.run!("""
        x = [2, 3]
        x.insert(0, 1)
        x
        """)

      assert result == [1, 2, 3]
    end
  end

  describe "list.remove()" do
    test "removes first occurrence" do
      result =
        Pyex.run!("""
        x = [1, 2, 3, 2]
        x.remove(2)
        x
        """)

      assert result == [1, 3, 2]
    end

    test "raises ValueError if not found" do
      assert_raise RuntimeError, ~r/ValueError/, fn ->
        Pyex.run!("""
        x = [1, 2, 3]
        x.remove(99)
        """)
      end
    end
  end

  describe "list.pop()" do
    test "pops last element by default" do
      result =
        Pyex.run!("""
        x = [1, 2, 3]
        val = x.pop()
        val
        """)

      assert result == 3
    end

    test "mutates the list" do
      result =
        Pyex.run!("""
        x = [1, 2, 3]
        x.pop()
        x
        """)

      assert result == [1, 2]
    end

    test "pops at index" do
      result =
        Pyex.run!("""
        x = [10, 20, 30]
        val = x.pop(0)
        val
        """)

      assert result == 10
    end

    test "raises on empty list" do
      assert_raise RuntimeError, ~r/IndexError/, fn ->
        Pyex.run!("""
        x = []
        x.pop()
        """)
      end
    end
  end

  describe "list.sort()" do
    test "sorts in place" do
      result =
        Pyex.run!("""
        x = [3, 1, 2]
        x.sort()
        x
        """)

      assert result == [1, 2, 3]
    end

    test "returns None" do
      result =
        Pyex.run!("""
        x = [3, 1, 2]
        x.sort()
        """)

      assert result == nil
    end
  end

  describe "list.reverse()" do
    test "reverses in place" do
      result =
        Pyex.run!("""
        x = [1, 2, 3]
        x.reverse()
        x
        """)

      assert result == [3, 2, 1]
    end
  end

  describe "list.clear()" do
    test "empties the list" do
      result =
        Pyex.run!("""
        x = [1, 2, 3]
        x.clear()
        x
        """)

      assert result == []
    end
  end

  describe "string.center()" do
    test "centers string with spaces" do
      assert Pyex.run!(~S["hi".center(10)]) == "    hi    "
    end

    test "centers string with custom fill" do
      assert Pyex.run!(~S["hi".center(10, "*")]) == "****hi****"
    end

    test "returns string when width is smaller" do
      assert Pyex.run!(~S["hello".center(3)]) == "hello"
    end
  end

  describe "string.ljust()" do
    test "left-justifies with spaces" do
      assert Pyex.run!(~S["hi".ljust(10)]) == "hi        "
    end

    test "left-justifies with custom fill" do
      assert Pyex.run!(~S["hi".ljust(10, "-")]) == "hi--------"
    end
  end

  describe "string.rjust()" do
    test "right-justifies with spaces" do
      assert Pyex.run!(~S["hi".rjust(10)]) == "        hi"
    end

    test "right-justifies with custom fill" do
      assert Pyex.run!(~S["hi".rjust(10, "-")]) == "--------hi"
    end
  end

  describe "string.swapcase()" do
    test "swaps case of all characters" do
      assert Pyex.run!(~S["Hello World".swapcase()]) == "hELLO wORLD"
    end

    test "handles all uppercase" do
      assert Pyex.run!(~S["ABC".swapcase()]) == "abc"
    end

    test "handles all lowercase" do
      assert Pyex.run!(~S["abc".swapcase()]) == "ABC"
    end
  end

  describe "string.isupper()" do
    test "returns True for uppercase string" do
      assert Pyex.run!(~S["HELLO".isupper()]) == true
    end

    test "returns False for mixed case" do
      assert Pyex.run!(~S["Hello".isupper()]) == false
    end

    test "returns False for empty string" do
      assert Pyex.run!(~S["".isupper()]) == false
    end

    test "returns True for uppercase with non-alpha" do
      assert Pyex.run!(~S["HELLO 123".isupper()]) == true
    end
  end

  describe "string.islower()" do
    test "returns True for lowercase string" do
      assert Pyex.run!(~S["hello".islower()]) == true
    end

    test "returns False for mixed case" do
      assert Pyex.run!(~S["Hello".islower()]) == false
    end

    test "returns False for empty string" do
      assert Pyex.run!(~S["".islower()]) == false
    end
  end

  describe "string.isspace()" do
    test "returns True for whitespace only" do
      assert Pyex.run!(~S["   ".isspace()]) == true
    end

    test "returns False for non-whitespace" do
      assert Pyex.run!(~S["hello".isspace()]) == false
    end

    test "returns False for empty string" do
      assert Pyex.run!(~S["".isspace()]) == false
    end
  end

  describe "string.isalnum()" do
    test "returns True for alphanumeric" do
      assert Pyex.run!(~S["hello123".isalnum()]) == true
    end

    test "returns False for string with spaces" do
      assert Pyex.run!(~S["hello 123".isalnum()]) == false
    end

    test "returns False for empty string" do
      assert Pyex.run!(~S["".isalnum()]) == false
    end
  end

  describe "string.index()" do
    test "returns position of substring" do
      assert Pyex.run!(~S["hello".index("ll")]) == 2
    end

    test "raises ValueError when not found" do
      {:error, %Error{message: msg}} = Pyex.run(~S["hello".index("xyz")])
      assert msg =~ "ValueError: substring not found"
    end

    test "with start argument" do
      assert Pyex.run!(~S["hello hello".index("hello", 1)]) == 6
    end

    test "with start and end arguments" do
      {:error, %Error{message: msg}} = Pyex.run(~S["abcabc".index("abc", 1, 5)])
      assert msg =~ "ValueError: substring not found"
      assert Pyex.run!(~S["abcabc".index("abc", 1, 7)]) == 3
    end
  end

  describe "string.rfind()" do
    test "finds last occurrence" do
      assert Pyex.run!(~S["hello hello".rfind("hello")]) == 6
    end

    test "returns -1 when not found" do
      assert Pyex.run!(~S["hello".rfind("xyz")]) == -1
    end

    test "with start argument" do
      assert Pyex.run!(~S["abcabcabc".rfind("abc", 4)]) == 6
    end

    test "with start and end arguments" do
      assert Pyex.run!(~S["abcabcabc".rfind("abc", 1, 6)]) == 3
    end
  end

  describe "string.rindex()" do
    test "finds last occurrence" do
      assert Pyex.run!(~S["hello hello".rindex("hello")]) == 6
    end

    test "raises ValueError when not found" do
      {:error, %Error{message: msg}} = Pyex.run(~S["hello".rindex("xyz")])
      assert msg =~ "ValueError: substring not found"
    end

    test "with start argument" do
      assert Pyex.run!(~S["abcabcabc".rindex("abc", 4)]) == 6
    end

    test "with start and end, raises when not in range" do
      {:error, %Error{message: msg}} = Pyex.run(~S["abcabc".rindex("abc", 1, 3)])
      assert msg =~ "ValueError: substring not found"
    end
  end

  describe "string.partition()" do
    test "splits around first occurrence of separator" do
      assert Pyex.run!(~S["hello-world-test".partition("-")]) ==
               {:tuple, ["hello", "-", "world-test"]}
    end

    test "returns original string and empty strings when not found" do
      assert Pyex.run!(~S["hello".partition("-")]) == {:tuple, ["hello", "", ""]}
    end
  end

  describe "string.rpartition()" do
    test "splits around last occurrence of separator" do
      assert Pyex.run!(~S["hello-world-test".rpartition("-")]) ==
               {:tuple, ["hello-world", "-", "test"]}
    end

    test "returns empty strings and original when not found" do
      assert Pyex.run!(~S["hello".rpartition("-")]) == {:tuple, ["", "", "hello"]}
    end
  end

  describe "string.rsplit()" do
    test "splits from the right with maxsplit" do
      assert Pyex.run!(~S["a-b-c-d".rsplit("-", 2)]) == ["a-b", "c", "d"]
    end

    test "splits all by default" do
      assert Pyex.run!(~S["a-b-c".rsplit("-")]) == ["a", "b", "c"]
    end
  end

  describe "string.splitlines()" do
    code = ~S|"hello\nworld\nfoo".splitlines()|

    test "splits on newlines" do
      assert Pyex.run!(unquote(code)) == ["hello", "world", "foo"]
    end
  end

  describe "string.expandtabs()" do
    test "expands tabs to 8 spaces by default" do
      assert Pyex.run!(~S["a\tb".expandtabs()]) == "a" <> String.duplicate(" ", 8) <> "b"
    end

    test "expands tabs to custom width" do
      assert Pyex.run!(~S["a\tb".expandtabs(4)]) == "a" <> String.duplicate(" ", 4) <> "b"
    end
  end

  describe "string.encode()" do
    test "returns string unchanged" do
      assert Pyex.run!(~S["hello".encode()]) == "hello"
    end

    test "accepts encoding argument" do
      assert Pyex.run!(~S["hello".encode("utf-8")]) == "hello"
    end
  end

  describe "string.istitle()" do
    test "returns True for title-cased string" do
      assert Pyex.run!(~S["Hello World".istitle()]) == true
    end

    test "returns False for non-title-cased" do
      assert Pyex.run!(~S["hello world".istitle()]) == false
    end

    test "returns False for empty string" do
      assert Pyex.run!(~S["".istitle()]) == false
    end
  end

  describe "dict.update()" do
    test "merges another dict into the original" do
      code = """
      d = {"a": 1, "b": 2}
      d.update({"b": 99, "c": 3})
      d
      """

      assert Pyex.run!(code) == %{"a" => 1, "b" => 99, "c" => 3}
    end

    test "returns None" do
      code = """
      d = {"a": 1}
      result = d.update({"b": 2})
      result
      """

      assert Pyex.run!(code) == nil
    end
  end

  describe "dict.setdefault()" do
    test "returns existing value for present key" do
      code = """
      d = {"a": 1}
      d.setdefault("a", 99)
      """

      assert Pyex.run!(code) == 1
    end

    test "inserts and returns default for missing key" do
      code = """
      d = {"a": 1}
      result = d.setdefault("b", 42)
      (result, d["b"])
      """

      assert Pyex.run!(code) == {:tuple, [42, 42]}
    end

    test "inserts None when no default given" do
      code = """
      d = {"a": 1}
      result = d.setdefault("b")
      (result, d["b"] is None)
      """

      assert Pyex.run!(code) == {:tuple, [nil, true]}
    end
  end

  describe "dict.clear()" do
    test "empties the dict" do
      code = """
      d = {"a": 1, "b": 2, "c": 3}
      d.clear()
      len(d)
      """

      assert Pyex.run!(code) == 0
    end

    test "returns None" do
      code = """
      d = {"a": 1}
      result = d.clear()
      result
      """

      assert Pyex.run!(code) == nil
    end
  end

  describe "dict.copy()" do
    test "returns a shallow copy" do
      code = """
      d = {"a": 1, "b": 2}
      d2 = d.copy()
      d2["c"] = 3
      (len(d), len(d2))
      """

      assert Pyex.run!(code) == {:tuple, [2, 3]}
    end

    test "copy equals original" do
      code = """
      d = {"x": 10, "y": 20}
      d2 = d.copy()
      d2 == d
      """

      assert Pyex.run!(code) == true
    end
  end

  describe "dict.pop() edge cases" do
    test "pop with default on missing key" do
      code = """
      d = {"a": 1}
      d.pop("b", "default_val")
      """

      assert Pyex.run!(code) == "default_val"
    end

    test "pop without default on missing key raises KeyError" do
      assert {:error, %Error{message: msg}} = Pyex.run(~S|d = {"a": 1}| <> "\nd.pop(\"b\")")
      assert msg =~ "KeyError"
    end

    test "pop mutates the dict" do
      code = """
      d = {"a": 1, "b": 2}
      val = d.pop("a")
      (val, len(d), "a" not in d)
      """

      assert Pyex.run!(code) == {:tuple, [1, 1, true]}
    end
  end

  describe "string.isnumeric()" do
    test "returns True for digit string" do
      assert Pyex.run!(~S["12345".isnumeric()]) == true
    end

    test "returns False for non-numeric" do
      assert Pyex.run!(~S["12.5".isnumeric()]) == false
    end

    test "returns False for empty string" do
      assert Pyex.run!(~S["".isnumeric()]) == false
    end
  end
end
