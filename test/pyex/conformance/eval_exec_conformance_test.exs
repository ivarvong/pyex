defmodule Pyex.Conformance.EvalExecTest do
  @moduledoc """
  Live CPython conformance tests for `eval` and `exec` builtins.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "eval" do
    test "simple arithmetic" do
      check!(~S|print(eval("1 + 2 * 3"))|)
    end

    test "reads enclosing variable" do
      check!("""
      x = 10
      print(eval("x * 2"))
      """)
    end

    test "builds expression dynamically" do
      check!("""
      op = "+"
      print(eval(f"5 {op} 3"))
      """)
    end
  end

  describe "exec" do
    test "defines variable in current scope" do
      check!("""
      exec("x = 42")
      print(x)
      """)
    end

    test "runs multiple statements" do
      check!("""
      exec('''
      a = 1
      b = 2
      c = a + b
      ''')
      print(c)
      """)
    end

    test "exec with print" do
      check!(~S|exec('print("hello")')|)
    end
  end
end
