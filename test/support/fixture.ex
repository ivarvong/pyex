defmodule Pyex.Test.Fixture do
  @moduledoc """
  Support module for fixture-based conformance tests.

  Each fixture lives in `test/fixtures/programs/<name>/` and contains:

    - `main.py`       — the Python script under test (required)
    - `fs/`           — input filesystem files, pre-loaded into memory (optional)
    - `expected.json` — CPython ground truth, recorded by `mix pyex.fixture record`

  The `expected.json` includes a SHA-256 hash of `main.py` so that stale
  recordings are detected automatically at test time.

  ## Usage

      fixture = Pyex.Test.Fixture.load!("csv_stats")
      result  = Pyex.Test.Fixture.run_pyex(fixture)
      Pyex.Test.Fixture.assert_conforms(fixture, result)
  """

  @fixtures_dir "test/fixtures/programs"

  defstruct [
    :name,
    :source,
    :source_hash,
    :input_fs,
    :expected_stdout,
    :expected_files,
    :expected_error,
    :expected_hash
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          source: String.t(),
          source_hash: String.t(),
          input_fs: %{String.t() => String.t()},
          expected_stdout: String.t(),
          expected_files: %{String.t() => String.t()},
          expected_error: String.t() | nil,
          expected_hash: String.t()
        }

  @doc """
  Returns the list of all fixture names (directory names under programs/).
  """
  @spec list_all() :: [String.t()]
  def list_all do
    case File.ls(@fixtures_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          dir = Path.join(@fixtures_dir, entry)
          File.dir?(dir) and File.exists?(Path.join(dir, "main.py"))
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc """
  Loads a fixture by name.  Raises on missing files or JSON parse errors.
  """
  @spec load!(String.t()) :: t()
  def load!(name) do
    dir = Path.join(@fixtures_dir, name)
    main_py = Path.join(dir, "main.py")
    expected_json = Path.join(dir, "expected.json")

    source = File.read!(main_py)
    source_hash = sha256(source)

    expected = File.read!(expected_json) |> Jason.decode!()

    input_fs = load_input_fs(Path.join(dir, "fs"))

    %__MODULE__{
      name: name,
      source: source,
      source_hash: source_hash,
      input_fs: input_fs,
      expected_stdout: expected["stdout"],
      expected_files: expected["files"] || %{},
      expected_error: expected["error"],
      expected_hash: expected["sha256"]
    }
  end

  @doc """
  Runs a fixture through Pyex with an in-memory filesystem seeded from
  the fixture's `fs/` directory.  Returns a result map with `:stdout`,
  `:files`, and `:error` keys matching the `expected.json` shape.
  """
  @spec run_pyex(t()) :: %{
          stdout: String.t(),
          files: %{String.t() => String.t()},
          error: String.t() | nil
        }
  def run_pyex(%__MODULE__{source: source, input_fs: input_fs}) do
    fs = Pyex.Filesystem.Memory.new(input_fs)

    case Pyex.run(source, filesystem: fs) do
      {:ok, _value, ctx} ->
        stdout = Pyex.output(ctx)
        output_files = diff_filesystem(input_fs, ctx.filesystem)
        %{stdout: stdout, files: output_files, error: nil}

      {:error, err} ->
        %{stdout: "", files: %{}, error: err.message}
    end
  end

  @doc """
  Asserts that the Pyex result matches the CPython ground truth.
  Returns `:ok` on success, raises `ExUnit.AssertionError` on mismatch.
  """
  @spec assert_conforms(t(), %{stdout: String.t(), files: map(), error: term()}) :: :ok
  def assert_conforms(fixture, result) do
    import ExUnit.Assertions

    assert fixture.source_hash == fixture.expected_hash,
           stale_message(fixture.name)

    if fixture.expected_error do
      assert result.error != nil,
             "Expected an error from #{fixture.name} but Pyex succeeded.\n" <>
               "CPython error: #{fixture.expected_error}"
    else
      assert result.error == nil,
             "Pyex raised an error on #{fixture.name}:\n#{result.error}"

      assert result.stdout == fixture.expected_stdout,
             stdout_diff(fixture.name, fixture.expected_stdout, result.stdout)

      for {path, expected_content} <- fixture.expected_files do
        actual = Map.get(result.files, path)

        assert actual != nil,
               "Pyex did not write expected file #{inspect(path)} in #{fixture.name}"

        assert actual == expected_content,
               file_diff(fixture.name, path, expected_content, actual)
      end

      pyex_extra = Map.keys(result.files) -- Map.keys(fixture.expected_files)

      assert pyex_extra == [],
             "Pyex wrote unexpected files in #{fixture.name}: #{inspect(pyex_extra)}"
    end

    :ok
  end

  @doc """
  Returns true if the fixture's `expected.json` hash matches the current
  `main.py` source.
  """
  @spec fresh?(t()) :: boolean()
  def fresh?(%__MODULE__{source_hash: current, expected_hash: recorded}) do
    current == recorded
  end

  defp load_input_fs(fs_dir) do
    if File.dir?(fs_dir) do
      fs_dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reject(&File.dir?/1)
      |> Enum.into(%{}, fn abs_path ->
        rel = Path.relative_to(abs_path, fs_dir)
        {rel, File.read!(abs_path)}
      end)
    else
      %{}
    end
  end

  defp diff_filesystem(input_fs, %Pyex.Filesystem.Memory{files: files}) do
    Enum.reduce(files, %{}, fn {path, content}, acc ->
      if Map.get(input_fs, path) != content do
        Map.put(acc, path, content)
      else
        acc
      end
    end)
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp stale_message(name) do
    """
    Fixture #{inspect(name)} has a stale expected.json — the source has
    changed since it was last recorded.

    Run: mix pyex.fixture record #{name}
    """
  end

  defp stdout_diff(name, expected, actual) do
    """
    Stdout mismatch in fixture #{inspect(name)}:

    CPython:
    #{indent(expected)}

    Pyex:
    #{indent(actual)}
    """
  end

  defp file_diff(name, path, expected, actual) do
    """
    File content mismatch in fixture #{inspect(name)} for #{inspect(path)}:

    CPython (#{byte_size(expected)} bytes):
    #{indent(String.slice(expected, 0, 500))}

    Pyex (#{byte_size(actual)} bytes):
    #{indent(String.slice(actual, 0, 500))}
    """
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end
end
