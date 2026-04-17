defmodule Pyex.Stdlib.Math do
  @moduledoc """
  Python `math` module backed by Erlang's `:math`.

  Covers trig, hyperbolic, power/log, angular, number-theoretic,
  floating-point inspection, and summation functions plus all
  standard constants.
  """

  @behaviour Pyex.Stdlib.Module

  @doc """
  Returns the module value -- a map with callable attributes
  and constants.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      # ── trig ──
      "sin" => {:builtin, &do_sin/1},
      "cos" => {:builtin, &do_cos/1},
      "tan" => {:builtin, &do_tan/1},
      "asin" => {:builtin, &do_asin/1},
      "acos" => {:builtin, &do_acos/1},
      "atan" => {:builtin, &do_atan/1},
      "atan2" => {:builtin, &do_atan2/1},
      # ── hyperbolic ──
      "sinh" => {:builtin, &do_sinh/1},
      "cosh" => {:builtin, &do_cosh/1},
      "tanh" => {:builtin, &do_tanh/1},
      "asinh" => {:builtin, &do_asinh/1},
      "acosh" => {:builtin, &do_acosh/1},
      "atanh" => {:builtin, &do_atanh/1},
      # ── power / exponential / log ──
      "sqrt" => {:builtin, &do_sqrt/1},
      "cbrt" => {:builtin, &do_cbrt/1},
      "pow" => {:builtin, &do_pow/1},
      "exp" => {:builtin, &do_exp/1},
      "exp2" => {:builtin, &do_exp2/1},
      "expm1" => {:builtin, &do_expm1/1},
      "log" => {:builtin, &do_log/1},
      "log2" => {:builtin, &do_log2/1},
      "log10" => {:builtin, &do_log10/1},
      "log1p" => {:builtin, &do_log1p/1},
      "hypot" => {:builtin, &do_hypot/1},
      # ── rounding / float arithmetic ──
      "ceil" => {:builtin, &do_ceil/1},
      "floor" => {:builtin, &do_floor/1},
      "trunc" => {:builtin, &do_trunc/1},
      "fabs" => {:builtin, &do_fabs/1},
      "fmod" => {:builtin, &do_fmod/1},
      "remainder" => {:builtin, &do_remainder/1},
      "copysign" => {:builtin, &do_copysign/1},
      # ── angular ──
      "radians" => {:builtin, &do_radians/1},
      "degrees" => {:builtin, &do_degrees/1},
      # ── number-theoretic ──
      "factorial" => {:builtin, &do_factorial/1},
      "gcd" => {:builtin, &do_gcd/1},
      "lcm" => {:builtin, &do_lcm/1},
      "comb" => {:builtin, &do_comb/1},
      "perm" => {:builtin, &do_perm/1},
      "isqrt" => {:builtin, &do_isqrt/1},
      # ── float inspection ──
      "isinf" => {:builtin, &do_isinf/1},
      "isnan" => {:builtin, &do_isnan/1},
      "isfinite" => {:builtin, &do_isfinite/1},
      "isclose" => {:builtin_kw, &do_isclose/2},
      # ── summation / product ──
      "fsum" => {:builtin, &do_fsum/1},
      "prod" => {:builtin_kw, &do_prod/2},
      # ── constants ──
      "pi" => :math.pi(),
      "e" => :math.exp(1),
      "tau" => 2 * :math.pi(),
      "inf" => :infinity,
      "nan" => :nan
    }
  end

  # ── trig ──────────────────────────────────────────────────────

  defp do_sin([x]) when is_number(x), do: :math.sin(x)
  defp do_cos([x]) when is_number(x), do: :math.cos(x)
  defp do_tan([x]) when is_number(x), do: :math.tan(x)
  defp do_asin([x]) when is_number(x), do: :math.asin(x)
  defp do_acos([x]) when is_number(x), do: :math.acos(x)
  defp do_atan([x]) when is_number(x), do: :math.atan(x)
  defp do_atan2([y, x]) when is_number(y) and is_number(x), do: :math.atan2(y, x)

  # ── hyperbolic ────────────────────────────────────────────────

  defp do_sinh([x]) when is_number(x), do: :math.sinh(x)
  defp do_cosh([x]) when is_number(x), do: :math.cosh(x)
  defp do_tanh([x]) when is_number(x), do: :math.tanh(x)
  defp do_asinh([x]) when is_number(x), do: :math.asinh(x)
  defp do_acosh([x]) when is_number(x), do: :math.acosh(x)
  defp do_atanh([x]) when is_number(x), do: :math.atanh(x)

  # ── power / exponential / log ─────────────────────────────────

  defp do_sqrt([x]) when is_number(x), do: :math.sqrt(x)
  defp do_cbrt([x]) when is_number(x) and x >= 0, do: :math.pow(x, 1 / 3)
  defp do_cbrt([x]) when is_number(x), do: -:math.pow(-x, 1 / 3)
  defp do_pow([x, y]) when is_number(x) and is_number(y), do: :math.pow(x, y)
  defp do_exp([x]) when is_number(x), do: :math.exp(x)
  defp do_exp2([x]) when is_number(x), do: :math.pow(2, x)
  defp do_expm1([x]) when is_number(x), do: :math.exp(x) - 1

  defp do_log([x]) when is_number(x), do: :math.log(x)

  defp do_log([x, base]) when is_number(x) and is_number(base) do
    :math.log(x) / :math.log(base)
  end

  defp do_log2([x]) when is_number(x), do: :math.log2(x)
  defp do_log10([x]) when is_number(x), do: :math.log10(x)
  defp do_log1p([x]) when is_number(x), do: :math.log(1 + x)

  defp do_hypot([x, y]) when is_number(x) and is_number(y) do
    :math.sqrt(x * x + y * y)
  end

  # ── rounding / float arithmetic ───────────────────────────────

  defp do_ceil([x]) when is_number(x), do: :erlang.ceil(x)
  defp do_floor([x]) when is_number(x), do: :erlang.floor(x)
  defp do_trunc([x]) when is_number(x), do: trunc(x)
  defp do_fabs([x]) when is_number(x), do: abs(x) / 1
  defp do_fmod([x, y]) when is_number(x) and is_number(y), do: :math.fmod(x, y)

  # IEEE-754 remainder: `r = x - n*y` where n is the nearest integer to x/y,
  # ties to even.  Python's `math.remainder`.
  defp do_remainder([x, y]) when is_number(x) and is_number(y) do
    q = x / y
    n = round_half_to_even(q)
    (x - n * y) * 1.0
  end

  defp do_copysign([x, y]) when is_number(x) and is_number(y) do
    magnitude = abs(x) / 1

    if is_neg_zero?(y) or y < 0 do
      -magnitude
    else
      magnitude
    end
  end

  # Detects IEEE-754 negative zero.  Erlang preserves the sign bit, so
  # dividing a positive number by `y` gives `-infinity` when y is -0.0.
  @spec is_neg_zero?(number()) :: boolean()
  defp is_neg_zero?(y) when is_float(y) and y == 0.0 do
    <<sign::1, _rest::63>> = <<y::float-64>>
    sign == 1
  end

  defp is_neg_zero?(_), do: false

  @spec round_half_to_even(float()) :: integer()
  defp round_half_to_even(q) do
    f = :erlang.floor(q)
    diff = q - f

    cond do
      diff < 0.5 -> trunc(f)
      diff > 0.5 -> trunc(f) + 1
      # Exactly 0.5: round to even.
      rem(trunc(f), 2) == 0 -> trunc(f)
      true -> trunc(f) + 1
    end
  end

  # ── angular ───────────────────────────────────────────────────

  defp do_radians([x]) when is_number(x), do: x * :math.pi() / 180
  defp do_degrees([x]) when is_number(x), do: x * 180 / :math.pi()

  # ── number-theoretic ──────────────────────────────────────────

  defp do_factorial([n]) when is_integer(n) and n >= 0, do: factorial(n)

  defp do_gcd(args) when is_list(args) do
    Enum.reduce(args, 0, fn a, acc when is_integer(a) -> Integer.gcd(acc, a) end)
  end

  defp do_lcm([]), do: 1

  defp do_lcm(args) when is_list(args) do
    Enum.reduce(args, 1, fn a, acc when is_integer(a) -> lcm_pair(acc, a) end)
  end

  @spec lcm_pair(integer(), integer()) :: integer()
  defp lcm_pair(0, _), do: 0
  defp lcm_pair(_, 0), do: 0

  defp lcm_pair(a, b) do
    abs(div(a, Integer.gcd(a, b)) * b)
  end

  defp do_comb([n, k]) when is_integer(n) and is_integer(k) and n >= 0 and k >= 0 and k <= n do
    k = min(k, n - k)
    comb_iter(n, k, 1, 1)
  end

  defp do_comb([n, k]) when is_integer(n) and is_integer(k) and (k < 0 or k > n), do: 0

  defp do_perm([n, k]) when is_integer(n) and is_integer(k) and n >= 0 and k >= 0 and k <= n do
    perm_iter(n, k, 1)
  end

  defp do_perm([n, k]) when is_integer(n) and is_integer(k) and (k < 0 or k > n), do: 0

  defp do_isqrt([n]) when is_integer(n) and n >= 0 do
    s = trunc(:math.sqrt(n))
    if (s + 1) * (s + 1) <= n, do: s + 1, else: s
  end

  # ── float inspection ──────────────────────────────────────────

  defp do_isinf([:infinity]), do: true
  defp do_isinf([:neg_infinity]), do: true
  defp do_isinf([_x]), do: false

  defp do_isnan([:nan]), do: true
  defp do_isnan([_x]), do: false

  defp do_isfinite([:infinity]), do: false
  defp do_isfinite([:neg_infinity]), do: false
  defp do_isfinite([:nan]), do: false
  defp do_isfinite([x]) when is_number(x), do: true
  defp do_isfinite([_x]), do: false

  defp do_isclose([a, b], kwargs) when is_number(a) and is_number(b) do
    rel_tol = Map.get(kwargs, "rel_tol", 1.0e-9)
    abs_tol = Map.get(kwargs, "abs_tol", 0.0)
    isclose(a, b, rel_tol, abs_tol)
  end

  # ── summation / product ───────────────────────────────────────

  defp do_fsum([{:py_list, reversed, _}]) do
    reversed |> Enum.reverse() |> neumaier_sum()
  end

  defp do_fsum([items]) when is_list(items) do
    neumaier_sum(items)
  end

  # Neumaier summation: a variant of Kahan summation that handles cases
  # where the running sum is smaller than the next input.  Enough precision
  # for the typical Python `math.fsum` use cases (0.1 summed 10 times == 1.0).
  @spec neumaier_sum([number()]) :: float()
  defp neumaier_sum(items) do
    {sum, c} =
      Enum.reduce(items, {0.0, 0.0}, fn x, {s, c} ->
        t = s + x

        new_c =
          if abs(s) >= abs(x) do
            c + (s - t + x)
          else
            c + (x - t + s)
          end

        {t, new_c}
      end)

    sum + c
  end

  defp do_prod([{:py_list, reversed, _}], kwargs) do
    start = Map.get(kwargs, "start", 1)
    Enum.reduce(reversed, start, fn x, acc when is_number(x) -> acc * x end)
  end

  defp do_prod([items], kwargs) when is_list(items) do
    start = Map.get(kwargs, "start", 1)
    Enum.reduce(items, start, fn x, acc when is_number(x) -> acc * x end)
  end

  # ── helpers ───────────────────────────────────────────────────

  @spec factorial(non_neg_integer()) :: pos_integer()
  defp factorial(0), do: 1
  defp factorial(n) when n > 0, do: n * factorial(n - 1)

  @spec comb_iter(integer(), integer(), integer(), integer()) :: integer()
  defp comb_iter(_n, 0, _num, _den), do: 1

  defp comb_iter(n, k, num, den) do
    new_num = num * (n - k + den)
    new_den = den

    if rem(new_num, new_den) == 0 do
      result = div(new_num, new_den)

      if new_den == k do
        result
      else
        comb_iter(n, k, result, new_den + 1)
      end
    else
      if new_den == k do
        div(new_num, new_den)
      else
        comb_iter(n, k, new_num, new_den + 1)
      end
    end
  end

  @spec perm_iter(integer(), integer(), integer()) :: integer()
  defp perm_iter(_n, 0, acc), do: acc
  defp perm_iter(n, k, acc), do: perm_iter(n - 1, k - 1, acc * n)

  @spec isclose(number(), number(), float(), float()) :: boolean()
  defp isclose(a, b, rel_tol, abs_tol) do
    abs(a - b) <= max(rel_tol * max(abs(a), abs(b)), abs_tol)
  end
end
