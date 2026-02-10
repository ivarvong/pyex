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
  Returns a helpful error suffix for unknown module names.
  """
  @spec import_hint(String.t()) :: String.t()
  def import_hint(name)
      when name in ["urllib", "urllib2", "http", "httplib", "httpx", "aiohttp"],
      do: ". Use 'import requests' instead"

  def import_hint("sys"), do: ". Use 'import os' for environ access"

  def import_hint(_) do
    names = ["os" | Pyex.Stdlib.module_names()] |> Enum.join(", ")
    ". Available modules: #{names}"
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
    {:ok, %{"environ" => ctx.environ}}
  end

  defp resolve_builtin_module(name, _ctx) do
    Pyex.Stdlib.fetch(name)
  end

  @spec resolve_filesystem_module(String.t(), Env.t(), Ctx.t()) ::
          {:ok, Pyex.Stdlib.Module.module_value(), Ctx.t()}
          | {:unknown_module, Ctx.t()}
          | {:import_error, String.t(), Ctx.t()}
  defp resolve_filesystem_module(_name, _env, %{fs_module: nil} = ctx) do
    {:unknown_module, ctx}
  end

  defp resolve_filesystem_module(name, _env, ctx) do
    case Map.fetch(ctx.imported_modules, name) do
      {:ok, cached} ->
        {:ok, cached, ctx}

      :error ->
        path = String.replace(name, ".", "/") <> ".py"

        case ctx.fs_module.read(ctx.filesystem, path) do
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
end
