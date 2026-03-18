defmodule Mix.Tasks.Pyex.Fixture do
  @shortdoc "Record or check CPython ground truth for fixture tests"
  @moduledoc """
  Manages fixture-based conformance tests that compare Pyex output against
  real CPython.

  ## Recording ground truth

      mix pyex.fixture record                    # all fixtures
      mix pyex.fixture record elixir_highlight   # single fixture by name

  Runs each fixture's `main.py` through CPython via `test/fixtures/runner.py`,
  captures stdout and filesystem writes, and stores the result as
  `expected.json` inside the fixture directory.  The JSON includes a SHA-256
  hash of `main.py` so stale recordings are detected automatically.

  ## Checking for staleness

      mix pyex.fixture check

  Verifies every fixture's `expected.json` hash matches its current `main.py`.
  Exits non-zero if any are stale or missing.

  ## Fixture directory layout

      test/fixtures/programs/<name>/
        main.py          # the Python script (required)
        fs/              # input filesystem files (optional)
          data.csv
          ...
        expected.json    # recorded ground truth (generated)
  """

  use Mix.Task

  @fixtures_dir "test/fixtures/programs"
  @runner_script "test/fixtures/runner.py"

  @impl Mix.Task
  def run(["record" | names]) do
    python3 = find_python3!()
    dirs = fixture_dirs(names)

    if dirs == [] do
      Mix.shell().error("No fixtures found.")
      exit({:shutdown, 1})
    end

    for dir <- dirs do
      name = Path.basename(dir)
      Mix.shell().info("Recording #{name} ...")

      case record_fixture(python3, dir) do
        :ok ->
          Mix.shell().info("  -> expected.json written")

        {:error, reason} ->
          Mix.shell().error("  FAILED: #{reason}")
          exit({:shutdown, 1})
      end
    end

    Mix.shell().info("Done. #{length(dirs)} fixture(s) recorded.")
  end

  def run(["check"]) do
    dirs = fixture_dirs([])

    if dirs == [] do
      Mix.shell().error("No fixtures found.")
      exit({:shutdown, 1})
    end

    {ok, stale, missing} =
      Enum.reduce(dirs, {0, [], []}, fn dir, {ok, stale, missing} ->
        name = Path.basename(dir)
        expected_path = Path.join(dir, "expected.json")

        if File.exists?(expected_path) do
          source = File.read!(Path.join(dir, "main.py"))
          hash = sha256(source)
          json = File.read!(expected_path) |> Jason.decode!()

          if json["sha256"] == hash do
            {ok + 1, stale, missing}
          else
            {ok, [name | stale], missing}
          end
        else
          {ok, stale, [name | missing]}
        end
      end)

    Mix.shell().info("#{ok} OK")

    if missing != [] do
      Mix.shell().error("Missing expected.json: #{Enum.join(missing, ", ")}")
    end

    if stale != [] do
      Mix.shell().error("Stale (source changed): #{Enum.join(stale, ", ")}")
    end

    if missing != [] or stale != [] do
      Mix.shell().error("\nRun `mix pyex.fixture record` to update.")
      exit({:shutdown, 1})
    end
  end

  def run(_) do
    Mix.shell().info("""
    Usage:
      mix pyex.fixture record [name ...]   Record CPython ground truth
      mix pyex.fixture check               Check for stale recordings
    """)
  end

  defp fixture_dirs([]) do
    case File.ls(@fixtures_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(@fixtures_dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.filter(&File.exists?(Path.join(&1, "main.py")))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp fixture_dirs(names) do
    Enum.flat_map(names, fn name ->
      dir = Path.join(@fixtures_dir, name)

      if File.exists?(Path.join(dir, "main.py")) do
        [dir]
      else
        Mix.shell().error("Fixture not found: #{name}")
        []
      end
    end)
  end

  defp record_fixture(python3, dir) do
    source = File.read!(Path.join(dir, "main.py"))

    case System.cmd(python3, [@runner_script, dir], stderr_to_stdout: false) do
      {json_output, 0} ->
        case Jason.decode(json_output) do
          {:ok, result} ->
            expected = %{
              "sha256" => sha256(source),
              "python_version" => python_version(python3),
              "source_file" => "main.py",
              "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "stdout" => result["stdout"],
              "files" => result["files"],
              "error" => result["error"]
            }

            json = Jason.encode!(expected, pretty: true)
            File.write!(Path.join(dir, "expected.json"), json <> "\n")
            :ok

          {:error, reason} ->
            {:error, "Failed to parse runner output: #{inspect(reason)}"}
        end

      {output, code} ->
        {:error, "python3 exited with code #{code}: #{output}"}
    end
  end

  defp find_python3! do
    case System.find_executable("python3") do
      nil ->
        Mix.shell().error("python3 not found on PATH")
        exit({:shutdown, 1})

      path ->
        path
    end
  end

  defp python_version(python3) do
    {output, 0} = System.cmd(python3, ["--version"])
    output |> String.trim() |> String.replace("Python ", "")
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
