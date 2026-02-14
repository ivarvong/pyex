defmodule Mix.Tasks.Pyex do
  @shortdoc "Run a Python file through the Pyex interpreter"
  @moduledoc """
  Runs a `.py` file through the Pyex interpreter.

      mix pyex program.py

  Environment variables from the system are passed through
  to the script via `os.environ` and `sql` module access.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [path | _] ->
        run_file(path)

      [] ->
        Mix.shell().error("Usage: mix pyex <file.py>")
    end
  end

  defp run_file(path) do
    trace = Pyex.Trace.attach()

    case File.read(path) do
      {:ok, code} ->
        env =
          System.get_env()
          |> Map.new(fn {k, v} -> {k, v} end)

        ctx = Pyex.Ctx.new(env: env)

        case Pyex.run(code, ctx) do
          {:ok, nil, _ctx} ->
            :ok

          {:ok, result, _ctx} ->
            IO.inspect(result)

          {:error, msg} ->
            Mix.shell().error(msg)
        end

      {:error, reason} ->
        Mix.shell().error("Cannot read #{path}: #{:file.format_error(reason)}")
    end

    Pyex.Trace.flush(trace)
  end
end
