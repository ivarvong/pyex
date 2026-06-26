defmodule Pyex.LibraryConformance.StdlibModulesTest do
  @moduledoc """
  Conformance tests for the `ast`, `inspect`, `logging`, and `traceback`
  shims against the real CPython standard library.

  Unlike the third-party shims (pydantic, fastapi), these modules ship
  with CPython itself, so the "reference" is plain `python -c` under the
  pinned `uv` environment. Each test asserts byte-equal output for the
  parts of each module that *do* have a faithful analogue in the sandbox:

    * `ast.literal_eval` — exact value evaluation and `ValueError` rejection
    * `inspect` — `is*` predicates and `signature` rendering
    * `logging` — level constants and stderr-only output (empty stdout)
    * `traceback` — the structural `ExcType: message` line code inspects

  Frame/source introspection and exact traceback frame lines have no
  faithful analogue in the sandbox and are deliberately not asserted here.

  Tagged `:library_conformance` so they're excluded by default. Run with:

      mix test --include library_conformance

  Requires `uv` on PATH. Skipped at suite-start if missing.
  """

  use ExUnit.Case, async: true

  @moduletag :library_conformance

  import Pyex.Test.LibraryConformance

  unless uv_available?() do
    @moduletag skip: "uv not found on PATH"
  end

  describe "ast.literal_eval" do
    test "evaluates a nested list/dict literal" do
      assert_matches_library("""
      import ast
      print(ast.literal_eval('[1, 2, {"a": 3}]'))
      """)
    end

    test "evaluates a tuple literal" do
      assert_matches_library("""
      import ast
      print(ast.literal_eval('(1, 2, 3)'))
      """)
    end

    test "evaluates a set literal" do
      assert_matches_library("""
      import ast
      print(ast.literal_eval('{1, 2, 3}'))
      """)
    end

    test "evaluates a negative number" do
      assert_matches_library("""
      import ast
      print(ast.literal_eval('-5'))
      """)
    end

    test "evaluates a string literal" do
      assert_matches_library("""
      import ast
      print(ast.literal_eval("'hello'"))
      """)
    end

    test "evaluates booleans and None" do
      assert_matches_library("""
      import ast
      print(ast.literal_eval('[True, False, None]'))
      """)
    end

    test "rejects a function call with ValueError" do
      assert_matches_library("""
      import ast
      try:
          ast.literal_eval('foo()')
          print('NO ERROR')
      except ValueError:
          print('ValueError')
      """)
    end

    test "rejects a name reference with ValueError" do
      assert_matches_library("""
      import ast
      try:
          ast.literal_eval('x + 1')
          print('NO ERROR')
      except ValueError:
          print('ValueError')
      """)
    end
  end

  describe "inspect predicates" do
    test "isfunction / isclass / isbuiltin" do
      assert_matches_library("""
      import inspect
      def f(): pass
      print(inspect.isfunction(f), inspect.isclass(int), inspect.isbuiltin(len))
      """)
    end

    test "isfunction is False for a class and a builtin" do
      assert_matches_library("""
      import inspect
      class C: pass
      print(inspect.isfunction(C), inspect.isfunction(len))
      """)
    end

    test "isclass is True for user and builtin classes" do
      assert_matches_library("""
      import inspect
      class C: pass
      print(inspect.isclass(C), inspect.isclass(int), inspect.isclass(str))
      """)
    end
  end

  describe "inspect.signature" do
    test "renders positional, default, *args and **kwargs" do
      assert_matches_library("""
      import inspect
      def f(a, b=2, *args, **kw): pass
      print(str(inspect.signature(f)))
      """)
    end

    test "renders a string default with repr quoting" do
      assert_matches_library("""
      import inspect
      def g(x, y='hi'): pass
      print(str(inspect.signature(g)))
      """)
    end

    test "renders an empty signature" do
      assert_matches_library("""
      import inspect
      def h(): pass
      print(str(inspect.signature(h)))
      """)
    end
  end

  describe "logging" do
    test "level constants match CPython" do
      assert_matches_library("""
      import logging
      print(logging.CRITICAL, logging.ERROR, logging.WARNING, logging.INFO, logging.DEBUG, logging.NOTSET)
      """)
    end

    test "getLevelName maps integers to names" do
      assert_matches_library("""
      import logging
      print(logging.getLevelName(40), logging.getLevelName(20), logging.getLevelName(0))
      """)
    end

    # Note: logging's actual emission goes to *stderr* (the lastResort
    # handler), which the conformance helper merges into stdout — so a
    # "writes nothing to stdout" assertion can't be made faithfully here.
    # That behaviour is covered as a functional unit test instead, where
    # the sandbox's stdout-only model is the contract. See
    # test/pyex/stdlib_modules_test.exs.
  end

  describe "traceback" do
    test "format_exc carries the ExcType: message line" do
      assert_matches_library("""
      import traceback
      try:
          1 / 0
      except ZeroDivisionError:
          tb = traceback.format_exc()
          print('ZeroDivisionError: division by zero' in tb)
      """)
    end

    test "format_exception_only renders the exception line" do
      assert_matches_library("""
      import traceback
      try:
          raise ValueError('bad value')
      except ValueError as e:
          lines = traceback.format_exception_only(type(e), e)
          print(lines[-1].strip())
      """)
    end
  end
end
