defmodule Pyex.Stdlib.Glob do
  @moduledoc """
  Minimal `glob` module support for filesystem-backed sandboxes.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.{Ctx, Env, Interpreter}

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "glob" => {:builtin, &glob/1}
    }
  end

  @spec glob([Interpreter.pyvalue()]) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})}
          | {:exception, String.t()}
  defp glob([pattern]) do
    case Pyex.Path.coerce(pattern) do
      {:ok, pattern} ->
        {:ctx_call,
         fn env, ctx ->
           case ctx.filesystem do
             nil ->
               {{:exception, "OSError: no filesystem configured"}, env, ctx}

             fs ->
               {:ok, matches} = Pyex.Path.glob(fs, pattern)
               {matches, env, ctx}
           end
         end}

      :error ->
        {:exception, "TypeError: glob() pathname must be str or PathLike"}
    end
  end

  defp glob(_args) do
    {:exception, "TypeError: glob() takes exactly 1 argument"}
  end
end
