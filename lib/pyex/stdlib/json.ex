defmodule Pyex.Stdlib.Json do
  @moduledoc """
  Python `json` module backed by Jason.

  Provides `json.loads(string)` and `json.dumps(value)`.
  """

  @behaviour Pyex.Stdlib.Module

  @doc """
  Returns the module value -- a map with callable attributes.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "loads" => {:builtin, &do_loads/1},
      "dumps" => {:builtin, &do_dumps/1}
    }
  end

  @spec do_loads([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_loads([string]) when is_binary(string) do
    case Jason.decode(string) do
      {:ok, value} -> value
      {:error, reason} -> {:exception, "json.loads failed: #{inspect(reason)}"}
    end
  end

  @spec do_dumps([Pyex.Interpreter.pyvalue()]) :: String.t()
  defp do_dumps([value]) do
    Jason.encode!(value)
  end
end
