defmodule Pyex.Filesystem.Memory do
  @moduledoc """
  In-memory filesystem backend.

  Stores files as a map of path strings to content strings and keeps an
  explicit directory set so empty directories can exist.
  """

  @behaviour Pyex.Filesystem

  @type t :: %__MODULE__{
          files: %{optional(String.t()) => String.t()},
          dirs: MapSet.t(String.t())
        }

  defstruct files: %{}, dirs: MapSet.new([""])

  @doc """
  Creates a new empty in-memory filesystem.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates an in-memory filesystem pre-populated with files.
  """
  @spec new(%{optional(String.t()) => String.t()}) :: t()
  def new(files) when is_map(files) do
    normalized = Map.new(files, fn {path, content} -> {normalize(path), content} end)
    %__MODULE__{files: normalized, dirs: derive_dirs(normalized)}
  end

  @impl Pyex.Filesystem
  @spec read(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(%__MODULE__{files: files}, path) do
    case Map.fetch(files, normalize(path)) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{path}'"}
    end
  end

  @impl Pyex.Filesystem
  @spec write(t(), String.t(), String.t(), Pyex.Filesystem.mode()) ::
          {:ok, t()} | {:error, String.t()}
  def write(%__MODULE__{files: files, dirs: dirs} = fs, path, content, mode) do
    normalized = normalize(path)

    new_content =
      case mode do
        :write -> content
        :append -> Map.get(files, normalized, "") <> content
      end

    {:ok,
     %{
       fs
       | files: Map.put(files, normalized, new_content),
         dirs: MapSet.union(dirs, parent_dirs(normalized))
     }}
  end

  @impl Pyex.Filesystem
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{files: files, dirs: dirs}, path) do
    normalized = normalize(path)

    normalized == "" or Map.has_key?(files, normalized) or MapSet.member?(dirs, normalized)
  end

  @impl Pyex.Filesystem
  @spec list_dir(t(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_dir(%__MODULE__{files: files, dirs: dirs}, path) do
    normalized = normalize(path)

    cond do
      normalized != "" and Map.has_key?(files, normalized) and
          not MapSet.member?(dirs, normalized) ->
        {:error, "NotADirectoryError: [Errno 20] Not a directory: '#{path}'"}

      normalized != "" and not MapSet.member?(dirs, normalized) ->
        {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{path}'"}

      true ->
        prefix = if normalized == "", do: "", else: normalized <> "/"

        file_entries =
          files
          |> Map.keys()
          |> Enum.filter(&String.starts_with?(&1, prefix))
          |> Enum.map(&entry_name(&1, prefix))

        dir_entries =
          dirs
          |> Enum.reject(&(&1 in ["", normalized]))
          |> Enum.filter(&String.starts_with?(&1, prefix))
          |> Enum.map(&entry_name(&1, prefix))

        {:ok,
         (file_entries ++ dir_entries)
         |> Enum.reject(&(&1 == ""))
         |> Enum.uniq()
         |> Enum.sort()}
    end
  end

  @impl Pyex.Filesystem
  @spec delete(t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def delete(%__MODULE__{files: files} = fs, path) do
    normalized = normalize(path)

    if Map.has_key?(files, normalized) do
      {:ok, %{fs | files: Map.delete(files, normalized)}}
    else
      {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{path}'"}
    end
  end

  @doc """
  Creates a directory and any missing parents.
  """
  @spec mkdir(t(), String.t()) :: {:ok, t()}
  def mkdir(%__MODULE__{dirs: dirs} = fs, path) do
    normalized = normalize(path)
    {:ok, %{fs | dirs: MapSet.union(dirs, path_and_parent_dirs(normalized))}}
  end

  @doc """
  Deletes a directory tree and all nested files.
  """
  @spec delete_tree(t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def delete_tree(%__MODULE__{files: files, dirs: dirs} = fs, path) do
    normalized = normalize(path)

    cond do
      normalized == "" ->
        {:ok, %__MODULE__{}}

      not MapSet.member?(dirs, normalized) ->
        {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{path}'"}

      true ->
        new_files =
          Map.reject(files, fn {file, _} ->
            file == normalized or String.starts_with?(file, normalized <> "/")
          end)

        new_dirs =
          dirs
          |> Enum.reject(fn dir ->
            dir == normalized or String.starts_with?(dir, normalized <> "/")
          end)
          |> MapSet.new()

        {:ok, %{fs | files: new_files, dirs: MapSet.put(new_dirs, "")}}
    end
  end

  @spec normalize(String.t()) :: String.t()
  defp normalize(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
  end

  @spec derive_dirs(%{optional(String.t()) => String.t()}) :: MapSet.t(String.t())
  defp derive_dirs(files) do
    Enum.reduce(files, MapSet.new([""]), fn {path, _}, acc ->
      MapSet.union(acc, parent_dirs(path))
    end)
  end

  @spec parent_dirs(String.t()) :: MapSet.t(String.t())
  defp parent_dirs(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.drop(-1)
    |> Enum.reduce({MapSet.new([""]), []}, fn segment, {acc, prefix} ->
      prefix = prefix ++ [segment]
      {MapSet.put(acc, Enum.join(prefix, "/")), prefix}
    end)
    |> elem(0)
  end

  @spec path_and_parent_dirs(String.t()) :: MapSet.t(String.t())
  defp path_and_parent_dirs(path) do
    MapSet.put(parent_dirs(path), path)
  end

  @spec entry_name(String.t(), String.t()) :: String.t()
  defp entry_name(full_path, prefix) do
    rest = String.replace_prefix(full_path, prefix, "")

    case String.split(rest, "/", parts: 2) do
      [name | _] -> name
      _ -> rest
    end
  end
end
