defmodule Pyex.Test.CountingFS do
  @moduledoc """
  A `VFS.Mountable` test backend whose **reads mutate observable state**, used
  to prove Pyex threads the filesystem through every operation.

  It wraps an inner `VFS.Memory` and keeps a counter `n`. Every read-side op —
  `stream_read/3`, `stat/2`, `exists?/2`, `readdir/2` — increments `n` in the
  returned backend value, exactly as a lazy/caching backend would mutate its
  cache. The current counter is exposed as the file `"/seq"`: reading it yields
  the counter as a decimal string (and, like every read, bumps it).

  Because the counter only advances if callers thread the returned backend
  back, a Python program that interleaves operations with reads of `"/seq"`
  observes the counter advancing **iff** Pyex threaded state correctly. Drop a
  single `fs'` on the read path and the observed sequence diverges.

  Writes delegate to the inner memory (they already thread in Pyex); this
  backend's whole point is the read path.
  """

  @type t :: %__MODULE__{inner: VFS.Memory.t(), n: non_neg_integer()}
  defstruct inner: nil, n: 0

  @spec new(%{optional(String.t()) => binary()}) :: t()
  def new(files \\ %{}) do
    %__MODULE__{inner: VFS.Memory.new(files), n: 0}
  end
end

defimpl VFS.Mountable, for: Pyex.Test.CountingFS do
  use VFS.Skeleton

  alias Pyex.Test.CountingFS
  alias VFS.Stat

  @seq "/seq"
  @epoch DateTime.from_unix!(0)

  def capabilities(_), do: MapSet.new([:read, :write, :mkdir])

  # Reading "/seq" returns the counter; reading anything else delegates. Either
  # way the read bumps the counter in the returned backend.
  def stream_read(%CountingFS{n: n} = cf, @seq, _opts) do
    {:ok, [Integer.to_string(n)], bump(cf)}
  end

  def stream_read(%CountingFS{inner: inner} = cf, path, opts) do
    case VFS.Mountable.stream_read(inner, path, opts) do
      {:ok, stream, inner} -> {:ok, stream, bump(%{cf | inner: inner})}
      {:error, _} = err -> err
    end
  end

  def stat(%CountingFS{n: n} = cf, @seq) do
    {:ok, Stat.regular(byte_size(Integer.to_string(n)), @epoch), bump(cf)}
  end

  def stat(%CountingFS{inner: inner} = cf, path) do
    case VFS.Mountable.stat(inner, path) do
      {:ok, stat, inner} -> {:ok, stat, bump(%{cf | inner: inner})}
      {:error, _} = err -> err
    end
  end

  def exists?(%CountingFS{} = cf, @seq), do: {true, bump(cf)}

  def exists?(%CountingFS{inner: inner} = cf, path) do
    {exists, inner} = VFS.Mountable.exists?(inner, path)
    {exists, bump(%{cf | inner: inner})}
  end

  def readdir(%CountingFS{inner: inner} = cf, path) do
    case VFS.Mountable.readdir(inner, path) do
      {:ok, names, inner} ->
        # "/seq" is a synthetic root entry.
        names = if path in ["/", ""], do: Enum.sort(["seq" | names]), else: names
        {:ok, names, bump(%{cf | inner: inner})}

      {:error, _} = err ->
        err
    end
  end

  def write_file(%CountingFS{inner: inner} = cf, path, content, opts) do
    case VFS.Mountable.write_file(inner, path, content, opts) do
      {:ok, inner} -> {:ok, %{cf | inner: inner}}
      {:error, _} = err -> err
    end
  end

  def mkdir(%CountingFS{inner: inner} = cf, path, opts) do
    case VFS.Mountable.mkdir(inner, path, opts) do
      {:ok, inner} -> {:ok, %{cf | inner: inner}}
      {:error, _} = err -> err
    end
  end

  def rm(%CountingFS{inner: inner} = cf, path, opts) do
    case VFS.Mountable.rm(inner, path, opts) do
      {:ok, inner} -> {:ok, %{cf | inner: inner}}
      {:error, _} = err -> err
    end
  end

  defp bump(%CountingFS{n: n} = cf), do: %{cf | n: n + 1}
end
