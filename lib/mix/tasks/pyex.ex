defmodule Mix.Tasks.Pyex do
  @shortdoc "Run a Python file through the Pyex interpreter"
  @moduledoc """
  Runs a `.py` file through the Pyex interpreter.

      mix pyex program.py
      mix pyex -        # read source from stdin
      echo 'print(1)' | mix pyex -

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

    case read_source(path) do
      {:ok, code} ->
        ctx = Pyex.Ctx.new()

        case Pyex.run(code, ctx) do
          {:ok, nil, ctx} ->
            print_output(ctx)

          {:ok, result, ctx} ->
            print_output(ctx)
            IO.inspect(result)

          {:error, msg} ->
            Mix.shell().error(msg)
        end

      {:error, reason} ->
        Mix.shell().error("Cannot read #{path}: #{:file.format_error(reason)}")
    end

    Pyex.Trace.flush(trace)
  end

  defp print_output(ctx) do
    case Pyex.output(ctx) do
      "" -> :ok
      out -> IO.puts(out)
    end
  end

  defp read_source("-") do
    case IO.read(:stdio, :eof) do
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, reason}
      data when is_binary(data) -> {:ok, data}
    end
  end

  defp read_source(path), do: File.read(path)
end
