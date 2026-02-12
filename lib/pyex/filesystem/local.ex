defmodule Pyex.Filesystem.Local do
  @moduledoc """
  Local filesystem backend with sandboxing.

  All operations are confined to a root directory. Path traversal
  attacks (`../` etc.) are blocked by resolving the full path and
  verifying it stays within the root.
  """

  @behaviour Pyex.Filesystem

  @type t :: %__MODULE__{root: String.t()}

  defstruct [:root]

  @doc """
  Creates a new local filesystem rooted at the given directory.

  The directory must exist.
  """
  @spec new(String.t()) :: t()
  def new(root) when is_binary(root) do
    %__MODULE__{root: Path.expand(root)}
  end

  @impl Pyex.Filesystem
  @spec read(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(%__MODULE__{} = fs, path) do
    with {:ok, full} <- safe_path(fs, path) do
      case File.read(full) do
        {:ok, content} ->
          {:ok, content}

        {:error, :enoent} ->
          {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{path}'"}

        {:error, reason} ->
          {:error, "IOError: #{inspect(reason)}"}
      end
    end
  end

  @impl Pyex.Filesystem
  @spec write(t(), String.t(), String.t(), Pyex.Filesystem.mode()) ::
          {:ok, t()} | {:error, String.t()}
  def write(%__MODULE__{} = fs, path, content, mode) do
    with {:ok, full} <- safe_path(fs, path),
         :ok <- mkdir_p_safe(Path.dirname(full)) do
      file_mode =
        case mode do
          :write -> [:write]
          :append -> [:append]
        end

      case File.open(full, file_mode) do
        {:ok, device} ->
          IO.write(device, content)
          File.close(device)
          {:ok, fs}

        {:error, reason} ->
          {:error, "IOError: #{inspect(reason)}"}
      end
    end
  end

  @impl Pyex.Filesystem
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{} = fs, path) do
    case safe_path(fs, path) do
      {:ok, full} -> File.exists?(full)
      {:error, _} -> false
    end
  end

  @impl Pyex.Filesystem
  @spec list_dir(t(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_dir(%__MODULE__{} = fs, path) do
    with {:ok, full} <- safe_path(fs, path) do
      case File.ls(full) do
        {:ok, entries} ->
          {:ok, Enum.sort(entries)}

        {:error, :enoent} ->
          {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{path}'"}

        {:error, reason} ->
          {:error, "IOError: #{inspect(reason)}"}
      end
    end
  end

  @impl Pyex.Filesystem
  @spec delete(t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def delete(%__MODULE__{} = fs, path) do
    with {:ok, full} <- safe_path(fs, path) do
      case File.rm(full) do
        :ok ->
          {:ok, fs}

        {:error, :enoent} ->
          {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{path}'"}

        {:error, reason} ->
          {:error, "IOError: #{inspect(reason)}"}
      end
    end
  end

  @spec mkdir_p_safe(String.t()) :: :ok | {:error, String.t()}
  defp mkdir_p_safe(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "IOError: #{inspect(reason)}"}
    end
  end

  @spec safe_path(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp safe_path(%__MODULE__{root: root}, path) do
    full = Path.expand(path, root)

    unless String.starts_with?(full, root <> "/") or full == root do
      {:error, "PermissionError: path traversal blocked: '#{path}'"}
    else
      case resolve_real_path(full) do
        {:ok, real} ->
          if String.starts_with?(real, root <> "/") or real == root do
            {:ok, full}
          else
            {:error, "PermissionError: path traversal blocked: '#{path}'"}
          end

        :enoent ->
          parent = Path.dirname(full)

          case resolve_real_path(parent) do
            {:ok, real_parent} ->
              if String.starts_with?(real_parent, root) do
                {:ok, full}
              else
                {:error, "PermissionError: path traversal blocked: '#{path}'"}
              end

            :enoent ->
              {:ok, full}
          end
      end
    end
  end

  @spec resolve_real_path(String.t()) :: {:ok, String.t()} | :enoent
  defp resolve_real_path(path) do
    case :file.read_link_info(String.to_charlist(path)) do
      {:ok, {:file_info, _, :symlink, _, _, _, _, _, _, _, _, _, _, _}} ->
        case :file.read_link(String.to_charlist(path)) do
          {:ok, target} ->
            resolved = Path.expand(List.to_string(target), Path.dirname(path))
            resolve_real_path(resolved)

          _ ->
            :enoent
        end

      {:ok, _} ->
        {:ok, path}

      {:error, :enoent} ->
        :enoent
    end
  end
end
