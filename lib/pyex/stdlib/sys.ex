defmodule Pyex.Stdlib.Sys do
  @moduledoc """
  Minimal Python `sys` module stub.

  Provides `sys.stdin`, `sys.stdout`, `sys.stderr`, `sys.argv`, `sys.version`,
  `sys.exit()`, and `sys.maxsize` so that `import sys` does not fail
  in the sandbox.
  """

  @behaviour Pyex.Stdlib.Module

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "argv" => {:py_list, [], 0},
      "version" => "3.11.0 (Pyex sandbox) [Python compatible]",
      "maxsize" => 9_223_372_036_854_775_807,
      "stdin" => {:stringio, make_ref()},
      "stdout" => {:stringio, make_ref()},
      "stderr" => {:stringio, make_ref()},
      "exit" => {:builtin, &do_exit/1}
    }
  end

  @spec do_exit([Pyex.Interpreter.pyvalue()]) :: {:exception, String.t()}
  defp do_exit([]), do: {:exception, "SystemExit: 0"}
  defp do_exit([code]) when is_integer(code), do: {:exception, "SystemExit: #{code}"}
  defp do_exit([msg]) when is_binary(msg), do: {:exception, "SystemExit: #{msg}"}
  defp do_exit(_), do: {:exception, "SystemExit"}
end
