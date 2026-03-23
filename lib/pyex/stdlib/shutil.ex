defmodule Pyex.Stdlib.Shutil do
  @moduledoc """
  Minimal `shutil` support for filesystem-backed sandboxes.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.{Ctx, Env, Interpreter}

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "copyfile" => {:builtin, &copyfile/1},
      "copytree" => {:builtin, &copytree/1},
      "rmtree" => {:builtin, &rmtree/1},
      "move" => {:builtin, &move/1}
    }
  end

  @spec copyfile([Interpreter.pyvalue()]) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})} | {:exception, String.t()}
  defp copyfile([src, dest]) do
    with {:ok, src} <- coerce(src), {:ok, dest} <- coerce(dest) do
      ctx_fs_call(fn fs -> Pyex.Path.copyfile(fs, src, dest) end, dest)
    end
  end

  defp copyfile(_args), do: {:exception, "TypeError: copyfile() expects src and dst"}

  @spec copytree([Interpreter.pyvalue()]) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})} | {:exception, String.t()}
  defp copytree([src, dest]) do
    with {:ok, src} <- coerce(src), {:ok, dest} <- coerce(dest) do
      ctx_fs_call(fn fs -> Pyex.Path.copytree(fs, src, dest) end, dest)
    end
  end

  defp copytree(_args), do: {:exception, "TypeError: copytree() expects src and dst"}

  @spec rmtree([Interpreter.pyvalue()]) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})} | {:exception, String.t()}
  defp rmtree([path]) do
    with {:ok, path} <- coerce(path) do
      ctx_fs_call(fn fs -> Pyex.Path.delete_tree(fs, path) end, nil)
    end
  end

  defp rmtree(_args), do: {:exception, "TypeError: rmtree() expects a path"}

  @spec move([Interpreter.pyvalue()]) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})} | {:exception, String.t()}
  defp move([src, dest]) do
    with {:ok, src} <- coerce(src), {:ok, dest} <- coerce(dest) do
      ctx_fs_call(fn fs -> Pyex.Path.move(fs, src, dest) end, dest)
    end
  end

  defp move(_args), do: {:exception, "TypeError: move() expects src and dst"}

  @spec coerce(Interpreter.pyvalue()) :: {:ok, String.t()} | {:exception, String.t()}
  defp coerce(value) do
    case Pyex.Path.coerce(value) do
      {:ok, path} -> {:ok, path}
      :error -> {:exception, "TypeError: expected str or PathLike object"}
    end
  end

  @spec ctx_fs_call((term() -> {:ok, term()} | {:error, String.t()}), String.t() | nil) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})}
  defp ctx_fs_call(fun, return_path) do
    {:ctx_call,
     fn env, ctx ->
       case ctx.filesystem do
         nil ->
           {{:exception, "OSError: no filesystem configured"}, env, ctx}

         fs ->
           case fun.(fs) do
             {:ok, fs} -> {return_path, env, %{ctx | filesystem: fs}}
             {:error, msg} -> {{:exception, msg}, env, ctx}
           end
       end
     end}
  end
end
