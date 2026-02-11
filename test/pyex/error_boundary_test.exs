defmodule Pyex.ErrorBoundaryTest do
  use ExUnit.Case, async: true
  alias Pyex.Error

  describe "type errors in arithmetic" do
    test "string minus integer" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s("hello" - 1))
      assert msg =~ "TypeError"
      assert msg =~ "unsupported operand"
    end

    test "string minus string" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s("a" - "b"))
      assert msg =~ "TypeError"
    end

    test "list plus integer" do
      assert {:error, %Error{message: msg}} = Pyex.run("[1, 2] + 5")
      assert msg =~ "TypeError"
    end

    test "dict plus dict" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s({"a": 1} + {"b": 2}))
      assert msg =~ "TypeError"
    end

    test "None plus integer" do
      assert {:error, %Error{message: msg}} = Pyex.run("None + 1")
      assert msg =~ "TypeError"
    end

    test "None plus string" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s(None + "hello"))
      assert msg =~ "TypeError"
    end

    test "string divided by integer" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s("hello" / 2))
      assert msg =~ "TypeError"
    end

    test "list minus list" do
      assert {:error, %Error{message: msg}} = Pyex.run("[1] - [2]")
      assert msg =~ "TypeError"
    end

    test "boolean arithmetic preserves int coercion" do
      assert Pyex.run!("True + 1") == 2
      assert Pyex.run!("False + 1") == 1
      assert Pyex.run!("True * 5") == 5
      assert Pyex.run!("True + True") == 2
    end

    test "string modulo non-tuple" do
      result = Pyex.run(~s("%s" % [1, 2]))
      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end

    test "exponentiation with incompatible types" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s("hello" ** 2))
      assert msg =~ "TypeError"
    end

    test "floor division with incompatible types" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s("hello" // 2))
      assert msg =~ "TypeError"
    end
  end

  describe "cross-type comparison" do
    test "string less than integer raises TypeError" do
      {:error, error} = Pyex.run(~s("hello" < 5))
      assert error.kind == :python
      assert error.message =~ "TypeError"
    end

    test "list less than integer raises TypeError" do
      {:error, error} = Pyex.run("[1] < 5")
      assert error.kind == :python
      assert error.message =~ "TypeError"
    end

    test "None less than integer raises TypeError" do
      {:error, error} = Pyex.run("None < 5")
      assert error.kind == :python
      assert error.message =~ "TypeError"
    end

    test "equality across types returns false" do
      assert Pyex.run!(~s("1" == 1)) == false
      assert Pyex.run!("None == 0") == false
      assert Pyex.run!("[1] == 1") == false
    end
  end

  describe "type errors in subscript" do
    test "integer is not subscriptable" do
      assert {:error, %Error{message: msg}} = Pyex.run("x = 42\nx[0]")
      assert msg =~ "KeyError" or msg =~ "not subscriptable"
    end

    test "None is not subscriptable" do
      assert {:error, %Error{message: msg}} = Pyex.run("None[0]")
      assert msg =~ "KeyError" or msg =~ "not subscriptable"
    end

    test "string subscript with non-integer" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s("hello"["a"]))
      assert msg =~ "KeyError" or msg =~ "TypeError"
    end

    test "list subscript with string key" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s([1, 2, 3]["a"]))
      assert msg =~ "KeyError" or msg =~ "TypeError"
    end
  end

  describe "index errors" do
    test "list index out of range (positive)" do
      assert {:error, %Error{message: msg}} = Pyex.run("x = [1, 2, 3]\nx[10]")
      assert msg =~ "IndexError"
      assert msg =~ "list index out of range"
    end

    test "list index out of range (negative)" do
      assert {:error, %Error{message: msg}} = Pyex.run("x = [1, 2]\nx[-3]")
      assert msg =~ "IndexError"
    end

    test "tuple index out of range" do
      assert {:error, %Error{message: msg}} = Pyex.run("x = (1, 2)\nx[5]")
      assert msg =~ "IndexError"
      assert msg =~ "tuple index out of range"
    end

    test "string index out of range" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s(x = "hi"\nx[5]))
      assert msg =~ "IndexError"
      assert msg =~ "string index out of range"
    end

    test "empty list subscript" do
      assert {:error, %Error{message: msg}} = Pyex.run("[][0]")
      assert msg =~ "IndexError"
    end

    test "valid negative indexing works" do
      assert Pyex.run!("[10, 20, 30][-1]") == 30
      assert Pyex.run!("[10, 20, 30][-3]") == 10
    end

    test "list containing None at index is accessible" do
      assert Pyex.run!("[None, 1, 2][0]") == nil
      assert Pyex.run!("[None, 1, 2][0] is None") == true
    end
  end

  describe "key errors" do
    test "dict missing key" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s(d = {"a": 1}\nd["b"]))
      assert msg =~ "KeyError"
    end

    test "dict integer key on string-keyed dict" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s(d = {"a": 1}\nd[0]))
      assert msg =~ "KeyError"
    end
  end

  describe "name errors" do
    test "undefined variable" do
      assert {:error, %Error{message: msg}} = Pyex.run("x + 1")
      assert msg =~ "NameError"
      assert msg =~ "x"
    end

    test "undefined in expression" do
      assert {:error, %Error{message: msg}} = Pyex.run("y = undefined_var + 1")
      assert msg =~ "NameError"
      assert msg =~ "undefined_var"
    end
  end

  describe "attribute errors" do
    test "attribute on integer" do
      assert {:error, %Error{message: msg}} = Pyex.run("x = 42\nx.foo")
      assert msg =~ "AttributeError"
    end

    test "non-existent method on string" do
      assert {:error, %Error{message: msg}} = Pyex.run(~S|"hello".nonexistent()|)
      assert msg =~ "AttributeError" or msg =~ "has no attribute"
    end

    test "non-existent method on list" do
      assert {:error, %Error{message: msg}} = Pyex.run("[1, 2].nonexistent()")
      assert msg =~ "AttributeError" or msg =~ "has no attribute"
    end

    test "non-existent method on dict" do
      assert {:error, %Error{message: msg}} = Pyex.run(~S|{"a": 1}.nonexistent()|)
      assert msg =~ "AttributeError" or msg =~ "has no attribute"
    end
  end

  describe "function call errors" do
    test "too many arguments" do
      assert {:error, %Error{message: msg}} = Pyex.run("def f():\n    pass\nf(1, 2, 3)")
      assert msg =~ "TypeError"
      assert msg =~ "positional arguments"
    end

    test "calling a non-callable" do
      assert {:error, %Error{message: msg}} = Pyex.run("x = 42\nx()")
      assert msg =~ "not callable" or msg =~ "TypeError"
    end

    test "calling None" do
      assert {:error, %Error{message: msg}} = Pyex.run("x = None\nx()")
      assert msg =~ "not callable" or msg =~ "TypeError"
    end
  end

  describe "division errors" do
    test "division by zero" do
      assert {:error, %Error{message: msg}} = Pyex.run("1 / 0")
      assert msg =~ "ZeroDivisionError"
    end

    test "floor division by zero" do
      assert {:error, %Error{message: msg}} = Pyex.run("1 // 0")
      assert msg =~ "ZeroDivisionError"
    end

    test "modulo by zero" do
      assert {:error, %Error{message: msg}} = Pyex.run("1 % 0")
      assert msg =~ "ZeroDivisionError"
    end
  end

  describe "import errors" do
    test "non-existent module" do
      assert {:error, %Error{message: msg}} = Pyex.run("import nonexistent_module")
      assert msg =~ "ImportError"
      assert msg =~ "nonexistent_module"
    end

    test "non-existent name from module" do
      assert {:error, %Error{message: msg}} = Pyex.run("from json import nonexistent")
      assert msg =~ "ImportError"
      assert msg =~ "nonexistent"
    end
  end

  describe "unary operator errors" do
    test "negate a string" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s(-"hello"))
      assert msg =~ "TypeError"
    end

    test "bitwise not on string" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s(~"hello"))
      assert msg =~ "TypeError"
    end
  end

  describe "assignment errors" do
    test "augmented assignment on undefined variable" do
      assert {:error, %Error{message: msg}} = Pyex.run("x += 1")
      assert msg =~ "NameError"
    end

    test "item assignment on non-subscriptable" do
      assert {:error, %Error{message: msg}} = Pyex.run("x = 42\nx[0] = 1")
      assert msg =~ "TypeError" or msg =~ "not support item assignment"
    end

    test "item assignment on string" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s(x = "hello"\nx[0] = "H"))
      assert msg =~ "TypeError" or msg =~ "not support item assignment"
    end

    test "item assignment on tuple" do
      assert {:error, %Error{message: msg}} = Pyex.run("x = (1, 2, 3)\nx[0] = 99")
      assert msg =~ "TypeError" or msg =~ "not support item assignment"
    end
  end

  describe "iteration errors" do
    test "iterating over an integer" do
      assert {:error, %Error{message: msg}} = Pyex.run("for x in 42:\n    pass")
      assert msg =~ "TypeError"
      assert msg =~ "not iterable"
    end

    test "iterating over None" do
      assert {:error, %Error{message: msg}} = Pyex.run("for x in None:\n    pass")
      assert msg =~ "TypeError"
      assert msg =~ "not iterable"
    end
  end

  describe "parser errors" do
    test "missing colon after if" do
      assert {:error, %Error{message: msg}} = Pyex.run("if True\n    x = 1")
      assert msg =~ "expected ':'"
    end

    test "unclosed parenthesis" do
      assert {:error, %Error{message: msg}} = Pyex.run("f(1, 2")
      assert msg =~ "expected" or msg =~ "unexpected"
    end

    test "invalid syntax" do
      assert {:error, %Error{message: msg}} = Pyex.run("def 123():\n    pass")
      assert msg =~ "expected" or msg =~ "unexpected"
    end
  end

  describe "lexer errors" do
    test "unterminated double-quoted string" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s(x = "hello))
      assert msg =~ "unterminated string"
    end

    test "unterminated single-quoted string" do
      assert {:error, %Error{message: msg}} = Pyex.run("x = 'hello")
      assert msg =~ "unterminated string"
    end

    test "unterminated triple-quoted string" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s(x = \"\"\"hello))
      assert msg =~ "unterminated"
    end

    test "unterminated f-string" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s(x = f"hello {name))
      assert msg =~ "unterminated string"
    end

    test "unterminated raw string" do
      assert {:error, %Error{message: msg}} = Pyex.run(~s(x = r"hello))
      assert msg =~ "unterminated string"
    end

    test "unrecognized character" do
      assert {:error, %Error{message: msg}} = Pyex.run("`x = 1")
      assert msg =~ "Lexer error"
    end

    test "invalid UTF-8" do
      assert {:error, %Error{message: msg}} = Pyex.run(<<0xFF, 0xFE>>)
      assert msg =~ "invalid UTF-8"
    end
  end

  describe "line numbers in errors" do
    test "TypeError includes line number" do
      code = """
      x = 10
      y = "hello"
      z = x + y
      """

      {:error, %Error{message: msg}} = Pyex.run(code)
      assert msg =~ "TypeError"
      assert msg =~ "(line 3)"
    end

    test "NameError includes line number" do
      code = """
      x = 1
      y = undefined_var
      """

      {:error, %Error{message: msg}} = Pyex.run(code)
      assert msg =~ "NameError"
      assert msg =~ "(line 2)"
    end

    test "IndexError includes line number" do
      code = """
      items = [1, 2]
      val = items[10]
      """

      {:error, %Error{message: msg}} = Pyex.run(code)
      assert msg =~ "IndexError"
      assert msg =~ "(line 2)"
    end

    test "ZeroDivisionError includes line number" do
      code = """
      x = 5
      y = 0
      z = x / y
      """

      {:error, %Error{message: msg}} = Pyex.run(code)
      assert msg =~ "ZeroDivisionError"
      assert msg =~ "(line 3)"
    end

    test "single line error reports line 1" do
      {:error, %Error{message: msg}} = Pyex.run("1 / 0")
      assert msg =~ "(line 1)"
    end

    test "caught exceptions do not have line numbers in message" do
      code = """
      try:
          x = 1 / 0
      except ZeroDivisionError as e:
          str(e)
      """

      result = Pyex.run!(code)
      refute result =~ "(line"
    end
  end
end
