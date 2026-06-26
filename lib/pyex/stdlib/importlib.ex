defmodule Pyex.Stdlib.Importlib do
  @moduledoc """
  Python `importlib` module: programmatic (re)import control.

  Imports in pyex are cached per run by module name with no eviction, so the
  first `import X` of a run wins for the whole run. This module exposes the
  escape hatches:

    * `reload(module)` — evict the cached module and re-read + re-execute its
      source from the filesystem, returning the fresh module. Lets a program
      pick up a module it rewrote mid-run (`m = importlib.reload(m)`).
    * `invalidate_caches()` — a no-op (returns `None`), matching CPython:
      it refreshes finder caches so *new* module files can be found, and pyex
      has no such cache (the filesystem is read fresh on every cache-miss, and
      failed imports are never cached), so there is nothing to invalidate. It
      does *not* evict already-imported modules — use `reload` for that.

  `reload` operates on filesystem-backed modules; stdlib modules resolve from
  the registry and are unaffected.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Interpreter.Import

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "__name__" => "importlib",
      "reload" => {:builtin, &reload/1},
      "invalidate_caches" => {:builtin, &invalidate_caches/1}
    }
  end

  @spec reload([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp reload([{:module, name, _attrs}]) do
    {:ctx_call,
     fn env, ctx ->
       case Import.reload_module(name, env, ctx) do
         {:ok, module, ctx} ->
           {module, env, ctx}

         {:import_error, msg, ctx} ->
           {{:exception, msg}, env, ctx}

         {:unknown_module, ctx} ->
           {{:exception, "ImportError: no module named '#{name}'"}, env, ctx}
       end
     end}
  end

  defp reload([other]),
    do: {:exception, "TypeError: reload() argument must be a module, not '#{type_name(other)}'"}

  defp reload(_),
    do: {:exception, "TypeError: reload() takes exactly one argument"}

  # No-op (returns None), matching CPython: pyex has no finder cache to
  # invalidate, and this must NOT evict already-imported modules.
  @spec invalidate_caches([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp invalidate_caches([]), do: nil

  defp invalidate_caches(_),
    do: {:exception, "TypeError: invalidate_caches() takes no arguments"}

  defp type_name({:module, _, _}), do: "module"
  defp type_name(val), do: Pyex.Interpreter.Helpers.py_type(val)
end
