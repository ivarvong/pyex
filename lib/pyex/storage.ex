defprotocol Pyex.Storage do
  @moduledoc """
  **Experimental.** A host-provided key/value storage capability.

  Storage works exactly like `filesystem` does (see `Pyex.FS`): the
  interpreter core stays pure and deterministic, and the *host* owns the
  backend. A run is granted storage by passing a backend to `Pyex.run`:

      Pyex.run(source, storage: Pyex.Storage.Memory.new())

  Without a backend, the Python `store` module raises `StorageError` — the
  same denied-by-default posture as the network and filesystem capabilities.

  The contract is a deliberately small string→string KV: `get`, `put`,
  `delete`, and a prefix scan. That is the lowest common denominator that
  every realistic backend supports — a Postgres table, a managed KV, Redis,
  or the in-memory reference here — so the same Python code runs against any
  of them by swapping the backend. The Python-facing `store` module owns
  JSON (de)serialization, so a backend only ever stores strings.

  Backends are threaded through the `Pyex.Ctx` functionally: `put`/`delete`
  return an updated backend which the interpreter stores back on the
  context. A side-effecting backend (Postgres, ETS) just returns its handle
  unchanged; a pure backend (the reference `Memory`) returns a new value.

  ## Implementing a host backend

  Define a struct and implement this protocol for it:

      defmodule MyApp.PostgresStore do
        defstruct [:conn]
      end

      defimpl Pyex.Storage, for: MyApp.PostgresStore do
        def get(s, key), do: # SELECT value FROM kv WHERE key = $1 ...
        def put(s, key, json), do: # INSERT ... ON CONFLICT ...; {:ok, s}
        def delete(s, key), do: # DELETE ...; {:ok, s}
        def list_prefix(s, prefix), do: # SELECT key ... WHERE key LIKE $1 ...
      end

  An operation may also return `{:error, reason}` (see `t:error/0`) to deny
  or fail without crashing the run; the `store` module surfaces it as a
  Python `StorageError`.

  ## Multitenancy (the host-binding model)

  Tenancy is an *object* boundary, not a keyspace partition: give each
  tenant a **distinct backend** (its own table/schema/database/bucket) and
  bind the right one per request, exactly like a Cloudflare Worker binding.
  The Python program holds the capability it was handed and has no reference
  with which to name another tenant's store.

      def handle(tenant_id, source) do
        Pyex.run(source, storage: MyApp.store_for(tenant_id))
      end

  For least-authority *within* a tenant, attenuate with `Pyex.Storage.View`
  before binding — e.g. a read-only handle for a GET route, or a handle
  scoped to one resource type:

      Pyex.run(source, storage: Pyex.Storage.View.readonly(MyApp.store_for(tenant_id)))

  Because a capability is handed out per request, **revocation is simply not
  re-binding it** on the next request — no shared mutable state, and the
  `Ctx` stays a serializable value.

  > #### Experimental {: .warning}
  > This API is new and may change without a major-version bump.
  """

  @type key :: String.t()
  @type json :: String.t()

  @typedoc """
  A denial or failure. The `store` module surfaces it to Python as
  `StorageError: <reason>`. Attenuating membranes (see `Pyex.Storage.View`)
  return this to deny a verb the holder lacks the right to use; a real
  backend may also return it to signal a transport failure instead of
  crashing the run.
  """
  @type error :: {:error, String.t()}

  @doc "Fetches the JSON-encoded value at `key`, or `:miss` if absent."
  @spec get(t, key) :: {:ok, json} | :miss | error
  def get(backend, key)

  @doc "Stores the JSON-encoded `value` at `key`, returning the updated backend."
  @spec put(t, key, json) :: {:ok, t} | error
  def put(backend, key, value)

  @doc "Removes `key`, returning the updated backend (a no-op if absent)."
  @spec delete(t, key) :: {:ok, t} | error
  def delete(backend, key)

  @doc "Returns all keys beginning with `prefix`, in ascending order."
  @spec list_prefix(t, key) :: {:ok, [key]} | error
  def list_prefix(backend, prefix)
end
