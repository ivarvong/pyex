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
  # `whiteouts` and `explicit_dirs` are maps used as sets (not MapSet), to
  # stay clear of the opaque-type friction MapSet causes Dialyzer on Elixir
  # 1.19 (see `Pyex.Storage.Overlay.deletes` for the same fix, hit first).
  defstruct [:lower, :upper, whiteouts: %{}, explicit_dirs: %{}]

  @type t :: %__MODULE__{
          lower: Mountable.t(),
          upper: Mountable.t(),
          whiteouts: %{optional(Path.t()) => true},
          explicit_dirs: %{optional(Path.t()) => true}
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
  def commit(%__MODULE__{lower: lower, upper: upper, whiteouts: whiteouts} = ov) do
    with {:ok, lower} <- apply_deletes(lower, Map.keys(whiteouts)) do
      apply_writes(lower, upper, ov.explicit_dirs)
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

  defp apply_writes(lower, upper, explicit_dirs) do
    entries = upper |> Mountable.walk("/", include_dirs: true) |> Enum.to_list()

    reduce_ok(entries, lower, fn
      # Only a directory `mkdir/3` genuinely targeted — not every ancestor
      # `VFS.Memory`'s own `parents: true` happened to materialize along the
      # way while bridging up from a `lower`-only implicit directory (see
      # `mkdir/3`'s comment). Those bridged ancestors were never meant to
      # become real; skipping them lets them fall back to being implicit on
      # `lower` too, exactly as they would on a plain (non-overlaid) backend.
      # A file written under a skipped ancestor still creates it implicitly
      # via `write_file` below — `VFS.Memory` never requires a pre-existing
      # parent directory.
      {"/", %Stat{type: :directory}}, acc ->
        {:ok, acc}

      {path, %Stat{type: :directory}}, acc ->
        if Map.has_key?(explicit_dirs, path) do
          case Mountable.mkdir(acc, path, parents: true) do
            {:ok, acc} -> {:ok, acc}
            {:error, %Error{kind: :eexist}} -> {:ok, acc}
            error -> error
          end
        else
          {:ok, acc}
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

  # Delegates to `stat/2` rather than duplicating its logic — the two must
  # agree on whether a `lower`-only *implicit* directory (see `stat/2`'s
  # comment) is still visible, and drift is exactly the kind of bug that's
  # easy to introduce by hand-rolling `exists?` separately.
  def exists?(%Overlay{} = ov, path) do
    case stat(ov, path) do
      {:ok, _stat, ov} -> {true, ov}
      {:error, _} -> {false, ov}
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
            # `lower` may define this directory *implicitly* (it exists only
            # because it has descendants — `VFS.Memory`'s model, and the
            # closest real-world analogue: an S3 "directory" is just a key
            # prefix). Whiting out its last visible child should make it
            # vanish too, exactly as it would on a plain backend with no
            # overlay — `lower.stat` alone can't know that, since it has no
            # idea what the overlay staged on top of it.
            {:ok, %VFS.Stat{type: :directory} = stat, lower} ->
              case directory_visible(%{ov | lower: lower}, p) do
                {true, ov} -> {:ok, stat, ov}
                {false, _ov} -> {:error, Error.new(:enoent, path: p)}
              end

            {:ok, stat, lower} ->
              {:ok, stat, %{ov | lower: lower}}

            error ->
              error
          end
        end

      error ->
        error
    end
  end

  defp directory_visible(ov, p) do
    case readdir(ov, p) do
      {:ok, [_ | _], ov} -> {true, ov}
      {:ok, [], ov} -> {false, ov}
      {:error, _} -> {false, ov}
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

  # `upper` alone can't see conflicts whose ancestor lives only in `lower` —
  # a plain `Mountable.write_file(upper, ...)` would happily write through a
  # path that's a directory (or descends through a file) in the *merged*
  # view but doesn't exist in `upper` at all. Check the merged view first.
  #
  # Deliberately does *not* clear a whiteout at `p`: every read already
  # checks `upper` before ever consulting `whiteouts` (see `stat/2`), so a
  # stale whiteout entry never hides a resurrected path. Clearing it would
  # instead corrupt `commit/1` when `p` is recreated as a *different type*
  # than it had in `lower` (e.g. a file replaced by a directory) — leaving
  # the whiteout in place is what makes `apply_deletes` remove the old
  # entry from `lower` before `apply_writes` recreates it.
  def write_file(%Overlay{} = ov, path, content, opts) do
    p = Path.normalize(path)

    cond do
      match?({:ok, %VFS.Stat{type: :directory}, _ov}, stat(ov, p)) ->
        {:error, Error.new(:eisdir, path: p)}

      ancestor_is_file?(ov, p) ->
        {:error, Error.new(:enotdir, path: p)}

      true ->
        case Mountable.write_file(ov.upper, p, content, opts) do
          {:ok, upper} -> {:ok, %{ov | upper: upper}}
          error -> error
        end
    end
  end

  # See `write_file/4` above for why a successful `mkdir` doesn't clear `p`'s
  # whiteout either.
  def mkdir(%Overlay{} = ov, path, opts) do
    p = Path.normalize(path)
    parents? = Keyword.get(opts, :parents, false)

    case exists?(ov, p) do
      {true, ov} ->
        if parents?, do: {:ok, ov}, else: {:error, Error.new(:eexist, path: p)}

      {false, ov} ->
        with :ok <- ensure_creatable(ov, p, parents?) do
          # `parents: true` regardless of the caller's own opts: `upper`'s
          # tree may be missing the ancestor chain entirely (it only exists,
          # implicitly or explicitly, in `lower`), so `upper`'s own mkdir
          # must never reject on a missing intermediate — `ensure_creatable/3`
          # already did the real (merged-view) validation above.
          #
          # That bridging has a side effect worth naming: `VFS.Memory`'s own
          # `parents: true` permanently materializes every intermediate
          # ancestor as an *explicit* directory in `upper`, even ones that
          # were only ever implicit in `lower` (e.g. bridging up through a
          # directory that exists purely because it has files). Record which
          # paths this call actually targeted — the leaf always, every
          # ancestor only when the caller asked for `parents: true` (real
          # `mkdir -p` semantics: every level it creates is as real as the
          # leaf) — so `commit/1` can tell a genuine directory from an
          # incidental bridging artifact and skip recreating the latter.
          case Mountable.mkdir(ov.upper, p, Keyword.put(opts, :parents, true)) do
            {:ok, upper} ->
              {:ok,
               %{ov | upper: upper, explicit_dirs: mark_explicit(ov.explicit_dirs, p, parents?)}}

            error ->
              error
          end
        end
    end
  end

  defp mark_explicit(explicit_dirs, p, false), do: Map.put(explicit_dirs, p, true)

  defp mark_explicit(explicit_dirs, p, true) do
    [p | ancestors(p)]
    |> Enum.reject(&(&1 == "/"))
    |> Enum.reduce(explicit_dirs, &Map.put(&2, &1, true))
  end

  defp ensure_creatable(_ov, "/", _parents?), do: :ok
  defp ensure_creatable(_ov, _p, true), do: :ok

  defp ensure_creatable(ov, p, false) do
    case stat(ov, Path.dirname(p)) do
      {:ok, %VFS.Stat{type: :directory}, _ov} -> :ok
      {:ok, _stat, _ov} -> {:error, Error.new(:enotdir, path: p)}
      {:error, %Error{kind: :enoent}} -> {:error, Error.new(:enoent, path: p)}
      error -> error
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

  # Whether any ancestor of `p` is a regular file in the *merged* view — a
  # cheap, non-threaded read (like `diff/1`'s reads), since this only gates
  # whether the real write below is attempted at all.
  defp ancestor_is_file?(ov, p) do
    p
    |> ancestors()
    |> Enum.any?(fn a -> match?({:ok, %VFS.Stat{type: :regular}, _ov}, stat(ov, a)) end)
  end

  defp ancestors("/"), do: []
  defp ancestors(p), do: [Path.dirname(p) | ancestors(Path.dirname(p))]

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
