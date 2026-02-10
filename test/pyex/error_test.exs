defmodule Pyex.ErrorTest do
  @moduledoc """
  Tests for the Pyex.Error structured error type.

  Covers classification logic, line extraction, and convenience
  constructors.
  """
  use ExUnit.Case, async: true

  alias Pyex.Error

  describe "from_message/1 classification" do
    test "classifies TypeError" do
      err = Error.from_message("TypeError: unsupported operand on line 5")
      assert err.kind == :python
      assert err.exception_type == "TypeError"
      assert err.line == 5
      assert err.message == "TypeError: unsupported operand on line 5"
    end

    test "classifies ValueError" do
      err = Error.from_message("ValueError: invalid literal for int()")
      assert err.kind == :python
      assert err.exception_type == "ValueError"
      assert err.line == nil
    end

    test "classifies NameError with line" do
      err = Error.from_message("NameError: name 'x' is not defined on line 3")
      assert err.kind == :python
      assert err.exception_type == "NameError"
      assert err.line == 3
    end

    test "classifies AttributeError" do
      err = Error.from_message("AttributeError: 'int' object has no attribute 'foo' on line 2")
      assert err.kind == :python
      assert err.exception_type == "AttributeError"
      assert err.line == 2
    end

    test "classifies IndexError" do
      err = Error.from_message("IndexError: list index out of range on line 1")
      assert err.kind == :python
      assert err.exception_type == "IndexError"
      assert err.line == 1
    end

    test "classifies KeyError" do
      err = Error.from_message("KeyError: 'missing' on line 4")
      assert err.kind == :python
      assert err.exception_type == "KeyError"
      assert err.line == 4
    end

    test "classifies ZeroDivisionError" do
      err = Error.from_message("ZeroDivisionError: division by zero on line 1")
      assert err.kind == :python
      assert err.exception_type == "ZeroDivisionError"
      assert err.line == 1
    end

    test "classifies RuntimeError" do
      err = Error.from_message("RuntimeError: something went wrong")
      assert err.kind == :python
      assert err.exception_type == "RuntimeError"
    end

    test "classifies StopIteration" do
      err = Error.from_message("StopIteration: iterator exhausted")
      assert err.kind == :python
      assert err.exception_type == "StopIteration"
    end

    test "classifies OverflowError" do
      err = Error.from_message("OverflowError: too large")
      assert err.kind == :python
      assert err.exception_type == "OverflowError"
    end

    test "classifies RecursionError" do
      err = Error.from_message("RecursionError: maximum recursion depth exceeded")
      assert err.kind == :python
      assert err.exception_type == "RecursionError"
    end

    test "classifies NotImplementedError" do
      err = Error.from_message("NotImplementedError: async/await not supported")
      assert err.kind == :python
      assert err.exception_type == "NotImplementedError"
    end

    test "classifies AssertionError" do
      err = Error.from_message("AssertionError: assertion failed")
      assert err.kind == :python
      assert err.exception_type == "AssertionError"
    end

    test "classifies UnboundLocalError" do
      err =
        Error.from_message("UnboundLocalError: local variable 'x' referenced before assignment")

      assert err.kind == :python
      assert err.exception_type == "UnboundLocalError"
    end

    test "classifies SyntaxError" do
      err = Error.from_message("SyntaxError: unexpected token on line 1")
      assert err.kind == :syntax
      assert err.exception_type == "SyntaxError"
      assert err.line == 1
    end

    test "classifies IndentationError" do
      err = Error.from_message("IndentationError: expected an indented block on line 2")
      assert err.kind == :syntax
      assert err.exception_type == "IndentationError"
      assert err.line == 2
    end

    test "classifies ImportError" do
      err = Error.from_message("ImportError: no module named 'foo'")
      assert err.kind == :import
      assert err.exception_type == "ImportError"
    end

    test "classifies ModuleNotFoundError" do
      err = Error.from_message("ModuleNotFoundError: no module named 'bar'")
      assert err.kind == :import
      assert err.exception_type == "ModuleNotFoundError"
    end

    test "classifies IOError" do
      err = Error.from_message("IOError: file not found")
      assert err.kind == :io
      assert err.exception_type == "IOError"
    end

    test "classifies FileNotFoundError" do
      err = Error.from_message("FileNotFoundError: /tmp/missing.txt")
      assert err.kind == :io
      assert err.exception_type == "FileNotFoundError"
    end

    test "classifies ComputeTimeout" do
      err = Error.from_message("ComputeTimeout: execution exceeded 5000ms budget")
      assert err.kind == :timeout
      assert err.exception_type == "ComputeTimeout"
    end

    test "unknown message falls back to :python with nil type" do
      err = Error.from_message("something went wrong")
      assert err.kind == :python
      assert err.exception_type == nil
      assert err.message == "something went wrong"
    end
  end

  describe "line extraction" do
    test "extracts line from 'on line N' suffix" do
      err = Error.from_message("NameError: x is not defined on line 42")
      assert err.line == 42
    end

    test "extracts line from middle of message" do
      err = Error.from_message("error on line 7 in some context")
      assert err.line == 7
    end

    test "returns nil when no line present" do
      err = Error.from_message("TypeError: bad operand")
      assert err.line == nil
    end
  end

  describe "convenience constructors" do
    test "syntax/1 creates syntax error" do
      err = Error.syntax("unexpected token on line 3")
      assert err.kind == :syntax
      assert err.message == "unexpected token on line 3"
      assert err.line == 3
      assert err.exception_type == nil
    end

    test "timeout/1 creates timeout error" do
      err = Error.timeout("exceeded 5000ms")
      assert err.kind == :timeout
      assert err.message == "exceeded 5000ms"
      assert err.line == nil
    end

    test "route_not_found/1 creates route_not_found error" do
      err = Error.route_not_found("GET /missing")
      assert err.kind == :route_not_found
      assert err.message == "GET /missing"
    end

    test "io/1 creates IO error" do
      err = Error.io("permission denied")
      assert err.kind == :io
      assert err.message == "permission denied"
    end
  end

  describe "integration with Pyex.run/2" do
    test "runtime error returns structured error" do
      {:error, %Error{} = err} = Pyex.run("1 / 0")
      assert err.kind == :python
      assert err.exception_type == "ZeroDivisionError"
      assert err.message =~ "division by zero"
    end

    test "syntax error returns structured error" do
      {:error, %Error{} = err} = Pyex.run("def")
      assert err.kind == :syntax
    end

    test "import error returns structured error" do
      {:error, %Error{} = err} = Pyex.run("import nonexistent_xyz")
      assert err.kind == :import
    end

    test "timeout error returns structured error" do
      ctx = Pyex.Ctx.new(timeout_ms: 50)
      {:error, %Error{} = err} = Pyex.run("while True:\n    x = 1", ctx)
      assert err.kind == :timeout
    end
  end
end
