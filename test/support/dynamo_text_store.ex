defmodule Pyex.Test.DynamoTextStore do
  @moduledoc """
  A reference `Pyex.Storage` backend that keeps the whole keyspace in a single
  serialized text blob — one `key\\tbase64(json)` row per item.

  It exists to demonstrate that the `dynamo` table module is backend-agnostic:
  a CSV file, a SQLite/Postgres row store, or this text blob are the same shape
  the host implements (`get`/`put`/`delete`/`list_prefix`/`scan_prefix`); only
  where the bytes live differs. Pure and IO-free, so it lives in test support.
  """
  defstruct text: ""

  @type t :: %__MODULE__{text: String.t()}
end

defimpl Pyex.Storage, for: Pyex.Test.DynamoTextStore do
  defp rows(%{text: ""}), do: []

  defp rows(%{text: text}) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [k, b64] = String.split(line, "\t", parts: 2)
      {k, Base.decode64!(b64)}
    end)
  end

  defp dump(rows) do
    rows
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {k, v} -> k <> "\t" <> Base.encode64(v) end)
  end

  def get(store, key) do
    case List.keyfind(rows(store), key, 0) do
      {_k, json} -> {:ok, json}
      nil -> :miss
    end
  end

  def put(store, key, json) do
    {:ok, %{store | text: rows(store) |> List.keystore(key, 0, {key, json}) |> dump()}}
  end

  def delete(store, key) do
    {:ok, %{store | text: rows(store) |> List.keydelete(key, 0) |> dump()}}
  end

  def list_prefix(store, prefix) do
    keys =
      rows(store)
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()

    {:ok, keys}
  end

  def scan_prefix(store, prefix) do
    {:ok,
     rows(store)
     |> Enum.filter(fn {k, _} -> String.starts_with?(k, prefix) end)
     |> Enum.sort_by(&elem(&1, 0))}
  end
end
