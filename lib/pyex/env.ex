defmodule Pyex.Env do
  @moduledoc """
  Scope-stack environment for the interpreter.

  Variables are resolved by walking the stack from top (innermost
  scope) to bottom (module scope). Writes always target the
  topmost scope unless a `global` or `nonlocal` declaration
  redirects them.
  """

  @type name :: String.t()
  @type value :: term()
  @type scope :: %{optional(name()) => value()}
  @type t :: %__MODULE__{scopes: [scope(), ...], global: scope()}

  defstruct scopes: [%{}], global: %{}

  @doc """
  Creates a fresh environment with a single empty scope.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{scopes: [%{}], global: %{}}

  @doc """
  Looks up `name` in the scope stack, returning `{:ok, value}`
  or `:undefined`.
  """
  @spec get(t(), name()) :: {:ok, value()} | :undefined
  def get(%__MODULE__{scopes: scopes}, name) do
    find_in_scopes(scopes, name)
  end

  @spec find_in_scopes([scope()], name()) :: {:ok, value()} | :undefined
  defp find_in_scopes([], _name), do: :undefined

  defp find_in_scopes([scope | rest], name) do
    case Map.fetch(scope, name) do
      {:ok, _} = found -> found
      :error -> find_in_scopes(rest, name)
    end
  end

  @doc """
  Binds `name` to `value` in the topmost scope.
  """
  @spec put(t(), name(), value()) :: t()
  def put(%__MODULE__{scopes: [top | rest]} = env, name, value) do
    new_top = Map.put(top, name, value)

    case rest do
      [] -> %{env | scopes: [new_top], global: new_top}
      _ -> %{env | scopes: [new_top | rest]}
    end
  end

  @doc """
  Binds `name` to `value`, respecting `global` and `nonlocal`
  declarations in the current scope. Falls back to `put/3`.
  """
  @spec smart_put(t(), name(), value()) :: t()
  def smart_put(%__MODULE__{scopes: [top | _rest]} = env, name, value) do
    cond do
      Map.has_key?(top, {:__global__, name}) -> put_global(env, name, value)
      Map.has_key?(top, {:__nonlocal__, name}) -> put_enclosing(env, name, value)
      true -> put(env, name, value)
    end
  end

  @doc """
  Binds `name` to `value` in the bottom (module-level) scope.
  """
  @spec put_global(t(), name(), value()) :: t()
  def put_global(%__MODULE__{scopes: scopes, global: global}, name, value) do
    new_global = Map.put(global, name, value)
    upper = Enum.drop(scopes, -1)
    %__MODULE__{scopes: upper ++ [new_global], global: new_global}
  end

  @doc """
  Binds `name` to `value` in the nearest enclosing scope
  (skipping the topmost) that already contains `name`.
  Falls back to writing the first enclosing scope if not found.
  """
  @spec put_enclosing(t(), name(), value()) :: t()
  def put_enclosing(%__MODULE__{scopes: [top | rest]}, name, value) do
    updated = put_in_enclosing(rest, name, value, [])
    new_scopes = [top | updated]
    %__MODULE__{scopes: new_scopes, global: List.last(new_scopes)}
  end

  @spec put_in_enclosing([scope()], name(), value(), [scope()]) :: [scope()]
  defp put_in_enclosing([], _name, _value, acc), do: Enum.reverse(acc)

  defp put_in_enclosing([scope | rest], name, value, acc) do
    if Map.has_key?(scope, name) do
      Enum.reverse(acc) ++ [Map.put(scope, name, value) | rest]
    else
      put_in_enclosing(rest, name, value, [scope | acc])
    end
  end

  @doc """
  Marks `name` as a `global` variable in the current scope.
  """
  @spec declare_global(t(), name()) :: t()
  def declare_global(%__MODULE__{scopes: [top | rest], global: global}, name) do
    %__MODULE__{scopes: [Map.put(top, {:__global__, name}, true) | rest], global: global}
  end

  @doc """
  Marks `name` as a `nonlocal` variable in the current scope.
  """
  @spec declare_nonlocal(t(), name()) :: t()
  def declare_nonlocal(%__MODULE__{scopes: [top | rest], global: global}, name) do
    %__MODULE__{scopes: [Map.put(top, {:__nonlocal__, name}, true) | rest], global: global}
  end

  @doc """
  Returns the bottom (module-level) scope.
  """
  @spec global_scope(t()) :: scope()
  def global_scope(%__MODULE__{global: global}), do: global

  @doc """
  Returns all bindings across all scopes as a flat list of
  `{name, value}` pairs. Inner scopes shadow outer scopes.
  """
  @spec all_bindings(t()) :: [{String.t(), term()}]
  def all_bindings(%__MODULE__{scopes: scopes}) do
    scopes
    |> Enum.reduce(%{}, fn scope, acc -> Map.merge(acc, scope) end)
    |> Map.to_list()
  end

  @doc """
  Replaces the bottom (module-level) scope with `new_bottom`.
  """
  @spec put_global_scope(t(), scope()) :: t()
  def put_global_scope(%__MODULE__{scopes: [_]}, new_bottom) do
    %__MODULE__{scopes: [new_bottom], global: new_bottom}
  end

  def put_global_scope(%__MODULE__{scopes: scopes}, new_bottom) do
    upper = Enum.drop(scopes, -1)
    %__MODULE__{scopes: upper ++ [new_bottom], global: new_bottom}
  end

  @doc """
  Propagates `global` and `nonlocal` writes back to the caller's
  environment after a function call.

  The closure env's scopes are a suffix of the post-call env.
  This function finds the shared suffix and merges any mutations
  from the post-call env into the caller's env at the matching
  scope depth.
  """
  @spec propagate_scopes(t(), t(), t()) :: t()
  def propagate_scopes(
        %__MODULE__{scopes: caller_scopes},
        %__MODULE__{scopes: closure_scopes},
        %__MODULE__{scopes: post_call_scopes}
      ) do
    closure_depth = length(closure_scopes)
    post_closure = Enum.drop(post_call_scopes, length(post_call_scopes) - closure_depth)

    caller_depth = length(caller_scopes)
    shared_depth = min(caller_depth, closure_depth)

    caller_upper = Enum.take(caller_scopes, caller_depth - shared_depth)
    post_shared = Enum.drop(post_closure, closure_depth - shared_depth)

    new_scopes = caller_upper ++ post_shared
    %__MODULE__{scopes: new_scopes, global: List.last(new_scopes)}
  end

  @doc """
  Binds `name` to `value` in the scope where `name` was originally
  defined. Used for mutable object operations (subscript assignment,
  method mutation) that don't rebind the name itself but must update
  the value in place. Falls back to `smart_put/3` if not found.
  """
  @spec put_at_source(t(), name(), value()) :: t()
  def put_at_source(%__MODULE__{scopes: scopes} = env, name, value) do
    case put_in_source(scopes, name, value, []) do
      {:ok, new_scopes} ->
        new_global = List.last(new_scopes)
        %{env | scopes: new_scopes, global: new_global}

      :not_found ->
        smart_put(env, name, value)
    end
  end

  @spec put_in_source([scope()], name(), value(), [scope()]) ::
          {:ok, [scope()]} | :not_found
  defp put_in_source([], _name, _value, _acc), do: :not_found

  defp put_in_source([scope | rest], name, value, acc) do
    if Map.has_key?(scope, name) do
      {:ok, Enum.reverse(acc) ++ [Map.put(scope, name, value) | rest]}
    else
      put_in_source(rest, name, value, [scope | acc])
    end
  end

  @doc """
  Removes `name` from the topmost scope that contains it.
  """
  @spec delete(t(), name()) :: t()
  def delete(%__MODULE__{scopes: scopes} = env, name) do
    case delete_from_scopes(scopes, name, []) do
      {:ok, new_scopes} -> %__MODULE__{scopes: new_scopes, global: List.last(new_scopes)}
      :not_found -> env
    end
  end

  @spec delete_from_scopes([scope()], name(), [scope()]) ::
          {:ok, [scope()]} | :not_found
  defp delete_from_scopes([], _name, _acc), do: :not_found

  defp delete_from_scopes([scope | rest], name, acc) do
    if Map.has_key?(scope, name) do
      {:ok, Enum.reverse(acc) ++ [Map.delete(scope, name) | rest]}
    else
      delete_from_scopes(rest, name, [scope | acc])
    end
  end

  @doc """
  Pushes a new empty scope onto the stack.
  """
  @spec push_scope(t()) :: t()
  def push_scope(%__MODULE__{scopes: scopes, global: global}) do
    %__MODULE__{scopes: [%{} | scopes], global: global}
  end

  @doc """
  Pushes a new scope with initial bindings onto the stack.

  Equivalent to `push_scope/1` followed by multiple `put/3` calls,
  but creates only one intermediate struct instead of N+1.
  """
  @spec push_scope_with(t(), scope()) :: t()
  def push_scope_with(%__MODULE__{scopes: scopes, global: global}, initial) do
    %__MODULE__{scopes: [initial | scopes], global: global}
  end

  @doc """
  Returns the topmost (current) scope as a map.
  """
  @spec current_scope(t()) :: scope()
  def current_scope(%__MODULE__{scopes: [top | _]}), do: top

  @doc """
  Removes the topmost scope from the stack.
  """
  @spec drop_top_scope(t()) :: t()
  def drop_top_scope(%__MODULE__{scopes: [_top | rest], global: global}) do
    %__MODULE__{scopes: rest, global: global}
  end

  @doc """
  Merges mutations from a post-call environment back into an original
  closure environment. The post-call env has `[local | closure_scopes]`
  where `closure_scopes` may have been mutated (e.g. via subscript
  assignment). This replaces the bottom N scopes of `old_env` with the
  corresponding scopes from `post_call_env` (minus its local scope).
  """
  @spec merge_closure_scopes(t(), t()) :: t()
  def merge_closure_scopes(%__MODULE__{scopes: old_scopes}, %__MODULE__{scopes: post_scopes}) do
    post_closure = tl(post_scopes)
    post_len = length(post_closure)
    old_len = length(old_scopes)

    new_scopes =
      if post_len >= old_len do
        Enum.drop(post_closure, post_len - old_len)
      else
        kept = Enum.take(old_scopes, old_len - post_len)
        kept ++ post_closure
      end

    %__MODULE__{scopes: new_scopes, global: List.last(new_scopes)}
  end
end
