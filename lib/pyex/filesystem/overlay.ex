defmodule Pyex.Filesystem.Overlay do
  @moduledoc """
  **Experimental.** A copy-on-write `VFS.Mountable` for *staging* filesystem
  effects: reads check `upper` first, then fall through to `lower`; writes
  and `mkdir` land in `upper`; `rm` marks a whiteout instead of touching
  `lower`. Nothing reaches `lower` until you choose to `commit/1`.

  This is the filesystem counterpart to `Pyex.Storage.Overlay` — same
  staging shape, applied to `Pyex.Ctx`'s `:filesystem` capability instead of
  `:storage`. Run untrusted (e.g. agent-generated) code against an overlay
  and you get back what it would have done — inspect with `diff/1` — without
  it having touched anything real:

      overlay = Pyex.Filesystem.Overlay.new(real_fs)
      {:ok, _value, ctx} = Pyex.run(agent_code, filesystem: overlay, seed: 1)

      Pyex.Filesystem.Overlay.diff(ctx.filesystem)
      # %{added: [...], modified: [...], deleted: [...]}

      # gate on the above, then either:
      {:ok, committed} = Pyex.Filesystem.Overlay.commit(ctx.filesystem)
      # ...or just drop `ctx.filesystem` to discard the run entirely.

  As with `Pyex.Storage.Overlay`, `upper` gives read-your-writes exactly as
  a real backend would, so the run is identical whether staged or applied —
  combined with deterministic execution (`seed:`), the ledger produced under
  the overlay equals the ledger of the committed run. There is no
  time-of-check/time-of-use gap between what you approved and what happens.
  (`test/pyex/filesystem/overlay_test.exs` proves the two ledgers are equal.)

  This module was previously a documented-but-unshipped pattern in `vfs`
  (see `vfs`'s `SPEC.md`, "CoW overlay — the agent staging pattern") — it
  lands here first, under real usage, before it's a candidate for promotion
  to a stock `vfs` impl.

  ## Directory semantics

  A whiteout is recorded per-path (file or directory) and masks that path
  *and everything under it* in `lower`, so `rm(overlay, "/dir", recursive:
  true)` correctly hides every previously-visible descendant even though
  only one entry was recorded. `upper` always wins over a whiteout: writing
  a fresh file back under a whited-out directory makes it visible again
  without needing to clear the directory's whiteout.

  `upper` must behave like `VFS.Memory` with respect to implicit
  directories (no `mkdir` required before writing a file under a path) —
  the default `upper` (`VFS.Memory.new/0`) does.

  > #### Experimental {: .warning}
  > This API is new and may change without a major-version bump.
  """

  alias VFS.Error
  alias VFS.Mountable
  alias VFS.Path
  alias VFS.Stat

  @enforce_keys [:lower, :upper]
  # `whiteouts` is a map used as a set (not a MapSet), to stay clear of the
  # opaque-type friction MapSet causes Dialyzer on Elixir 1.19 (see
  # `Pyex.Storage.Overlay.deletes` for the same fix, hit first).
  defstruct [:lower, :upper, whiteouts: %{}]

  @type t :: %__MODULE__{
          lower: Mountable.t(),
          upper: Mountable.t(),
          whiteouts: %{optional(Path.t()) => true}
        }

  @doc """
  Wraps `lower` in a staging overlay. Reads fall through to `lower`; writes
  are staged in `upper`, which defaults to a fresh `VFS.Memory`.
  """
  @spec new(Mountable.t(), Mountable.t()) :: t()
  def new(lower, upper \\ VFS.Memory.new()), do: %__MODULE__{lower: lower, upper: upper}

  @doc """
  The effects staged so far, relative to `lower`: paths only in `upper`
  (`added`), paths in both with different content (`modified`), and
  whited-out paths (`deleted`). The unit a policy gate inspects.

  Reads `lower` and `upper` to compare content, so — like `VFS.walk/3` —
  any cache state a lazy backend populates during the comparison does not
  escape into the returned overlay's state. Call `Pyex.Filesystem.Overlay`'s
  `materialize/2` (via `VFS.materialize/2`) first if you need warmed caches
  to persist past this call.
  """
  @spec diff(t()) :: %{added: [Path.t()], modified: [Path.t()], deleted: [Path.t()]}
  def diff(%__MODULE__{lower: lower, upper: upper, whiteouts: whiteouts}) do
    {added, modified} =
      upper
      |> Mountable.walk("/", [])
      |> Enum.reduce({[], []}, fn {path, _stat}, {added, modified} ->
        classify(lower, upper, path, added, modified)
      end)

    %{
      added: Enum.sort(added),
      modified: Enum.sort(modified),
      deleted: whiteouts |> Map.keys() |> Enum.sort()
    }
  end

  defp classify(lower, upper, path, added, modified) do
    case Mountable.stream_read(lower, path, []) do
      {:error, %Error{kind: :enoent}} ->
        {[path | added], modified}

      {:ok, lower_stream, _lower} ->
        {:ok, upper_stream, _upper} = Mountable.stream_read(upper, path, [])

        if Enum.into(lower_stream, <<>>) == Enum.into(upper_stream, <<>>) do
          {added, modified}
        else
          {added, [path | modified]}
        end

      {:error, _} ->
        {[path | added], modified}
    end
  end

  @doc """
  Applies the staged writes and whiteouts to `lower` and returns it.
  Deletes apply first, then writes — so a directory that was removed and
  had a fresh file staged back under it ends up containing just that file.
  Stops and returns `{:error, reason}` if `lower` rejects an operation
  (e.g. it's read-only).
  """
  @spec commit(t()) :: {:ok, Mountable.t()} | {:error, Error.t()}
  def commit(%__MODULE__{lower: lower, upper: upper, whiteouts: whiteouts}) do
    with {:ok, lower} <- apply_deletes(lower, Map.keys(whiteouts)) do
      apply_writes(lower, upper)
    end
  end

  defp apply_deletes(lower, paths) do
    reduce_ok(paths, lower, fn path, acc ->
      case Mountable.rm(acc, path, recursive: true) do
        {:ok, acc} -> {:ok, acc}
        {:error, %Error{kind: :enoent}} -> {:ok, acc}
        error -> error
      end
    end)
  end

  defp apply_writes(lower, upper) do
    entries = upper |> Mountable.walk("/", include_dirs: true) |> Enum.to_list()

    reduce_ok(entries, lower, fn
      {path, %Stat{type: :directory}}, acc ->
        case Mountable.mkdir(acc, path, parents: true) do
          {:ok, acc} -> {:ok, acc}
          {:error, %Error{kind: :eexist}} -> {:ok, acc}
          error -> error
        end

      {path, %Stat{type: :regular}}, acc ->
        with {:ok, stream, _upper} <- Mountable.stream_read(upper, path, []) do
          Mountable.write_file(acc, path, Enum.into(stream, <<>>), [])
        end

      _entry, acc ->
        {:ok, acc}
    end)
  end

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

