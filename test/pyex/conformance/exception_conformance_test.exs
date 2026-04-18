defmodule Pyex.Conformance.ExceptionTest do
  @moduledoc """
  Live CPython conformance tests for exception handling, hierarchy,
  and catch semantics.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "basic raise/except" do
    test "raise and catch by type" do
      check!("""
      try:
          raise ValueError("bad input")
      except ValueError as e:
          print(type(e).__name__, str(e))
      """)
    end

    test "raise and catch by base class" do
      check!("""
      try:
          raise ValueError("x")
      except Exception as e:
          print(type(e).__name__)
      """)
    end

    test "multiple except clauses" do
      check!("""
      try:
          raise TypeError("x")
      except ValueError:
          print("value")
      except TypeError:
          print("type")
      except Exception:
          print("generic")
      """)
    end

    test "except tuple of types" do
      check!("""
      for exc in [ValueError("v"), TypeError("t"), KeyError("k")]:
          try:
              raise exc
          except (ValueError, TypeError) as e:
              print("caught:", type(e).__name__)
          except Exception as e:
              print("generic:", type(e).__name__)
      """)
    end

    test "finally runs on success" do
      check!("""
      try:
          print("try")
      finally:
          print("finally")
      """)
    end

    test "finally runs on exception" do
      check!("""
      try:
          raise ValueError("x")
      except ValueError:
          print("except")
      finally:
          print("finally")
      """)
    end

    test "else clause runs on success" do
      check!("""
      try:
          x = 42
      except Exception:
          print("except")
      else:
          print("else", x)
      """)
    end

    test "else does not run on exception" do
      check!("""
      try:
          raise ValueError("x")
      except ValueError:
          print("except")
      else:
          print("else")
      """)
    end
  end

  describe "exception hierarchy" do
    for {label, raise_code, catch_class} <- [
          {"IndexError as LookupError", "IndexError('x')", "LookupError"},
          {"KeyError as LookupError", "KeyError('x')", "LookupError"},
          {"ValueError as Exception", "ValueError('x')", "Exception"},
          {"TypeError as Exception", "TypeError('x')", "Exception"},
          {"ZeroDivisionError as ArithmeticError", "ZeroDivisionError('x')", "ArithmeticError"},
          {"FileNotFoundError as OSError", "FileNotFoundError('x')", "OSError"},
          {"StopIteration as Exception", "StopIteration()", "Exception"},
          {"AttributeError as Exception", "AttributeError('x')", "Exception"}
        ] do
      test "#{label}" do
        check!("""
        try:
            raise #{unquote(raise_code)}
        except #{unquote(catch_class)} as e:
            print("caught", type(e).__name__)
        """)
      end
    end
  end

  describe "raise from real operations" do
    test "division by zero" do
      check!("""
      try:
          1 / 0
      except ZeroDivisionError as e:
          print(type(e).__name__)
      """)
    end

    test "list index out of range" do
      check!("""
      try:
          [1, 2, 3][10]
      except IndexError as e:
          print(type(e).__name__)
      """)
    end

    test "dict KeyError" do
      check!("""
      try:
          {"a": 1}["missing"]
      except KeyError as e:
          print(type(e).__name__)
      """)
    end

    test "attribute error" do
      check!("""
      try:
          "abc".nonexistent_method()
      except AttributeError as e:
          print(type(e).__name__)
      """)
    end

    test "type error" do
      check!("""
      try:
          "abc" + 1
      except TypeError as e:
          print(type(e).__name__)
      """)
    end

    test "value error from int()" do
      check!("""
      try:
          int("not a number")
      except ValueError as e:
          print(type(e).__name__)
      """)
    end
  end

  describe "custom exceptions" do
    test "user-defined exception inherits from Exception" do
      check!("""
      class MyError(Exception):
          pass

      try:
          raise MyError("custom message")
      except MyError as e:
          print(type(e).__name__, str(e))
      """)
    end

    test "user-defined exception caught as Exception" do
      check!("""
      class MyError(Exception):
          pass

      try:
          raise MyError("x")
      except Exception as e:
          print(type(e).__name__)
      """)
    end

    test "exception with custom __init__" do
      check!("""
      class MyError(Exception):
          def __init__(self, code, msg):
              super().__init__(msg)
              self.code = code

      try:
          raise MyError(42, "oops")
      except MyError as e:
          print(e.code, str(e))
      """)
    end
  end

  describe "re-raise" do
    test "bare raise re-raises current exception" do
      check!("""
      try:
          try:
              raise ValueError("original")
          except ValueError:
              raise
      except ValueError as e:
          print(type(e).__name__, str(e))
      """)
    end

    test "raise from sets __cause__" do
      check!("""
      try:
          try:
              raise ValueError("orig")
          except ValueError as e:
              raise TypeError("wrapped") from e
      except TypeError as e:
          print(type(e).__name__, str(e))
          print(type(e.__cause__).__name__)
      """)
    end
  end

  describe "exception attributes" do
    test "args attribute" do
      check!("""
      try:
          raise ValueError("a", "b", "c")
      except ValueError as e:
          print(e.args)
      """)
    end

    test "str on exception with one arg" do
      check!("""
      try:
          raise ValueError("only one")
      except ValueError as e:
          print(str(e))
      """)
    end

    test "str on exception with multiple args" do
      check!("""
      try:
          raise ValueError("a", "b")
      except ValueError as e:
          print(str(e))
      """)
    end

    test "str on exception with no args" do
      check!("""
      try:
          raise ValueError()
      except ValueError as e:
          print(repr(str(e)))
      """)
    end
  end

  describe "KeyboardInterrupt and SystemExit (special)" do
    test "Exception does NOT catch KeyboardInterrupt" do
      check!("""
      print(issubclass(KeyboardInterrupt, Exception))
      print(issubclass(KeyboardInterrupt, BaseException))
      """)
    end
  end

  describe "exception in generator" do
    test "exception bubbles from generator consumer list()" do
      check!("""
      def gen():
          yield 1
          raise ValueError("from gen")

      try:
          list(gen())
      except ValueError as e:
          print(type(e).__name__, str(e))
      """)
    end
  end
end
