defmodule Pyex.FS do
  @moduledoc """
  Pyex's filesystem boundary over a [`VFS.Mountable`](https://hexdocs.pm/vfs).

  The interpreter stores a `VFS.Mountable` (a `%VFS{}` mount table, a bare
  `VFS.Memory`, an S3 backend, or any conformant struct) in `Pyex.Ctx`'s
  `:filesystem` field, and a current working directory in `:cwd`. This module
  is the single place that reconciles Pyex's world with VFS's:

    * **Paths.** Python code uses cwd-relative paths (`open("data.txt")`,
      `os.listdir("posts")`). `resolve/2` turns a Python path into an
      absolute, normalized VFS path: an absolute path (leading `/`) is taken
      as-is; a relative path is joined onto the cwd. With the default cwd of
      `"/"` this matches how Pyex has always behaved, but a non-root cwd (as a
      shell sharing the same `%VFS{}` would set) now resolves correctly —
      `open("data.txt")` under cwd `/project` reads `/project/data.txt`.

    * **State threading.** VFS is immutable: every op returns the
      possibly-updated filesystem as the last element of its success tuple, so
      lazy/caching backends and `%VFS{}` mount tables stay coherent. Every
      function here that touches a backend — reads included — returns that
      updated value, and callers thread it back into `ctx.filesystem`. Nothing
      drops it on the floor.

    * **Errors.** VFS returns `%VFS.Error{kind: atom}`; Pyex surfaces Python
      exception strings (`"FileNotFoundError: [Errno 2] ..."`). `py_error/2`
      maps between them, naming the path as the caller wrote it.
  """

  @type fs :: VFS.Mountable.t()
  @type cwd :: VFS.Path.t()
  @type mode :: :read | :write | :append

  @root "/"

  # ── construction ──────────────────────────────────────────────────────────

  @doc """
  Builds an in-memory filesystem, optionally seeded with files. Alias for
  `from_map/1`.
  """
  @spec new(%{optional(String.t()) => binary()}) :: VFS.Memory.t()
  def new(files \\ %{}) when is_map(files), do: from_map(files)

  @doc """
  Wraps a `%{path => content}` map as a seeded `VFS.Memory` backend.

  Keys are treated as absolute filesystem locations (rooted at `/`), so
  `%{"posts/a.md" => ...}` seeds `/posts/a.md`. Raises `ArgumentError` (with a
  Pyex-flavored message) if the seed is internally inconsistent — a path that
  is both a file and a directory, or a literal `"/"` key.
  """
  @spec from_map(%{optional(String.t()) => binary()}) :: VFS.Memory.t()
  def from_map(files \\ %{}) when is_map(files) do
    files
    |> Map.new(fn {path, content} -> {to_vfs(path), content} end)
    |> VFS.Memory.new()
  rescue
    e in ArgumentError ->
      reraise ArgumentError,
              "invalid filesystem seed: #{Exception.message(e)}",
              __STACKTRACE__
  end

  # ── path resolution ───────────────────────────────────────────────────────

  @doc """
  Resolves a Python path against `cwd` into an absolute, normalized VFS path.

  An absolute path (leading `/`) ignores the cwd; a relative path is joined
  onto it; the empty path is the cwd itself.

  ## Examples

      iex> Pyex.FS.resolve("/project", "data.txt")
      "/project/data.txt"

      iex> Pyex.FS.resolve("/project", "/etc/hosts")
      "/etc/hosts"

      iex> Pyex.FS.resolve("/a/b", "../c")
      "/a/c"
  """
  @spec resolve(cwd(), String.t()) :: VFS.Path.t()
  def resolve(cwd, "" = _path), do: VFS.Path.normalize(cwd)
  def resolve(_cwd, "/" <> _ = path), do: VFS.Path.normalize(path)
  def resolve(cwd, path), do: VFS.Path.join(VFS.Path.normalize(cwd), path)

  @doc """
  Roots a path at `/` without reference to any cwd. Used for seed-map keys,
  which are absolute filesystem locations.

  ## Examples

      iex> Pyex.FS.to_vfs("posts/a.md")
      "/posts/a.md"

      iex> Pyex.FS.to_vfs("")
      "/"
  """
  @spec to_vfs(String.t()) :: VFS.Path.t()
  def to_vfs(path) when is_binary(path), do: resolve(@root, path)

  # ── threaded, cwd-aware primitives ────────────────────────────────────────

  @doc """
  Reads a file, threading back the (possibly cache-updated) filesystem.
  """
  @spec read_file(fs(), cwd(), String.t()) :: {:ok, binary(), fs()} | {:error, String.t()}
  def read_file(fs, cwd, path) do
    case VFS.read_file(fs, resolve(cwd, path)) do
      {:ok, content, fs} -> {:ok, content, fs}
      {:error, err} -> {:error, py_error(err, path)}
    end
  end

  @doc """
  Writes content to a file. Mode `:write` truncates, `:append` concatenates
  onto the existing contents (a missing file reads as empty).
  """
  @spec write_file(fs(), cwd(), String.t(), binary(), mode()) ::
          {:ok, fs()} | {:error, String.t()}
  def write_file(fs, cwd, path, content, mode) do
    vpath = resolve(cwd, path)

    with {:ok, data, fs} <- write_payload(fs, vpath, content, mode, path) do
      case VFS.write_file(fs, vpath, data) do
        {:ok, fs} -> {:ok, fs}
        {:error, err} -> {:error, py_error(err, path)}
      end
    end
  end

  @spec write_payload(fs(), VFS.Path.t(), binary(), mode(), String.t()) ::
          {:ok, binary(), fs()} | {:error, String.t()}
  defp write_payload(fs, _vpath, content, :write, _path), do: {:ok, content, fs}

  defp write_payload(fs, vpath, content, :append, path) do
    case VFS.read_file(fs, vpath) do
      {:ok, existing, fs} -> {:ok, existing <> content, fs}
      {:error, %VFS.Error{kind: :enoent}} -> {:ok, content, fs}
      {:error, err} -> {:error, py_error(err, path)}
    end
  end

  @doc """
  Returns whether a path exists, threading back the filesystem.
  """
  @spec exists(fs(), cwd(), String.t()) :: {boolean(), fs()}
  def exists(fs, cwd, path), do: VFS.exists?(fs, resolve(cwd, path))

  @doc """
  Returns the entry type at `path` (`:regular` or `:directory`), threading the
  filesystem.
  """
  @spec stat(fs(), cwd(), String.t()) ::
          {:ok, VFS.Stat.type(), fs()} | {:error, String.t()}
  def stat(fs, cwd, path) do
    case VFS.stat(fs, resolve(cwd, path)) do
      {:ok, %VFS.Stat{type: type}, fs} -> {:ok, type, fs}
      {:error, err} -> {:error, py_error(err, path)}
    end
  end

  @doc """
  Lists the entry names directly under a directory, threading the filesystem.
  """
  @spec readdir(fs(), cwd(), String.t()) ::
          {:ok, [String.t()], fs()} | {:error, String.t()}
  def readdir(fs, cwd, path) do
    case VFS.readdir(fs, resolve(cwd, path)) do
      # `VFS.readdir` may return a Stream for paginated/unbounded backends; the
      # interpreter materializes it here because `os.listdir`/`iterdir` are
      # eager. A backend with genuinely unbounded listings would need a lazy
      # path — none of Pyex's backends (Memory, S3) are unbounded.
      {:ok, names, fs} -> {:ok, Enum.to_list(names), fs}
      {:error, err} -> {:error, py_error(err, path)}
    end
  end

  @doc """
  Deletes a single file, returning the updated filesystem.
  """
  @spec rm(fs(), cwd(), String.t()) :: {:ok, fs()} | {:error, String.t()}
  def rm(fs, cwd, path) do
    case VFS.rm(fs, resolve(cwd, path)) do
      {:ok, fs} -> {:ok, fs}
      {:error, err} -> {:error, py_error(err, path)}
    end
  end

  @doc """
  Creates a directory and any missing parents. An existing directory is a
  no-op; a genuine failure (e.g. an ancestor that is a file) surfaces.
  """
  @spec mkdir_p(fs(), cwd(), String.t()) :: {:ok, fs()} | {:error, String.t()}
  def mkdir_p(fs, cwd, path) do
    case VFS.mkdir(fs, resolve(cwd, path), parents: true) do
      {:ok, fs} -> {:ok, fs}
      {:error, err} -> {:error, py_error(err, path)}
    end
  end

  @doc """
  Recursively deletes a directory tree, returning the updated filesystem.
  """
  @spec rm_rf(fs(), cwd(), String.t()) :: {:ok, fs()} | {:error, String.t()}
  def rm_rf(fs, cwd, path) do
    case VFS.rm(fs, resolve(cwd, path), recursive: true) do
      {:ok, fs} -> {:ok, fs}
      {:error, err} -> {:error, py_error(err, path)}
    end
  end

  # ── inspection convenience ────────────────────────────────────────────────
  #
  # Root-relative (cwd = "/"), filesystem-dropping wrappers over the threaded
  # primitives above, mirroring the shapes the interpreter relied on before the
  # VFS migration. Convenient for seeding fixtures and inspecting a final
  # filesystem state; the interpreter itself uses the threaded `*_file` /
  # `exists` / `readdir` / `rm` forms so no backend state is lost.

  @doc """
  Reads a file rooted at `/`, returning just `{:ok, content}`.
  """
  @spec read(fs(), String.t()) :: {:ok, binary()} | {:error, String.t()}
  def read(fs, path) do
    case read_file(fs, @root, path) do
      {:ok, content, _fs} -> {:ok, content}
      {:error, _} = err -> err
    end
  end

  @doc """
  Writes a file rooted at `/`, returning the updated filesystem.
  """
  @spec write(fs(), String.t(), binary(), mode()) :: {:ok, fs()} | {:error, String.t()}
  def write(fs, path, content, mode), do: write_file(fs, @root, path, content, mode)

  @doc """
  Returns whether a path (rooted at `/`) exists.
  """
  @spec exists?(fs(), String.t()) :: boolean()
  def exists?(fs, path) do
    {exists, _fs} = exists(fs, @root, path)
    exists
  end

  @doc """
  Lists a directory rooted at `/`, returning just `{:ok, names}`.
  """
  @spec list_dir(fs(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_dir(fs, path) do
    case readdir(fs, @root, path) do
      {:ok, names, _fs} -> {:ok, names}
      {:error, _} = err -> err
    end
  end

  @doc """
  Deletes a file rooted at `/`, returning the updated filesystem.
  """
  @spec delete(fs(), String.t()) :: {:ok, fs()} | {:error, String.t()}
  def delete(fs, path), do: rm(fs, @root, path)

  # ── error mapping ─────────────────────────────────────────────────────────

  @doc """
  Translates a `%VFS.Error{}` into the Python exception string Pyex surfaces,
  naming `path` in the caller's namespace.

  Every `t:VFS.Error.kind/0` maps to a concrete CPython exception with its
  POSIX errno. Kinds that carry a backend-specific `:message` (e.g. an S3
  `:eio` with the failing HTTP status) append it in parentheses so the cause
  survives into the traceback.

  Also emits a `[:pyex, :fs, :error]` telemetry event carrying the structured
  `%{kind, mount, vfs_path, path}` — the flattened Python string loses the kind
  and which mount failed, so this is the channel to recover them for logging or
  metrics. Errors are cold, so the unconditional emit is cheap.
  """
  @spec py_error(VFS.Error.t(), String.t()) :: String.t()
  def py_error(%VFS.Error{kind: kind, mount: mount, path: vfs_path} = error, path) do
    :telemetry.execute(
      [:pyex, :fs, :error],
      %{},
      %{kind: kind, mount: mount, vfs_path: vfs_path, path: path}
    )

    base =
      case kind do
        :enoent -> "FileNotFoundError: [Errno 2] No such file or directory: '#{path}'"
        :enotdir -> "NotADirectoryError: [Errno 20] Not a directory: '#{path}'"
        :eisdir -> "IsADirectoryError: [Errno 21] Is a directory: '#{path}'"
        :eexist -> "FileExistsError: [Errno 17] File exists: '#{path}'"
        :eacces -> "PermissionError: [Errno 13] Permission denied: '#{path}'"
        :erofs -> "OSError: [Errno 30] Read-only file system: '#{path}'"
        :exdev -> "OSError: [Errno 18] Invalid cross-device link: '#{path}'"
        :einval -> "OSError: [Errno 22] Invalid argument: '#{path}'"
        :eio -> "OSError: [Errno 5] Input/output error: '#{path}'"
        :enotsup -> "OSError: [Errno 95] Operation not supported: '#{path}'"
        :eloop -> "OSError: [Errno 40] Too many levels of symbolic links: '#{path}'"
      end

    base <> detail(error)
  end

  # Append a backend-specific message (e.g. "S3 returned 500") so the cause
  # reaches the traceback, but not VFS.Error's auto-generated default. The
  # default is recomputed *by vfs* for the same kind/path rather than
  # reconstructing its format here, so a change to vfs's default wording can't
  # silently start appending a redundant suffix.
  @spec detail(VFS.Error.t()) :: String.t()
  defp detail(%VFS.Error{kind: kind, path: epath, message: message})
       when is_binary(message) do
    default = VFS.Error.message(VFS.Error.new(kind, path: epath))
    if message == default, do: "", else: " (#{message})"
  end

  defp detail(_error), do: ""
end
