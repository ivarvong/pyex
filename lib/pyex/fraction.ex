defmodule Pyex.Fraction do
  @moduledoc """
  Exact rational arithmetic backing Python's `fractions.Fraction`.

  A fraction is the tagged tuple `{:fraction, numerator, denominator}` kept
  in canonical form: the denominator is always positive and the pair is
  reduced to lowest terms (`gcd(|num|, den) == 1`). Pure value math with no
  interpreter dependencies, so the binary-op dispatch, repr/str helpers, the
  `float()`/`int()` builtins, and the `fractions` stdlib module can all share
  it.
  """

  @type t :: {:fraction, integer(), pos_integer()}

  @doc """
  Builds a reduced fraction from a numerator and denominator.

  Returns a `ZeroDivisionError` exception tuple when the denominator is zero,
  matching CPython's `Fraction(n, 0)`.
  """
  @spec new(integer(), integer()) :: t() | {:exception, String.t()}
  def new(n, 0), do: {:exception, "ZeroDivisionError: Fraction(#{n}, 0)"}

  def new(n, d) do
    sign = if d < 0, do: -1, else: 1
    n = n * sign
    d = abs(d)
    g = max(Integer.gcd(abs(n), d), 1)
    {:fraction, div(n, g), div(d, g)}
  end

  @doc "Numerator/denominator pair for a fraction, int, or bool operand."
  @spec parts(term()) :: {integer(), pos_integer()} | :error
  def parts({:fraction, n, d}), do: {n, d}
  def parts(n) when is_integer(n), do: {n, 1}
  def parts(true), do: {1, 1}
  def parts(false), do: {0, 1}
  def parts(_), do: :error

  @spec fraction?(term()) :: boolean()
  def fraction?({:fraction, _, _}), do: true
  def fraction?(_), do: false

  @spec to_float(t()) :: float()
  def to_float({:fraction, n, d}), do: n / d

  @doc "Truncates toward zero, like CPython's `int(Fraction(...))`."
  @spec to_integer(t()) :: integer()
  def to_integer({:fraction, n, d}), do: div(n, d)

  @spec to_str(t()) :: String.t()
  def to_str({:fraction, n, 1}), do: Integer.to_string(n)
  def to_str({:fraction, n, d}), do: "#{n}/#{d}"

  @spec to_repr(t()) :: String.t()
  def to_repr({:fraction, n, d}), do: "Fraction(#{n}, #{d})"
end
