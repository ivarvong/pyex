defmodule Pyex.Conformance.MathTest do
  @moduledoc """
  Live CPython conformance tests for the `math` module.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "constants" do
    test "pi" do
      check!("import math; print(math.pi)")
    end

    test "e" do
      check!("import math; print(math.e)")
    end

    test "inf" do
      check!("import math; print(math.inf)")
    end

    test "nan is not equal to itself" do
      check!("import math; print(math.nan != math.nan)")
    end

    test "tau" do
      check!("import math; print(math.tau)")
    end
  end

  describe "basic arithmetic" do
    for expr <- [
          "math.sqrt(2)",
          "math.sqrt(0)",
          "math.sqrt(100)",
          "math.pow(2, 10)",
          "math.pow(2, 0.5)",
          "math.pow(10, -2)",
          "math.exp(0)",
          "math.exp(1)",
          "math.exp(-1)",
          "math.log(math.e)",
          "math.log(1)",
          "math.log(100, 10)",
          "math.log2(1024)",
          "math.log10(1000)"
        ] do
      test "#{expr}" do
        check!("import math; print(#{unquote(expr)})")
      end
    end
  end

  describe "trig" do
    for expr <- [
          "math.sin(0)",
          "math.cos(0)",
          "math.tan(0)",
          "math.sin(math.pi / 2)",
          "math.cos(math.pi)",
          "math.asin(1)",
          "math.acos(0)",
          "math.atan(1)",
          "math.atan2(1, 1)",
          "math.atan2(-1, -1)",
          "math.atan2(0, 0)",
          "math.degrees(math.pi)",
          "math.radians(180)",
          "math.hypot(3, 4)"
        ] do
      test "#{expr}" do
        check!("import math; print(#{unquote(expr)})")
      end
    end
  end

  describe "hyperbolic" do
    for expr <- [
          "math.sinh(0)",
          "math.cosh(0)",
          "math.tanh(0)",
          "math.sinh(1)",
          "math.cosh(1)",
          "math.tanh(1)"
        ] do
      test "#{expr}" do
        check!("import math; print(#{unquote(expr)})")
      end
    end
  end

  describe "rounding and truncation" do
    for expr <- [
          "math.ceil(2.3)",
          "math.ceil(-2.3)",
          "math.ceil(3)",
          "math.floor(2.7)",
          "math.floor(-2.3)",
          "math.floor(3)",
          "math.trunc(2.7)",
          "math.trunc(-2.7)",
          "math.trunc(3)"
        ] do
      test "#{expr}" do
        check!("import math; print(#{unquote(expr)})")
      end
    end
  end

  describe "factorial and combinatorics" do
    for expr <- [
          "math.factorial(0)",
          "math.factorial(1)",
          "math.factorial(10)",
          "math.factorial(20)",
          "math.comb(10, 3)",
          "math.comb(5, 0)",
          "math.comb(5, 5)",
          "math.perm(10, 3)",
          "math.perm(5, 5)",
          "math.gcd(12, 18)",
          "math.gcd(0, 5)",
          "math.lcm(4, 6)",
          "math.lcm(3, 5, 7)"
        ] do
      test "#{expr}" do
        check!("import math; print(#{unquote(expr)})")
      end
    end
  end

  describe "sign and absolute" do
    for expr <- [
          "math.copysign(3, -0.0)",
          "math.copysign(-3, 1)",
          "math.fabs(-5)",
          "math.fabs(5)",
          "math.fabs(-0.0)"
        ] do
      test "#{expr}" do
        check!("import math; print(#{unquote(expr)})")
      end
    end
  end

  describe "special" do
    for expr <- [
          "math.isnan(float('nan'))",
          "math.isnan(1.0)",
          "math.isinf(float('inf'))",
          "math.isinf(1.0)",
          "math.isfinite(1.0)",
          "math.isfinite(float('inf'))",
          "math.isfinite(float('nan'))",
          "math.isclose(1.0, 1.00000001)",
          "math.isclose(1.0, 1.1)",
          "math.isclose(1.0, 1.0 + 1e-10)"
        ] do
      test "#{expr}" do
        check!("import math; print(#{unquote(expr)})")
      end
    end
  end

  describe "sum and product" do
    test "fsum" do
      check!("""
      import math
      print(math.fsum([0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1]))
      """)
    end

    test "prod" do
      check!("""
      import math
      print(math.prod([1, 2, 3, 4]))
      print(math.prod([], start=10))
      """)
    end
  end

  describe "remainders" do
    for expr <- [
          "math.fmod(10, 3)",
          "math.fmod(-10, 3)",
          "math.fmod(10, -3)",
          "math.remainder(10, 3)",
          "math.remainder(-10, 3)"
        ] do
      test "#{expr}" do
        check!("import math; print(#{unquote(expr)})")
      end
    end
  end
end
