defmodule Pyex.Interpreter.Import do
  @moduledoc """
  Module resolution and import logic for the Pyex interpreter.

  Resolves Python `import` and `from ... import` statements against
  the stdlib registry, custom modules, and the pluggable filesystem.
  Supports dotted module names (e.g. `os.path`) and caches imported
  filesystem modules in `ctx.imported_modules`.
  """

  alias Pyex.{Builtins, Ctx, Env, Interpreter}

  @doc """
  Evaluates an `import ...` statement.
  """
  @spec eval_import([String.t() | {String.t(), String.t() | nil}], Env.t(), Ctx.t()) ::
          {nil, Env.t(), Ctx.t()} | {{:exception, String.t()}, Env.t(), Ctx.t()}
  def eval_import(imports, env, ctx) when is_list(imports) do
    Enum.reduce_while(imports, {nil, env, ctx}, fn import_spec, {_, env, ctx} ->
      {module_name, alias_name} =
        case import_spec do
          {module_name, alias_name} -> {module_name, alias_name}
          module_name when is_binary(module_name) -> {module_name, nil}
        end

      bind_as = alias_name || import_binding_name(module_name)

      case resolve_module(module_name, env, ctx) do
        {:ok, module_value, ctx} ->
          bound_value = binding_value(module_name, alias_name, module_value, env, ctx)
          {:cont, {nil, Env.put(env, bind_as, bound_value), ctx}}

        {:import_error, msg, ctx} ->
          {:halt, {{:exception, msg}, env, ctx}}

        {:unknown_module, ctx} ->
          {:halt,
           {{:exception,
             "ImportError: no module named '#{module_name}'#{import_hint(module_name)}"}, env,
            ctx}}
      end
    end)
  end

  @doc """
  Evaluates a `from ... import ...` statement.
  """
  @spec eval_from_import(String.t(), [{String.t(), String.t() | nil}], Env.t(), Ctx.t()) ::
          {nil, Env.t(), Ctx.t()} | {{:exception, String.t()}, Env.t(), Ctx.t()}
  def eval_from_import(module_name, names, env, ctx) do
    case resolve_module(module_name, env, ctx) do
      {:ok, module_value, ctx} when is_map(module_value) ->
        Enum.reduce_while(names, {nil, env, ctx}, fn {name, alias_name}, {_, env, ctx} ->
          bind_as = alias_name || name

          case Map.fetch(module_value, name) do
            {:ok, value} ->
              {:cont, {nil, Env.put(env, bind_as, value), ctx}}

            :error ->
              {:halt,
               {{:exception, "ImportError: cannot import name '#{name}' from '#{module_name}'"},
                env, ctx}}
          end
        end)

      {:import_error, msg, ctx} ->
        {{:exception, msg}, env, ctx}

      {:unknown_module, ctx} ->
        {{:exception, "ImportError: no module named '#{module_name}'#{import_hint(module_name)}"},
         env, ctx}
    end
  end

  @doc """
  Returns a helpful error suffix for unknown module names.
  """
  @spec import_hint(String.t()) :: String.t()
  def import_hint("urllib.request"), do: ". Use 'import requests' instead"
  def import_hint("urllib.error"), do: ". Use 'import requests' instead"

  def import_hint(name) when name in ["urllib2", "http", "httplib", "httpx", "aiohttp"],
    do: ". Use 'import requests' instead"

  def import_hint("http." <> _), do: ". Use 'import requests' instead"

  def import_hint("sys"), do: ". Use 'import os' for environ access"
  def import_hint("pathlib"), do: ". Use the filesystem option with Pyex.Filesystem.Memory"
  def import_hint("io"), do: ". Use the filesystem option for file operations"

  def import_hint(_) do
    names = ["os" | Pyex.Stdlib.module_names()] |> Enum.join(", ")
    ". Available modules: #{names}"
  end

  @spec import_binding_name(String.t()) :: String.t()
  defp import_binding_name(module_name) do
    module_name
    |> String.split(".")
    |> hd()
  end

  @spec binding_value(String.t(), String.t() | nil, map(), Env.t(), Ctx.t()) :: map()
  defp binding_value(module_name, alias_name, module_value, env, ctx) do
    cond do
      alias_name != nil ->
        module_value

      String.contains?(module_name, ".") ->
        root = import_binding_name(module_name)
        {:ok, root_module, _ctx} = resolve_single_module(root, env, ctx)
        root_module

      true ->
        module_value
    end
  end

  @doc """
  Resolves a module name to its value map.

  Returns `{:ok, module_value, ctx}`, `{:unknown_module, ctx}`,
  or `{:import_error, message, ctx}`.
  """
  @spec resolve_module(String.t(), Env.t(), Ctx.t()) ::
          {:ok, Pyex.Stdlib.Module.module_value(), Ctx.t()}
          | {:unknown_module, Ctx.t()}
          | {:import_error, String.t(), Ctx.t()}
  def resolve_module(name, env, ctx) do
    case String.split(name, ".") do
      [single] ->
        resolve_single_module(single, env, ctx)

      [root | parts] ->
        case resolve_single_module(root, env, ctx) do
          {:ok, module_value, ctx} ->
            resolve_dotted_parts(module_value, parts, name, ctx)

          other ->
            other
        end
    end
  end

  @spec resolve_single_module(String.t(), Env.t(), Ctx.t()) ::
          {:ok, Pyex.Stdlib.Module.module_value(), Ctx.t()}
          | {:unknown_module, Ctx.t()}
          | {:import_error, String.t(), Ctx.t()}
  defp resolve_single_module(name, env, ctx) do
    case Map.fetch(ctx.modules, name) do
      {:ok, value} ->
        {:ok, value, ctx}

      :error ->
        case resolve_builtin_module(name, ctx) do
          {:ok, value} ->
            {:ok, value, ctx}

          :unknown_module ->
            resolve_filesystem_module(name, env, ctx)
        end
    end
  end

  @spec resolve_dotted_parts(map(), [String.t()], String.t(), Ctx.t()) ::
          {:ok, Pyex.Stdlib.Module.module_value(), Ctx.t()} | {:unknown_module, Ctx.t()}
  defp resolve_dotted_parts(value, [], _full_name, ctx), do: {:ok, value, ctx}

  defp resolve_dotted_parts(value, [part | rest], full_name, ctx) do
    case Map.fetch(value, part) do
      {:ok, sub} when is_map(sub) -> resolve_dotted_parts(sub, rest, full_name, ctx)
      {:ok, _} -> {:unknown_module, ctx}
      :error -> {:unknown_module, ctx}
    end
  end

  @spec resolve_builtin_module(String.t(), Ctx.t()) ::
          {:ok, Pyex.Stdlib.Module.module_value()} | :unknown_module
  defp resolve_builtin_module("os", ctx) do
    path_module = %{
      "join" => {:builtin, &os_path_join/1},
      "exists" => {:builtin, &os_path_exists/1},
      "basename" => {:builtin, &os_path_basename/1},
      "dirname" => {:builtin, &os_path_dirname/1},
      "splitext" => {:builtin, &os_path_splitext/1},
      "isfile" => {:builtin, &os_path_isfile/1},
      "isdir" => {:builtin, &os_path_isdir/1}
    }

    {:ok,
     %{
       "environ" => ctx.env,
       "path" => path_module,
       "makedirs" => {:builtin, &os_makedirs/1},
       "listdir" => {:builtin, &os_listdir/1},
       "walk" => {:builtin, &os_walk/1}
     }}
  end

  defp resolve_builtin_module(name, _ctx) do
    Pyex.Stdlib.fetch(name)
  end

  @spec os_listdir([Interpreter.pyvalue()]) ::
          {:ctx_call, (Pyex.Env.t(), Ctx.t() -> {term(), Pyex.Env.t(), Ctx.t()})}
          | {:exception, String.t()}
  defp os_listdir([]) do
    os_listdir([""])
  end

  defp os_listdir([path]) do
    case Pyex.Path.coerce(path) do
      {:ok, path} ->
        {:ctx_call,
         fn env, ctx ->
           case ctx.filesystem do
             nil ->
               {{:exception, "OSError: no filesystem configured"}, env, ctx}

             fs ->
               case fs.__struct__.list_dir(fs, path) do
                 {:ok, entries} ->
                   {entries, env, ctx}

                 {:error, msg} ->
                   {{:exception, msg}, env, ctx}
               end
           end
         end}

      :error ->
        {:exception, "TypeError: listdir: path should be string"}
    end
  end

  defp os_listdir(_args) do
    {:exception, "TypeError: listdir expected at most 1 argument"}
  end

  @spec os_walk([Interpreter.pyvalue()]) ::
          {:ctx_call, (Pyex.Env.t(), Ctx.t() -> {term(), Pyex.Env.t(), Ctx.t()})}
          | {:exception, String.t()}
  defp os_walk([path]) do
    case Pyex.Path.coerce(path) do
      {:ok, path} ->
        {:ctx_call,
         fn env, ctx ->
           case ctx.filesystem do
             nil ->
               {{:exception, "OSError: no filesystem configured"}, env, ctx}

             fs ->
               case Pyex.Path.walk(fs, path) do
                 {:ok, entries} ->
                   rows =
                     Enum.map(entries, fn {root, dirs, files} ->
                       {:tuple, [root, dirs, Enum.map(files, &Pyex.Path.basename/1)]}
                     end)

                   {token, ctx} = Ctx.new_iterator(ctx, rows)
                   {token, env, ctx}

                 {:error, msg} ->
                   {{:exception, msg}, env, ctx}
               end
           end
         end}

      :error ->
        {:exception, "TypeError: walk: top should be string"}
    end
  end

  defp os_walk(_args), do: {:exception, "TypeError: walk expected exactly 1 argument"}

  @spec resolve_filesystem_module(String.t(), Env.t(), Ctx.t()) ::
          {:ok, Pyex.Stdlib.Module.module_value(), Ctx.t()}
          | {:unknown_module, Ctx.t()}
          | {:import_error, String.t(), Ctx.t()}
  defp resolve_filesystem_module(_name, _env, %{filesystem: nil} = ctx) do
    {:unknown_module, ctx}
  end

  defp resolve_filesystem_module(name, _env, ctx) do
    case Map.fetch(ctx.imported_modules, name) do
      {:ok, cached} ->
        {:ok, cached, ctx}

      :error ->
        path = String.replace(name, ".", "/") <> ".py"

        case ctx.filesystem.__struct__.read(ctx.filesystem, path) do
          {:ok, source} ->
            case Pyex.compile(source) do
              {:ok, ast} ->
                mod_env = Env.push_scope(Builtins.env())

                case Interpreter.eval(ast, mod_env, ctx) do
                  {{:exception, msg}, _mod_env, ctx} ->
                    {:import_error, "ImportError: error in '#{name}': #{msg}", ctx}

                  {_val, mod_env, ctx} ->
                    module_value = collect_module_bindings(mod_env)

                    ctx = %{
                      ctx
                      | imported_modules: Map.put(ctx.imported_modules, name, module_value)
                    }

                    {:ok, module_value, ctx}
                end

              {:error, msg} ->
                {:import_error, "SyntaxError: error in '#{name}': #{msg}", ctx}
            end

          {:error, _} ->
            {:unknown_module, ctx}
        end
    end
  end

  @spec collect_module_bindings(Env.t()) :: Pyex.Stdlib.Module.module_value()
  defp collect_module_bindings(env) do
    env
    |> Env.all_bindings()
    |> Enum.reject(fn {name, _} -> String.starts_with?(name, "__") end)
    |> Map.new()
  end

  # os.path module functions
  defp os_path_join(args) when args != [] do
    case coerce_paths(args) do
      {:ok, parts} -> Pyex.Path.join(parts)
      {:error, msg} -> {:exception, msg}
    end
  end

  defp os_path_join(_args) do
    {:exception, "TypeError: join() takes at least 1 argument"}
  end

  defp os_path_exists([path]) do
    case Pyex.Path.coerce(path) do
      {:ok, path} ->
        {:ctx_call,
         fn env, ctx ->
           case ctx.filesystem do
             nil -> {false, env, ctx}
             fs -> {Pyex.Path.exists?(fs, path), env, ctx}
           end
         end}

      :error ->
        {:exception, "TypeError: path should be string"}
    end
  end

  defp os_path_basename([path]) do
    case Pyex.Path.coerce(path) do
      {:ok, path} -> Pyex.Path.basename(path)
      :error -> {:exception, "TypeError: path should be string"}
    end
  end

  defp os_path_dirname([path]) do
    case Pyex.Path.coerce(path) do
      {:ok, path} -> Pyex.Path.dirname(path)
      :error -> {:exception, "TypeError: path should be string"}
    end
  end

  defp os_path_splitext([path]) do
    case Pyex.Path.coerce(path) do
      {:ok, path} ->
        {root, ext} = Pyex.Path.splitext(path)
        {:tuple, [root, ext]}

      :error ->
        {:exception, "TypeError: path should be string"}
    end
  end

  defp os_path_isfile([path]) do
    case Pyex.Path.coerce(path) do
      {:ok, path} ->
        {:ctx_call,
         fn env, ctx ->
           case ctx.filesystem do
             nil -> {false, env, ctx}
             fs -> {Pyex.Path.file?(fs, path), env, ctx}
           end
         end}

      :error ->
        {:exception, "TypeError: path should be string"}
    end
  end

  defp os_path_isdir([path]) do
    case Pyex.Path.coerce(path) do
      {:ok, path} ->
        {:ctx_call,
         fn env, ctx ->
           case ctx.filesystem do
             nil -> {false, env, ctx}
             fs -> {Pyex.Path.dir?(fs, path), env, ctx}
           end
         end}

      :error ->
        {:exception, "TypeError: path should be string"}
    end
  end

  defp os_makedirs([path]) do
    case Pyex.Path.coerce(path) do
      {:ok, path} ->
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

      :error ->
        {:exception, "TypeError: path should be string"}
    end
  end

  defp os_makedirs([path, kwargs]) when is_map(kwargs) do
    case Map.keys(kwargs) -- ["exist_ok"] do
      [] ->
        os_makedirs([path])

      [name | _] ->
        {:exception, "TypeError: makedirs() got an unexpected keyword argument '#{name}'"}
    end
  end

  @spec coerce_paths([Interpreter.pyvalue()]) :: {:ok, [String.t()]} | {:error, String.t()}
  defp coerce_paths(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case Pyex.Path.coerce(path) do
        {:ok, path} -> {:cont, {:ok, [path | acc]}}
        :error -> {:halt, {:error, "TypeError: path should be string"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = error -> error
    end
  end
end
