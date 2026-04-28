defmodule Pyex.Test.DifferentialFuzz do
  @moduledoc """
  Helpers for the differential-fuzz property suites.

  Each property generates a Python snippet, runs it through both
  CPython (`python3`) and Pyex, and asserts the outputs match. Sharing
  the runner + generators here lets the suite be split into multiple
  test modules so ExUnit can run them in parallel — the file used to
  be a single `defmodule` and was the dominant chunk of suite wall time.
  """

  use ExUnitProperties

  @python3 System.find_executable("python3")

  @doc "True if `python3` is on PATH at suite-start time."
  @spec python3_available?() :: boolean()
  def python3_available?, do: @python3 != nil

  @doc """
  Run `code` through CPython and Pyex, asserting their outputs match.
  Imports `ExUnit.Assertions` lazily so this module doesn't depend on
  ExUnit being started.
  """
  def assert_differential(code) do
    import ExUnit.Assertions

    cpython_output = run_cpython(code)
    pyex_output = run_pyex(code)

    assert pyex_output == cpython_output,
           """
           Differential fuzz mismatch:

           Python code:
           #{indent(code)}

           CPython output: #{inspect(cpython_output)}
           Pyex output:    #{inspect(pyex_output)}
           """
  end

  defp run_cpython(code) do
    case System.cmd(@python3, ["-c", code], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, extract_exception_type(String.trim(output))}
    end
  end

  defp run_pyex(code) do
    case Pyex.run(code, Pyex.Ctx.new(timeout: 2_000)) do
      {:ok, _, ctx} -> {:ok, ctx |> Pyex.output() |> IO.iodata_to_binary() |> String.trim()}
      {:error, err} -> {:error, err.exception_type || err.kind}
    end
  end

  defp extract_exception_type(stderr) do
    case Regex.run(~r/(\w+Error|\w+Exception|StopIteration|KeyboardInterrupt)\b/, stderr) do
      [_, type] -> type
      _ -> :unknown
    end
  end

  defp indent(code) do
    code
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end

  # ── Generators ──────────────────────────────────────────────

  def small_int, do: integer(-50..50)
  def arith_op, do: member_of(["+", "-", "*"])
  def comparison_op, do: member_of(["==", "!=", "<", ">", "<=", ">="])

  def safe_string do
    gen all(s <- string(:alphanumeric, min_length: 0, max_length: 12)) do
      s
    end
  end
end
