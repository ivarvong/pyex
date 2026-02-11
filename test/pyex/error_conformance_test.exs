defmodule Pyex.ErrorConformanceTest do
  @moduledoc """
  Error conformance tests that verify Pyex raises the same exception
  types as CPython for code that should fail.

  For each test, we run code through CPython to confirm it errors, then
  run it through Pyex and assert the exception type matches. This ensures
  LLMs see the same error signals they'd see from real Python, enabling
  accurate self-healing.

  Requires `python3` on PATH. Skipped otherwise.
  """
  use ExUnit.Case, async: true

  @python3 System.find_executable("python3")

  setup do
    if @python3 do
      :ok
    else
      {:skip, "python3 not found on PATH"}
    end
  end

  defp assert_error_type(code, expected_type) do
    cpython_type = cpython_exception_type(code)

    assert cpython_type == expected_type,
           "CPython sanity check: expected #{expected_type}, got #{inspect(cpython_type)} for:\n#{code}"

    case Pyex.run(code) do
      {:error, err} ->
        assert err.exception_type == expected_type,
               """
               Error type mismatch:

               Python code:
                   #{indent(code)}

               CPython exception: #{expected_type}
               Pyex exception:    #{inspect(err.exception_type)}
               Pyex message:      #{err.message}
               """

      {:ok, val, _ctx} ->
        flunk("""
        Expected Pyex to error but it succeeded:

        Python code:
            #{indent(code)}

        CPython exception: #{expected_type}
        Pyex result:       #{inspect(val)}
        """)
    end
  end

  defp cpython_exception_type(code) do
    {output, exit_code} = System.cmd(@python3, ["-c", code], stderr_to_stdout: true)
    assert exit_code != 0, "Expected CPython to error on:\n#{code}\nGot output: #{output}"

    case Regex.run(~r/(\w+Error|\w+Exception|StopIteration)(?=:|\s|$)/, output) do
      [_, type] -> type
      _ -> nil
    end
  end

  defp indent(code) do
    code
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end

  # ── TypeError ──────────────────────────────────────────────

  describe "TypeError conformance" do
    test "unsupported operand types for +" do
      assert_error_type(~S[1 + "hello"], "TypeError")
    end

    test "unsupported operand types for -" do
      assert_error_type(~S["hello" - 1], "TypeError")
    end

    test "string * string" do
      assert_error_type(~S["a" * "b"], "TypeError")
    end

    test "int not iterable" do
      assert_error_type(
        """
        for x in 42:
            pass
        """,
        "TypeError"
      )
    end

    test "int not subscriptable" do
      assert_error_type("x = 42[0]", "TypeError")
    end

    test "wrong number of arguments" do
      assert_error_type(
        """
        def f(x):
            return x
        f(1, 2)
        """,
        "TypeError"
      )
    end

    test "NoneType not callable" do
      assert_error_type("None()", "TypeError")
    end

    test "list + int" do
      assert_error_type("[1, 2] + 3", "TypeError")
    end

    test "unorderable types in comparison" do
      assert_error_type(~S["abc" < 123], "TypeError")
    end

    test "unhashable type: list" do
      assert_error_type("{[1, 2]: 3}", "TypeError")
    end

    test "int() argument must be a string or a number" do
      assert_error_type("int([1, 2])", "TypeError")
    end

    test "not enough arguments to function" do
      assert_error_type(
        """
        def f(a, b, c):
            return a + b + c
        f(1, 2)
        """,
        "TypeError"
      )
    end
  end

  # ── ValueError ─────────────────────────────────────────────

  describe "ValueError conformance" do
    test "invalid literal for int" do
      assert_error_type(~S[int("abc")], "ValueError")
    end

    test "invalid literal for float" do
      assert_error_type(~S[float("abc")], "ValueError")
    end

    test "list.remove with missing value" do
      assert_error_type(
        """
        x = [1, 2, 3]
        x.remove(99)
        """,
        "ValueError"
      )
    end

    test "list.index with missing value" do
      assert_error_type("[1, 2, 3].index(99)", "ValueError")
    end

    test "too many values to unpack" do
      assert_error_type("a, b = [1, 2, 3]", "ValueError")
    end

    test "not enough values to unpack" do
      assert_error_type("a, b, c = [1, 2]", "ValueError")
    end

    test "int with invalid base" do
      assert_error_type(~S[int("xyz", 16)], "ValueError")
    end
  end

  # ── NameError ──────────────────────────────────────────────

  describe "NameError conformance" do
    test "undefined variable" do
      assert_error_type("print(undefined_var)", "NameError")
    end

    test "undefined variable in expression" do
      assert_error_type("x = y + 1", "NameError")
    end

    test "deleted variable" do
      assert_error_type(
        """
        x = 42
        del x
        print(x)
        """,
        "NameError"
      )
    end
  end

  # ── IndexError ─────────────────────────────────────────────

  describe "IndexError conformance" do
    test "list index out of range" do
      assert_error_type("[1, 2, 3][5]", "IndexError")
    end

    test "list negative index out of range" do
      assert_error_type("[1, 2, 3][-5]", "IndexError")
    end

    test "empty list index" do
      assert_error_type("[][0]", "IndexError")
    end

    test "tuple index out of range" do
      assert_error_type("(1, 2, 3)[5]", "IndexError")
    end

    test "string index out of range" do
      assert_error_type(~s|"abc"[5]|, "IndexError")
    end

    test "pop from empty list" do
      assert_error_type("[].pop()", "IndexError")
    end
  end

  # ── KeyError ───────────────────────────────────────────────

  describe "KeyError conformance" do
    test "missing dict key" do
      assert_error_type(~s|{"a": 1}["b"]|, "KeyError")
    end

    test "missing dict key with int" do
      assert_error_type("{1: 2}[3]", "KeyError")
    end

    test "dict.pop missing key without default" do
      assert_error_type(~s|{}.pop("x")|, "KeyError")
    end
  end

  # ── ZeroDivisionError ─────────────────────────────────────

  describe "ZeroDivisionError conformance" do
    test "integer division by zero" do
      assert_error_type("1 / 0", "ZeroDivisionError")
    end

    test "integer floor division by zero" do
      assert_error_type("1 // 0", "ZeroDivisionError")
    end

    test "modulo by zero" do
      assert_error_type("1 % 0", "ZeroDivisionError")
    end

    test "divmod by zero" do
      assert_error_type("divmod(1, 0)", "ZeroDivisionError")
    end
  end

  # ── AttributeError ────────────────────────────────────────

  describe "AttributeError conformance" do
    test "int has no attribute upper" do
      assert_error_type("(42).upper()", "AttributeError")
    end

    test "list has no attribute keys" do
      assert_error_type("[1, 2].keys()", "AttributeError")
    end

    test "string has no attribute append" do
      assert_error_type(~S["hello".append("!")], "AttributeError")
    end

    test "missing attribute on class instance" do
      assert_error_type(
        """
        class Foo:
            pass
        Foo().bar
        """,
        "AttributeError"
      )
    end

    test "NoneType has no attributes" do
      assert_error_type("None.x", "AttributeError")
    end
  end

  # ── RuntimeError ──────────────────────────────────────────

  describe "RuntimeError conformance" do
    test "explicit raise RuntimeError" do
      assert_error_type(~S[raise RuntimeError("oops")], "RuntimeError")
    end

    test "maximum recursion depth" do
      code = """
      def f():
          return f()
      f()
      """

      case Pyex.run(code) do
        {:error, err} ->
          assert err.exception_type == "RecursionError",
                 "Expected RecursionError, got: #{inspect(err.exception_type)} - #{err.message}"

        {:ok, _, _} ->
          flunk("Expected Pyex to error on infinite recursion")
      end
    end
  end

  # ── StopIteration ──────────────────────────────────────────

  describe "StopIteration conformance" do
    test "next() on exhausted iterator" do
      code = """
      it = iter([])
      next(it)
      """

      case Pyex.run(code) do
        {:error, err} ->
          assert String.contains?(err.message, "StopIteration"),
                 "Expected StopIteration in error message, got: #{err.message}"

        {:ok, _, _} ->
          flunk("Expected Pyex to error on StopIteration")
      end
    end

    test "next() past end of list iterator" do
      code = """
      it = iter([1])
      next(it)
      next(it)
      """

      case Pyex.run(code) do
        {:error, err} ->
          assert String.contains?(err.message, "StopIteration"),
                 "Expected StopIteration in error message, got: #{err.message}"

        {:ok, _, _} ->
          flunk("Expected Pyex to error on StopIteration")
      end
    end
  end

  # ── Errors caught inside try/except ────────────────────────

  describe "caught error type conformance" do
    test "TypeError caught in try/except" do
      code = """
      try:
          x = 1 + "a"
      except TypeError as e:
          print(repr(type(e).__name__))
      """

      cpython_output = run_cpython(code)
      pyex_output = run_pyex(code)
      assert pyex_output == cpython_output, mismatch_msg(code, cpython_output, pyex_output)
    end

    test "ValueError caught in try/except" do
      code = ~S"""
      try:
          x = int("abc")
      except ValueError as e:
          print(repr(type(e).__name__))
      """

      cpython_output = run_cpython(code)
      pyex_output = run_pyex(code)
      assert pyex_output == cpython_output, mismatch_msg(code, cpython_output, pyex_output)
    end

    test "IndexError caught in try/except" do
      code = """
      try:
          x = [1, 2][5]
      except IndexError as e:
          print(repr(type(e).__name__))
      """

      cpython_output = run_cpython(code)
      pyex_output = run_pyex(code)
      assert pyex_output == cpython_output, mismatch_msg(code, cpython_output, pyex_output)
    end

    test "KeyError caught in try/except" do
      code = ~S"""
      try:
          x = {"a": 1}["b"]
      except KeyError as e:
          print(repr(type(e).__name__))
      """

      cpython_output = run_cpython(code)
      pyex_output = run_pyex(code)
      assert pyex_output == cpython_output, mismatch_msg(code, cpython_output, pyex_output)
    end

    test "ZeroDivisionError caught in try/except" do
      code = """
      try:
          x = 1 / 0
      except ZeroDivisionError as e:
          print(repr(type(e).__name__))
      """

      cpython_output = run_cpython(code)
      pyex_output = run_pyex(code)
      assert pyex_output == cpython_output, mismatch_msg(code, cpython_output, pyex_output)
    end

    test "exception hierarchy: except base catches derived" do
      code = """
      try:
          raise ValueError("test")
      except Exception as e:
          print(repr(type(e).__name__))
      """

      cpython_output = run_cpython(code)
      pyex_output = run_pyex(code)
      assert pyex_output == cpython_output, mismatch_msg(code, cpython_output, pyex_output)
    end

    test "multiple except clauses route correctly" do
      code = """
      errors = []
      for val in ["abc", [1,2], 0]:
          try:
              if isinstance(val, str):
                  int(val)
              elif isinstance(val, list):
                  val[10]
              else:
                  1 / val
          except ValueError:
              errors.append("value")
          except IndexError:
              errors.append("index")
          except ZeroDivisionError:
              errors.append("zero")
      print(repr(errors))
      """

      cpython_output = run_cpython(code)
      pyex_output = run_pyex(code)
      assert pyex_output == cpython_output, mismatch_msg(code, cpython_output, pyex_output)
    end

    test "custom exception class" do
      code = ~S"""
      class AppError(Exception):
          pass
      try:
          raise AppError("custom")
      except AppError as e:
          print(repr((type(e).__name__, str(e))))
      """

      cpython_output = run_cpython(code)
      pyex_output = run_pyex(code)
      assert pyex_output == cpython_output, mismatch_msg(code, cpython_output, pyex_output)
    end

    test "tuple of exception types" do
      code = """
      try:
          raise TypeError("oops")
      except (ValueError, TypeError) as e:
          print(repr(type(e).__name__))
      """

      cpython_output = run_cpython(code)
      pyex_output = run_pyex(code)
      assert pyex_output == cpython_output, mismatch_msg(code, cpython_output, pyex_output)
    end

    test "bare raise re-raises" do
      code = """
      try:
          try:
              raise ValueError("inner")
          except ValueError:
              raise
      except ValueError as e:
          print(repr(str(e)))
      """

      cpython_output = run_cpython(code)
      pyex_output = run_pyex(code)
      assert pyex_output == cpython_output, mismatch_msg(code, cpython_output, pyex_output)
    end
  end

  defp run_cpython(code) do
    {output, 0} = System.cmd(@python3, ["-c", code], stderr_to_stdout: true)
    String.trim(output)
  end

  defp run_pyex(code) do
    case Pyex.run(code) do
      {:ok, _, ctx} -> String.trim(Pyex.output(ctx))
      {:error, err} -> "PYEX_ERROR: #{err.message}"
    end
  end

  defp mismatch_msg(code, cpython, pyex) do
    """
    Error conformance mismatch:

    Python code:
        #{indent(code)}

    CPython output: #{inspect(cpython)}
    Pyex output:    #{inspect(pyex)}
    """
  end
end
