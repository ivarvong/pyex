defmodule Pyex.InterpreterTest do
  use ExUnit.Case, async: true

  alias Pyex.Error

  describe "arithmetic" do
    test "operator precedence" do
      assert Pyex.run!("2 + 3 * 4") == 14
    end

    test "parenthesized expressions" do
      assert Pyex.run!("(2 + 3) * 4") == 20
    end

    test "floor division and modulo" do
      assert Pyex.run!("17 // 5") == 3
      assert Pyex.run!("17 % 5") == 2
    end

    test "floor division toward negative infinity" do
      assert Pyex.run!("-7 // 2") == -4
      assert Pyex.run!("7 // -2") == -4
      assert Pyex.run!("-7 // -2") == 3
    end

    test "modulo follows divisor sign" do
      assert Pyex.run!("-7 % 2") == 1
      assert Pyex.run!("7 % -2") == -1
      assert Pyex.run!("-7 % -2") == -1
    end

    test "floor division with floats" do
      assert Pyex.run!("7.0 // 2") == 3.0
      assert Pyex.run!("-7.0 // 2") == -4.0
    end

    test "exponentiation" do
      assert Pyex.run!("2 ** 10") == 1024
    end

    test "unary negation" do
      assert Pyex.run!("-5 + 3") == -2
    end

    test "float arithmetic" do
      assert Pyex.run!("1.5 + 2.5") == 4.0
    end

    test "true division" do
      assert Pyex.run!("7 / 2") == 3.5
    end

    test "not-equal operator" do
      assert Pyex.run!("1 != 2") == true
      assert Pyex.run!("1 != 1") == false
    end

    test "greater-than-or-equal operator" do
      assert Pyex.run!("3 >= 3") == true
      assert Pyex.run!("2 >= 3") == false
    end
  end

  describe "variables and assignment" do
    test "simple assignment and reference" do
      assert Pyex.run!("x = 42\nx") == 42
    end

    test "chained assignments through expressions" do
      result =
        Pyex.run!("""
        x = 10
        y = x + 5
        y
        """)

      assert result == 15
    end
  end

  describe "conditionals" do
    test "if/elif/else" do
      result =
        Pyex.run!("""
        def classify(n):
            if n > 0:
                return 1
            elif n == 0:
                return 0
            else:
                return -1

        classify(-5)
        """)

      assert result == -1
    end
  end

  describe "boolean logic" do
    test "and/or/not" do
      assert Pyex.run!("True and False") == false
      assert Pyex.run!("True or False") == true
      assert Pyex.run!("not True") == false
    end

    test "truthy values follow Python semantics" do
      assert Pyex.run!("0 or 42") == 42
      assert Pyex.run!("None or 1") == 1
      assert Pyex.run!("1 and 2") == 2
    end

    test "falsy edge cases: 0.0, empty string, empty list, empty dict" do
      assert Pyex.run!("0.0 or 99") == 99
      assert Pyex.run!(~s("" or "fallback")) == "fallback"
      assert Pyex.run!("[] or 1") == 1
      assert Pyex.run!("{} or 1") == 1
    end
  end

  describe "while loops" do
    test "sum with a while loop" do
      result =
        Pyex.run!("""
        total = 0
        i = 1
        while i <= 10:
            total = total + i
            i = i + 1
        total
        """)

      assert result == 55
    end
  end

  describe "functions" do
    test "function with return" do
      result =
        Pyex.run!("""
        def double(n):
            return n * 2

        double(21)
        """)

      assert result == 42
    end

    test "function without explicit return yields None" do
      result =
        Pyex.run!("""
        def noop():
            pass

        noop()
        """)

      assert result == nil
    end

    test "closures capture enclosing scope" do
      result =
        Pyex.run!("""
        x = 10
        def add_x(n):
            return n + x

        add_x(5)
        """)

      assert result == 15
    end

    test "return inside if unwinds correctly" do
      result =
        Pyex.run!("""
        def abs_val(x):
            if x < 0:
                return -x
            return x

        abs_val(-7)
        """)

      assert result == 7
    end

    test "return inside while loop exits function" do
      result =
        Pyex.run!("""
        def find_first_even(n):
            i = 1
            while i <= n:
                if i % 2 == 0:
                    return i
                i = i + 1
            return -1

        find_first_even(10)
        """)

      assert result == 2
    end

    test "return inside for loop exits function" do
      result =
        Pyex.run!("""
        def find_negative(items):
            for x in items:
                if x < 0:
                    return x
            return None

        find_negative([3, 5, -2, 7])
        """)

      assert result == -2
    end

    test "recursive function calls itself" do
      result =
        Pyex.run!("""
        def factorial(n):
            if n <= 1:
                return 1
            return n * factorial(n - 1)

        factorial(10)
        """)

      assert result == 3_628_800
    end
  end

  describe "strings" do
    test "string literals" do
      assert Pyex.run!(~s("hello")) == "hello"
      assert Pyex.run!("'world'") == "world"
    end

    test "string concatenation with +" do
      assert Pyex.run!(~s("hello" + " " + "world")) == "hello world"
    end

    test "string repetition with *" do
      assert Pyex.run!(~s("ab" * 3)) == "ababab"
    end

    test "int * string repetition (reversed operand)" do
      assert Pyex.run!(~s(3 * "ab")) == "ababab"
    end
  end

  describe "lists" do
    test "list literal" do
      assert Pyex.run!("[1, 2, 3]") == [1, 2, 3]
    end

    test "empty list" do
      assert Pyex.run!("[]") == []
    end

    test "list subscript by index" do
      assert Pyex.run!("[10, 20, 30][1]") == 20
    end

    test "list concatenation with +" do
      assert Pyex.run!("[1, 2] + [3, 4]") == [1, 2, 3, 4]
    end

    test "list repetition with *" do
      assert Pyex.run!("[1, 2] * 3") == [1, 2, 1, 2, 1, 2]
    end

    test "int * list repetition (reversed operand)" do
      assert Pyex.run!("3 * [1, 2]") == [1, 2, 1, 2, 1, 2]
    end

    test "list * 0 yields empty list" do
      assert Pyex.run!("[1, 2, 3] * 0") == []
    end

    test "list slice [1:3]" do
      assert Pyex.run!("[10, 20, 30, 40, 50][1:3]") == [20, 30]
    end

    test "list slice with omitted start [:3]" do
      assert Pyex.run!("[10, 20, 30, 40, 50][:3]") == [10, 20, 30]
    end

    test "list slice with omitted stop [2:]" do
      assert Pyex.run!("[10, 20, 30, 40, 50][2:]") == [30, 40, 50]
    end

    test "list slice full copy [:]" do
      assert Pyex.run!("[10, 20, 30][:]") == [10, 20, 30]
    end

    test "list slice with negative indices" do
      assert Pyex.run!("[10, 20, 30, 40, 50][-3:-1]") == [30, 40]
    end

    test "list slice with step [::2]" do
      assert Pyex.run!("[0, 1, 2, 3, 4, 5][::2]") == [0, 2, 4]
    end

    test "list slice reverse [::-1]" do
      assert Pyex.run!("[1, 2, 3][::-1]") == [3, 2, 1]
    end

    test "string slice" do
      assert Pyex.run!(~s("hello"[1:4])) == "ell"
    end

    test "string slice reverse" do
      assert Pyex.run!(~s("hello"[::-1])) == "olleh"
    end
  end

  describe "dicts" do
    test "dict literal and subscript" do
      result =
        Pyex.run!("""
        d = {"a": 1, "b": 2}
        d["b"]
        """)

      assert result == 2
    end

    test "empty dict" do
      assert Pyex.run!("{}") == %{}
    end
  end

  describe "for loops" do
    test "iterate over a list" do
      result =
        Pyex.run!("""
        total = 0
        for x in [1, 2, 3, 4]:
            total = total + x
        total
        """)

      assert result == 10
    end

    test "for loop with conditional" do
      result =
        Pyex.run!("""
        count = 0
        for n in [1, 2, 3, 4, 5]:
            if n > 3:
                count = count + 1
        count
        """)

      assert result == 2
    end
  end

  describe "import" do
    test "import unknown module raises ImportError" do
      assert_raise RuntimeError, ~r/ImportError/, fn ->
        Pyex.run!("import nonexistent")
      end
    end
  end

  describe "error handling" do
    test "undefined variable raises NameError" do
      assert_raise RuntimeError, ~r/NameError.*undefined_var/, fn ->
        Pyex.run!("undefined_var")
      end
    end

    test "missing attribute raises AttributeError" do
      assert_raise RuntimeError, ~r/AttributeError/, fn ->
        Pyex.run!("""
        import json
        json.nonexistent
        """)
      end
    end

    test "missing dict key raises KeyError" do
      assert_raise RuntimeError, ~r/KeyError/, fn ->
        Pyex.run!("""
        d = {"a": 1}
        d["missing"]
        """)
      end
    end

    test "run! raises on parse error" do
      assert_raise RuntimeError, fn ->
        Pyex.run!("(1 +")
      end
    end
  end

  describe "comments" do
    test "inline comment is ignored" do
      assert Pyex.run!("x = 42 # the answer\nx") == 42
    end

    test "full-line comment between statements" do
      code = """
      x = 1
      # increment
      x = x + 1
      x
      """

      assert Pyex.run!(code) == 2
    end

    test "comment inside function body" do
      code = """
      def add(a, b):
          # sum two numbers
          return a + b
      add(3, 4)
      """

      assert Pyex.run!(code) == 7
    end

    test "hash inside string is not treated as comment" do
      assert Pyex.run!(~s[len("a#b")]) == 3
    end
  end

  describe "string subscript" do
    test "positive index" do
      assert Pyex.run!(~s|"hello"[0]|) == "h"
      assert Pyex.run!(~s|"hello"[4]|) == "o"
    end

    test "negative index" do
      assert Pyex.run!(~s|"hello"[-1]|) == "o"
      assert Pyex.run!(~s|"hello"[-5]|) == "h"
    end

    test "string index on variable" do
      code = """
      s = "abcde"
      s[2]
      """

      assert Pyex.run!(code) == "c"
    end

    test "index out of range raises" do
      assert_raise RuntimeError, ~r/IndexError/, fn ->
        Pyex.run!(~s|"hi"[5]|)
      end
    end
  end

  describe "for over strings" do
    test "iterates characters" do
      code = """
      result = ""
      for ch in "abc":
          result = result + ch + "-"
      result
      """

      assert Pyex.run!(code) == "a-b-c-"
    end

    test "for over string with len" do
      code = """
      count = 0
      for ch in "hello":
          count = count + 1
      count
      """

      assert Pyex.run!(code) == 5
    end
  end

  describe "for over dicts" do
    test "iterates keys" do
      code = """
      d = {"a": 1, "b": 2, "c": 3}
      keys = ""
      for k in d:
          keys = keys + k
      len(keys)
      """

      assert Pyex.run!(code) == 3
    end
  end

  describe "break and continue" do
    test "break exits while loop" do
      code = """
      i = 0
      while True:
          if i == 5:
              break
          i = i + 1
      i
      """

      assert Pyex.run!(code) == 5
    end

    test "continue skips to next iteration in while" do
      code = """
      total = 0
      i = 0
      while i < 10:
          i = i + 1
          if i % 2 == 0:
              continue
          total = total + i
      total
      """

      assert Pyex.run!(code) == 25
    end

    test "break exits for loop" do
      code = """
      result = 0
      for i in range(100):
          if i == 5:
              break
          result = result + i
      result
      """

      assert Pyex.run!(code) == 10
    end

    test "continue skips in for loop" do
      code = """
      result = ""
      for i in range(6):
          if i == 3:
              continue
          result = result + str(i)
      result
      """

      assert Pyex.run!(code) == "01245"
    end
  end

  describe "in and not in operators" do
    test "x in list" do
      assert Pyex.run!("3 in [1, 2, 3]") == true
      assert Pyex.run!("4 in [1, 2, 3]") == false
    end

    test "x not in list" do
      assert Pyex.run!("4 not in [1, 2, 3]") == true
      assert Pyex.run!("3 not in [1, 2, 3]") == false
    end

    test "key in dict" do
      assert Pyex.run!(~s("a" in {"a": 1, "b": 2})) == true
      assert Pyex.run!(~s("c" in {"a": 1, "b": 2})) == false
    end

    test "key not in dict" do
      assert Pyex.run!(~s("c" not in {"a": 1, "b": 2})) == true
      assert Pyex.run!(~s("a" not in {"a": 1, "b": 2})) == false
    end

    test "substring in string" do
      assert Pyex.run!(~s("ell" in "hello")) == true
      assert Pyex.run!(~s("xyz" in "hello")) == false
    end

    test "substring not in string" do
      assert Pyex.run!(~s("xyz" not in "hello")) == true
      assert Pyex.run!(~s("ell" not in "hello")) == false
    end

    test "in used in if condition" do
      result =
        Pyex.run!("""
        items = [1, 2, 3, 4, 5]
        if 3 in items:
            x = "found"
        else:
            x = "missing"
        x
        """)

      assert result == "found"
    end
  end

  describe "default arguments" do
    test "uses default when argument not provided" do
      result =
        Pyex.run!("""
        def greet(name, greeting="Hello"):
            return greeting + " " + name

        greet("World")
        """)

      assert result == "Hello World"
    end

    test "override default argument" do
      result =
        Pyex.run!("""
        def greet(name, greeting="Hello"):
            return greeting + " " + name

        greet("World", "Hi")
        """)

      assert result == "Hi World"
    end
  end

  describe "keyword arguments" do
    test "call with keyword argument" do
      result =
        Pyex.run!("""
        def greet(name, greeting="Hello"):
            return greeting + " " + name

        greet(greeting="Hi", name="World")
        """)

      assert result == "Hi World"
    end

    test "mix positional and keyword arguments" do
      result =
        Pyex.run!("""
        def add(a, b, c=0):
            return a + b + c

        add(1, c=10, b=2)
        """)

      assert result == 13
    end
  end

  describe "decorators" do
    test "simple decorator wraps function" do
      result =
        Pyex.run!("""
        def double_result(fn):
            def wrapper():
                return fn() * 2
            return wrapper

        @double_result
        def get_value():
            return 21

        get_value()
        """)

      assert result == 42
    end

    test "decorator with arguments (decorator factory)" do
      result =
        Pyex.run!("""
        def multiply(factor):
            def decorator(fn):
                def wrapper():
                    return fn() * factor
                return wrapper
            return decorator

        @multiply(3)
        def get_value():
            return 14

        get_value()
        """)

      assert result == 42
    end
  end

  describe "bare return" do
    test "return with no value returns None" do
      result =
        Pyex.run!("""
        def f():
            return

        f()
        """)

      assert result == nil
    end

    test "bare return in conditional" do
      result =
        Pyex.run!("""
        def check(x):
            if x > 10:
                return
            return x

        check(20)
        """)

      assert result == nil
    end
  end

  describe "is / is not operators" do
    test "x is None" do
      assert Pyex.run!("None is None") == true
      assert Pyex.run!("0 is None") == false
    end

    test "x is not None" do
      assert Pyex.run!("1 is not None") == true
      assert Pyex.run!("None is not None") == false
    end

    test "is with booleans" do
      assert Pyex.run!("True is True") == true
      assert Pyex.run!("False is False") == true
      assert Pyex.run!("True is False") == false
    end

    test "is in if condition" do
      result =
        Pyex.run!("""
        x = None
        if x is None:
            y = "none"
        else:
            y = "not none"
        y
        """)

      assert result == "none"
    end
  end

  describe "ternary if/else expression" do
    test "true branch" do
      assert Pyex.run!("1 if True else 2") == 1
    end

    test "false branch" do
      assert Pyex.run!("1 if False else 2") == 2
    end

    test "ternary with variables" do
      result =
        Pyex.run!("""
        x = 10
        result = "big" if x > 5 else "small"
        result
        """)

      assert result == "big"
    end

    test "nested ternary" do
      result =
        Pyex.run!("""
        x = 5
        result = "pos" if x > 0 else "zero" if x == 0 else "neg"
        result
        """)

      assert result == "pos"
    end

    test "ternary in function return" do
      result =
        Pyex.run!("""
        def sign(x):
            return 1 if x > 0 else -1

        sign(-5)
        """)

      assert result == -1
    end
  end

  describe "lambda expressions" do
    test "simple lambda" do
      result =
        Pyex.run!("""
        f = lambda x: x + 1
        f(10)
        """)

      assert result == 11
    end

    test "lambda with multiple params" do
      result =
        Pyex.run!("""
        add = lambda a, b: a + b
        add(3, 4)
        """)

      assert result == 7
    end

    test "lambda with no params" do
      result =
        Pyex.run!("""
        f = lambda: 42
        f()
        """)

      assert result == 42
    end

    test "lambda as sort key" do
      result =
        Pyex.run!("""
        items = [[3, "c"], [1, "a"], [2, "b"]]
        result = sorted(items)
        result
        """)

      assert result == [[1, "a"], [2, "b"], [3, "c"]]
    end

    test "lambda in list" do
      result =
        Pyex.run!("""
        ops = [lambda x: x + 1, lambda x: x * 2]
        ops[0](5)
        """)

      assert result == 6
    end
  end

  describe "multiple assignment / unpacking" do
    test "simple multi-assign" do
      result =
        Pyex.run!("""
        a, b = 1, 2
        a + b
        """)

      assert result == 3
    end

    test "three variables" do
      result =
        Pyex.run!("""
        x, y, z = 10, 20, 30
        x + y + z
        """)

      assert result == 60
    end

    test "unpack from list" do
      result =
        Pyex.run!("""
        a, b, c = [1, 2, 3]
        b
        """)

      assert result == 2
    end

    test "unpack from function return" do
      result =
        Pyex.run!("""
        def pair():
            return [10, 20]

        a, b = pair()
        a + b
        """)

      assert result == 30
    end

    test "swap values" do
      result =
        Pyex.run!("""
        a, b = 1, 2
        a, b = b, a
        a
        """)

      assert result == 2
    end

    test "starred unpack at end" do
      result =
        Pyex.run!("""
        first, *rest = [1, 2, 3, 4, 5]
        (first, rest)
        """)

      assert result == {:tuple, [1, [2, 3, 4, 5]]}
    end

    test "starred unpack at start" do
      result =
        Pyex.run!("""
        *init, last = [1, 2, 3, 4, 5]
        (init, last)
        """)

      assert result == {:tuple, [[1, 2, 3, 4], 5]}
    end

    test "starred unpack in middle" do
      result =
        Pyex.run!("""
        a, *mid, z = [1, 2, 3, 4, 5]
        (a, mid, z)
        """)

      assert result == {:tuple, [1, [2, 3, 4], 5]}
    end

    test "starred unpack with empty rest" do
      result =
        Pyex.run!("""
        a, *rest = [1]
        (a, rest)
        """)

      assert result == {:tuple, [1, []]}
    end

    test "starred unpack from tuple" do
      result =
        Pyex.run!("""
        first, *rest = (10, 20, 30)
        (first, rest)
        """)

      assert result == {:tuple, [10, [20, 30]]}
    end

    test "starred unpack from range" do
      result =
        Pyex.run!("""
        first, *rest = range(5)
        (first, rest)
        """)

      assert result == {:tuple, [0, [1, 2, 3, 4]]}
    end

    test "starred unpack too few values" do
      {:error, %Error{message: msg}} =
        Pyex.run("""
        a, b, *rest = [1]
        """)

      assert msg =~ "ValueError"
    end
  end

  describe "tuple type" do
    test "tuple literal" do
      result = Pyex.run!("(1, 2, 3)")
      assert result == {:tuple, [1, 2, 3]}
    end

    test "single-element tuple needs trailing comma" do
      assert Pyex.run!("(1,)") == {:tuple, [1]}
    end

    test "empty tuple" do
      assert Pyex.run!("()") == {:tuple, []}
    end

    test "tuple() constructor" do
      assert Pyex.run!("tuple()") == {:tuple, []}
      assert Pyex.run!("tuple([1, 2, 3])") == {:tuple, [1, 2, 3]}
    end

    test "len of tuple" do
      assert Pyex.run!("len((1, 2, 3))") == 3
    end

    test "tuple subscript" do
      assert Pyex.run!("(10, 20, 30)[1]") == 20
    end

    test "in operator with tuple" do
      assert Pyex.run!("2 in (1, 2, 3)") == true
      assert Pyex.run!("4 in (1, 2, 3)") == false
    end

    test "for over tuple" do
      result =
        Pyex.run!("""
        total = 0
        for x in (1, 2, 3):
            total = total + x
        total
        """)

      assert result == 6
    end

    test "tuple type function" do
      {:instance, _, %{"__name__" => name}} = Pyex.run!("type((1, 2))")
      assert name == "tuple"
    end
  end

  describe "f-strings" do
    test "simple interpolation" do
      result =
        Pyex.run!("""
        name = "World"
        f"Hello {name}"
        """)

      assert result == "Hello World"
    end

    test "expression in f-string" do
      assert Pyex.run!("f\"{1 + 2}\"") == "3"
    end

    test "multiple interpolations" do
      result =
        Pyex.run!("""
        x = 3
        y = 4
        f"{x} + {y} = {x + y}"
        """)

      assert result == "3 + 4 = 7"
    end

    test "f-string with no interpolation" do
      assert Pyex.run!("f\"hello\"") == "hello"
    end

    test "f-string with function call" do
      result =
        Pyex.run!("""
        name = "world"
        f"Hello {name.upper()}"
        """)

      assert result == "Hello WORLD"
    end
  end

  describe "triple-quoted strings" do
    test "double-quote triple string" do
      result = Pyex.run!(~s|x = \"""hello\"""\nx|)
      assert result == "hello"
    end

    test "single-quote triple string" do
      result = Pyex.run!("x = '''hello'''\nx")
      assert result == "hello"
    end

    test "triple string with newlines" do
      result = Pyex.run!(~s|x = \"""line1\nline2\"""\nlen(x)|)
      assert result == 11
    end
  end

  describe "os.environ" do
    test "reads environment variable from ctx" do
      ctx = Pyex.Ctx.new(environ: %{"MY_KEY" => "secret123"})

      {:ok, result, _ctx} =
        Pyex.run(
          """
          import os
          os.environ["MY_KEY"]
          """,
          ctx
        )

      assert result == "secret123"
    end

    test "missing key returns KeyError" do
      ctx = Pyex.Ctx.new(environ: %{})

      assert {:error, %Error{message: msg}} =
               Pyex.run(
                 """
                 import os
                 os.environ["MISSING"]
                 """,
                 ctx
               )

      assert msg =~ "KeyError"
    end

    test "environ is a dict supporting in operator" do
      ctx = Pyex.Ctx.new(environ: %{"A" => "1", "B" => "2"})

      {:ok, result, _ctx} =
        Pyex.run(
          """
          import os
          "A" in os.environ
          """,
          ctx
        )

      assert result == true
    end

    test "default empty environ when not provided" do
      {:ok, result, _ctx} =
        Pyex.run("""
        import os
        len(os.environ)
        """)

      assert result == 0
    end
  end

  describe "from_import" do
    test "from math import sin" do
      assert {:ok, +0.0, _ctx} = Pyex.run("from math import sin\nsin(0)")
    end

    test "from math import multiple names" do
      assert {:ok, result, _ctx} = Pyex.run("from math import pi, sin\nsin(pi)")
      assert_in_delta result, 0.0, 1.0e-10
    end

    test "from json import loads" do
      assert {:ok, [1, 2, 3], _ctx} = Pyex.run("from json import loads\nloads(\"[1,2,3]\")")
    end

    test "from X import Y as Z" do
      assert {:ok, +0.0, _ctx} = Pyex.run("from math import sin as s\ns(0)")
    end

    test "from fastapi import FastAPI" do
      app =
        Pyex.run!("""
        from fastapi import FastAPI
        app = FastAPI()
        app
        """)

      assert is_map(app)
      assert Map.has_key?(app, "__routes__")
    end

    test "importing nonexistent name returns error" do
      assert {:error, %Error{message: msg}} = Pyex.run("from math import nonexistent")
      assert msg =~ "ImportError"
      assert msg =~ "nonexistent"
    end

    test "importing from nonexistent module returns error" do
      assert {:error, %Error{message: msg}} = Pyex.run("from nope import x")
      assert msg =~ "ImportError"
      assert msg =~ "nope"
    end
  end

  describe "for loop tuple unpacking" do
    test "for k, v in dict.items()" do
      assert {:ok, ["a=1", "b=2"], _ctx} =
               Pyex.run("""
               d = {"a": 1, "b": 2}
               result = []
               for k, v in d.items():
                   result.append(k + "=" + str(v))
               result
               """)
    end

    test "for a, b in list of lists" do
      assert {:ok, 9, _ctx} =
               Pyex.run("""
               total = 0
               for a, b in [[1, 2], [3, 4], [5, 6]]:
                   total = total + a
               total
               """)
    end

    test "for with tuple unpacking in list comprehension" do
      assert {:ok, ["x=1", "y=2"], _ctx} =
               Pyex.run(~s|[k + "=" + str(v) for k, v in {"x": 1, "y": 2}.items()]|)
    end

    test "for k, v with wrong item length returns error" do
      assert {:error, %Error{message: msg}} =
               Pyex.run("""
               for a, b in [[1, 2, 3]]:
                   pass
               """)

      assert msg =~ "ValueError"
    end
  end

  describe "chained comparisons" do
    test "simple two-operator chain" do
      assert Pyex.run!("1 < 2 < 3") == true
      assert Pyex.run!("1 < 3 < 2") == false
      assert Pyex.run!("3 < 2 < 1") == false
    end

    test "three-operator chain" do
      assert Pyex.run!("1 < 2 < 3 < 4") == true
      assert Pyex.run!("1 < 2 < 4 < 3") == false
    end

    test "mixed comparison operators" do
      assert Pyex.run!("1 < 2 <= 2 < 3") == true
      assert Pyex.run!("1 <= 1 < 2 <= 2") == true
    end

    test "chained equality" do
      assert Pyex.run!("1 == 1 == 1") == true
      assert Pyex.run!("1 == 1 == 2") == false
    end

    test "chained with variables" do
      code = """
      x = 5
      1 < x < 10
      """

      assert Pyex.run!(code) == true

      code2 = """
      x = 15
      1 < x < 10
      """

      assert Pyex.run!(code2) == false
    end

    test "short-circuit stops early on false" do
      code = """
      x = 5
      10 < x < 3
      """

      assert Pyex.run!(code) == false
    end

    test "middle operand evaluated only once in chain" do
      code = """
      x = 5
      1 < x < 10
      """

      assert Pyex.run!(code) == true
    end

    test "chained with in operator" do
      code = """
      x = 3
      0 < x < 10
      """

      assert Pyex.run!(code) == true
    end

    test "chained gte and lte" do
      assert Pyex.run!("0 <= 0 <= 1") == true
      assert Pyex.run!("0 >= 0 >= -1") == true
    end

    test "short-circuit skips later operands" do
      assert Pyex.run!("10 < 5 < 1 / 0") == false
    end

    test "single comparison still works" do
      assert Pyex.run!("1 < 2") == true
      assert Pyex.run!("2 < 1") == false
    end
  end

  describe "else on for loop" do
    test "else runs when loop completes normally" do
      assert Pyex.run!("""
             result = "none"
             for x in [1, 2, 3]:
                 pass
             else:
                 result = "completed"
             result
             """) == "completed"
    end

    test "else does not run when break is used" do
      assert Pyex.run!("""
             result = "none"
             for x in [1, 2, 3]:
                 break
             else:
                 result = "completed"
             result
             """) == "none"
    end

    test "else runs on empty iterable" do
      assert Pyex.run!("""
             result = "none"
             for x in []:
                 result = "body"
             else:
                 result = "completed"
             result
             """) == "completed"
    end

    test "for-else without break exits normally" do
      assert Pyex.run!("""
             found = False
             for x in [1, 2, 3]:
                 if x == 2:
                     found = True
             else:
                 found = "else ran"
             found
             """) == "else ran"
    end
  end

  describe "else on while loop" do
    test "else runs when condition becomes false" do
      assert Pyex.run!("""
             x = 3
             result = "none"
             while x > 0:
                 x = x - 1
             else:
                 result = "completed"
             result
             """) == "completed"
    end

    test "else does not run when break is used" do
      assert Pyex.run!("""
             x = 3
             result = "none"
             while x > 0:
                 x = x - 1
                 if x == 1:
                     break
             else:
                 result = "completed"
             result
             """) == "none"
    end

    test "else runs when condition is initially false" do
      assert Pyex.run!("""
             result = "none"
             while False:
                 result = "body"
             else:
                 result = "completed"
             result
             """) == "completed"
    end
  end

  describe "assert statement" do
    test "assert passes on truthy" do
      assert Pyex.run!("assert True") == nil
      assert Pyex.run!("assert 1") == nil
    end

    test "assert fails on falsy" do
      {:error, %Error{message: msg}} = Pyex.run("assert False")
      assert msg =~ "AssertionError"
    end

    test "assert with message" do
      {:error, %Error{message: msg}} = Pyex.run(~s|assert False, "oops"|)
      assert msg =~ "AssertionError: oops"
    end

    test "assert with expression" do
      assert Pyex.run!("assert 1 + 1 == 2") == nil
    end
  end

  describe "del statement" do
    test "del variable" do
      {:error, %Error{message: msg}} =
        Pyex.run("""
        x = 10
        del x
        x
        """)

      assert msg =~ "NameError"
    end

    test "del dict key" do
      assert Pyex.run!("""
             d = {"a": 1, "b": 2}
             del d["a"]
             d
             """) == %{"b" => 2}
    end

    test "del list element" do
      assert Pyex.run!("""
             lst = [1, 2, 3]
             del lst[1]
             lst
             """) == [1, 3]
    end
  end

  describe "augmented subscript assignment" do
    test "dict value += " do
      assert Pyex.run!("""
             d = {"a": 1}
             d["a"] += 10
             d["a"]
             """) == 11
    end

    test "list element += " do
      assert Pyex.run!("""
             lst = [10, 20, 30]
             lst[1] += 5
             lst
             """) == [10, 25, 30]
    end

    test "dict value *= " do
      assert Pyex.run!("""
             d = {"x": 3}
             d["x"] *= 4
             d["x"]
             """) == 12
    end

    test "nested dict augmented assign" do
      assert Pyex.run!("""
             counts = {"a": 0, "b": 0}
             counts["a"] += 1
             counts["a"] += 1
             counts["b"] += 1
             counts
             """) == %{"a" => 2, "b" => 1}
    end
  end

  describe "chained assignment" do
    test "a = b = 1" do
      assert Pyex.run!("""
             a = b = 1
             a + b
             """) == 2
    end

    test "a = b = c = 5" do
      assert Pyex.run!("""
             a = b = c = 5
             a + b + c
             """) == 15
    end

    test "chained assign with expression" do
      assert Pyex.run!("""
             x = y = 2 + 3
             x * y
             """) == 25
    end
  end

  describe "global keyword" do
    test "global variable is accessible after function call" do
      result =
        Pyex.run!("""
        x = 0
        def set_x():
            global x
            x = 42
        set_x()
        x
        """)

      assert result == 42
    end

    test "global variable created inside function" do
      result =
        Pyex.run!("""
        def make_global():
            global y
            y = 99
        make_global()
        y
        """)

      assert result == 99
    end

    test "multiple global declarations" do
      result =
        Pyex.run!("""
        a = 1
        b = 2
        def swap():
            global a, b
            a, b = b, a
        swap()
        a
        """)

      assert result == 2
    end

    test "global with augmented assignment" do
      result =
        Pyex.run!("""
        counter = 0
        def increment():
            global counter
            counter += 1
        increment()
        increment()
        increment()
        counter
        """)

      assert result == 3
    end
  end

  describe "nonlocal keyword" do
    test "nonlocal modifies enclosing variable" do
      result =
        Pyex.run!("""
        def outer():
            x = 10
            def inner():
                nonlocal x
                x = 20
            inner()
            return x
        outer()
        """)

      assert result == 20
    end

    test "nonlocal counter pattern" do
      result =
        Pyex.run!("""
        def make_counter():
            count = 0
            def increment():
                nonlocal count
                count += 1
                return count
            return increment
        c = make_counter()
        c()
        c()
        c()
        """)

      assert result == 3
    end

    test "multiple nonlocal declarations" do
      result =
        Pyex.run!("""
        def outer():
            a = 1
            b = 2
            def inner():
                nonlocal a, b
                a = 10
                b = 20
            inner()
            return a + b
        outer()
        """)

      assert result == 30
    end
  end

  describe "*args and **kwargs" do
    test "*args collects extra positional arguments" do
      result =
        Pyex.run!("""
        def f(a, *args):
            return args
        f(1, 2, 3, 4)
        """)

      assert result == [2, 3, 4]
    end

    test "*args is empty when no extra args" do
      result =
        Pyex.run!("""
        def f(a, *args):
            return args
        f(1)
        """)

      assert result == []
    end

    test "**kwargs collects extra keyword arguments" do
      result =
        Pyex.run!("""
        def f(a, **kwargs):
            return kwargs
        f(1, x=10, y=20)
        """)

      assert result == %{"x" => 10, "y" => 20}
    end

    test "**kwargs is empty when no extra kwargs" do
      result =
        Pyex.run!("""
        def f(a, **kwargs):
            return kwargs
        f(1)
        """)

      assert result == %{}
    end

    test "*args and **kwargs together" do
      result =
        Pyex.run!("""
        def f(*args, **kwargs):
            return [args, kwargs]
        f(1, 2, x=3)
        """)

      assert result == [[1, 2], %{"x" => 3}]
    end

    test "regular + *args + **kwargs" do
      result =
        Pyex.run!("""
        def f(a, b, *args, **kwargs):
            return [a, b, args, kwargs]
        f(1, 2, 3, 4, key="val")
        """)

      assert result == [1, 2, [3, 4], %{"key" => "val"}]
    end

    test "len(*args)" do
      result =
        Pyex.run!("""
        def count(*args):
            return len(args)
        count(1, 2, 3)
        """)

      assert result == 3
    end

    test "*args with for loop" do
      result =
        Pyex.run!("""
        def total(*args):
            s = 0
            for x in args:
                s += x
            return s
        total(10, 20, 30)
        """)

      assert result == 60
    end
  end

  describe "set type" do
    test "set literal" do
      result = Pyex.run!("{1, 2, 3}")
      assert result == {:set, MapSet.new([1, 2, 3])}
    end

    test "set() constructor empty" do
      result = Pyex.run!("set()")
      assert result == {:set, MapSet.new()}
    end

    test "set() from list" do
      result = Pyex.run!("set([1, 2, 2, 3])")
      assert result == {:set, MapSet.new([1, 2, 3])}
    end

    test "set() from string" do
      result = Pyex.run!("set(\"abc\")")
      {:set, s} = result
      assert MapSet.size(s) == 3
    end

    test "len of set" do
      assert Pyex.run!("len({1, 2, 3})") == 3
    end

    test "in operator with set" do
      assert Pyex.run!("2 in {1, 2, 3}") == true
      assert Pyex.run!("5 in {1, 2, 3}") == false
    end

    test "for loop over set" do
      result =
        Pyex.run!("""
        s = 0
        for x in {10, 20, 30}:
            s += x
        s
        """)

      assert result == 60
    end

    test "set difference with -" do
      result = Pyex.run!("{1, 2, 3} - {2}")
      assert result == {:set, MapSet.new([1, 3])}
    end

    test "set.add()" do
      result =
        Pyex.run!("""
        s = {1, 2}
        s.add(3)
        s
        """)

      assert result == {:set, MapSet.new([1, 2, 3])}
    end

    test "set.remove()" do
      result =
        Pyex.run!("""
        s = {1, 2, 3}
        s.remove(2)
        s
        """)

      assert result == {:set, MapSet.new([1, 3])}
    end

    test "set.discard() on missing element" do
      result =
        Pyex.run!("""
        s = {1, 2}
        s.discard(99)
        s
        """)

      assert result == {:set, MapSet.new([1, 2])}
    end

    test "set.union()" do
      result = Pyex.run!("{1, 2}.union({2, 3})")
      assert result == {:set, MapSet.new([1, 2, 3])}
    end

    test "set.intersection()" do
      result = Pyex.run!("{1, 2, 3}.intersection({2, 3, 4})")
      assert result == {:set, MapSet.new([2, 3])}
    end

    test "set.issubset()" do
      assert Pyex.run!("{1, 2}.issubset({1, 2, 3})") == true
      assert Pyex.run!("{1, 4}.issubset({1, 2, 3})") == false
    end

    test "sorted(set)" do
      assert Pyex.run!("sorted({3, 1, 2})") == [1, 2, 3]
    end

    test "list(set)" do
      result = Pyex.run!("list({1, 2, 3})")
      assert is_list(result)
      assert Enum.sort(result) == [1, 2, 3]
    end

    test "empty set is falsy" do
      assert Pyex.run!("not set()") == true
      assert Pyex.run!("not {1}") == false
    end

    test "isinstance with set" do
      assert Pyex.run!("isinstance({1, 2}, \"set\")") == true
    end
  end

  describe "bitwise operators" do
    test "bitwise AND" do
      assert Pyex.run!("0b1100 & 0b1010") == 0b1000
      assert Pyex.run!("15 & 9") == 9
    end

    test "bitwise OR" do
      assert Pyex.run!("0b1100 | 0b1010") == 0b1110
      assert Pyex.run!("8 | 5") == 13
    end

    test "bitwise XOR" do
      assert Pyex.run!("0b1100 ^ 0b1010") == 0b0110
      assert Pyex.run!("12 ^ 10") == 6
    end

    test "bitwise NOT" do
      assert Pyex.run!("~0") == -1
      assert Pyex.run!("~1") == -2
      assert Pyex.run!("~-1") == 0
      assert Pyex.run!("~42") == -43
    end

    test "left shift" do
      assert Pyex.run!("1 << 4") == 16
      assert Pyex.run!("3 << 2") == 12
    end

    test "right shift" do
      assert Pyex.run!("16 >> 2") == 4
      assert Pyex.run!("15 >> 1") == 7
    end

    test "precedence: bitwise AND binds tighter than OR" do
      assert Pyex.run!("1 | 2 & 3") == 3
      assert Pyex.run!("(1 | 2) & 3") == 3
    end

    test "precedence: shift binds tighter than bitwise AND" do
      assert Pyex.run!("1 << 2 & 7") == 4
    end

    test "precedence: arithmetic binds tighter than shift" do
      assert Pyex.run!("1 << 2 + 1") == 8
    end

    test "bitwise XOR between AND and OR in precedence" do
      assert Pyex.run!("2 | 4 ^ 6") == 2
    end

    test "chained bitwise" do
      assert Pyex.run!("0xFF & 0x0F | 0xF0") == 0xFF
    end

    test "bitwise type errors" do
      {:error, %Error{message: msg}} = Pyex.run("1.0 & 2")
      assert msg =~ "TypeError"

      {:error, %Error{message: msg}} = Pyex.run("~1.5")
      assert msg =~ "TypeError"
    end

    test "set operations with | & ^" do
      assert Pyex.run!("{1, 2} | {2, 3}") == {:set, MapSet.new([1, 2, 3])}
      assert Pyex.run!("{1, 2, 3} & {2, 3, 4}") == {:set, MapSet.new([2, 3])}
      assert Pyex.run!("{1, 2, 3} ^ {2, 3, 4}") == {:set, MapSet.new([1, 4])}
    end

    test "augmented bitwise assignment" do
      assert Pyex.run!("x = 0xFF\nx &= 0x0F\nx") == 0x0F
      assert Pyex.run!("x = 0\nx |= 0xFF\nx") == 0xFF
      assert Pyex.run!("x = 0xFF\nx ^= 0x0F\nx") == 0xF0
      assert Pyex.run!("x = 1\nx <<= 4\nx") == 16
      assert Pyex.run!("x = 16\nx >>= 2\nx") == 4
    end

    test "augmented bitwise on subscripts" do
      assert Pyex.run!("""
             d = {"flags": 0}
             d["flags"] |= 0x01
             d["flags"] |= 0x04
             d["flags"]
             """) == 5
    end
  end

  describe "unary plus" do
    test "unary plus on integers" do
      assert Pyex.run!("+5") == 5
      assert Pyex.run!("+0") == 0
    end

    test "unary plus on floats" do
      assert Pyex.run!("+3.14") == 3.14
    end

    test "unary plus on negative" do
      assert Pyex.run!("+-5") == -5
    end

    test "unary plus type error" do
      {:error, %Error{message: msg}} = Pyex.run(~s|+"hello"|)
      assert msg =~ "TypeError"
    end
  end

  describe "starred expressions in calls" do
    test "*args unpacking in call" do
      result =
        Pyex.run!("""
        def add(a, b, c):
            return a + b + c
        args = [1, 2, 3]
        add(*args)
        """)

      assert result == 6
    end

    test "**kwargs unpacking in call" do
      result =
        Pyex.run!("""
        def greet(name, greeting):
            return greeting + " " + name
        kw = {"name": "World", "greeting": "Hello"}
        greet(**kw)
        """)

      assert result == "Hello World"
    end

    test "mixed positional and *args" do
      result =
        Pyex.run!("""
        def f(a, b, c, d):
            return [a, b, c, d]
        rest = [3, 4]
        f(1, 2, *rest)
        """)

      assert result == [1, 2, 3, 4]
    end

    test "mixed *args and **kwargs" do
      result =
        Pyex.run!("""
        def f(a, b, c=0):
            return a + b + c
        f(*[1, 2], **{"c": 10})
        """)

      assert result == 13
    end

    test "*args with builtin" do
      result =
        Pyex.run!("""
        args = [1, 10]
        list(range(*args))
        """)

      assert result == [1, 2, 3, 4, 5, 6, 7, 8, 9]
    end

    test "**kwargs with string keys" do
      result =
        Pyex.run!("""
        def f(x, y):
            return x * y
        f(**{"x": 3, "y": 4})
        """)

      assert result == 12
    end
  end

  describe "semicolon statement separator" do
    test "two statements on one line" do
      assert Pyex.run!("x = 1; x + 1") == 2
    end

    test "three statements on one line" do
      assert Pyex.run!("x = 1; y = 2; x + y") == 3
    end

    test "semicolon inside string is preserved" do
      assert Pyex.run!(~s|"a;b"|) == "a;b"
    end

    test "semicolon with function calls" do
      result =
        Pyex.run!("""
        items = []; items.append(1); items.append(2)
        items
        """)

      assert result == [1, 2]
    end
  end

  describe "infinity and nan" do
    test "float('inf') returns infinity atom" do
      assert Pyex.run!("float('inf')") == :infinity
    end

    test "float('-inf') returns neg_infinity atom" do
      assert Pyex.run!("float('-inf')") == :neg_infinity
    end

    test "float('nan') returns nan atom" do
      assert Pyex.run!("float('nan')") == :nan
    end

    test "float('infinity') case insensitive" do
      assert Pyex.run!("float('Infinity')") == :infinity
      assert Pyex.run!("float('+inf')") == :infinity
      assert Pyex.run!("float('-Infinity')") == :neg_infinity
    end

    test "str() of special floats" do
      assert Pyex.run!("str(float('inf'))") == "inf"
      assert Pyex.run!("str(float('-inf'))") == "-inf"
      assert Pyex.run!("str(float('nan'))") == "nan"
    end

    test "math.inf and math.nan" do
      assert Pyex.run!("import math\nmath.inf") == :infinity
      assert Pyex.run!("import math\nmath.nan") == :nan
    end

    test "math.isinf()" do
      assert Pyex.run!("import math\nmath.isinf(math.inf)") == true
      assert Pyex.run!("import math\nmath.isinf(float('-inf'))") == true
      assert Pyex.run!("import math\nmath.isinf(42)") == false
    end

    test "math.isnan()" do
      assert Pyex.run!("import math\nmath.isnan(math.nan)") == true
      assert Pyex.run!("import math\nmath.isnan(42)") == false
    end

    test "special floats are truthy" do
      assert Pyex.run!("bool(float('inf'))") == true
      assert Pyex.run!("bool(float('nan'))") == true
    end
  end

  describe "walrus operator :=" do
    test "basic walrus in if condition" do
      result =
        Pyex.run!("""
        if (n := 10) > 5:
            x = n
        else:
            x = 0
        x
        """)

      assert result == 10
    end

    test "walrus assigns and returns value" do
      assert Pyex.run!("(x := 42)") == 42
    end

    test "walrus in while loop" do
      result =
        Pyex.run!("""
        items = [1, 2, 3, 0, 4]
        total = 0
        i = 0
        while (val := items[i]) != 0:
            total += val
            i += 1
        total
        """)

      assert result == 6
    end

    test "walrus variable accessible after expression" do
      result =
        Pyex.run!("""
        data = [1, 2, 3, 4, 5]
        if (n := len(data)) > 3:
            result = n
        else:
            result = 0
        result
        """)

      assert result == 5
    end

    test "walrus in list comprehension filter" do
      result =
        Pyex.run!("""
        results = [y for x in [1, 2, 3, 4] if (y := x * 2) > 4]
        results
        """)

      assert result == [6, 8]
    end
  end

  describe "inline if body" do
    test "if x: y" do
      assert Pyex.run!("x = 5\nif x > 3: x = 10\nx") == 10
    end

    test "if/else inline" do
      result =
        Pyex.run!("""
        x = 1
        if x > 5: y = "big"
        else: y = "small"
        y
        """)

      assert result == "small"
    end

    test "inline if with function call" do
      result =
        Pyex.run!("""
        items = []
        if True: items.append(1)
        items
        """)

      assert result == [1]
    end

    test "inline if false branch not taken" do
      assert Pyex.run!("x = 0\nif False: x = 99\nx") == 0
    end
  end

  describe "type annotations" do
    test "variable annotation with value" do
      assert Pyex.run!("x: int = 5\nx") == 5
    end

    test "bare variable annotation" do
      result =
        Pyex.run!("""
        x: int
        y = 10
        y
        """)

      assert result == 10
    end

    test "complex type annotation" do
      assert Pyex.run!("x: List[int] = [1, 2]\nx") == [1, 2]
    end

    test "None type annotation" do
      assert Pyex.run!("x: None = None\nx") == nil
    end

    test "function with annotated params and return" do
      result =
        Pyex.run!("""
        def add(a: int, b: int) -> int:
            return a + b
        add(3, 4)
        """)

      assert result == 7
    end
  end

  describe "string % formatting" do
    test "basic string substitution" do
      assert Pyex.run!(~s("Hello %s" % "world")) == "Hello world"
    end

    test "integer substitution with %d" do
      assert Pyex.run!(~s("%d items" % 5)) == "5 items"
    end

    test "multiple substitutions with tuple" do
      assert Pyex.run!(~S["Name: %s, Age: %d" % ("Alice", 30)]) == "Name: Alice, Age: 30"
    end

    test "float formatting with %f" do
      assert Pyex.run!(~s("%.2f" % 3.14159)) == "3.14"
    end

    test "zero-padded integer" do
      assert Pyex.run!(~s("%05d" % 42)) == "00042"
    end

    test "literal percent with %%" do
      assert Pyex.run!(~S["100%%" % ()]) == "100%"
    end

    test "hex formatting with %x" do
      assert Pyex.run!(~s("%x" % 255)) == "ff"
    end

    test "octal formatting with %o" do
      assert Pyex.run!(~s("%o" % 8)) == "10"
    end

    test "repr formatting with %r" do
      assert Pyex.run!(~s("%r" % "hello")) == "'hello'"
    end

    test "width padding with right alignment" do
      assert Pyex.run!(~s("%10s" % "hi")) == "        hi"
    end

    test "width padding with left alignment" do
      assert Pyex.run!(~s("%-10s" % "hi")) == "hi        "
    end

    test "multiple format codes in one string" do
      assert Pyex.run!(~S["%s has %d apples and %.1f oranges" % ("Bob", 3, 2.5)]) ==
               "Bob has 3 apples and 2.5 oranges"
    end

    test "integer substitution with %i" do
      assert Pyex.run!(~s("%i" % 42)) == "42"
    end

    test "scientific notation with %e" do
      result = Pyex.run!(~s("%e" % 12345.6789))
      assert result =~ ~r/1\.\d+e\+04/
    end

    test "string formatting with precision truncates" do
      assert Pyex.run!(~s("%.3s" % "hello")) == "hel"
    end
  end

  describe "with statement" do
    test "basic with statement" do
      code = """
      class Ctx:
          def __enter__(self):
              return "entered"
          def __exit__(self, *args):
              pass

      with Ctx() as val:
          result = val
      result
      """

      assert Pyex.run!(code) == "entered"
    end

    test "with statement without as clause" do
      code = """
      class Ctx:
          def __enter__(self):
              return 42
          def __exit__(self, *args):
              pass

      with Ctx():
          result = "done"
      result
      """

      assert Pyex.run!(code) == "done"
    end

    test "with statement __enter__ return value is bound" do
      code = """
      class Ctx:
          def __enter__(self):
              return "resource"
          def __exit__(self, *args):
              pass

      with Ctx() as val:
          result = val
      result
      """

      assert Pyex.run!(code) == "resource"
    end

    test "with plain value (no __enter__/__exit__)" do
      code = """
      with 42 as x:
          result = x
      result
      """

      assert Pyex.run!(code) == 42
    end
  end

  describe "trailing commas" do
    test "trailing comma in dict literal" do
      assert Pyex.run!(~s({"a": 1, "b": 2,})) == %{"a" => 1, "b" => 2}
    end

    test "trailing comma in multiline dict" do
      code = """
      x = {
          "key": "value",
          "num": 42,
      }
      x["key"]
      """

      assert Pyex.run!(code) == "value"
    end

    test "trailing comma in nested dicts" do
      code = """
      data = {
          "headers": {
              "content-type": "application/json",
              "x-api-key": "test",
          },
          "body": {
              "model": "claude",
              "messages": [
                  {"role": "user", "content": "hello",},
              ],
          },
      }
      data["body"]["messages"][0]["content"]
      """

      assert Pyex.run!(code) == "hello"
    end
  end
end
