defmodule Pyex.Stdlib.MathTest do
  @moduledoc false
  use ExUnit.Case, async: true

  defp run!(code), do: Pyex.run!("import math\n" <> code)

  # ── constants ──────────────────────────────────────────────────

  describe "constants" do
    test "pi" do
      assert_in_delta run!("math.pi"), :math.pi(), 1.0e-15
    end

    test "e" do
      assert_in_delta run!("math.e"), :math.exp(1), 1.0e-15
    end

    test "tau equals 2*pi" do
      assert_in_delta run!("math.tau"), 2 * :math.pi(), 1.0e-15
    end

    test "inf" do
      assert run!("math.inf") == :infinity
    end

    test "nan" do
      assert run!("math.nan") == :nan
    end
  end

  # ── trig ───────────────────────────────────────────────────────

  describe "trigonometric" do
    test "sin" do
      assert_in_delta run!("math.sin(math.pi / 2)"), 1.0, 1.0e-12
    end

    test "cos" do
      assert_in_delta run!("math.cos(0)"), 1.0, 1.0e-12
    end

    test "tan" do
      assert_in_delta run!("math.tan(math.pi / 4)"), 1.0, 1.0e-12
    end

    test "asin" do
      assert_in_delta run!("math.asin(1)"), :math.pi() / 2, 1.0e-12
    end

    test "acos" do
      assert_in_delta run!("math.acos(1)"), 0.0, 1.0e-12
    end

    test "atan" do
      assert_in_delta run!("math.atan(1)"), :math.pi() / 4, 1.0e-12
    end

    test "atan2" do
      assert_in_delta run!("math.atan2(1, 1)"), :math.pi() / 4, 1.0e-12
    end
  end

  # ── hyperbolic ─────────────────────────────────────────────────

  describe "hyperbolic" do
    test "sinh" do
      assert_in_delta run!("math.sinh(1)"), :math.sinh(1), 1.0e-12
    end

    test "cosh" do
      assert_in_delta run!("math.cosh(0)"), 1.0, 1.0e-12
    end

    test "tanh" do
      assert_in_delta run!("math.tanh(0)"), 0.0, 1.0e-12
    end

    test "tanh approaches 1 for large input" do
      assert_in_delta run!("math.tanh(100)"), 1.0, 1.0e-12
    end

    test "asinh" do
      assert_in_delta run!("math.asinh(0)"), 0.0, 1.0e-12
    end

    test "acosh" do
      assert_in_delta run!("math.acosh(1)"), 0.0, 1.0e-12
    end

    test "atanh" do
      assert_in_delta run!("math.atanh(0)"), 0.0, 1.0e-12
    end
  end

  # ── power / exponential / log ──────────────────────────────────

  describe "power / exponential / log" do
    test "sqrt" do
      assert_in_delta run!("math.sqrt(9)"), 3.0, 1.0e-12
    end

    test "cbrt of positive" do
      assert_in_delta run!("math.cbrt(27)"), 3.0, 1.0e-9
    end

    test "cbrt of negative" do
      assert_in_delta run!("math.cbrt(-8)"), -2.0, 1.0e-9
    end

    test "pow" do
      assert_in_delta run!("math.pow(2, 10)"), 1024.0, 1.0e-12
    end

    test "exp" do
      assert_in_delta run!("math.exp(1)"), :math.exp(1), 1.0e-12
    end

    test "exp(0) is 1" do
      assert_in_delta run!("math.exp(0)"), 1.0, 1.0e-12
    end

    test "exp2" do
      assert_in_delta run!("math.exp2(3)"), 8.0, 1.0e-12
    end

    test "expm1 near zero" do
      assert_in_delta run!("math.expm1(0)"), 0.0, 1.0e-12
    end

    test "log natural" do
      assert_in_delta run!("math.log(math.e)"), 1.0, 1.0e-12
    end

    test "log with base" do
      assert_in_delta run!("math.log(8, 2)"), 3.0, 1.0e-12
    end

    test "log2" do
      assert_in_delta run!("math.log2(1024)"), 10.0, 1.0e-12
    end

    test "log10" do
      assert_in_delta run!("math.log10(1000)"), 3.0, 1.0e-12
    end

    test "log1p near zero" do
      assert_in_delta run!("math.log1p(0)"), 0.0, 1.0e-12
    end

    test "hypot 3-4-5 triangle" do
      assert_in_delta run!("math.hypot(3, 4)"), 5.0, 1.0e-12
    end
  end

  # ── rounding / float arithmetic ────────────────────────────────

  describe "rounding and float arithmetic" do
    test "ceil" do
      assert run!("math.ceil(3.2)") == 4
    end

    test "floor" do
      assert run!("math.floor(3.9)") == 3
    end

    test "trunc positive" do
      assert run!("math.trunc(3.7)") == 3
    end

    test "trunc negative" do
      assert run!("math.trunc(-3.7)") == -3
    end

    test "fabs" do
      assert_in_delta run!("math.fabs(-5)"), 5.0, 1.0e-12
    end

    test "fmod" do
      assert_in_delta run!("math.fmod(7.5, 3.0)"), 1.5, 1.0e-12
    end

    test "copysign positive to negative" do
      assert_in_delta run!("math.copysign(1.0, -3.0)"), -1.0, 1.0e-12
    end

    test "copysign negative to positive" do
      assert_in_delta run!("math.copysign(-5.0, 1.0)"), 5.0, 1.0e-12
    end
  end

  # ── angular ────────────────────────────────────────────────────

  describe "angular conversion" do
    test "radians" do
      assert_in_delta run!("math.radians(180)"), :math.pi(), 1.0e-12
    end

    test "degrees" do
      assert_in_delta run!("math.degrees(math.pi)"), 180.0, 1.0e-12
    end
  end

  # ── number-theoretic ───────────────────────────────────────────

  describe "number-theoretic" do
    test "factorial of 0" do
      assert run!("math.factorial(0)") == 1
    end

    test "factorial of 10" do
      assert run!("math.factorial(10)") == 3_628_800
    end

    test "factorial of 20" do
      assert run!("math.factorial(20)") == 2_432_902_008_176_640_000
    end

    test "gcd" do
      assert run!("math.gcd(12, 8)") == 4
    end

    test "gcd with zero" do
      assert run!("math.gcd(7, 0)") == 7
    end

    test "lcm" do
      assert run!("math.lcm(4, 6)") == 12
    end

    test "lcm with zero" do
      assert run!("math.lcm(0, 5)") == 0
    end

    test "comb (10 choose 3)" do
      assert run!("math.comb(10, 3)") == 120
    end

    test "comb (n choose 0)" do
      assert run!("math.comb(5, 0)") == 1
    end

    test "comb (n choose n)" do
      assert run!("math.comb(5, 5)") == 1
    end

    test "comb with k > n returns 0" do
      assert run!("math.comb(3, 5)") == 0
    end

    test "perm" do
      assert run!("math.perm(5, 2)") == 20
    end

    test "perm with k > n returns 0" do
      assert run!("math.perm(3, 5)") == 0
    end

    test "isqrt" do
      assert run!("math.isqrt(17)") == 4
    end

    test "isqrt of perfect square" do
      assert run!("math.isqrt(25)") == 5
    end
  end

  # ── float inspection ───────────────────────────────────────────

  describe "float inspection" do
    test "isinf true for inf" do
      assert run!("math.isinf(math.inf)") == true
    end

    test "isinf false for number" do
      assert run!("math.isinf(1.0)") == false
    end

    test "isnan true for nan" do
      assert run!("math.isnan(math.nan)") == true
    end

    test "isnan false for number" do
      assert run!("math.isnan(1.0)") == false
    end

    test "isfinite true for number" do
      assert run!("math.isfinite(1.0)") == true
    end

    test "isfinite false for inf" do
      assert run!("math.isfinite(math.inf)") == false
    end

    test "isfinite false for nan" do
      assert run!("math.isfinite(math.nan)") == false
    end

    test "isclose with default tolerance" do
      assert run!("math.isclose(1.0, 1.0 + 1e-10)") == true
    end

    test "isclose rejects distant values" do
      assert run!("math.isclose(1.0, 1.1)") == false
    end

    test "isclose with custom rel_tol" do
      assert run!("math.isclose(1.0, 1.05, rel_tol=0.1)") == true
    end

    test "isclose with abs_tol" do
      assert run!("math.isclose(0.0, 0.001, abs_tol=0.01)") == true
    end
  end

  # ── summation / product ────────────────────────────────────────

  describe "summation and product" do
    test "fsum" do
      assert_in_delta run!("math.fsum([0.1, 0.2, 0.3])"), 0.6, 1.0e-12
    end

    test "fsum empty list" do
      assert_in_delta run!("math.fsum([])"), 0.0, 1.0e-12
    end

    test "prod" do
      assert run!("math.prod([1, 2, 3, 4])") == 24
    end

    test "prod empty list" do
      assert run!("math.prod([])") == 1
    end

    test "prod with start" do
      assert run!("math.prod([2, 3], start=10)") == 60
    end
  end

  # ── integration ────────────────────────────────────────────────

  describe "integration" do
    test "sigmoid function using exp" do
      result =
        run!("""
        def sigmoid(x):
            return 1 / (1 + math.exp(-x))
        sigmoid(0)
        """)

      assert_in_delta result, 0.5, 1.0e-12
    end

    test "normal distribution PDF" do
      result =
        run!("""
        def normal_pdf(x, mu, sigma):
            return (1 / (sigma * math.sqrt(2 * math.pi))) * math.exp(-0.5 * ((x - mu) / sigma) ** 2)
        normal_pdf(0, 0, 1)
        """)

      assert_in_delta result, 0.3989422804014327, 1.0e-10
    end

    test "combinatorics: pascal triangle row" do
      assert run!("[math.comb(5, k) for k in range(6)]") == [1, 5, 10, 10, 5, 1]
    end

    test "distance calculation with hypot" do
      result =
        run!("""
        points = [(0, 0), (3, 4), (6, 8)]
        total = 0
        for i in range(1, len(points)):
            dx = points[i][0] - points[i-1][0]
            dy = points[i][1] - points[i-1][1]
            total = total + math.hypot(dx, dy)
        total
        """)

      assert_in_delta result, 10.0, 1.0e-12
    end
  end
end
