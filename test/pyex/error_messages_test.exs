defmodule Pyex.ErrorMessagesTest do
  @moduledoc """
  Tests that Pyex produces high-quality, actionable error messages.

  LLMs use these error messages to self-heal their code. Every error must:
  1. Name the exception type (NameError, TypeError, SyntaxError, etc.)
  2. Include the line number where the error occurred
  3. Describe what went wrong in terms the programmer understands
  4. Suggest what to do instead (for unimplemented features)
  """
  use ExUnit.Case, async: true
  alias Pyex.Error

  # ── Unimplemented features ──────────────────────────────────
  #
  # These features are recognized by the interpreter but not supported.
  # Error messages must say so clearly, not pretend the name doesn't exist.

  describe "unimplemented: async/await" do
    test "async def gives NotImplementedError, not NameError" do
      {:error, %Error{message: msg}} = Pyex.run("async def foo():\n    pass")
      assert msg =~ "NotImplementedError"
      assert msg =~ "async"
      assert msg =~ "not supported"
      refute msg =~ "NameError"
    end

    test "await gives NotImplementedError, not NameError" do
      {:error, %Error{message: msg}} = Pyex.run("await foo()")
      assert msg =~ "NotImplementedError"
      assert msg =~ "await"
      assert msg =~ "not supported"
      refute msg =~ "NameError"
    end

    test "async for gives NotImplementedError" do
      {:error, %Error{message: msg}} = Pyex.run("async for x in gen():\n    pass")
      assert msg =~ "NotImplementedError"
      assert msg =~ "async"
      assert msg =~ "not supported"
    end

    test "async with gives NotImplementedError" do
      {:error, %Error{message: msg}} = Pyex.run("async with ctx() as c:\n    pass")
      assert msg =~ "NotImplementedError"
      assert msg =~ "async"
      assert msg =~ "not supported"
    end
  end

  describe "unimplemented: exec/eval/compile" do
    test "exec() gives NotImplementedError with explanation" do
      {:error, %Error{message: msg}} = Pyex.run(~s|exec("x = 1")|)
      assert msg =~ "NotImplementedError"
      assert msg =~ "exec()"
      assert msg =~ "not supported"
      refute msg =~ "NameError"
    end

    test "eval() gives NotImplementedError with explanation" do
      {:error, %Error{message: msg}} = Pyex.run(~s|eval("1 + 2")|)
      assert msg =~ "NotImplementedError"
      assert msg =~ "eval()"
      assert msg =~ "not supported"
      refute msg =~ "NameError"
    end

    test "compile() gives NotImplementedError with explanation" do
      {:error, %Error{message: msg}} = Pyex.run(~s|compile("x", "<string>", "eval")|)
      assert msg =~ "NotImplementedError"
      assert msg =~ "compile()"
      assert msg =~ "not supported"
      refute msg =~ "NameError"
    end
  end

  describe "unimplemented: complex numbers" do
    test "complex() gives NotImplementedError" do
      {:error, %Error{message: msg}} = Pyex.run("x = complex(1, 2)")
      assert msg =~ "NotImplementedError"
      assert msg =~ "complex"
      assert msg =~ "not supported"
      refute msg =~ "NameError"
    end

    test "j literal suffix gives NotImplementedError" do
      {:error, %Error{message: msg}} = Pyex.run("x = 2j")
      assert msg =~ "NotImplementedError"
      assert msg =~ "complex"
      assert msg =~ "not supported"
      refute msg =~ "NameError"
    end
  end

  describe "unimplemented: bytes/bytearray" do
    test "b-string literal gives NotImplementedError" do
      {:error, %Error{message: msg}} = Pyex.run(~s|x = b"hello"|)
      assert msg =~ "NotImplementedError"
      assert msg =~ "bytes"
      assert msg =~ "not supported"
      refute msg =~ "NameError"
    end

    test "bytearray() gives NotImplementedError" do
      {:error, %Error{message: msg}} = Pyex.run(~s|x = bytearray(b"hello")|)
      assert msg =~ "NotImplementedError"
      assert msg =~ "not supported"
      refute msg =~ "NameError"
    end

    test "bytes() gives NotImplementedError" do
      {:error, %Error{message: msg}} = Pyex.run("x = bytes([72, 101])")
      assert msg =~ "NotImplementedError"
      assert msg =~ "not supported"
      refute msg =~ "NameError"
    end
  end

  # ── Type errors include type names ──────────────────────────
  #
  # Python always says "'int' object has no attribute 'foo'" not just
  # "object has no attribute 'foo'". The type name is critical for debugging.

  describe "AttributeError includes type name" do
    test "int attribute error includes 'int'" do
      {:error, %Error{message: msg}} = Pyex.run("x = 5\nx.foo")
      assert msg =~ "AttributeError"
      assert msg =~ "'int'"
      assert msg =~ "foo"
    end

    test "float attribute error includes 'float'" do
      {:error, %Error{message: msg}} = Pyex.run("x = 3.14\nx.foo")
      assert msg =~ "AttributeError"
      assert msg =~ "'float'"
    end

    test "str attribute error includes 'str'" do
      {:error, %Error{message: msg}} = Pyex.run(~s|"hello".foo()|)
      assert msg =~ "AttributeError"
      assert msg =~ "'str'"
    end

    test "list attribute error includes 'list'" do
      {:error, %Error{message: msg}} = Pyex.run("[1,2].upper()")
      assert msg =~ "AttributeError"
      assert msg =~ "'list'"
    end

    test "dict attribute error includes 'dict'" do
      {:error, %Error{message: msg}} = Pyex.run("{}.upper()")
      assert msg =~ "AttributeError"
      assert msg =~ "'dict'"
    end

    test "NoneType attribute error includes 'NoneType'" do
      {:error, %Error{message: msg}} = Pyex.run("x = None\nx.foo")
      assert msg =~ "AttributeError"
      assert msg =~ "'NoneType'"
    end

    test "bool attribute error includes 'bool'" do
      {:error, %Error{message: msg}} = Pyex.run("x = True\nx.foo")
      assert msg =~ "AttributeError"
      assert msg =~ "'bool'"
    end

    test "tuple attribute error includes 'tuple'" do
      {:error, %Error{message: msg}} = Pyex.run("x = (1, 2)\nx.foo")
      assert msg =~ "AttributeError"
      assert msg =~ "'tuple'"
    end

    test "set attribute error includes 'set'" do
      {:error, %Error{message: msg}} = Pyex.run("x = {1, 2}\nx.foo")
      assert msg =~ "AttributeError"
      assert msg =~ "'set'"
    end

    test "type object attribute error includes class name" do
      {:error, %Error{message: msg}} =
        Pyex.run("""
        class Foo:
            pass
        Foo.nonexistent
        """)

      assert msg =~ "AttributeError"
      assert msg =~ "Foo"
      assert msg =~ "nonexistent"
    end
  end

  # ── Import errors list all available modules ────────────────

  describe "ImportError lists available modules" do
    test "unknown module lists all stdlib modules" do
      {:error, %Error{message: msg}} = Pyex.run("import nonexistent_module")
      assert msg =~ "ImportError"
      assert msg =~ "no module named 'nonexistent_module'"

      for mod <- ~w(os math json requests random re time datetime collections itertools) do
        assert msg =~ mod,
               "ImportError should list '#{mod}' as available but got: #{msg}"
      end
    end

    test "http-like module suggests requests" do
      {:error, %Error{message: msg}} = Pyex.run("import urllib")
      assert msg =~ "requests"
    end

    test "dotted urllib.request suggests requests" do
      {:error, %Error{message: msg}} = Pyex.run("import urllib.request")
      assert msg =~ "requests"
    end

    test "sys module suggests os" do
      {:error, %Error{message: msg}} = Pyex.run("import sys")
      assert msg =~ "os"
    end
  end

  # ── Common runtime errors are clear and actionable ──────────

  describe "runtime error quality" do
    test "NameError includes the variable name and line" do
      {:error, %Error{message: msg}} = Pyex.run("print(undefined_var)")
      assert msg =~ "NameError"
      assert msg =~ "undefined_var"
      assert msg =~ "line"
    end

    test "TypeError for bad + operands includes both types" do
      {:error, %Error{message: msg}} = Pyex.run("1 + \"hello\"")
      assert msg =~ "TypeError"
      assert msg =~ "int"
      assert msg =~ "str"
    end

    test "TypeError for calling non-callable includes the type" do
      {:error, %Error{message: msg}} = Pyex.run("x = 5\nx()")
      assert msg =~ "TypeError"
      assert msg =~ "'int'"
      assert msg =~ "not callable"
    end

    test "IndexError includes 'list index out of range'" do
      {:error, %Error{message: msg}} = Pyex.run("[1,2,3][10]")
      assert msg =~ "IndexError"
      assert msg =~ "list index out of range"
    end

    test "KeyError includes the missing key" do
      {:error, %Error{message: msg}} = Pyex.run(~s|{"a": 1}["b"]|)
      assert msg =~ "KeyError"
      assert msg =~ "b"
    end

    test "ZeroDivisionError is clear" do
      {:error, %Error{message: msg}} = Pyex.run("1 / 0")
      assert msg =~ "ZeroDivisionError"
      assert msg =~ "division by zero"
    end

    test "wrong argument count names the missing arg" do
      {:error, %Error{message: msg}} = Pyex.run("def f(a, b):\n    return a + b\nf(1)")
      assert msg =~ "TypeError"
      assert msg =~ "b"
    end

    test "too many arguments includes counts" do
      {:error, %Error{message: msg}} = Pyex.run("def f(a):\n    return a\nf(1, 2, 3)")
      assert msg =~ "TypeError"
      assert msg =~ "1"
      assert msg =~ "3"
    end
  end

  # ── Generator/iterator errors are actionable ─────────────────

  describe "generator error messages" do
    test "next() on raw generator suggests iter()" do
      {:error, %Error{message: msg}} =
        Pyex.run("""
        def gen():
            yield 1
        g = gen()
        next(g)
        """)

      assert msg =~ "TypeError"
      assert msg =~ "iter()"
      refute msg =~ "not an iterator"
    end

    test "iter() then next() works correctly" do
      {:ok, result, _ctx} =
        Pyex.run("""
        def gen():
            yield 10
            yield 20
        g = iter(gen())
        a = next(g)
        b = next(g)
        [a, b]
        """)

      assert result == [10, 20]
    end
  end

  # ── Parser errors are human-readable ────────────────────────
  #
  # Parser errors should never dump raw token representations like
  # "op::comma" or "keyword:\"pass\"" — they should use Python syntax.

  describe "parser error quality" do
    test "missing colon after if says what's expected" do
      {:error, %Error{message: msg}} = Pyex.run("if True\n    pass")
      assert msg =~ "expected ':'"
      assert msg =~ "if"
    end

    test "missing colon after def says what's expected" do
      {:error, %Error{message: msg}} = Pyex.run("def foo()\n    pass")
      assert msg =~ "expected ':'"
    end

    test "indentation error is clear" do
      {:error, %Error{message: msg}} = Pyex.run("if True:\npass")
      assert msg =~ "IndentationError" or msg =~ "indent" or msg =~ "expected"
    end

    test "unmatched paren says what's expected" do
      {:error, %Error{message: msg}} = Pyex.run("print(1 + 2")
      assert msg =~ "expected ')'" or msg =~ "unexpected"
    end

    test "unmatched bracket says what's expected" do
      {:error, %Error{message: msg}} = Pyex.run("[1, 2, 3")
      assert msg =~ "']'"
    end
  end

  # ── Lexer errors include context ────────────────────────────

  describe "lexer error quality" do
    test "unterminated string says so" do
      {:error, %Error{message: msg}} = Pyex.run(~s|x = "hello|)
      assert msg =~ "unterminated string"
    end

    test "unterminated triple-quoted string says so" do
      {:error, %Error{message: msg}} = Pyex.run(~s|x = \"\"\"\nhello|)
      assert msg =~ "unterminated" and msg =~ "triple"
    end
  end
end
