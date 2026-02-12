defmodule Pyex.Filesystem.S3 do
  @moduledoc """
  S3-backed filesystem via Req with AWS signature v4.

  All paths are prefixed with a configurable key prefix within
  a single bucket. Works with any S3-compatible store (AWS S3,
  MinIO, Cloudflare R2, Backblaze B2, etc.) by setting `:endpoint_url`.
  """

  @behaviour Pyex.Filesystem

  @type t :: %__MODULE__{
          bucket: String.t(),
          prefix: String.t(),
          region: String.t(),
          endpoint_url: String.t() | nil,
          access_key_id: String.t(),
          secret_access_key: String.t()
        }

  defstruct [:bucket, :prefix, :region, :endpoint_url, :access_key_id, :secret_access_key]

  @doc """
  Creates a new S3 filesystem backend.

  Options:
  - `:bucket` (required) -- S3 bucket name
  - `:access_key_id` (required) -- AWS access key
  - `:secret_access_key` (required) -- AWS secret key
  - `:prefix` -- key prefix, default `""`
  - `:region` -- AWS region, default `"us-east-1"`
  - `:endpoint_url` -- custom endpoint for S3-compatible stores (e.g. MinIO)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      bucket: Keyword.fetch!(opts, :bucket),
      access_key_id: Keyword.fetch!(opts, :access_key_id),
      secret_access_key: Keyword.fetch!(opts, :secret_access_key),
      prefix: Keyword.get(opts, :prefix, ""),
      region: Keyword.get(opts, :region, "us-east-1"),
      endpoint_url: Keyword.get(opts, :endpoint_url)
    }
  end

  @impl Pyex.Filesystem
  @spec read(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(%__MODULE__{} = fs, path) do
    url = object_url(fs, path)

    case Req.get(url, req_opts(fs, decode_body: false)) do
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

    case Req.put(url, [{:body, full_content} | req_opts(fs)]) do
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

    case Req.head(url, req_opts(fs)) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  @impl Pyex.Filesystem
  @spec list_dir(t(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_dir(%__MODULE__{} = fs, path) do
    prefix = s3_key(fs, path)
    prefix = if prefix == "", do: "", else: String.trim_trailing(prefix, "/") <> "/"
    url = base_url(fs) <> "/"
    params = [{"list-type", "2"}, {"prefix", prefix}, {"delimiter", "/"}]

    case Req.get(url, [{:params, params} | req_opts(fs, decode_body: false)]) do
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

    case Req.delete(url, req_opts(fs)) do
      {:ok, %{status: status}} when status in [200, 204] ->
        {:ok, fs}

      {:ok, %{status: status, body: body}} ->
        {:error, "IOError: S3 DELETE returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "IOError: #{inspect(reason)}"}
    end
  end

  @spec req_opts(t(), keyword()) :: keyword()
  defp req_opts(%__MODULE__{} = fs, extra \\ []) do
    [{:aws_sigv4, aws_opts(fs)}, {:retry, false} | extra]
  end

  @spec object_url(t(), String.t()) :: String.t()
  defp object_url(%__MODULE__{} = fs, path) do
    key = s3_key(fs, path)
    base_url(fs) <> "/#{key}"
  end

  @spec base_url(t()) :: String.t()
  defp base_url(%__MODULE__{endpoint_url: url, bucket: bucket}) when is_binary(url) do
    String.trim_trailing(url, "/") <> "/#{bucket}"
  end

  defp base_url(%__MODULE__{bucket: bucket, region: region}) do
    "https://#{bucket}.s3.#{region}.amazonaws.com"
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
  defp aws_opts(%__MODULE__{
         region: region,
         access_key_id: access_key_id,
         secret_access_key: secret_access_key
       }) do
    [
      service: :s3,
      region: region,
      access_key_id: access_key_id,
      secret_access_key: secret_access_key
    ]
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
