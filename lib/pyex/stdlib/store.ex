defmodule Pyex.Stdlib.Store do
  @moduledoc """
  **Experimental.** The Python-facing `store` module — a host-provided
  key/value store.

      import store

      store.set("expense:1", {"amount": 9.99, "category": "food"})
      store.get("expense:1")        # -> {"amount": 9.99, "category": "food"}
      store.get("missing")          # -> None
      store.keys("expense:")        # -> ["expense:1"]
      store.delete("expense:1")     # -> True (False if it wasn't there)

  Values are any JSON-serializable Python value; this module encodes them
  with the same engine as `json.dumps`, so the backend only ever stores
  strings (see `Pyex.Storage`). State persists for as long as the host keeps
  the backend — across `Pyex.run` calls when `ctx.storage` is threaded
  forward, or durably when the backend is a real database.

  The module is always importable, but every operation requires a backend:
  without `storage:` on the context it raises `StorageError`, the same
  denied-by-default posture as the network capability.

  > #### Experimental {: .warning}
  > This API is new and may change without a major-version bump.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Stdlib.JSON

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "__name__" => "store",
      "get" => {:builtin, &store_get/1},
      "set" => {:builtin, &store_set/1},
      "delete" => {:builtin, &store_delete/1},
      "keys" => {:builtin, &store_keys/1}
    }
  end

  # store.get(key) -> the decoded value, or None when the key is absent.
  @spec store_get([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp store_get([key]) when is_binary(key) do
    with_backend(fn backend, env, ctx ->
      {ctx, span} = Pyex.Ctx.open_runtime_span(ctx, "db.get", db_attrs("get", key))

      case Pyex.Storage.get(backend, key) do
        {:ok, json} ->
          {JSON.decode(json), env, Pyex.Ctx.close_runtime_span(ctx, span, %{"hit" => true})}

        :miss ->
          {nil, env, Pyex.Ctx.close_runtime_span(ctx, span, %{"hit" => false})}

        {:error, reason} ->
          {storage_error(reason), env, close_error(ctx, span, reason)}
      end
    end)
  end

  defp store_get(_), do: {:exception, "TypeError: store.get(key) expects a single string key"}

  # store.set(key, value) -> None. Encodes value to JSON before storing.
  @spec store_set([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp store_set([key, value]) when is_binary(key) do
    with_backend(fn backend, env, ctx ->
      {ctx, span} = Pyex.Ctx.open_runtime_span(ctx, "db.set", db_attrs("set", key))

      case JSON.dumps(value) do
        {:exception, _} = exc ->
          {exc, env, close_error(ctx, span, "value not JSON-serializable")}

        json when is_binary(json) ->
          case Pyex.Storage.put(backend, key, json) do
            {:ok, backend} ->
              {nil, env,
               Pyex.Ctx.close_runtime_span(%{ctx | storage: backend}, span, %{
                 "bytes" => byte_size(json)
               })}

            {:error, reason} ->
              {storage_error(reason), env, close_error(ctx, span, reason)}
          end
      end
    end)
  end

  defp store_set(_),
    do: {:exception, "TypeError: store.set(key, value) expects a string key and a value"}

  # store.delete(key) -> True if the key existed, else False.
  @spec store_delete([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp store_delete([key]) when is_binary(key) do
    with_backend(fn backend, env, ctx ->
      {ctx, span} = Pyex.Ctx.open_runtime_span(ctx, "db.delete", db_attrs("delete", key))

      case Pyex.Storage.get(backend, key) do
        {:error, reason} ->
          {storage_error(reason), env, close_error(ctx, span, reason)}

        existence ->
          existed = match?({:ok, _}, existence)

          case Pyex.Storage.delete(backend, key) do
            {:ok, backend} ->
              {existed, env,
               Pyex.Ctx.close_runtime_span(%{ctx | storage: backend}, span, %{
                 "existed" => existed
               })}

            {:error, reason} ->
              {storage_error(reason), env, close_error(ctx, span, reason)}
          end
      end
    end)
  end

  defp store_delete(_),
    do: {:exception, "TypeError: store.delete(key) expects a single string key"}

  # store.keys(prefix="") -> sorted list of keys beginning with prefix.
  @spec store_keys([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp store_keys([]), do: store_keys([""])

  defp store_keys([prefix]) when is_binary(prefix) do
    with_backend(fn backend, env, ctx ->
      {ctx, span} = Pyex.Ctx.open_runtime_span(ctx, "db.query", db_attrs("query", prefix))

      case Pyex.Storage.list_prefix(backend, prefix) do
        {:ok, keys} ->
          ctx = Pyex.Ctx.close_runtime_span(ctx, span, %{"count" => length(keys)})
          {{:py_list, Enum.reverse(keys), length(keys)}, env, ctx}

        {:error, reason} ->
          {storage_error(reason), env, close_error(ctx, span, reason)}
      end
    end)
  end

  defp store_keys(_),
    do: {:exception, "TypeError: store.keys(prefix='') expects an optional string prefix"}

  # OTel database semantic-convention attributes for a KV operation.
  @spec db_attrs(String.t(), String.t()) :: %{String.t() => String.t()}
  defp db_attrs(operation, target) do
    %{
      "db.system.name" => "pyex.kv",
      "db.operation.name" => operation,
      "db.collection.name" => target
    }
  end

  # A backend (or attenuating membrane) denial/failure, surfaced to Python.
  @spec storage_error(String.t()) :: Pyex.Interpreter.pyvalue()
  defp storage_error(reason), do: {:exception, "StorageError: #{reason}"}

  # Close a storage span that ended in a denial/failure, tagging it for review.
  @spec close_error(Pyex.Ctx.t(), non_neg_integer(), String.t()) :: Pyex.Ctx.t()
  defp close_error(ctx, span, reason) do
    Pyex.Ctx.close_runtime_span(ctx, span, %{"error" => reason})
  end

  # Gates every operation on a configured backend — presence is the grant,
  # mirroring how the filesystem is enabled. Absent → StorageError.
  @spec with_backend((term(), Pyex.Env.t(), Pyex.Ctx.t() ->
                        {Pyex.Interpreter.pyvalue(), Pyex.Env.t(), Pyex.Ctx.t()})) ::
          Pyex.Interpreter.pyvalue()
  defp with_backend(fun) do
    {:io_call,
     fn env, ctx ->
       case ctx.storage do
         nil ->
           {{:exception,
             "StorageError: no storage backend configured. " <>
               "Pass `storage:` to Pyex.run to enable the store module."}, env, ctx}

         backend ->
           fun.(backend, env, ctx)
       end
     end}
  end
end