defimpl VFS.Mountable, for: Pyex.Filesystem.Overlay do
  use VFS.Skeleton

  alias Pyex.Filesystem.Overlay
  alias VFS.Error
  alias VFS.Mountable
  alias VFS.Path

  def exists?(%Overlay{upper: upper} = ov, path) do
    p = Path.normalize(path)

    case Mountable.exists?(upper, p) do
      {true, upper} ->
        {true, %{ov | upper: upper}}

      {false, upper} ->
        if under_whiteout?(ov.whiteouts, p) do
          {false, %{ov | upper: upper}}
        else
          {exists, lower} = Mountable.exists?(ov.lower, p)
          {exists, %{ov | upper: upper, lower: lower}}
        end
    end
  end

  def stat(%Overlay{upper: upper} = ov, path) do
    p = Path.normalize(path)

    case Mountable.stat(upper, p) do
      {:ok, stat, upper} ->
        {:ok, stat, %{ov | upper: upper}}

      {:error, %Error{kind: :enoent}} ->
        if under_whiteout?(ov.whiteouts, p) do
          {:error, Error.new(:enoent, path: p)}
        else
          case Mountable.stat(ov.lower, p) do
            {:ok, stat, lower} -> {:ok, stat, %{ov | lower: lower}}
            error -> error
          end
        end

      error ->
        error
    end
  end

  def stream_read(%Overlay{upper: upper} = ov, path, opts) do
    p = Path.normalize(path)

    case Mountable.stream_read(upper, p, opts) do
      {:ok, stream, upper} ->
        {:ok, stream, %{ov | upper: upper}}

      {:error, %Error{kind: :enoent}} ->
        if under_whiteout?(ov.whiteouts, p) do
          {:error, Error.new(:enoent, path: p)}
        else
          case Mountable.stream_read(ov.lower, p, opts) do
            {:ok, stream, lower} -> {:ok, stream, %{ov | lower: lower}}
            error -> error
          end
        end

      error ->
        error
    end
  end

  def readdir(%Overlay{upper: upper} = ov, path) do
    p = Path.normalize(path)

    case Mountable.readdir(upper, p) do
      {:ok, upper_names, upper} ->
        lower_names = lower_readdir_names(ov.lower, p)
        merged = merge_names(upper_names, filter_children(lower_names, p, ov.whiteouts))
        {:ok, merged, %{ov | upper: upper}}

      {:error, %Error{kind: :enoent}} ->
        if under_whiteout?(ov.whiteouts, p) do
          {:error, Error.new(:enoent, path: p)}
        else
          case Mountable.readdir(ov.lower, p) do
            {:ok, names, lower} ->
              {:ok, filter_children(names, p, ov.whiteouts) |> Enum.sort(), %{ov | lower: lower}}

            error ->
              error
          end
        end

      error ->
        error
    end
  end

  def write_file(%Overlay{upper: upper, whiteouts: whiteouts} = ov, path, content, opts) do
    p = Path.normalize(path)

    case Mountable.write_file(upper, p, content, opts) do
      {:ok, upper} -> {:ok, %{ov | upper: upper, whiteouts: Map.delete(whiteouts, p)}}
      error -> error
    end
  end

  def mkdir(%Overlay{whiteouts: whiteouts} = ov, path, opts) do
    p = Path.normalize(path)
    parents? = Keyword.get(opts, :parents, false)

    case exists?(ov, p) do
      {true, ov} ->
        if parents?, do: {:ok, ov}, else: {:error, Error.new(:eexist, path: p)}

      {false, ov} ->
        case Mountable.mkdir(ov.upper, p, opts) do
          {:ok, upper} -> {:ok, %{ov | upper: upper, whiteouts: Map.delete(whiteouts, p)}}
          error -> error
        end
    end
  end

  def rm(%Overlay{whiteouts: whiteouts} = ov, path, opts) do
    p = Path.normalize(path)
    recursive? = Keyword.get(opts, :recursive, false)

    case stat(ov, p) do
      {:error, _} = error ->
        error

      {:ok, %VFS.Stat{type: :directory}, _ov} when not recursive? ->
        {:error, Error.new(:eisdir, path: p)}

      {:ok, _stat, ov} ->
        {in_upper?, upper} = Mountable.exists?(ov.upper, p)

        with {:ok, upper} <- maybe_rm(upper, p, opts, in_upper?) do
          {in_lower?, lower} = Mountable.exists?(ov.lower, p)
          whiteouts = if in_lower?, do: Map.put(whiteouts, p, true), else: whiteouts
          {:ok, %{ov | upper: upper, lower: lower, whiteouts: whiteouts}}
        end
    end
  end

  def materialize(%Overlay{lower: lower, upper: upper} = ov, opts) do
    with {:ok, lower} <- Mountable.materialize(lower, opts),
         {:ok, upper} <- Mountable.materialize(upper, opts) do
      {:ok, %{ov | lower: lower, upper: upper}}
    end
  end

  # Static, not derived from `upper`'s own `capabilities/1`: probing a
  # protocol-dispatched MapSet here hits the same opaque-type friction
  # `Pyex.Storage.Overlay` avoided by dropping MapSet from its struct entirely
  # (see the comment on `whiteouts` above) — except here the protocol itself
  # requires returning a `MapSet.t()`, so there's no map-as-set escape hatch.
  # `upper` is documented to behave like `VFS.Memory` (read/write/mkdir,
  # implicit directories), so this mirrors `VFS.Memory`'s own static
  # `capabilities/1` rather than reflecting a caller-supplied `upper` that
  # deviates from that contract.
  def capabilities(_overlay), do: MapSet.new([:read, :write, :mkdir])

  # ── helpers ──

  defp maybe_rm(upper, _p, _opts, false), do: {:ok, upper}
  defp maybe_rm(upper, p, opts, true), do: Mountable.rm(upper, p, opts)

  defp lower_readdir_names(lower, path) do
    case Mountable.readdir(lower, path) do
      {:ok, names, _lower} -> names
      {:error, _} -> []
    end
  end

  defp filter_children(names, dir, whiteouts) do
    Enum.reject(names, fn name -> under_whiteout?(whiteouts, Path.join(dir, name)) end)
  end

  defp merge_names(upper_names, lower_names) do
    (Enum.to_list(upper_names) ++ Enum.to_list(lower_names)) |> Enum.uniq() |> Enum.sort()
  end

  defp under_whiteout?(whiteouts, path) do
    Enum.any?(whiteouts, fn {whited, _} ->
      path == whited or String.starts_with?(path, whited <> "/")
    end)
  end
end
