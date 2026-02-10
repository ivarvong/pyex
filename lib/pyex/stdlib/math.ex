defmodule Pyex.Stdlib.Math do
  @moduledoc """
  Python `math` module backed by Erlang's `:math`.

  Provides common mathematical functions and constants:
  `sin`, `cos`, `tan`, `asin`, `acos`, `atan2`, `sqrt`,
  `pow`, `log`, `log10`, `ceil`, `floor`, `fabs`,
  `radians`, `degrees`, `pi`, and `e`.
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
      "sin" => {:builtin, &do_sin/1},
      "cos" => {:builtin, &do_cos/1},
      "tan" => {:builtin, &do_tan/1},
      "asin" => {:builtin, &do_asin/1},
      "acos" => {:builtin, &do_acos/1},
      "atan2" => {:builtin, &do_atan2/1},
      "sqrt" => {:builtin, &do_sqrt/1},
      "pow" => {:builtin, &do_pow/1},
      "log" => {:builtin, &do_log/1},
      "log10" => {:builtin, &do_log10/1},
      "ceil" => {:builtin, &do_ceil/1},
      "floor" => {:builtin, &do_floor/1},
      "fabs" => {:builtin, &do_fabs/1},
      "radians" => {:builtin, &do_radians/1},
      "degrees" => {:builtin, &do_degrees/1},
      "pi" => :math.pi(),
      "e" => :math.exp(1),
      "inf" => :infinity,
      "nan" => :nan,
      "isinf" => {:builtin, &do_isinf/1},
      "isnan" => {:builtin, &do_isnan/1}
    }
  end

  defp do_sin([x]) when is_number(x), do: :math.sin(x)
  defp do_cos([x]) when is_number(x), do: :math.cos(x)
  defp do_tan([x]) when is_number(x), do: :math.tan(x)
  defp do_asin([x]) when is_number(x), do: :math.asin(x)
  defp do_acos([x]) when is_number(x), do: :math.acos(x)
  defp do_atan2([y, x]) when is_number(y) and is_number(x), do: :math.atan2(y, x)
  defp do_sqrt([x]) when is_number(x), do: :math.sqrt(x)
  defp do_pow([x, y]) when is_number(x) and is_number(y), do: :math.pow(x, y)

  defp do_log([x]) when is_number(x), do: :math.log(x)

  defp do_log([x, base]) when is_number(x) and is_number(base) do
    :math.log(x) / :math.log(base)
  end

  defp do_log10([x]) when is_number(x), do: :math.log10(x)

  defp do_ceil([x]) when is_number(x), do: :erlang.ceil(x)
  defp do_floor([x]) when is_number(x), do: :erlang.floor(x)
  defp do_fabs([x]) when is_number(x), do: abs(x) / 1

  defp do_radians([x]) when is_number(x), do: x * :math.pi() / 180
  defp do_degrees([x]) when is_number(x), do: x * 180 / :math.pi()

  defp do_isinf([:infinity]), do: true
  defp do_isinf([:neg_infinity]), do: true
  defp do_isinf([_x]), do: false

  defp do_isnan([:nan]), do: true
  defp do_isnan([_x]), do: false
end
