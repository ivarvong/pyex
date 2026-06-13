defmodule Pyex.FS do
  @moduledoc """
  Pyex's filesystem facade over a [`VFS.Mountable`](https://hexdocs.pm/vfs).

  The interpreter stores a `VFS.Mountable` (a `%VFS{}` mount table, a bare
  `VFS.Memory`, or any backend implementing the protocol) in `Pyex.Ctx`'s
  `:filesystem` field. This module is the single boundary that translates
  between two worlds:

    * **Path namespace.** Python code uses cwd-relative paths
      (`open("data.txt")`, `os.listdir("posts")`). VFS paths are absolute,
      with a leading `/`. `to_vfs/1` maps the former onto the latter, rooting
      every Python path at `/` and collapsing the absolute/relative
      distinction the way Pyex always has — `"posts/a.md"`, `"/posts/a.md"`,
      and `"posts/a.md/"` all address `/posts/a.md`.

    * **Errors.** VFS returns `%VFS.Error{kind: atom}` structs; Pyex surfaces
      Python-style exception strings (`"FileNotFoundError: [Errno 2] ..."`).
      `py_error/2` does that mapping, naming the path in the caller's own
      namespace.

  The public functions deliberately mirror the shapes the interpreter relied
  on before the VFS migration (`read/2` returns `{:ok, content}`, `write/4`
  takes a `:write | :append` mode, etc.), so call sites read the same.

  > #### Reads don't thread state {: .info}
  >
  > `read/2` discards the `VFS.Mountable` returned by `VFS.read_file/2`. For
  > the in-memory and S3 backends a read never mutates state, so this is
  > lossless. A lazy backend that warms a cache on read would lose that
  > warming; thread the filesystem yourself via `VFS.read_file/2` if you add
  > one.
  """

  @type fs :: VFS.Mountable.t()
  @type mode :: :read | :write | :append

  @doc """
  Builds an in-memory filesystem, optionally seeded with files.

  Keys are Pyex-namespace paths (no leading slash required); they are mapped
  into the VFS namespace via `to_vfs/1`. Equivalent to `from_map/1`.
  """
  @spec new(%{optional(String.t()) => binary()}) :: VFS.Memory.t()
  def new(files \\ %{}) when is_map(files), do: from_map(files)

  @doc """
  Wraps a `%{path => content}` map as a seeded `VFS.Memory` backend, mapping
  each key into the VFS namespace.
  """
  @spec from_map(%{optional(String.t()) => binary()}) :: VFS.Memory.t()
  def from_map(files \\ %{}) when is_map(files) do
    files
    |> Map.new(fn {path, content} -> {to_vfs(path), content} end)
    |> VFS.Memory.new()
  end

  @doc """
  Maps a Pyex-namespace path onto an absolute VFS path.

  Strips leading and trailing slashes, then roots the result at `/`. The empty
  path (and `"/"`) map to the VFS root `"/"`.

  ## Examples

      iex> Pyex.FS.to_vfs("posts/a.md")
      "/posts/a.md"

      iex> Pyex.FS.to_vfs("/posts/a.md/")
      "/posts/a.md"

      iex> Pyex.FS.to_vfs("")
      "/"
  """
  @spec to_vfs(String.t()) :: VFS.Path.t()
  def to_vfs(path) when is_binary(path) do
    case path |> String.trim_leading("/") |> String.trim_trailing("/") do
      "" -> "/"
      trimmed -> "/" <> trimmed
    end
  end

  @doc """
  Reads the full contents of a file.
  """
  @spec read(fs(), String.t()) :: {:ok, binary()} | {:error, String.t()}
  def read(fs, path) do
    case VFS.read_file(fs, to_vfs(path)) do
      {:ok, content, _fs} -> {:ok, content}
      {:error, err} -> {:error, py_error(err, path)}
    end
  end

  @doc """
  Writes content to a file, returning the updated filesystem.

  Mode `:write` truncates; `:append` concatenates onto the existing contents
  (treating a missing file as empty).
  """
  @spec write(fs(), String.t(), binary(), mode()) :: {:ok, fs()} | {:error, String.t()}
  def write(fs, path, content, mode) do
    vpath = to_vfs(path)

    with {:ok, data} <- resolve_write_content(fs, vpath, content, mode, path) do
      case VFS.write_file(fs, vpath, data) do
        {:ok, fs} -> {:ok, fs}
        {:error, err} -> {:error, py_error(err, path)}
      end
    end
  end

  @spec resolve_write_content(fs(), VFS.Path.t(), binary(), mode(), String.t()) ::
          {:ok, binary()} | {:error, String.t()}
  defp resolve_write_content(_fs, _vpath, content, mode, _path) when mode in [:write, :read],
    do: {:ok, content}

  defp resolve_write_content(fs, vpath, content, :append, path) do
    case VFS.read_file(fs, vpath) do
      {:ok, existing, _fs} -> {:ok, existing <> content}
      {:error, %VFS.Error{kind: :enoent}} -> {:ok, content}
      {:error, err} -> {:error, py_error(err, path)}
    end
  end

  @doc """
  Returns true if the path exists (file or directory).
  """
  @spec exists?(fs(), String.t()) :: boolean()
  def exists?(fs, path) do
    {exists, _fs} = VFS.exists?(fs, to_vfs(path))
    exists
  end

  @doc """
  Returns the entry type at `path`: `{:ok, :regular}` for a file,
  `{:ok, :directory}` for a directory, or `{:error, reason}`.
  """
  @spec stat(fs(), String.t()) :: {:ok, VFS.Stat.type()} | {:error, String.t()}
  def stat(fs, path) do
    case VFS.stat(fs, to_vfs(path)) do
      {:ok, %VFS.Stat{type: type}, _fs} -> {:ok, type}
      {:error, err} -> {:error, py_error(err, path)}
    end
  end

  @doc """
  Lists the entry names directly under a directory.
  """
  @spec list_dir(fs(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_dir(fs, path) do
    case VFS.readdir(fs, to_vfs(path)) do
      {:ok, names, _fs} -> {:ok, Enum.to_list(names)}
      {:error, err} -> {:error, py_error(err, path)}
    end
  end

  @doc """
  Deletes a single file, returning the updated filesystem.
  """
  @spec delete(fs(), String.t()) :: {:ok, fs()} | {:error, String.t()}
  def delete(fs, path) do
    case VFS.rm(fs, to_vfs(path)) do
      {:ok, fs} -> {:ok, fs}
      {:error, err} -> {:error, py_error(err, path)}
    end
  end

  @doc """
  Creates a directory and any missing parents. Best-effort: an existing
  directory is a no-op, and a path that can't be created leaves the
  filesystem unchanged rather than raising.
  """
  @spec mkdir_p(fs(), String.t()) :: {:ok, fs()}
  def mkdir_p(fs, path) do
    case VFS.mkdir(fs, to_vfs(path), parents: true) do
      {:ok, fs} -> {:ok, fs}
      {:error, _err} -> {:ok, fs}
    end
  end

  @doc """
  Recursively deletes a directory tree, returning the updated filesystem.
  """
  @spec delete_tree(fs(), String.t()) :: {:ok, fs()} | {:error, String.t()}
  def delete_tree(fs, path) do
    case VFS.rm(fs, to_vfs(path), recursive: true) do
      {:ok, fs} -> {:ok, fs}
      {:error, err} -> {:error, py_error(err, path)}
    end
  end

  @doc """
  Translates a `%VFS.Error{}` into the Python exception string Pyex surfaces,
  naming `path` in the caller's namespace.
  """
  @spec py_error(VFS.Error.t(), String.t()) :: String.t()
  def py_error(%VFS.Error{kind: kind}, path) do
    case kind do
      :enoent -> "FileNotFoundError: [Errno 2] No such file or directory: '#{path}'"
      :enotdir -> "NotADirectoryError: [Errno 20] Not a directory: '#{path}'"
      :eisdir -> "IsADirectoryError: [Errno 21] Is a directory: '#{path}'"
      :eexist -> "FileExistsError: [Errno 17] File exists: '#{path}'"
      :eacces -> "PermissionError: [Errno 13] Permission denied: '#{path}'"
      :erofs -> "OSError: [Errno 30] Read-only file system: '#{path}'"
      other -> "OSError: #{other}: '#{path}'"
    end
  end
end
