defmodule Pyex.Stdlib.EnumModule do
  @moduledoc """
  Python `enum` module.

  Provides `Enum`, `IntEnum`, `auto`, and `unique`.
  """

  @behaviour Pyex.Stdlib.Module

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "Enum" => {:class, "Enum", [], %{"__name__" => "Enum"}},
      "IntEnum" => {:class, "IntEnum", [], %{"__name__" => "IntEnum"}},
      "auto" => {:builtin, &auto/1},
      "unique" => {:builtin, &unique/1}
    }
  end

  @spec auto([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp auto([]) do
    :erlang.unique_integer([:monotonic, :positive])
  end

  defp auto(_), do: {:exception, "TypeError: auto() takes no arguments"}

  @spec unique([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp unique([class]), do: class
  defp unique(_), do: {:exception, "TypeError: unique() takes 1 argument"}
end
