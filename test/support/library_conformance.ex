defmodule Pyex.Test.LibraryConformance do
  @moduledoc """
  Helpers for tests that check a Pyex stdlib shim conforms to its
  pinned reference library.

  Pyex ships in-tree shims for libraries like `pydantic`, `fastapi`,
  `requests`, and `pandas`. The differential-fuzz suite catches
  language-level divergence from CPython, but it cannot catch a shim
  diverging from the real library it imitates. These tests run the
  same snippet through Pyex's shim and against the pinned reference
  version (see `test/python_env/requirements.txt`), asserting
  byte-equal output.

  The reference library is invoked via `uv run --with-requirements`,
  which resolves and caches a virtualenv from the pinned file. The
  whole suite is skipped if `uv` is not on PATH.

  A failure is a real signal: usually the right fix is to make the
  Pyex shim match the reference library, occasionally to document
  intentional divergence. Each failure is a per-case judgment.
  """

  @uv System.find_executable("uv")
  @requirements_path Path.expand("../python_env/requirements.txt", __DIR__)

  @doc "True if `uv` is on PATH at suite-start time."
  @spec uv_available?() :: boolean()
  def uv_available?, do: @uv != nil

  @doc """
  Run `code` through the pinned reference library and through Pyex,
  asserting their outputs match.
  """
  def assert_matches_library(code) do
    import ExUnit.Assertions

    reference = run_reference(code)
    pyex = run_pyex(code)

    assert pyex == reference,
           """
           Pyex shim diverged from pinned reference library:

           Python code:
           #{indent(code)}

           Reference output: #{inspect(reference)}
           Pyex output:      #{inspect(pyex)}
           """
  end

  defp run_reference(code) do
    case System.cmd(
           @uv,
           ["run", "--quiet", "--with-requirements", @requirements_path, "python", "-c", code],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, extract_exception_type(String.trim(output))}
    end
  end

  defp run_pyex(code) do
    case Pyex.run(code, Pyex.Ctx.new(timeout: 5_000)) do
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
end
