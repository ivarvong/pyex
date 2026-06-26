defmodule Pyex.Stdlib.Traceback do
  @moduledoc """
  Python `traceback` module — a pragmatic shim.

  LLM-generated `except` handlers reach for `traceback.format_exc()` /
  `print_exc()` reflexively. The sandbox does not retain per-frame Python
  stacks, so the frame lines can't be reproduced exactly, but the part code
  actually inspects — the final `ExcType: message` line — is faithful. The API
  is importable and callable so a missing import never costs a round.
  """

  @behaviour Pyex.Stdlib.Module

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "__name__" => "traceback",
      "format_exc" => {:builtin, &format_exc/1},
      "print_exc" => {:builtin, &print_exc/1},
      "format_exception" => {:builtin, &format_exception/1},
      "format_exception_only" => {:builtin, &format_exception_only/1},
      "print_exception" => {:builtin, fn _ -> nil end},
      "format_tb" => {:builtin, fn _ -> [] end},
      "print_tb" => {:builtin, fn _ -> nil end},
      "format_stack" => {:builtin, fn _ -> [] end},
      "print_stack" => {:builtin, fn _ -> nil end}
    }
  end

  # traceback.format_exc() — the current exception as a single string.
  @spec format_exc([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp format_exc(_args) do
    {:ctx_call, fn env, ctx -> {format_traceback(current_exception(env)), env, ctx} end}
  end

  # traceback.print_exc() — CPython writes to stderr; the sandbox surfaces only
  # stdout, so this is a no-op (matching CPython's empty stdout).
  @spec print_exc([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp print_exc(_args), do: nil

  # traceback.format_exception(...) — CPython returns a list of strings.
  # traceback.format_exception(exc) (3.10+) or (etype, value, tb) (legacy):
  # the message comes from the exception *value*, never the type.
  @spec format_exception([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp format_exception([_etype, value | _]) do
    ["Traceback (most recent call last):\n", exception_line(value) <> "\n"]
  end

  defp format_exception([exc]) do
    ["Traceback (most recent call last):\n", exception_line(exc) <> "\n"]
  end

  defp format_exception(_) do
    {:ctx_call,
     fn env, ctx ->
       {["Traceback (most recent call last):\n", line_for(current_exception(env)) <> "\n"], env,
        ctx}
     end}
  end

  # traceback.format_exception_only(exc) (3.10+) or (etype, value) (legacy):
  # again the line is rendered from the value, not the type.
  @spec format_exception_only([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp format_exception_only([_etype, value | _]), do: [exception_line(value) <> "\n"]
  defp format_exception_only([exc]), do: [exception_line(exc) <> "\n"]
  defp format_exception_only(_), do: ["NoneType: None\n"]

  @spec current_exception(Pyex.Env.t()) :: String.t() | nil
  defp current_exception(env) do
    case Pyex.Env.get(env, "__current_exception__") do
      {:ok, msg} when is_binary(msg) -> msg
      _ -> nil
    end
  end

  @spec format_traceback(String.t() | nil) :: String.t()
  defp format_traceback(nil), do: "NoneType: None\n"

  defp format_traceback(msg) do
    "Traceback (most recent call last):\n" <> line_for(msg) <> "\n"
  end

  @spec line_for(String.t() | nil) :: String.t()
  defp line_for(nil), do: "NoneType: None"
  defp line_for(msg), do: msg

  # The `ExcType: message` line for an exception value (instance or class).
  @spec exception_line(Pyex.Interpreter.pyvalue()) :: String.t()
  defp exception_line({:instance, {:class, name, _, _}, attrs}) do
    case Map.get(attrs, "args") do
      {:tuple, [arg]} when is_binary(arg) -> "#{name}: #{arg}"
      {:tuple, [arg]} -> "#{name}: #{Pyex.Interpreter.Helpers.py_str(arg)}"
      _ -> name
    end
  end

  defp exception_line({:exception_class, name}), do: name
  defp exception_line(other), do: Pyex.Interpreter.Helpers.py_str(other)
end
