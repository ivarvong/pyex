defmodule Pyex.TryExceptTest do
  use ExUnit.Case, async: true
  alias Pyex.Error

  describe "basic try/except" do
    test "catches bare except" do
      assert Pyex.run!("""
             x = 0
             try:
               x = 1 / 0
             except:
               x = -1
             x
             """) == -1
    end

    test "no exception runs try body normally" do
      assert Pyex.run!("""
             x = 0
             try:
               x = 42
             except:
               x = -1
             x
             """) == 42
    end
  end

  describe "named exception matching" do
    test "catches NameError" do
      assert Pyex.run!("""
             result = "ok"
             try:
               x = undefined_var
             except NameError:
               result = "caught"
             result
             """) == "caught"
    end

    test "catches ValueError" do
      assert Pyex.run!("""
             result = "ok"
             try:
               x = int("abc")
             except ValueError:
               result = "caught"
             result
             """) == "caught"
    end

    test "does not catch wrong exception type" do
      assert_raise RuntimeError, ~r/NameError/, fn ->
        Pyex.run!("""
        try:
          x = undefined_var
        except ValueError:
          x = "caught"
        """)
      end
    end

    test "Exception catches everything" do
      assert Pyex.run!("""
             result = "ok"
             try:
               x = undefined_var
             except Exception:
               result = "caught"
             result
             """) == "caught"
    end
  end

  describe "except as" do
    test "binds exception message to variable" do
      assert Pyex.run!("""
             msg = ""
             try:
               x = undefined_var
             except NameError as e:
               msg = str(e)
             msg
             """) =~ "undefined_var"
    end
  end

  describe "multiple except clauses" do
    test "matches first matching handler" do
      assert Pyex.run!("""
             result = ""
             try:
               x = int("abc")
             except NameError:
               result = "name"
             except ValueError:
               result = "value"
             result
             """) == "value"
    end

    test "falls through to bare except" do
      assert Pyex.run!("""
             result = ""
             try:
               x = undefined_var
             except ValueError:
               result = "value"
             except:
               result = "other"
             result
             """) == "other"
    end
  end

  describe "raise statement" do
    test "raise a string" do
      assert_raise RuntimeError, ~r/Exception: hello/, fn ->
        Pyex.run!("raise \"hello\"")
      end
    end

    test "raise caught by except" do
      assert Pyex.run!("""
             result = ""
             try:
               raise "boom"
             except Exception:
               result = "caught"
             result
             """) == "caught"
    end
  end

  describe "try/except in functions" do
    test "try/except inside a function" do
      assert Pyex.run!("""
             def safe_div(a, b):
               try:
                 return a / b
               except:
                 return 0
             safe_div(10, 0)
             """) == 0
    end

    test "return propagates out of try body" do
      assert Pyex.run!("""
             def f():
               try:
                 return 42
               except:
                 return -1
             f()
             """) == 42
    end
  end

  describe "nested try/except" do
    test "inner try catches, outer continues" do
      assert Pyex.run!("""
             result = ""
             try:
               try:
                 x = undefined_var
               except NameError:
                 result = "inner"
             except:
               result = "outer"
             result
             """) == "inner"
    end
  end

  describe "finally clause" do
    test "finally runs after normal execution" do
      assert Pyex.run!("""
             result = []
             try:
                 result.append("try")
             except:
                 result.append("except")
             finally:
                 result.append("finally")
             result
             """) == ["try", "finally"]
    end

    test "finally runs after exception" do
      assert Pyex.run!("""
             result = []
             try:
                 x = undefined
             except:
                 result.append("except")
             finally:
                 result.append("finally")
             result
             """) == ["except", "finally"]
    end

    test "finally runs even with unhandled exception" do
      {:error, %Error{message: msg}} =
        Pyex.run("""
        result = []
        try:
            result.append("try")
            raise "boom"
        except ValueError:
            result.append("wrong handler")
        finally:
            result.append("finally")
        result
        """)

      assert msg =~ "boom"
    end

    test "exception in finally overrides original" do
      {:error, %Error{message: msg}} =
        Pyex.run("""
        try:
            x = 1
        except:
            pass
        finally:
            raise "from finally"
        """)

      assert msg =~ "from finally"
    end

    test "finally without except clauses" do
      assert Pyex.run!("""
             result = []
             try:
                 result.append("try")
             finally:
                 result.append("finally")
             result
             """) == ["try", "finally"]
    end
  end

  describe "else clause on try" do
    test "else runs when no exception" do
      assert Pyex.run!("""
             result = []
             try:
                 result.append("try")
             except:
                 result.append("except")
             else:
                 result.append("else")
             result
             """) == ["try", "else"]
    end

    test "else does not run when exception occurs" do
      assert Pyex.run!("""
             result = []
             try:
                 x = undefined
             except:
                 result.append("except")
             else:
                 result.append("else")
             result
             """) == ["except"]
    end

    test "else with finally" do
      assert Pyex.run!("""
             result = []
             try:
                 result.append("try")
             except:
                 result.append("except")
             else:
                 result.append("else")
             finally:
                 result.append("finally")
             result
             """) == ["try", "else", "finally"]
    end

    test "except with else and finally on exception" do
      assert Pyex.run!("""
             result = []
             try:
                 x = undefined
             except:
                 result.append("except")
             else:
                 result.append("else")
             finally:
                 result.append("finally")
             result
             """) == ["except", "finally"]
    end
  end

  describe "raise ExcType(msg)" do
    test "raise ValueError with message" do
      {:error, %Error{message: msg}} = Pyex.run(~s|raise ValueError("bad value")|)
      assert msg =~ "ValueError: bad value"
    end

    test "raise TypeError with message" do
      {:error, %Error{message: msg}} = Pyex.run(~s|raise TypeError("wrong type")|)
      assert msg =~ "TypeError: wrong type"
    end

    test "raise without arguments" do
      {:error, %Error{message: msg}} = Pyex.run("raise RuntimeError()")
      assert msg =~ "RuntimeError"
    end

    test "raise bare exception name" do
      {:error, %Error{message: msg}} = Pyex.run("raise StopIteration")
      assert msg =~ "StopIteration"
    end

    test "raise caught by matching except" do
      assert Pyex.run!("""
             try:
                 raise ValueError("oops")
             except ValueError as e:
                 str(e)
             """) == "oops"
    end

    test "raise not caught by wrong except" do
      {:error, %Error{message: msg}} =
        Pyex.run("""
        try:
            raise TypeError("oops")
        except ValueError:
            pass
        """)

      assert msg =~ "TypeError: oops"
    end
  end

  describe "except tuple of types" do
    test "catches first type in tuple" do
      assert Pyex.run!("""
             try:
                 raise TypeError("oops")
             except (TypeError, ValueError):
                 "caught"
             """) == "caught"
    end

    test "catches second type in tuple" do
      assert Pyex.run!("""
             try:
                 raise ValueError("oops")
             except (TypeError, ValueError):
                 "caught"
             """) == "caught"
    end

    test "does not catch unmatched type" do
      {:error, %Error{message: msg}} =
        Pyex.run("""
        try:
            raise KeyError("oops")
        except (TypeError, ValueError):
            pass
        """)

      assert msg =~ "KeyError"
    end

    test "except tuple with as binding" do
      assert Pyex.run!("""
             try:
                 raise ValueError("bad")
             except (TypeError, ValueError) as e:
                 str(e)
             """) == "bad"
    end
  end

  describe "bare raise" do
    test "re-raises current exception" do
      assert Pyex.run!("""
             try:
                 try:
                     raise ValueError("inner")
                 except ValueError:
                     raise
             except ValueError as e:
                 str(e)
             """) == "inner"
    end

    test "bare raise caught by outer handler" do
      assert Pyex.run!("""
             try:
                 try:
                     raise ValueError("inner")
                 except:
                     raise
             except ValueError as e:
                 str(e)
             """) == "inner"
    end

    test "bare raise outside except is RuntimeError" do
      {:error, %Error{message: msg}} = Pyex.run("raise")
      assert msg =~ "RuntimeError"
    end
  end

  describe "custom exception classes" do
    test "custom exception with __init__ preserves attributes" do
      result =
        Pyex.run!("""
        class AppError(Exception):
            def __init__(self, msg, code):
                self.msg = msg
                self.code = code

        try:
            raise AppError("not found", 404)
        except AppError as e:
            (e.msg, e.code)
        """)

      assert result == {:tuple, ["not found", 404]}
    end

    test "custom exception without __init__ stores args" do
      result =
        Pyex.run!("""
        class MyError(Exception):
            pass

        try:
            raise MyError("oops")
        except MyError as e:
            e.args
        """)

      assert result == {:tuple, ["oops"]}
    end

    test "str() on custom exception with args shows message" do
      result =
        Pyex.run!("""
        class MyError(Exception):
            pass

        try:
            raise MyError("something broke")
        except MyError as e:
            str(e)
        """)

      assert result == "something broke"
    end

    test "str() on custom exception with multiple args" do
      result =
        Pyex.run!("""
        class MyError(Exception):
            pass

        try:
            raise MyError("bad", 42)
        except MyError as e:
            str(e)
        """)

      assert result == "bad, 42"
    end

    test "custom exception caught by Exception" do
      result =
        Pyex.run!("""
        class AppError(Exception):
            def __init__(self, msg):
                self.msg = msg

        try:
            raise AppError("test")
        except Exception as e:
            e.msg
        """)

      assert result == "test"
    end

    test "custom exception no args" do
      result =
        Pyex.run!("""
        class MyError(Exception):
            pass

        try:
            raise MyError()
        except MyError as e:
            str(e)
        """)

      assert is_binary(result)
    end

    test "uncaught custom exception shows proper error" do
      {:error, %Error{message: msg}} =
        Pyex.run("""
        class AppError(Exception):
            def __init__(self, msg, code):
                self.msg = msg
                self.code = code

        raise AppError("not found", 404)
        """)

      assert msg =~ "AppError: not found, 404"
    end
  end
end
