defmodule Mix.Tasks.Agent do
  @shortdoc "Run the Pyex LLM agent with a prompt"
  @dialyzer [:no_undefined_callbacks, {:nowarn_function, run: 1}]
  @moduledoc """
  Runs the Pyex agent loop, letting Claude use `run_python`
  to execute code in our interpreter.

      mix agent "Compute the first 10 fibonacci numbers"

  Set ANTHROPIC_API_KEY in your environment or .env file.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    load_dotenv()

    prompt =
      case args do
        [] ->
          "Write a Python program that computes the first 10 Fibonacci numbers and prints them."

        _ ->
          Enum.join(args, " ")
      end

    IO.puts("Prompt: #{prompt}\n")

    case Pyex.Agent.run(prompt) do
      {:ok, final, state} ->
        IO.puts("\n=== Final Response ===")
        IO.puts(final)
        print_filesystem(state)

      {:error, reason} ->
        IO.puts("\n=== Error ===")
        IO.puts(reason)
    end
  end

  defp print_filesystem(%{filesystem: %{files: files}}) when map_size(files) > 0 do
    IO.puts("\n=== Filesystem ===")

    Enum.each(files, fn {path, content} ->
      IO.puts("--- #{path} ---")
      IO.puts(content)
    end)
  end

  defp print_filesystem(_state), do: :ok

  defp load_dotenv do
    path = Path.join(File.cwd!(), ".env")

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.each(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            key = String.trim(key)
            value = String.trim(value)

            unless System.get_env(key) do
              System.put_env(key, value)
            end

          _ ->
            :ok
        end
      end)
    end
  end
end
