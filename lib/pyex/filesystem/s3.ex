defmodule Pyex.Filesystem.S3 do
  @moduledoc """
  S3-backed filesystem using pre-signed URLs via Req.

  All paths are prefixed with a configurable key prefix within
  a single bucket. Uses the standard AWS signature v4 via
  environment credentials.
  """

  @behaviour Pyex.Filesystem

  @type t :: %__MODULE__{
          bucket: String.t(),
          prefix: String.t(),
          region: String.t()
        }

  defstruct [:bucket, :prefix, :region]

  @doc """
  Creates a new S3 filesystem backend.

  Options:
  - `:bucket` (required) -- S3 bucket name
  - `:prefix` -- key prefix, default `""`
  - `:region` -- AWS region, default `"us-east-1"`
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      bucket: Keyword.fetch!(opts, :bucket),
      prefix: Keyword.get(opts, :prefix, ""),
      region: Keyword.get(opts, :region, "us-east-1")
    }
  end

  @impl Pyex.Filesystem
  @spec read(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(%__MODULE__{} = fs, path) do
    url = object_url(fs, path)

    case Req.get(url, aws_sigv4: aws_opts(fs)) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{path}'"}

      {:ok, %{status: status, body: body}} ->
        {:error, "IOError: S3 returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "IOError: #{inspect(reason)}"}
    end
  end

  @impl Pyex.Filesystem
  @spec write(t(), String.t(), String.t(), Pyex.Filesystem.mode()) ::
          {:ok, t()} | {:error, String.t()}
  def write(%__MODULE__{} = fs, path, content, mode) do
    full_content =
      case mode do
        :write ->
          content

        :append ->
          case read(fs, path) do
            {:ok, existing} -> existing <> content
            {:error, _} -> content
          end
      end

    url = object_url(fs, path)

    case Req.put(url, body: full_content, aws_sigv4: aws_opts(fs)) do
      {:ok, %{status: status}} when status in [200, 201] ->
        {:ok, fs}

      {:ok, %{status: status, body: body}} ->
        {:error, "IOError: S3 PUT returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "IOError: #{inspect(reason)}"}
    end
  end

  @impl Pyex.Filesystem
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{} = fs, path) do
    url = object_url(fs, path)

    case Req.head(url, aws_sigv4: aws_opts(fs)) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  @impl Pyex.Filesystem
  @spec list_dir(t(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_dir(%__MODULE__{bucket: bucket, region: region} = fs, path) do
    prefix = s3_key(fs, path)
    prefix = if prefix == "", do: "", else: prefix <> "/"
    url = "https://#{bucket}.s3.#{region}.amazonaws.com/?list-type=2&prefix=#{prefix}&delimiter=/"

    case Req.get(url, aws_sigv4: aws_opts(fs)) do
      {:ok, %{status: 200, body: body}} ->
        entries = parse_list_response(body, prefix)
        {:ok, entries}

      {:ok, %{status: status, body: body}} ->
        {:error, "IOError: S3 LIST returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "IOError: #{inspect(reason)}"}
    end
  end

  @impl Pyex.Filesystem
  @spec delete(t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def delete(%__MODULE__{} = fs, path) do
    url = object_url(fs, path)

    case Req.delete(url, aws_sigv4: aws_opts(fs)) do
      {:ok, %{status: status}} when status in [200, 204] ->
        {:ok, fs}

      {:ok, %{status: status, body: body}} ->
        {:error, "IOError: S3 DELETE returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "IOError: #{inspect(reason)}"}
    end
  end

  @spec object_url(t(), String.t()) :: String.t()
  defp object_url(%__MODULE__{bucket: bucket, region: region} = fs, path) do
    key = s3_key(fs, path)
    "https://#{bucket}.s3.#{region}.amazonaws.com/#{key}"
  end

  @spec s3_key(t(), String.t()) :: String.t()
  defp s3_key(%__MODULE__{prefix: prefix}, path) do
    normalized = String.trim_leading(path, "/")

    case prefix do
      "" -> normalized
      p -> "#{String.trim_trailing(p, "/")}/#{normalized}"
    end
  end

  @spec aws_opts(t()) :: keyword()
  defp aws_opts(%__MODULE__{region: region}) do
    [service: :s3, region: region]
  end

  @spec parse_list_response(String.t() | map(), String.t()) :: [String.t()]
  defp parse_list_response(body, prefix) when is_binary(body) do
    keys =
      Regex.scan(~r/<Key>([^<]+)<\/Key>/, body)
      |> Enum.map(fn [_, key] -> key end)

    prefixes =
      Regex.scan(~r/<Prefix>([^<]+)<\/Prefix>/, body)
      |> Enum.map(fn [_, p] -> p end)
      |> Enum.reject(&(&1 == prefix))

    entries =
      (keys ++ prefixes)
      |> Enum.map(fn full ->
        rest = String.replace_prefix(full, prefix, "")
        String.trim_trailing(rest, "/")
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    entries
  end

  defp parse_list_response(_body, _prefix), do: []
end
