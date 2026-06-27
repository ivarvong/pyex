defmodule Pyex.Storage.Memory do
  @moduledoc """
  **Experimental.** The reference `Pyex.Storage` backend: a plain in-memory
  map.

  It is the storage analogue of `VFS.Memory` — the default backend used by
  tests and examples. Because the map lives on the `Pyex.Ctx`, state
  survives *across* separate `Pyex.run` calls whenever the host threads the
  returned `ctx.storage` back into the next run, exactly as a filesystem
  does. For durability beyond the host process, implement `Pyex.Storage`
  over a real store (Postgres, a managed KV, Redis).
  """

  @enforce_keys [:data]
  defstruct data: %{}

  @type t :: %__MODULE__{data: %{optional(String.t()) => String.t()}}

  @doc """
  Builds an in-memory store, optionally seeded with `%{key => json_string}`.
  Seed values must already be JSON strings (the `store` module encodes
  Python values before they reach the backend).
  """
  @spec new(%{optional(String.t()) => String.t()}) :: t()
  def new(seed \\ %{}) when is_map(seed), do: %__MODULE__{data: seed}
end

defimpl Pyex.Storage, for: Pyex.Storage.Memory do
  def get(%{data: data}, key) do
    case Map.fetch(data, key) do
      {:ok, json} -> {:ok, json}
      :error -> :miss
    end
  end

  def put(%{data: data} = store, key, json) do
    {:ok, %{store | data: Map.put(data, key, json)}}
  end

  def delete(%{data: data} = store, key) do
    {:ok, %{store | data: Map.delete(data, key)}}
  end

  def list_prefix(%{data: data}, prefix) do
    keys =
      data
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()

    {:ok, keys}
  end
end
