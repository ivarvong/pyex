defmodule Mix.Tasks.Todo do
  @shortdoc "A simple TODO app powered by Pyex + Postgres"
  @moduledoc """
  A TODO list stored in Postgres, driven entirely by Python
  running inside the Pyex interpreter.

      mix todo init
      mix todo add Buy groceries
      mix todo list
      mix todo done 1
      mix todo delete 1

  Requires DATABASE_URL in your environment (defaults to
  postgres://ivar@localhost:5432/sr2_dev).
  """

  use Mix.Task

  @app_code File.read!(Path.join(__DIR__, "todo_app.py"))

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {command, arg} =
      case args do
        ["init"] -> {"init", ""}
        ["add" | words] -> {"add", Enum.join(words, " ")}
        ["done", id] -> {"done", id}
        ["delete", id] -> {"delete", id}
        ["list"] -> {"list", ""}
        [] -> {"list", ""}
        _ -> {"help", ""}
      end

    db_url =
      System.get_env("DATABASE_URL", "postgres://ivar@localhost:5432/sr2_dev")

    env = %{
      "DATABASE_URL" => db_url,
      "TODO_CMD" => command,
      "TODO_ARG" => arg
    }

    ctx = Pyex.Ctx.new(env: env)

    case Pyex.run(@app_code, ctx) do
      {:ok, _, _} -> :ok
      {:error, msg} -> Mix.shell().error(msg)
    end

    Process.sleep(50)
    Pyex.Trace.flush()
  end
end
