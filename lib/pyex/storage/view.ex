defmodule Pyex.Storage.View do
  @moduledoc """
  **Experimental.** An attenuating membrane over any `Pyex.Storage` backend.

  A view wraps an inner capability and mediates every access crossing it,
  handing out a *strictly weaker* capability — the ocap notion of
  attenuation. It implements `Pyex.Storage` itself, so it is interchangeable
  with a raw backend and composes (a view can wrap a view).

  In the host-binding ("Workers") model, the host composes views and injects
  the result as the run's `storage:`. The Python `store` module then only
  ever holds the attenuated capability and cannot widen or escape it — the
  authority *is* the object it was handed.

  Two independent axes:

    * **rights** — which verbs are permitted (`:get`, `:put`, `:delete`,
      `:list`). A denied verb returns `{:error, _}`, surfaced to Python as
      `StorageError`. `readonly/1` is sugar for `{:get, :list}`.

    * **scope** — which keys are *reachable at all*, given by a serializable
      **selector**, not a hardcoded prefix:
        * `:all` — no scope restriction
        * `{:prefix, p}` — keys beginning with `p`
        * `{:keys, list}` — exactly these keys
      A read of an out-of-scope key is a `:miss` (the holder cannot even
      observe its existence); a write or delete out of scope is denied; a
      listing is filtered to the reachable keys.

  Tenancy itself is a *backend* boundary (a distinct store per tenant), not
  a scope selector — views are for least-authority *within* a tenant (a
  read-only handle, a handle limited to one resource type).

  > #### Experimental {: .warning}
  > This API is new and may change without a major-version bump.
  """

  alias Pyex.Storage

  @all_rights [:get, :put, :delete, :list]

  @enforce_keys [:inner]
  defstruct inner: nil, rights: MapSet.new([:get, :put, :delete, :list]), selector: :all

  @type right :: :get | :put | :delete | :list
  @type selector :: :all | {:prefix, String.t()} | {:keys, [String.t()]}
  @type t :: %__MODULE__{
          inner: Storage.t(),
          rights: MapSet.t(right()),
          selector: selector()
        }

  @doc """
  Wraps `inner` with the given attenuations.

  Options:
    * `:rights` — a list of permitted verbs (default: all four)
    * `:scope` — a selector (default: `:all`)
  """
  @spec new(Storage.t(), keyword()) :: t()
  def new(inner, opts \\ []) do
    rights = opts |> Keyword.get(:rights, @all_rights) |> MapSet.new()
    selector = Keyword.get(opts, :scope, :all)
    validate_selector!(selector)
    %__MODULE__{inner: inner, rights: rights, selector: selector}
  end

  @doc "A read-only view of `inner`: only `:get` and `:list` are permitted."
  @spec readonly(Storage.t()) :: t()
  def readonly(inner), do: new(inner, rights: [:get, :list])

  @doc """
  A view of `inner` scoped to `selector` (`{:prefix, p}`, `{:keys, list}`,
  or `:all`). All four rights remain; combine with `readonly/1` for both.
  """
  @spec scope(Storage.t(), selector()) :: t()
  def scope(inner, selector), do: new(inner, scope: selector)

  @doc false
  @spec reachable?(selector(), String.t()) :: boolean()
  def reachable?(:all, _key), do: true
  def reachable?({:prefix, p}, key), do: String.starts_with?(key, p)
  def reachable?({:keys, keys}, key), do: key in keys

  @spec validate_selector!(term()) :: :ok
  defp validate_selector!(:all), do: :ok
  defp validate_selector!({:prefix, p}) when is_binary(p), do: :ok

  defp validate_selector!({:keys, keys}) do
    if is_list(keys) and Enum.all?(keys, &is_binary/1) do
      :ok
    else
      raise ArgumentError, "scope {:keys, list} requires a list of string keys"
    end
  end

  defp validate_selector!(other) do
    raise ArgumentError,
          "scope selector must be :all, {:prefix, p}, or {:keys, list}, got: #{inspect(other)}"
  end
end

defimpl Pyex.Storage, for: Pyex.Storage.View do
  alias Pyex.Storage
  alias Pyex.Storage.View

  # A right the holder lacks is a hard denial, surfaced as StorageError.
  defp denied(right), do: {:error, "#{right} not permitted by this capability"}

  def get(%View{rights: rights} = view, key) do
    cond do
      not MapSet.member?(rights, :get) -> denied(:get)
      # Out-of-scope reads are invisible — the holder can't even probe for
      # existence outside its capability.
      not View.reachable?(view.selector, key) -> :miss
      true -> Storage.get(view.inner, key)
    end
  end

  def put(%View{rights: rights} = view, key, json) do
    cond do
      not MapSet.member?(rights, :put) ->
        denied(:put)

      not View.reachable?(view.selector, key) ->
        {:error, "key is outside this capability's scope"}

      true ->
        case Storage.put(view.inner, key, json) do
          {:ok, inner} -> {:ok, %{view | inner: inner}}
          {:error, _} = err -> err
        end
    end
  end

  def delete(%View{rights: rights} = view, key) do
    cond do
      not MapSet.member?(rights, :delete) ->
        denied(:delete)

      not View.reachable?(view.selector, key) ->
        {:error, "key is outside this capability's scope"}

      true ->
        case Storage.delete(view.inner, key) do
          {:ok, inner} -> {:ok, %{view | inner: inner}}
          {:error, _} = err -> err
        end
    end
  end

  def list_prefix(%View{rights: rights} = view, prefix) do
    if MapSet.member?(rights, :list) do
      case Storage.list_prefix(view.inner, prefix) do
        {:ok, keys} -> {:ok, Enum.filter(keys, &View.reachable?(view.selector, &1))}
        {:error, _} = err -> err
      end
    else
      denied(:list)
    end
  end
end
