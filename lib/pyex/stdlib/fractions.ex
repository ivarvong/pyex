defmodule Pyex.Stdlib.Fractions do
  @moduledoc """
  Python `fractions` module: exact rational numbers.

  Values are tagged `{:fraction, numerator, denominator}` (canonical form,
  see `Pyex.Fraction`). Arithmetic, comparison, repr/str, and `float()`/
  `int()` conversion live alongside the other numeric types in the
  interpreter; this module exposes the `Fraction` constructor.

  ## Supported

    * `Fraction(int)`, `Fraction(int, int)`, `Fraction(Fraction)`.
    * Arithmetic `+ - * / // ** ` and unary `-`/`abs()` against another
      `Fraction`, `int`, or `bool`; mixing with `float` coerces to `float`.
    * All comparisons against `Fraction`, `int`, and `bool`.
    * `.numerator` / `.denominator`, `float(...)`, `int(...)`, `str`/`repr`.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Fraction

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "__name__" => "fractions",
      "Fraction" => {:builtin, &fraction_new/1}
    }
  end

  @spec fraction_new([Pyex.Interpreter.pyvalue()]) ::
          Pyex.Interpreter.pyvalue() | {:exception, String.t()}
  defp fraction_new([{:fraction, _, _} = f]), do: f
  defp fraction_new([n]) when is_integer(n), do: {:fraction, n, 1}
  defp fraction_new([true]), do: {:fraction, 1, 1}
  defp fraction_new([false]), do: {:fraction, 0, 1}
  defp fraction_new([n, d]) when is_integer(n) and is_integer(d), do: Fraction.new(n, d)

  defp fraction_new([n, d]) when is_boolean(n) or is_boolean(d),
    do: Fraction.new(bool_to_int(n), bool_to_int(d))

  defp fraction_new(_),
    do: {:exception, "TypeError: Fraction() takes integer or Fraction arguments"}

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0
  defp bool_to_int(n), do: n
end
