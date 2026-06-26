defmodule Pyex.Test.Sweep do
  @moduledoc """
  Reusable product-space conformance harness.

  A *sweep* is the cartesian product of one or more dimensions (e.g. every
  operator × every operand type), baked against CPython ground truth by a
  generator under `test/fixtures/sweeps/` and replayed through pyex here.
  Each cell records the `code` plus either CPython's `result` (the repr of
  the value) or the `error` (exception class name).

  `check!/1` asserts pyex conforms on every cell, in *both* directions:

    * where CPython produced a value, pyex must produce the same repr; and
    * where CPython raised, pyex must also raise — catching the
      over-permissive case (pyex accepting what CPython rejects), which a
      one-directional check would miss.

  This is conformance, not a snapshot of bugs: there is no allowlist of
  accepted divergences. A sweep is green because pyex matches CPython, and
  goes red the moment it doesn't — whether from a regression or a newly
  generated cell. Adding a new domain is just a generator plus a one-line
  test calling `check!`.

  Regenerate a fixture with `python3 test/fixtures/sweeps/<name>_gen.py`.
  """

  import ExUnit.Assertions

  @sweeps_dir Path.join([__DIR__, "..", "fixtures", "sweeps"])

  @doc "Absolute path to a sweep fixture by name (e.g. \"binop\")."
  @spec fixture_path(String.t()) :: String.t()
  def fixture_path(name), do: Path.join(@sweeps_dir, "#{name}.json")

  @doc """
  Loads the baked sweep `name` and asserts pyex conforms to CPython on
  every cell. Fails with a readable, clustered divergence report.
  """
  @spec check!(String.t()) :: :ok
  def check!(name) do
    cells = name |> fixture_path() |> File.read!() |> Jason.decode!() |> Map.fetch!("cells")
    divergences = Enum.flat_map(cells, &cell_divergence/1)

    assert divergences == [],
           "#{length(divergences)}/#{length(cells)} cells diverge from CPython in sweep " <>
             "'#{name}':\n" <> report(divergences)

    :ok
  end

  defp cell_divergence(%{"code" => code, "result" => want}) do
    case pyex_eval(code) do
      {:ok, ^want} -> []
      {:ok, got} -> [{code, "got #{got}", "CPython #{want}"}]
      :error -> [{code, "raised", "CPython #{want}"}]
    end
  end

  defp cell_divergence(%{"code" => code, "error" => exc}) do
    case pyex_eval(code) do
      {:error, ^exc} -> []
      {:error, got} -> [{code, "raised #{got || "(untyped)"}", "CPython raised #{exc}"}]
      {:ok, got} -> [{code, "got #{got}", "CPython raised #{exc}"}]
    end
  end

  # Statement cells: run a whole program and compare its stdout. Lets the
  # harness reach the statement half of Python (assignment, del, unpacking,
  # exceptions, control flow) that expression `code` cells can't.
  defp cell_divergence(%{"program" => prog, "stdout" => want}) do
    case pyex_run(prog) do
      {:ok, ^want} -> []
      {:ok, got} -> [{prog, "printed #{inspect(got)}", "CPython #{inspect(want)}"}]
      :error -> [{prog, "raised", "CPython printed #{inspect(want)}"}]
    end
  end

  defp cell_divergence(%{"program" => prog, "error" => exc}) do
    case pyex_run(prog) do
      {:error, ^exc} -> []
      {:error, got} -> [{prog, "raised #{got || "(untyped)"}", "CPython raised #{exc}"}]
      {:ok, got} -> [{prog, "printed #{inspect(got)}", "CPython raised #{exc}"}]
    end
  end

  # Evaluate `repr(code)` in pyex; {:ok, repr_string} or {:error, exc_type}.
  # `exc_type` is the Python exception class name (or nil when pyex failed
  # without a typed Python exception), so error cells verify the *type*
  # matches CPython, not merely that something was raised.
  defp pyex_eval(code) do
    case Pyex.run("repr(" <> code <> ")") do
      {:ok, repr, _ctx} when is_binary(repr) -> {:ok, repr}
      {:ok, other, _ctx} -> {:ok, inspect(other)}
      {:error, err} -> {:error, exc_type(err)}
    end
  rescue
    _ -> {:error, nil}
  end

  # Run a program in pyex; {:ok, captured_stdout} or {:error, exc_type}.
  defp pyex_run(program) do
    case Pyex.run(program) do
      {:ok, _value, ctx} -> {:ok, Pyex.output(ctx)}
      {:error, err} -> {:error, exc_type(err)}
    end
  rescue
    _ -> {:error, nil}
  end

  defp exc_type(%Pyex.Error{exception_type: type}), do: type
  defp exc_type(_), do: nil

  defp report(divergences) do
    divergences
    |> Enum.sort()
    |> Enum.map_join("\n", fn {code, got, want} -> "  #{code}\n    pyex #{got}; #{want}" end)
  end
end
