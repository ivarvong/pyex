defmodule Pyex.Test.Oracle do
  @moduledoc """
  Runs Python code through both CPython (`python3`) and Pyex, returning
  a diff-friendly comparison result.

  This is the "living" counterpart to `Pyex.Test.Fixture`: instead of
  asserting against a recorded expected.json, it asks the real CPython
  interpreter at test time.  Slower per call, but impossible to drift.

  ## Usage

      import Pyex.Test.Oracle

      test "datetime repr conforms" do
        check!("from datetime import datetime; print(repr(datetime(2026, 1, 15)))")
      end

  ## When to use this vs. fixtures

  - **Oracle**: small, self-contained expressions.  One-liner `print(...)`
    style.  Use for exhaustive combinatorial coverage.
  - **Fixtures**: larger programs, filesystem interactions, multi-statement
    scenarios.  Recorded ground truth is the right tradeoff there.

  ## Skipping when Python isn't available

  Tests using this module are tagged `:requires_python3` at the suite
  level.  If `python3` isn't on the PATH (rare, but possible in minimal
  CI images), exclude the tag:

      mix test --exclude requires_python3
  """

  @python_binary "python3"
  @python_timeout 10_000

  @type result :: %{
          cpython_stdout: String.t(),
          cpython_stderr: String.t(),
          cpython_exit: non_neg_integer(),
          pyex_stdout: String.t(),
          pyex_error: String.t() | nil
        }

  @doc """
  Returns true if CPython 3 is available on the PATH.  Used by
  conformance tests to gate themselves.
  """
  @spec python3_available?() :: boolean()
  def python3_available? do
    case System.find_executable(@python_binary) do
      nil -> false
      _path -> true
    end
  end

  @doc """
  Runs the given Python source through both CPython and Pyex, returning
  a result map with stdout from each.  Does NOT raise on mismatch.
  """
  @spec run(String.t()) :: result()
  def run(source) do
    {py_stdout, py_stderr, py_exit} = run_cpython(source)
    {pyex_stdout, pyex_error} = run_pyex(source)

    %{
      cpython_stdout: py_stdout,
      cpython_stderr: py_stderr,
      cpython_exit: py_exit,
      pyex_stdout: pyex_stdout,
      pyex_error: pyex_error
    }
  end

  @doc """
  Runs the source through both, asserts CPython succeeded, and asserts
  Pyex stdout matches byte-for-byte.  Raises `ExUnit.AssertionError`
  with a rich diff on mismatch.

  If CPython itself fails (exit code != 0), the test is skipped with
  an error — treat that as a bug in the test case, not in Pyex.
  """
  @spec check!(String.t()) :: :ok
  def check!(source) do
    import ExUnit.Assertions

    r = run(source)

    assert r.cpython_exit == 0,
           """
           CPython rejected the conformance snippet (exit #{r.cpython_exit}).
           This means the test itself is invalid, not that Pyex is wrong.

           stderr:
           #{indent(r.cpython_stderr)}

           source:
           #{indent(source)}
           """

    assert r.pyex_error == nil,
           """
           Pyex raised an error on a snippet CPython accepted.

           source:
           #{indent(source)}

           CPython stdout:
           #{indent(r.cpython_stdout)}

           Pyex error:
           #{indent(r.pyex_error)}
           """

    assert r.pyex_stdout == r.cpython_stdout,
           """
           Conformance mismatch.

           source:
           #{indent(source)}

           CPython:
           #{indent(r.cpython_stdout)}

           Pyex:
           #{indent(r.pyex_stdout)}
           """

    :ok
  end

  @doc """
  Convenience: wrap an expression in `print(repr(...))` and check it
  conforms.  Use for expression-at-a-time conformance matrices.

      check_expr!(\"\"\"
      from datetime import datetime, timezone
      datetime(2026, 1, 15, 10, 0, 0, tzinfo=timezone.utc)
      \"\"\")

  The last statement of `source` must be an expression.
  """
  @spec check_expr!(String.t()) :: :ok
  def check_expr!(source) do
    {setup, expr} = split_last_expr(source)

    wrapped = """
    #{setup}
    print(repr(#{expr}))
    """

    check!(wrapped)
  end

  @spec run_cpython(String.t()) ::
          {stdout :: String.t(), stderr :: String.t(), exit :: non_neg_integer()}
  defp run_cpython(source) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable(@python_binary)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, ["-c", source]}
        ]
      )

    collect_port(port, "", @python_timeout)
  end

  defp collect_port(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_port(port, acc <> data, timeout)

      {^port, {:exit_status, status}} ->
        # stderr was merged into stdout via :stderr_to_stdout; on success
        # we treat the whole thing as stdout.  On failure, the merged
        # stream contains the traceback.
        if status == 0 do
          {acc, "", 0}
        else
          {"", acc, status}
        end
    after
      timeout ->
        Port.close(port)
        {"", "timeout after #{timeout}ms", 124}
    end
  end

  @spec run_pyex(String.t()) :: {stdout :: String.t(), error :: String.t() | nil}
  defp run_pyex(source) do
    case Pyex.run(source) do
      {:ok, _value, ctx} -> {Pyex.output(ctx), nil}
      {:error, err} -> {"", err.message}
    end
  end

  @spec split_last_expr(String.t()) :: {String.t(), String.t()}
  defp split_last_expr(source) do
    lines = source |> String.trim_trailing() |> String.split("\n")
    {setup_lines, [last]} = Enum.split(lines, length(lines) - 1)
    {Enum.join(setup_lines, "\n"), String.trim(last)}
  end

  defp indent(nil), do: "    (nil)"

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end
end
