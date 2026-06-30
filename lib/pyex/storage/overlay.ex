defmodule Pyex.Storage.Overlay do
  @moduledoc """
  **Experimental.** A copy-on-write `Pyex.Storage` backend for *staging*
  effects: reads pass through to an inner backend, but writes and deletes
  accumulate in an overlay and are **not** committed until you choose to.

  It is the storage half of a *dry-run*. Run untrusted (e.g. agent-generated)
  code against an overlay and you get back two things the program cannot
  forge: the **capability ledger** of what it intended to do (on `ctx` /
  `%Pyex.Error{}`, via the `db.*` spans), and the **staged effects** it would
  apply (`pending/1`). A human or policy engine inspects them; only then do
  you `commit/1`.

      overlay = Pyex.Storage.Overlay.new(real_backend)
      {:ok, _value, ctx} = Pyex.run(agent_code, storage: overlay, seed: 1)

      Pyex.Storage.Overlay.pending(ctx.storage)   # the writes/deletes it WOULD do
      Pyex.Turn.render(ctx)                        # the ledger of every store op

      # gate on the above, then either:
      {:ok, committed} = Pyex.Storage.Overlay.commit(ctx.storage)   # apply for real
      # ...or just drop `ctx.storage` to discard the run entirely.

  ## Why the preview is *sound*, not best-effort

  The overlay gives read-your-writes (a `get` after a `put` sees the staged
  value), exactly as a real backend does — so the program executes identically
  whether its writes are staged or applied. Combined with deterministic
  execution (`seed:`), this means the run you previewed is *byte-for-byte the
  run that commits*: the ledger produced under the overlay equals the ledger of
  the committed run. There is no time-of-check/time-of-use gap between what you
  approved and what happens — the hole every nondeterministic "ask permission
  then act" system has. (`test/pyex/storage/overlay_test.exs` proves the two
  ledgers are equal.)

  > #### Experimental {: .warning}
  > This API is new and may change without a major-version bump.
  """

  alias Pyex.Storage

  @enforce_keys [:inner]
  # `deletes` is a map used as a set (not a MapSet), to stay clear of the
  # opaque-type friction MapSet causes Dialyzer on Elixir 1.19.
  defstruct inner: nil, writes: %{}, deletes: %{}

  @type t :: %__MODULE__{
          inner: Storage.t(),
          writes: %{optional(String.t()) => String.t()},
          deletes: %{optional(String.t()) => true}
        }

  @doc "Wraps `inner` in a staging overlay. Reads pass through; writes are deferred."
  @spec new(Storage.t()) :: t()
  def new(inner), do: %__MODULE__{inner: inner}

  @doc """
  Applies the staged writes and deletes to the inner backend and returns it.
  Stops and returns `{:error, reason}` if the inner backend rejects an
  operation (e.g. an attenuating `View` that denies a write on commit).
  """
  @spec commit(t()) :: {:ok, Storage.t()} | Storage.error()
  def commit(%__MODULE__{inner: inner, writes: writes, deletes: deletes}) do
    with {:ok, inner} <- reduce_ok(Map.keys(deletes), inner, &Storage.delete(&2, &1)),
         {:ok, inner} <-
           reduce_ok(Map.to_list(writes), inner, fn {k, v}, acc -> Storage.put(acc, k, v) end) do
      {:ok, inner}
    end
  end

  @doc """
  The effects staged so far: a map of pending `writes` (`key => json`) and a
  sorted list of pending `deletes`. The unit a policy gate inspects.
  """
  @spec pending(t()) :: %{writes: %{optional(String.t()) => String.t()}, deletes: [String.t()]}
  def pending(%__MODULE__{writes: writes, deletes: deletes}),
    do: %{writes: writes, deletes: deletes |> Map.keys() |> Enum.sort()}

  # Threads `acc` through `fun` for each item, halting on the first error.
  defp reduce_ok(items, acc, fun) do
    Enum.reduce_while(items, {:ok, acc}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end

defimpl Pyex.Storage, for: Pyex.Storage.Overlay do
  alias Pyex.Storage
  alias Pyex.Storage.Overlay

  def get(%Overlay{inner: inner, writes: writes, deletes: deletes}, key) do
    cond do
      Map.has_key?(deletes, key) -> :miss
      Map.has_key?(writes, key) -> {:ok, Map.fetch!(writes, key)}
      true -> Storage.get(inner, key)
    end
  end

  def put(%Overlay{writes: writes, deletes: deletes} = overlay, key, json) do
    {:ok, %{overlay | writes: Map.put(writes, key, json), deletes: Map.delete(deletes, key)}}
  end

  def delete(%Overlay{writes: writes, deletes: deletes} = overlay, key) do
    {:ok, %{overlay | deletes: Map.put(deletes, key, true), writes: Map.delete(writes, key)}}
  end

  def list_prefix(%Overlay{inner: inner, writes: writes, deletes: deletes}, prefix) do
    case Storage.list_prefix(inner, prefix) do
      {:ok, inner_keys} ->
        staged = writes |> Map.keys() |> Enum.filter(&String.starts_with?(&1, prefix))

        keys =
          (inner_keys ++ staged)
          |> Enum.reject(&Map.has_key?(deletes, &1))
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, keys}

      {:error, _} = err ->
        err
    end
  end

  def scan_prefix(%Overlay{inner: inner, writes: writes, deletes: deletes}, prefix) do
    case Storage.scan_prefix(inner, prefix) do
      {:ok, inner_pairs} ->
        merged =
          inner_pairs
          |> Map.new()
          |> drop_staged_deletes(deletes, prefix)
          |> apply_staged_writes(writes, prefix)

        {:ok, Enum.sort_by(merged, &elem(&1, 0))}

      {:error, _} = err ->
        err
    end
  end

  defp drop_staged_deletes(map, deletes, prefix) do
    Enum.reduce(Map.keys(deletes), map, fn k, acc ->
      if String.starts_with?(k, prefix), do: Map.delete(acc, k), else: acc
    end)
  end

  defp apply_staged_writes(map, writes, prefix) do
    Enum.reduce(writes, map, fn {k, v}, acc ->
      if String.starts_with?(k, prefix), do: Map.put(acc, k, v), else: acc
    end)
  end
end
