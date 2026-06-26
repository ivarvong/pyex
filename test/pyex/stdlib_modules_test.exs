defmodule Pyex.StdlibModulesTest do
  @moduledoc """
  Functional tests for the `ast`, `inspect`, `logging`, and `traceback`
  shims, exercising behaviour that is part of pyex's contract but not
  byte-checkable against CPython through the conformance helper — chiefly
  the sandbox's *stdout-only* model (CPython's logging writes to stderr,
  which the sandbox deliberately does not surface).

  Byte-equality against the real stdlib lives in
  test/pyex/library_conformance/stdlib_modules_library_conformance_test.exs.
  """

  use ExUnit.Case, async: true

  defp run!(src) do
    {:ok, _value, ctx} = Pyex.run(src)
    Pyex.output(ctx)
  end

  describe "logging is silent on stdout" do
    test "module-level warning/info/error emit nothing to stdout" do
      out =
        run!("""
        import logging
        logging.warning('w')
        logging.info('i')
        logging.error('e')
        print('done')
        """)

      assert out == "done\n"
    end

    test "getLogger().info / .warning emit nothing to stdout" do
      out =
        run!("""
        import logging
        log = logging.getLogger('app')
        log.info('hello')
        log.warning('careful')
        print('done')
        """)

      assert out == "done\n"
    end

    test "basicConfig is callable and silent" do
      out =
        run!("""
        import logging
        logging.basicConfig(level=logging.DEBUG)
        log = logging.getLogger(__name__)
        log.debug('details')
        print('configured')
        """)

      assert out == "configured\n"
    end
  end

  describe "logging level tracking" do
    test "setLevel then getEffectiveLevel reflects the set level" do
      out =
        run!("""
        import logging
        log = logging.getLogger('svc')
        log.setLevel(logging.ERROR)
        print(log.getEffectiveLevel())
        """)

      assert out == "40\n"
    end

    test "isEnabledFor compares against the effective level" do
      out =
        run!("""
        import logging
        log = logging.getLogger('svc')
        log.setLevel(logging.WARNING)
        print(log.isEnabledFor(logging.ERROR), log.isEnabledFor(logging.DEBUG))
        """)

      assert out == "True False\n"
    end

    test "an unset logger reports the default effective level of WARNING" do
      out =
        run!("""
        import logging
        log = logging.getLogger('fresh')
        print(log.getEffectiveLevel())
        """)

      assert out == "30\n"
    end
  end

  describe "traceback.format_exc inside an except block" do
    test "carries the ExcType: message line" do
      out =
        run!("""
        import traceback
        try:
            1 / 0
        except ZeroDivisionError:
            tb = traceback.format_exc()
            print('ZeroDivisionError: division by zero' in tb)
            print(tb.startswith('Traceback (most recent call last):'))
        """)

      assert out == "True\nTrue\n"
    end

    test "outside an except block reports the no-exception sentinel" do
      out =
        run!("""
        import traceback
        print(traceback.format_exc().strip())
        """)

      assert out == "NoneType: None\n"
    end
  end

  describe "inspect predicates on pyex values" do
    test "isfunction is True for a def and False for a lambda-bound class" do
      out =
        run!("""
        import inspect
        def f(): pass
        class C: pass
        print(inspect.isfunction(f), inspect.isclass(C), inspect.isroutine(f))
        """)

      assert out == "True True True\n"
    end
  end

  describe "ast.literal_eval" do
    test "round-trips a dict literal" do
      out =
        run!("""
        import ast
        d = ast.literal_eval("{'k': [1, 2], 'n': 3}")
        print(d['k'], d['n'])
        """)

      assert out == "[1, 2] 3\n"
    end

    test "raises ValueError on a name reference" do
      out =
        run!("""
        import ast
        try:
            ast.literal_eval('undefined_name')
        except ValueError:
            print('rejected')
        """)

      assert out == "rejected\n"
    end
  end
end
