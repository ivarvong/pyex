defmodule Pyex.Stdlib.Functools do
  @moduledoc """
  Python `functools` module.

  Provides `reduce`, `partial`, `wraps`, `lru_cache`, `cached_property`,
  `total_ordering`, and `cmp_to_key`.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Interpreter

  @doc """
  Returns the module value map.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "reduce" => {:builtin_kw, &functools_reduce/2},
      "partial" => {:builtin, &functools_partial/1},
      "wraps" => {:builtin, &functools_wraps/1},
      "lru_cache" => {:builtin, &functools_lru_cache/1},
      "cache" => {:builtin, &functools_lru_cache/1},
      "cached_property" => {:builtin, &functools_cached_property/1},
      "total_ordering" => {:builtin, &functools_total_ordering/1},
      "cmp_to_key" => {:builtin, &functools_cmp_to_key/1},
      "WRAPPER_ASSIGNMENTS" =>
        {:tuple, ["__module__", "__name__", "__qualname__", "__annotations__", "__doc__"]}
    }
  end

  @doc false
  @spec functools_reduce([Interpreter.pyvalue()], map()) :: Interpreter.pyvalue()
  def functools_reduce([func, iterable], _kwargs) do
    {:reduce_call, func, iterable, :no_initial}
  end

  def functools_reduce([func, iterable, initial], _kwargs) do
    {:reduce_call, func, iterable, initial}
  end

  def functools_reduce(_, _),
    do: {:exception, "TypeError: reduce() takes 2 or 3 arguments"}

  @doc false
  @spec functools_partial([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def functools_partial([func | partial_args]) when is_list(partial_args) do
    {:partial, func, partial_args, %{}}
  end

  def functools_partial(_), do: {:exception, "TypeError: partial() requires at least 1 argument"}

  @doc false
  @spec functools_wraps([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def functools_wraps([_wrapped]) do
    # Returns a decorator that copies __name__, __doc__ etc.
    # We implement this as a passthrough decorator since we don't track __name__ on functions.
    {:builtin, fn [func] -> func end}
  end

  def functools_wraps(_), do: {:exception, "TypeError: wraps() takes 1 argument"}

  @doc false
  @spec functools_lru_cache([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def functools_lru_cache([func]) when not is_integer(func) do
    # @lru_cache applied directly to a function
    wrap_with_cache(func)
  end

  def functools_lru_cache([maxsize]) when is_integer(maxsize) or is_nil(maxsize) do
    # @lru_cache(maxsize=128) — returns decorator
    {:builtin, fn [func] -> wrap_with_cache(func) end}
  end

  def functools_lru_cache([]) do
    # @lru_cache() with no args — returns decorator
    {:builtin, fn [func] -> wrap_with_cache(func) end}
  end

  def functools_lru_cache(_) do
    {:exception, "TypeError: lru_cache() invalid arguments"}
  end

  @spec wrap_with_cache(Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp wrap_with_cache(func) do
    # Allocate a heap slot for the cache when the decorated function is first called.
    # We use a ctx_call so the heap allocation threads through ctx properly.
    {:ctx_call,
     fn env, ctx ->
       # Allocate an empty map in the heap as the cache store
       {ref, ctx} = Pyex.Ctx.heap_alloc(ctx, %{})
       {:ref, cache_id} = ref
       wrapped = {:lru_cached_function, func, cache_id}
       {wrapped, env, ctx}
     end}
  end

  @doc false
  @spec functools_cached_property([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def functools_cached_property([func]) do
    # cached_property is like property but caches the result in the instance dict
    {:cached_property, func}
  end

  def functools_cached_property(_),
    do: {:exception, "TypeError: cached_property() takes 1 argument"}

  @doc false
  @spec functools_total_ordering([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def functools_total_ordering([cls]) do
    # Returns the class unchanged — a full implementation would add missing
    # comparison methods, but for typical usage the class already defines them.
    cls
  end

  def functools_total_ordering(_),
    do: {:exception, "TypeError: total_ordering() takes 1 argument"}

  @doc false
  @spec functools_cmp_to_key([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def functools_cmp_to_key([cmp_func]) do
    # Returns a key function that wraps the comparison function
    {:builtin, fn [item] -> {:cmp_key, cmp_func, item} end}
  end

  def functools_cmp_to_key(_),
    do: {:exception, "TypeError: cmp_to_key() takes 1 argument"}
end
