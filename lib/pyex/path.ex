defmodule Pyex.Path do
  @moduledoc """
  Filesystem and path helpers shared across Pyex APIs.
  """

  @type pathlike :: String.t() | term()

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

  @doc """
  Returns true when the path exists.
  """
  @spec exists?(term(), String.t()) :: boolean()
  def exists?(fs, path) do
    file?(fs, path) or dir?(fs, path)
  end

  @doc """
  Returns true when the path exists and is a regular file.
  """
  @spec file?(term(), String.t()) :: boolean()
  def file?(fs, path) do
    match?({:ok, _}, fs.__struct__.read(fs, path))
  end

  @doc """
  Returns true when the path exists and behaves like a directory.
  """
  @spec dir?(term(), String.t()) :: boolean()
  def dir?(fs, path) do
    case fs.__struct__.list_dir(fs, path) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Lists a directory, returning child names.
  """
  @spec list_dir(term(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_dir(fs, path) do
    fs.__struct__.list_dir(fs, path)
  end

  @doc """
  Creates a directory and any missing parents.
  """
  @spec mkdir_p(term(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def mkdir_p(%Pyex.Filesystem.Memory{} = fs, path), do: Pyex.Filesystem.Memory.mkdir(fs, path)
  def mkdir_p(fs, _path), do: {:ok, fs}

  @doc """
  Deletes a file path.
  """
  @spec unlink(term(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def unlink(fs, path), do: fs.__struct__.delete(fs, path)

  @doc """
  Deletes a directory tree.
  """
  @spec delete_tree(term(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def delete_tree(%Pyex.Filesystem.Memory{} = fs, path),
    do: Pyex.Filesystem.Memory.delete_tree(fs, path)

  def delete_tree(fs, path) do
    case walk(fs, path) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn {_root, _dirs, files} -> files end)
        |> Enum.reduce_while({:ok, fs}, fn file, {:ok, acc_fs} ->
          case unlink(acc_fs, file) do
            {:ok, acc_fs} -> {:cont, {:ok, acc_fs}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Recursively walks a directory tree.
  """
  @spec walk(term(), String.t()) ::
          {:ok, [{String.t(), [String.t()], [String.t()]}]} | {:error, String.t()}
  def walk(fs, path) do
    if dir?(fs, path) do
      {:ok, do_walk(fs, normalize_dir(path))}
    else
      {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{path}'"}
    end
  end

  @doc """
  Copies a single file.
  """
  @spec copyfile(term(), String.t(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def copyfile(fs, src, dest) do
    with {:ok, content} <- fs.__struct__.read(fs, src),
         {:ok, fs} <- mkdir_p(fs, dirname(dest)),
         {:ok, fs} <- fs.__struct__.write(fs, dest, content, :write) do
      {:ok, fs}
    end
  end

  @doc """
  Copies a directory tree.
  """
  @spec copytree(term(), String.t(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def copytree(fs, src, dest) do
    with true <- dir?(fs, src),
         {:ok, fs} <- mkdir_p(fs, dest),
         {:ok, entries} <- walk(fs, src) do
      Enum.reduce_while(entries, {:ok, fs}, fn {root, dirs, files}, {:ok, acc_fs} ->
        rel_root = relative_from(src, root)
        target_root = if rel_root == "", do: dest, else: join([dest, rel_root])

        with {:ok, acc_fs} <- mkdir_p(acc_fs, target_root),
             {:ok, acc_fs} <- ensure_dirs(acc_fs, target_root, dirs),
             {:ok, acc_fs} <- copy_files(acc_fs, root, target_root, files) do
          {:cont, {:ok, acc_fs}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      false -> {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{src}'"}
      {:error, _} = error -> error
    end
  end

  @doc """
  Moves a file or directory tree.
  """
  @spec move(term(), String.t(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def move(fs, src, dest) do
    cond do
      file?(fs, src) ->
        with {:ok, fs} <- copyfile(fs, src, dest),
             {:ok, fs} <- unlink(fs, src) do
          {:ok, fs}
        end

      dir?(fs, src) ->
        with {:ok, fs} <- copytree(fs, src, dest),
             {:ok, fs} <- delete_tree(fs, src) do
          {:ok, fs}
        end

      true ->
        {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{src}'"}
    end
  end

  @doc """
  Expands a glob pattern against the configured filesystem.
  """
  @spec glob(term(), String.t()) :: {:ok, [String.t()]}
  def glob(fs, pattern) do
    absolute? = String.starts_with?(pattern, "/")

    segments =
      pattern
      |> String.trim_leading("/")
      |> String.split("/", trim: true)

    initial = if absolute?, do: "/", else: ""

    {:ok, expand_glob(fs, [initial], segments)}
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

  @spec expand_glob(term(), [String.t()], [String.t()]) :: [String.t()]
  defp expand_glob(_fs, paths, []), do: paths |> Enum.reject(&(&1 == "")) |> Enum.uniq()

  defp expand_glob(fs, paths, [segment | rest]) do
    next_paths =
      Enum.flat_map(paths, fn current ->
        expand_segment(fs, current, segment, rest == [])
      end)

    expand_glob(fs, next_paths, rest)
  end

  @spec expand_segment(term(), String.t(), String.t(), boolean()) :: [String.t()]
  defp expand_segment(fs, current, segment, final?) do
    cond do
      wildcard?(segment) ->
        case fs.__struct__.list_dir(fs, current) do
          {:ok, entries} ->
            entries
            |> Enum.filter(&glob_match?(&1, segment))
            |> Enum.map(&join_glob_path(current, &1))
            |> Enum.filter(fn path -> final? or dir?(fs, path) end)

          {:error, _} ->
            []
        end

      final? ->
        path = join_glob_path(current, segment)
        if fs.__struct__.exists?(fs, path), do: [path], else: []

      true ->
        path = join_glob_path(current, segment)
        if dir?(fs, path), do: [path], else: []
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

  @spec do_walk(term(), String.t()) :: [{String.t(), [String.t()], [String.t()]}]
  defp do_walk(fs, root) do
    {:ok, entries} = list_dir(fs, root)

    {dirs, files} =
      Enum.reduce(entries, {[], []}, fn entry, {dirs, files} ->
        full = join_glob_path(root, entry)

        if dir?(fs, full) do
          {[entry | dirs], files}
        else
          {dirs, [full | files]}
        end
      end)

    dirs = Enum.sort(dirs)
    files = Enum.sort(files)
    [{root, dirs, files} | Enum.flat_map(dirs, &do_walk(fs, join_glob_path(root, &1)))]
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

  @spec ensure_dirs(term(), String.t(), [String.t()]) :: {:ok, term()} | {:error, String.t()}
  defp ensure_dirs(fs, root, dirs) do
    {:ok,
     Enum.reduce(dirs, fs, fn dir, acc_fs ->
       {:ok, acc_fs} = mkdir_p(acc_fs, join([root, dir]))
       acc_fs
     end)}
  end

  @spec copy_files(term(), String.t(), String.t(), [String.t()]) ::
          {:ok, term()} | {:error, String.t()}
  defp copy_files(fs, root, target_root, files) do
    Enum.reduce_while(files, {:ok, fs}, fn src_file, {:ok, acc_fs} ->
      file_name = basename(src_file)
      src = if root in ["", "/"], do: src_file, else: src_file
      dest = join([target_root, file_name])

      case copyfile(acc_fs, src, dest) do
        {:ok, acc_fs} -> {:cont, {:ok, acc_fs}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
