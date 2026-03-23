defmodule Pyex.Stdlib.Pathlib do
  @moduledoc """
  Minimal `pathlib` support for sandboxed filesystem workflows.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.{Ctx, Env, Interpreter}

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "Path" => path_class()
    }
  end

  @spec path_class() ::
          {:class, String.t(), [Interpreter.pyvalue()],
           %{optional(String.t()) => Interpreter.pyvalue()}}
  defp path_class do
    {:class, "Path", [],
     %{
       "__init__" => {:builtin_kw, &path_init/2},
       "__str__" => {:builtin, fn [self] -> path_string(self) end},
       "__repr__" => {:builtin, fn [self] -> "Path(#{inspect(path_string(self))})" end},
       "__fspath__" => {:builtin, fn [self] -> path_string(self) end},
       "__truediv__" => {:builtin, fn [self, other] -> path_div(self, other) end},
       "exists" => {:builtin_kw, &path_exists/2},
       "is_file" => {:builtin_kw, &path_is_file/2},
       "is_dir" => {:builtin_kw, &path_is_dir/2},
       "mkdir" => {:builtin_kw, &path_mkdir/2},
       "iterdir" => {:builtin_kw, &path_iterdir/2},
       "unlink" => {:builtin_kw, &path_unlink/2},
       "with_suffix" => {:builtin_kw, &path_with_suffix/2},
       "with_name" => {:builtin_kw, &path_with_name/2},
       "read_text" => {:builtin_kw, &path_read_text/2},
       "write_text" => {:builtin_kw, &path_write_text/2},
       "glob" => {:builtin_kw, &path_glob/2}
     }}
  end

  @spec path_init([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          Interpreter.pyvalue()
  defp path_init([instance | parts], kwargs) do
    cond do
      kwargs != %{} ->
        {:exception, "TypeError: Path() does not accept keyword arguments"}

      true ->
        case coerce_parts(parts) do
          {:ok, []} -> path_instance(instance, ".")
          {:ok, coerced} -> path_instance(instance, Pyex.Path.join(coerced))
          {:error, msg} -> {:exception, msg}
        end
    end
  end

  @spec path_div(Interpreter.pyvalue(), Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp path_div(self, other) do
    with {:ok, left} <- Pyex.Path.coerce(self),
         {:ok, right} <- Pyex.Path.coerce(other) do
      path_instance(self, Pyex.Path.join([left, right]))
    else
      :error -> {:exception, "TypeError: unsupported operand type(s) for /"}
    end
  end

  @spec path_read_text([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})} | {:exception, String.t()}
  defp path_read_text([self], kwargs) do
    with :ok <- no_kwargs("read_text", kwargs),
         {:ok, path} <- coerce_path(self) do
      {:ctx_call,
       fn env, ctx ->
         case ctx.filesystem do
           nil ->
             {{:exception, "OSError: no filesystem configured"}, env, ctx}

           _ ->
             case Ctx.open_handle(ctx, path, :read) do
               {:ok, id, ctx} ->
                 case Ctx.read_handle(ctx, id) do
                   {:ok, content, ctx} ->
                     case Ctx.close_handle(ctx, id) do
                       {:ok, ctx} -> {content, env, ctx}
                       {:error, _} -> {content, env, ctx}
                     end

                   {:error, msg} ->
                     {{:exception, msg}, env, ctx}
                 end

               {:error, msg} ->
                 {{:exception, msg}, env, ctx}
             end
         end
       end}
    end
  end

  defp path_read_text(_args, _kwargs) do
    {:exception, "TypeError: Path.read_text() takes no positional arguments"}
  end

  @spec path_write_text([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})} | {:exception, String.t()}
  defp path_write_text([self, data], kwargs) when is_binary(data) do
    with :ok <- no_kwargs("write_text", kwargs),
         {:ok, path} <- coerce_path(self) do
      {:ctx_call,
       fn env, ctx ->
         case ctx.filesystem do
           nil ->
             {{:exception, "OSError: no filesystem configured"}, env, ctx}

           _ ->
             case Ctx.open_handle(ctx, path, :write) do
               {:ok, id, ctx} ->
                 case Ctx.write_handle(ctx, id, data) do
                   {:ok, ctx} ->
                     case Ctx.close_handle(ctx, id) do
                       {:ok, ctx} -> {byte_size(data), env, ctx}
                       {:error, _} -> {byte_size(data), env, ctx}
                     end

                   {:error, msg} ->
                     {{:exception, msg}, env, ctx}
                 end

               {:error, msg} ->
                 {{:exception, msg}, env, ctx}
             end
         end
       end}
    end
  end

  defp path_write_text([_self, _data], _kwargs) do
    {:exception, "TypeError: Path.write_text() argument must be str"}
  end

  defp path_write_text(_args, _kwargs) do
    {:exception, "TypeError: Path.write_text() takes exactly 1 positional argument"}
  end

  @spec path_glob([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})} | {:exception, String.t()}
  defp path_glob([self, pattern], kwargs) when is_binary(pattern) do
    with :ok <- no_kwargs("glob", kwargs),
         {:ok, base} <- coerce_path(self) do
      {:ctx_call,
       fn env, ctx ->
         case ctx.filesystem do
           nil ->
             {{:exception, "OSError: no filesystem configured"}, env, ctx}

           fs ->
             pattern = Pyex.Path.join([base, pattern])
             {:ok, matches} = Pyex.Path.glob(fs, pattern)
             {Enum.map(matches, &path_instance(self, &1)), env, ctx}
         end
       end}
    end
  end

  defp path_glob([_self, _pattern], _kwargs) do
    {:exception, "TypeError: Path.glob() pattern must be str"}
  end

  defp path_glob(_args, _kwargs) do
    {:exception, "TypeError: Path.glob() takes exactly 1 argument"}
  end

  @spec path_exists([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})} | {:exception, String.t()}
  defp path_exists([self], kwargs) do
    with :ok <- no_kwargs("exists", kwargs),
         {:ok, path} <- coerce_path(self) do
      {:ctx_call,
       fn env, ctx ->
         case ctx.filesystem do
           nil -> {false, env, ctx}
           fs -> {Pyex.Path.exists?(fs, path), env, ctx}
         end
       end}
    end
  end

  @spec path_is_file([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})} | {:exception, String.t()}
  defp path_is_file([self], kwargs) do
    with :ok <- no_kwargs("is_file", kwargs),
         {:ok, path} <- coerce_path(self) do
      {:ctx_call,
       fn env, ctx ->
         case ctx.filesystem do
           nil -> {false, env, ctx}
           fs -> {Pyex.Path.file?(fs, path), env, ctx}
         end
       end}
    end
  end

  @spec path_is_dir([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})} | {:exception, String.t()}
  defp path_is_dir([self], kwargs) do
    with :ok <- no_kwargs("is_dir", kwargs),
         {:ok, path} <- coerce_path(self) do
      {:ctx_call,
       fn env, ctx ->
         case ctx.filesystem do
           nil -> {false, env, ctx}
           fs -> {Pyex.Path.dir?(fs, path), env, ctx}
         end
       end}
    end
  end

  @spec path_mkdir([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})} | {:exception, String.t()}
  defp path_mkdir([self], kwargs) do
    with {:ok, path} <- coerce_path(self),
         :ok <- validate_mkdir_kwargs(kwargs) do
      {:ctx_call,
       fn env, ctx ->
         case ctx.filesystem do
           nil ->
             {{:exception, "OSError: no filesystem configured"}, env, ctx}

           fs ->
             {:ok, fs} = Pyex.Path.mkdir_p(fs, path)
             {nil, env, %{ctx | filesystem: fs}}
         end
       end}
    end
  end

  defp path_mkdir(_args, _kwargs) do
    {:exception, "TypeError: Path.mkdir() takes no positional arguments"}
  end

  @spec path_iterdir([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})} | {:exception, String.t()}
  defp path_iterdir([self], kwargs) do
    with :ok <- no_kwargs("iterdir", kwargs),
         {:ok, path} <- coerce_path(self) do
      {:ctx_call,
       fn env, ctx ->
         case ctx.filesystem do
           nil ->
             {{:exception, "OSError: no filesystem configured"}, env, ctx}

           fs ->
             case Pyex.Path.list_dir(fs, path) do
               {:ok, entries} ->
                 children = Enum.map(entries, &path_instance(self, Pyex.Path.join([path, &1])))
                 {token, ctx} = Ctx.new_iterator(ctx, children)
                 {token, env, ctx}

               {:error, msg} ->
                 {{:exception, msg}, env, ctx}
             end
         end
       end}
    end
  end

  @spec path_unlink([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          {:ctx_call, (Env.t(), Ctx.t() -> {term(), Env.t(), Ctx.t()})} | {:exception, String.t()}
  defp path_unlink([self], kwargs) do
    with :ok <- no_kwargs("unlink", kwargs),
         {:ok, path} <- coerce_path(self) do
      {:ctx_call,
       fn env, ctx ->
         case ctx.filesystem do
           nil ->
             {{:exception, "OSError: no filesystem configured"}, env, ctx}

           fs ->
             case Pyex.Path.unlink(fs, path) do
               {:ok, fs} -> {nil, env, %{ctx | filesystem: fs}}
               {:error, msg} -> {{:exception, msg}, env, ctx}
             end
         end
       end}
    end
  end

  @spec path_with_suffix([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          Interpreter.pyvalue()
  defp path_with_suffix([self, suffix], kwargs) when is_binary(suffix) do
    with :ok <- no_kwargs("with_suffix", kwargs),
         {:ok, path} <- coerce_path(self) do
      {root, _old} = Pyex.Path.splitext(path)
      path_instance(self, root <> suffix)
    end
  end

  defp path_with_suffix([_self, _suffix], _kwargs),
    do: {:exception, "TypeError: suffix must be str"}

  defp path_with_suffix(_args, _kwargs),
    do: {:exception, "TypeError: Path.with_suffix() takes exactly 1 argument"}

  @spec path_with_name([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          Interpreter.pyvalue()
  defp path_with_name([self, name], kwargs) when is_binary(name) do
    with :ok <- no_kwargs("with_name", kwargs),
         {:ok, path} <- coerce_path(self) do
      path_instance(self, Pyex.Path.join([Pyex.Path.dirname(path), name]))
    end
  end

  defp path_with_name([_self, _name], _kwargs), do: {:exception, "TypeError: name must be str"}

  defp path_with_name(_args, _kwargs),
    do: {:exception, "TypeError: Path.with_name() takes exactly 1 argument"}

  @spec no_kwargs(String.t(), %{optional(String.t()) => Interpreter.pyvalue()}) ::
          :ok | {:exception, String.t()}
  defp no_kwargs(name, kwargs) do
    case Map.keys(kwargs) do
      [] ->
        :ok

      [key | _] ->
        {:exception, "TypeError: Path.#{name}() got an unexpected keyword argument '#{key}'"}
    end
  end

  @spec validate_mkdir_kwargs(%{optional(String.t()) => Interpreter.pyvalue()}) ::
          :ok | {:exception, String.t()}
  defp validate_mkdir_kwargs(kwargs) do
    case Map.keys(kwargs) -- ["parents", "exist_ok"] do
      [] ->
        :ok

      [key | _] ->
        {:exception, "TypeError: Path.mkdir() got an unexpected keyword argument '#{key}'"}
    end
  end

  @spec coerce_parts([Interpreter.pyvalue()]) :: {:ok, [String.t()]} | {:error, String.t()}
  defp coerce_parts(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case Pyex.Path.coerce(part) do
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        :error -> {:halt, {:error, "TypeError: expected str or PathLike object"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = error -> error
    end
  end

  @spec coerce_path(Interpreter.pyvalue()) :: {:ok, String.t()} | {:exception, String.t()}
  defp coerce_path(value) do
    case Pyex.Path.coerce(value) do
      {:ok, path} -> {:ok, path}
      :error -> {:exception, "TypeError: expected str or PathLike object"}
    end
  end

  @spec path_string(Interpreter.pyvalue()) :: String.t()
  defp path_string({:instance, {:class, "Path", _, _}, %{"__path__" => path}}), do: path

  @spec path_instance(Interpreter.pyvalue(), String.t()) :: Interpreter.pyvalue()
  defp path_instance({:instance, {:class, "Path", _, _} = class, _}, path) do
    {:instance, class,
     %{
       "__path__" => path,
       "name" => Pyex.Path.basename(path),
       "stem" => Pyex.Path.stem(path),
       "suffix" => Pyex.Path.suffix(path),
       "parent" => basic_path_instance(class, parent_path(path))
     }}
  end

  defp path_instance(_class_or_instance, path) do
    class = path_class()

    {:instance, class,
     %{
       "__path__" => path,
       "name" => Pyex.Path.basename(path),
       "stem" => Pyex.Path.stem(path),
       "suffix" => Pyex.Path.suffix(path),
       "parent" => basic_path_instance(class, parent_path(path))
     }}
  end

  @spec basic_path_instance(Interpreter.pyvalue(), String.t()) :: Interpreter.pyvalue()
  defp basic_path_instance(class, path) do
    {:instance, class,
     %{
       "__path__" => path,
       "name" => Pyex.Path.basename(path),
       "stem" => Pyex.Path.stem(path),
       "suffix" => Pyex.Path.suffix(path)
     }}
  end

  @spec parent_path(String.t()) :: String.t()
  defp parent_path("/"), do: "/"
  defp parent_path("."), do: "."

  defp parent_path(path) do
    parent = Pyex.Path.dirname(path)
    if parent == "", do: ".", else: parent
  end
end
