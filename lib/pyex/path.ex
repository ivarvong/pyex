defmodule Pyex.Path do
  @moduledoc """
  Filesystem and path helpers shared across Pyex APIs.

  The pure helpers (`join/1`, `basename/1`, `dirname/1`, `splitext/1`, …)
  operate on path strings alone. The filesystem helpers take a `VFS.Mountable`
  and the current working directory, resolve relative paths against it (see
  `Pyex.FS.resolve/2`), and thread the possibly-updated filesystem back out as
  the last element of their result — callers store it in `ctx.filesystem`.

  `walk/3` and `glob/3` resolve against the cwd for filesystem access but build
  their *output* paths in the caller's namespace, so `os.walk("/posts")` yields
  `/posts/...` and `os.walk("posts")` yields `posts/...`, matching CPython.
  """

  alias Pyex.FS

  @type fs :: VFS.Mountable.t()
  @type cwd :: VFS.Path.t()
  @type pathlike :: String.t() | term()

  # ── pure path-string helpers ──────────────────────────────────────────────

  @doc """
  Coerces a Python path-like value to a path string.
  """
  @spec coerce(pathlike()) :: {:ok, String.t()} | :error
  def coerce(path) when is_binary(path), do: {:ok, path}

  def coerce({:instance, {:class, "Path", _, _}, %{"__path__" => path}}) when is_binary(path) do
    {:ok, path}
  end

  def coerce(_), do: :error

  @doc """
  Joins path segments using Python-style path semantics.
  """
  @spec join([String.t()]) :: String.t()
  def join([]), do: ""
  def join(parts), do: Elixir.Path.join(parts)

  @doc """
  Returns the basename of a path.
  """
  @spec basename(String.t()) :: String.t()
  def basename(path), do: Elixir.Path.basename(path)

  @doc """
  Returns the dirname of a path.
  """
  @spec dirname(String.t()) :: String.t()
  def dirname(path), do: Elixir.Path.dirname(path)

  @doc """
  Splits a path into root and extension.
  """
  @spec splitext(String.t()) :: {String.t(), String.t()}
  def splitext(path) do
    base = basename(path)

    case splitext_basename(base) do
      {^base, ""} ->
        {path, ""}

      {root_base, ext} ->
        prefix = binary_part(path, 0, byte_size(path) - byte_size(base))
        {prefix <> root_base, ext}
    end
  end

  @doc """
  Returns the stem of a path.
  """
  @spec stem(String.t()) :: String.t()
  def stem(path) do
    {root, _ext} = splitext(path)
    basename(root)
  end

  @doc """
  Returns the suffix of a path.
  """
  @spec suffix(String.t()) :: String.t()
  def suffix(path) do
    {_root, ext} = splitext(path)
    ext
  end

  # ── filesystem helpers (cwd-aware, state-threading) ───────────────────────

  @doc """
  Returns `{exists?, fs}` for a path (file or directory).
  """
  @spec exists?(fs(), cwd(), String.t()) :: {boolean(), fs()}
  def exists?(fs, cwd, path), do: FS.exists(fs, cwd, path)

  @doc """
  Returns `{file?, fs}` — true when the path is a regular file.
  """
  @spec file?(fs(), cwd(), String.t()) :: {boolean(), fs()}
  def file?(fs, cwd, path) do
    case FS.stat(fs, cwd, path) do
      {:ok, :regular, fs} -> {true, fs}
      {:ok, _other, fs} -> {false, fs}
      {:error, _} -> {false, fs}
    end
  end

  @doc """
  Returns `{dir?, fs}` — true when the path behaves like a directory.
  """
  @spec dir?(fs(), cwd(), String.t()) :: {boolean(), fs()}
  def dir?(fs, cwd, path) do
    case FS.stat(fs, cwd, path) do
      {:ok, :directory, fs} -> {true, fs}
      {:ok, _other, fs} -> {false, fs}
      {:error, _} -> {false, fs}
    end
  end

  @doc """
  Lists a directory, returning `{:ok, names, fs}` or `{:error, reason}`.
  """
  @spec list_dir(fs(), cwd(), String.t()) :: {:ok, [String.t()], fs()} | {:error, String.t()}
  def list_dir(fs, cwd, path), do: FS.readdir(fs, cwd, path)

  @doc """
  Creates a directory and any missing parents.
  """
  @spec mkdir_p(fs(), cwd(), String.t()) :: {:ok, fs()} | {:error, String.t()}
  def mkdir_p(fs, cwd, path), do: FS.mkdir_p(fs, cwd, path)

  @doc """
  Deletes a file path.
  """
  @spec unlink(fs(), cwd(), String.t()) :: {:ok, fs()} | {:error, String.t()}
  def unlink(fs, cwd, path), do: FS.rm(fs, cwd, path)

  @doc """
  Deletes a directory tree.
  """
  @spec delete_tree(fs(), cwd(), String.t()) :: {:ok, fs()} | {:error, String.t()}
  def delete_tree(fs, cwd, path), do: FS.rm_rf(fs, cwd, path)

  @doc """
  Recursively walks a directory tree, returning `{:ok, entries, fs}` where each
  entry is a `{root, dirs, files}` triple in the caller's path namespace.
  """
  @spec walk(fs(), cwd(), String.t()) ::
          {:ok, [{String.t(), [String.t()], [String.t()]}], fs()} | {:error, String.t()}
  def walk(fs, cwd, path) do
    case dir?(fs, cwd, path) do
      {true, fs} ->
        {entries, fs} = do_walk(fs, cwd, normalize_dir(path))
        {:ok, entries, fs}

      {false, _fs} ->
        {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{path}'"}
    end
  end

  @doc """
  Copies a single file.
  """
  @spec copyfile(fs(), cwd(), String.t(), String.t()) :: {:ok, fs()} | {:error, String.t()}
  def copyfile(fs, cwd, src, dest) do
    with {:ok, content, fs} <- FS.read_file(fs, cwd, src),
         {:ok, fs} <- mkdir_p(fs, cwd, dirname(dest)),
         {:ok, fs} <- FS.write_file(fs, cwd, dest, content, :write) do
      {:ok, fs}
    end
  end

  @doc """
  Copies a directory tree.
  """
  @spec copytree(fs(), cwd(), String.t(), String.t()) :: {:ok, fs()} | {:error, String.t()}
  def copytree(fs, cwd, src, dest) do
    with {true, fs} <- dir?(fs, cwd, src),
         {:ok, fs} <- mkdir_p(fs, cwd, dest),
         {:ok, entries, fs} <- walk(fs, cwd, src) do
      Enum.reduce_while(entries, {:ok, fs}, fn {root, dirs, files}, {:ok, acc_fs} ->
        rel_root = relative_from(src, root)
        target_root = if rel_root == "", do: dest, else: join([dest, rel_root])

        with {:ok, acc_fs} <- mkdir_p(acc_fs, cwd, target_root),
             {:ok, acc_fs} <- ensure_dirs(acc_fs, cwd, target_root, dirs),
             {:ok, acc_fs} <- copy_files(acc_fs, cwd, target_root, files) do
          {:cont, {:ok, acc_fs}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      {false, _fs} -> {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{src}'"}
      {:error, _} = error -> error
    end
  end

  @doc """
  Moves a file or directory tree.
  """
  @spec move(fs(), cwd(), String.t(), String.t()) :: {:ok, fs()} | {:error, String.t()}
  def move(fs, cwd, src, dest) do
    case file?(fs, cwd, src) do
      {true, fs} ->
        with {:ok, fs} <- copyfile(fs, cwd, src, dest),
             {:ok, fs} <- unlink(fs, cwd, src) do
          {:ok, fs}
        end

      {false, fs} ->
        case dir?(fs, cwd, src) do
          {true, fs} ->
            with {:ok, fs} <- copytree(fs, cwd, src, dest),
                 {:ok, fs} <- delete_tree(fs, cwd, src) do
              {:ok, fs}
            end

          {false, _fs} ->
            {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{src}'"}
        end
    end
  end

  @doc """
  Expands a glob pattern against the filesystem, returning `{:ok, paths, fs}`.
  Output paths are in the pattern's namespace (absolute if the pattern was).
  """
  @spec glob(fs(), cwd(), String.t()) :: {:ok, [String.t()], fs()}
  def glob(fs, cwd, pattern) do
    absolute? = String.starts_with?(pattern, "/")

    segments =
      pattern
      |> String.trim_leading("/")
      |> String.split("/", trim: true)

    initial = if absolute?, do: "/", else: ""

    {paths, fs} = expand_glob(fs, cwd, [initial], segments)
    {:ok, paths |> Enum.reject(&(&1 == "")) |> Enum.uniq(), fs}
  end

  @doc """
  Returns true when a single path segment contains glob metacharacters.
  """
  @spec wildcard?(String.t()) :: boolean()
  def wildcard?(segment) do
    String.contains?(segment, ["*", "?"])
  end

  @doc """
  Returns true when a path segment matches a glob pattern.
  """
  @spec glob_match?(String.t(), String.t()) :: boolean()
  def glob_match?(name, pattern) do
    if String.starts_with?(name, ".") and not String.starts_with?(pattern, ".") do
      false
    else
      escaped =
        pattern
        |> Regex.escape()
        |> String.replace("\\*", "[^/]*")
        |> String.replace("\\?", "[^/]")

      Regex.match?(~r/\A#{escaped}\z/, name)
    end
  end

  # ── private ───────────────────────────────────────────────────────────────

  @spec splitext_basename(String.t()) :: {String.t(), String.t()}
  defp splitext_basename(base) do
    case last_dot_index(base) do
      nil ->
        {base, ""}

      idx ->
        if idx <= first_non_dot_index(base) do
          {base, ""}
        else
          {
            binary_part(base, 0, idx),
            binary_part(base, idx, byte_size(base) - idx)
          }
        end
    end
  end

  @spec last_dot_index(String.t()) :: non_neg_integer() | nil
  defp last_dot_index(base) do
    case :binary.matches(base, ".") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  @spec first_non_dot_index(String.t()) :: non_neg_integer()
  defp first_non_dot_index(base) do
    base
    |> String.to_charlist()
    |> Enum.find_index(&(&1 != ?.))
    |> Kernel.||(byte_size(base))
  end

  @spec expand_glob(fs(), cwd(), [String.t()], [String.t()]) :: {[String.t()], fs()}
  defp expand_glob(fs, _cwd, paths, []), do: {paths, fs}

  defp expand_glob(fs, cwd, paths, [segment | rest]) do
    {next_paths, fs} =
      Enum.reduce(paths, {[], fs}, fn current, {acc, fs} ->
        {expanded, fs} = expand_segment(fs, cwd, current, segment, rest == [])
        {acc ++ expanded, fs}
      end)

    expand_glob(fs, cwd, next_paths, rest)
  end

  @spec expand_segment(fs(), cwd(), String.t(), String.t(), boolean()) :: {[String.t()], fs()}
  defp expand_segment(fs, cwd, current, segment, final?) do
    cond do
      wildcard?(segment) ->
        case list_dir(fs, cwd, current) do
          {:ok, entries, fs} ->
            entries
            |> Enum.filter(&glob_match?(&1, segment))
            |> Enum.map(&join_glob_path(current, &1))
            |> Enum.reduce({[], fs}, fn path, {acc, fs} ->
              if final? do
                {acc ++ [path], fs}
              else
                case dir?(fs, cwd, path) do
                  {true, fs} -> {acc ++ [path], fs}
                  {false, fs} -> {acc, fs}
                end
              end
            end)

          {:error, _} ->
            {[], fs}
        end

      final? ->
        path = join_glob_path(current, segment)
        {exists, fs} = exists?(fs, cwd, path)
        {if(exists, do: [path], else: []), fs}

      true ->
        path = join_glob_path(current, segment)
        {is_dir, fs} = dir?(fs, cwd, path)
        {if(is_dir, do: [path], else: []), fs}
    end
  end

  @spec join_glob_path(String.t(), String.t()) :: String.t()
  defp join_glob_path("", entry), do: entry
  defp join_glob_path("/", entry), do: "/" <> entry
  defp join_glob_path(current, entry), do: join([current, entry])

  @spec normalize_dir(String.t()) :: String.t()
  defp normalize_dir(""), do: ""
  defp normalize_dir("/"), do: "/"
  defp normalize_dir(path), do: String.trim_trailing(path, "/")

  @spec do_walk(fs(), cwd(), String.t()) :: {[{String.t(), [String.t()], [String.t()]}], fs()}
  defp do_walk(fs, cwd, root) do
    {:ok, entries, fs} = list_dir(fs, cwd, root)

    {dirs, files, fs} =
      Enum.reduce(entries, {[], [], fs}, fn entry, {dirs, files, fs} ->
        full = join_glob_path(root, entry)

        case dir?(fs, cwd, full) do
          {true, fs} -> {[entry | dirs], files, fs}
          {false, fs} -> {dirs, [full | files], fs}
        end
      end)

    dirs = Enum.sort(dirs)
    files = Enum.sort(files)

    {child_entries, fs} =
      Enum.reduce(dirs, {[], fs}, fn dir, {acc, fs} ->
        {sub, fs} = do_walk(fs, cwd, join_glob_path(root, dir))
        {acc ++ sub, fs}
      end)

    {[{root, dirs, files} | child_entries], fs}
  end

  @spec relative_from(String.t(), String.t()) :: String.t()
  defp relative_from(src, root) do
    src = normalize_dir(src)
    root = normalize_dir(root)

    cond do
      root == src -> ""
      String.starts_with?(root, src <> "/") -> String.replace_prefix(root, src <> "/", "")
      true -> root
    end
  end

  @spec ensure_dirs(fs(), cwd(), String.t(), [String.t()]) :: {:ok, fs()} | {:error, String.t()}
  defp ensure_dirs(fs, cwd, root, dirs) do
    Enum.reduce_while(dirs, {:ok, fs}, fn dir, {:ok, acc_fs} ->
      case mkdir_p(acc_fs, cwd, join([root, dir])) do
        {:ok, acc_fs} -> {:cont, {:ok, acc_fs}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @spec copy_files(fs(), cwd(), String.t(), [String.t()]) :: {:ok, fs()} | {:error, String.t()}
  defp copy_files(fs, cwd, target_root, files) do
    Enum.reduce_while(files, {:ok, fs}, fn src_file, {:ok, acc_fs} ->
      dest = join([target_root, basename(src_file)])

      case copyfile(acc_fs, cwd, src_file, dest) do
        {:ok, acc_fs} -> {:cont, {:ok, acc_fs}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
