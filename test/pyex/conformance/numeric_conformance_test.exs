defmodule Pyex.Conformance.NumericTest do
  @moduledoc """
  Live CPython conformance tests for integer/float arithmetic and
  bitwise operations.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "integer arithmetic" do
    for {label, expr} <- [
          {"add", "2 + 3"},
          {"sub", "10 - 7"},
          {"mul", "6 * 7"},
          {"div returns float", "7 / 2"},
          {"div exact returns float", "6 / 2"},
          {"floor div", "7 // 2"},
          {"floor div negative", "-7 // 2"},
          {"floor div both neg", "-7 // -2"},
          {"mod", "10 % 3"},
          {"mod negative", "-10 % 3"},
          {"mod neg divisor", "10 % -3"},
          {"power", "2 ** 10"},
          {"power negative", "2 ** -3"},
          {"power zero zero", "0 ** 0"},
          {"unary minus", "-(5)"},
          {"unary plus", "+(-5)"},
          {"long arithmetic", "10**18 + 1"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "bitwise operations" do
    for {label, expr} <- [
          {"and", "0b1100 & 0b1010"},
          {"or", "0b1100 | 0b1010"},
          {"xor", "0b1100 ^ 0b1010"},
          {"not (two's complement)", "~5"},
          {"not zero", "~0"},
          {"lshift", "1 << 5"},
          {"rshift", "32 >> 2"},
          {"rshift negative", "-32 >> 2"},
          {"mixed", "(0xff & 0x0f) | 0xf0"},
          {"huge lshift", "1 << 100"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "int methods" do
    for {label, expr} <- [
          {"bit_length 0", "(0).bit_length()"},
          {"bit_length small", "(5).bit_length()"},
          {"bit_length negative", "(-5).bit_length()"},
          {"bit_length large", "(1 << 100).bit_length()"},
          {"bit_count", "(0b1101).bit_count()"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "float arithmetic" do
    for {label, expr} <- [
          {"add floats", "0.1 + 0.2"},
          {"float / int", "7.5 / 2"},
          {"float floor div", "7.5 // 2"},
          {"float mod", "7.5 % 2"},
          {"float power", "2.0 ** 10"},
          {"int ** float", "2 ** 0.5"},
          {"very small", "1e-300"},
          {"very large", "1e300"},
          {"inf + 1", ~S|float("inf") + 1|},
          {"inf * 0", ~S|float("inf") * 0|},
          {"1 / inf", ~S|1 / float("inf")|},
          {"nan != nan", ~S|float("nan") != float("nan")|}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "comparison chains" do
    for {label, expr} <- [
          {"chain all true", "1 < 2 < 3"},
          {"chain middle false", "1 < 3 < 2"},
          {"chain equality", "1 == 1 == 1"},
          {"mixed operators", "0 < 5 < 10"},
          {"negated", "not (1 < 2)"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "int() parsing" do
    for {label, expr} <- [
          {"hex prefix", ~S|int("0xFF", 16)|},
          {"oct prefix", ~S|int("0o777", 8)|},
          {"bin prefix", ~S|int("0b1010", 2)|},
          {"with underscore", ~S|int("1_000_000")|},
          {"whitespace", ~S|int("  42  ")|},
          {"sign", ~S|int("-42")|},
          {"plus sign", ~S|int("+42")|}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end

  describe "int() errors" do
    test "empty string raises" do
      check!("""
      try:
          int("")
          print("no error")
      except ValueError as e:
          print(type(e).__name__)
      """)
    end

    test "invalid base raises" do
      check!("""
      try:
          int("x", 16)
          print("no error")
      except ValueError as e:
          print(type(e).__name__)
      """)
    end
  end

  describe "arithmetic exceptions" do
    test "division by zero" do
      check!("""
      try:
          1 / 0
          print("no error")
      except ZeroDivisionError as e:
          print(type(e).__name__)
      """)
    end

    test "integer division by zero" do
      check!("""
      try:
          1 // 0
          print("no error")
      except ZeroDivisionError:
          print("ZeroDivisionError")
      """)
    end

    test "modulo by zero" do
      check!("""
      try:
          5 % 0
          print("no error")
      except ZeroDivisionError:
          print("ZeroDivisionError")
      """)
    end
  end

  describe "boolean arithmetic" do
    for {label, expr} <- [
          {"True + 1", "True + 1"},
          {"True * 3", "True * 3"},
          {"False + 5", "False + 5"},
          {"sum of bools", "sum([True, False, True, True])"},
          {"bool in condition", "(True if True else False)"}
        ] do
      test "#{label}" do
        check!("print(#{unquote(expr)})")
      end
    end
  end
end
