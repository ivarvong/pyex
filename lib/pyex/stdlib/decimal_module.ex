defmodule Pyex.Stdlib.DecimalModule do
  @moduledoc """
  Python `decimal` module.

  Provides `Decimal` for arbitrary-precision decimal arithmetic.
  Internally uses Elixir's `Decimal` library and wraps values in
  `{:pyex_decimal, %Decimal{}}` tagged tuples.
  """

  @behaviour Pyex.Stdlib.Module

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "Decimal" => {:builtin, &decimal_new/1}
    }
  end

  @spec decimal_new([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp decimal_new([val]) when is_binary(val) do
    case parse_decimal(val) do
      {:ok, decimal} -> {:pyex_decimal, decimal}
      {:error, msg} -> {:exception, msg}
    end
  end

  defp decimal_new([val]) when is_integer(val) do
    {:pyex_decimal, Decimal.new(val)}
  end

  defp decimal_new([{:pyex_decimal, _} = d]) do
    d
  end

  @spec parse_decimal(String.t()) :: {:ok, Decimal.t()} | {:error, String.t()}
  defp parse_decimal(val) do
    {:ok, Decimal.new(val)}
  rescue
    Decimal.Error -> {:error, "ValueError: invalid literal for Decimal(): '#{val}'"}
  end
end
