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

  @external_resource "lib/mix/tasks/spreadsheet.py"
  @spreadsheet File.read!("lib/mix/tasks/spreadsheet.py")

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
        ctx =
          Pyex.Ctx.new(filesystem: Pyex.FS.from_map(%{"spreadsheet.py" => @spreadsheet}))

        case Pyex.run(code, ctx) do
          {:ok, nil, ctx} ->
            print_output(ctx)
            sync_out(ctx)

          {:ok, result, ctx} ->
            print_output(ctx)
            sync_out(ctx)
            IO.inspect(result)

          {:error, msg} ->
            Mix.shell().error(msg.message)
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

  defp sync_out(%{filesystem: %VFS.Memory{tree: tree}}) do
    case tree |> Map.delete("/spreadsheet.py") |> Map.to_list() do
      [{vpath, data}] ->
        name = String.replace_prefix(vpath, "/", "")
        File.write!(name, data, [:binary])
        IO.puts("wrote #{name}")

      _ ->
        :ok
    end
  end

  defp sync_out(_ctx), do: :ok

  defp read_source("-") do
    case IO.read(:stdio, :eof) do
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, reason}
      data when is_binary(data) -> {:ok, data}
    end
  end

  defp read_source(path), do: File.read(path)
end
