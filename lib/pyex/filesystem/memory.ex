defmodule Pyex.Filesystem.Memory do
  @moduledoc """
  In-memory filesystem backend.

  Stores files as a map of path strings to content strings.
  Fully serializable — suitable for use with `Pyex.Ctx`.
  Directories are implicit (a file at "a/b/c.txt" implies "a/"
  and "a/b/" exist).
  """

  @behaviour Pyex.Filesystem

  @type t :: %__MODULE__{files: %{optional(String.t()) => String.t()}}

  defstruct files: %{}

  @doc """
  Creates a new empty in-memory filesystem.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates an in-memory filesystem pre-populated with files.
  """
  @spec new(%{optional(String.t()) => String.t()}) :: t()
  def new(files) when is_map(files), do: %__MODULE__{files: files}

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
  def write(%__MODULE__{files: files} = fs, path, content, mode) do
    normalized = normalize(path)

    new_content =
      case mode do
        :write ->
          content

        :append ->
          existing = Map.get(files, normalized, "")
          existing <> content
      end

    {:ok, %{fs | files: Map.put(files, normalized, new_content)}}
  end

  @impl Pyex.Filesystem
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{files: files}, path) do
    normalized = normalize(path)

    Map.has_key?(files, normalized) or
      Enum.any?(files, fn {k, _v} -> String.starts_with?(k, normalized <> "/") end)
  end

  @impl Pyex.Filesystem
  @spec list_dir(t(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_dir(%__MODULE__{files: files}, path) do
    prefix =
      case normalize(path) do
        "" -> ""
        p -> p <> "/"
      end

    entries =
      files
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.map(fn full_path ->
        rest = String.replace_prefix(full_path, prefix, "")

        case String.split(rest, "/", parts: 2) do
          [name | _] -> name
          _ -> rest
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, entries}
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

  @spec normalize(String.t()) :: String.t()
  defp normalize(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
  end
end
