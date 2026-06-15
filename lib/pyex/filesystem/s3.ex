defmodule Pyex.Filesystem.S3 do
  @moduledoc """
  S3-backed filesystem via Req with AWS signature v4.

  All paths are prefixed with a configurable key prefix within
  a single bucket. Works with any S3-compatible store (AWS S3,
  MinIO, Cloudflare R2, Backblaze B2, etc.) by setting `:endpoint_url`.

  Implements [`VFS.Mountable`](https://hexdocs.pm/vfs) so an `%S3{}` can be
  used directly as a `Pyex.Ctx` filesystem or mounted into a `%VFS{}`. The
  bare `read/2`, `write/4`, `exists?/2`, `list_dir/2`, and `delete/2`
  functions remain for direct use and return Python-style error strings.
  """

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

  # ── legacy string API ─────────────────────────────────────────────────────
  #
  # Thin wrappers over the structured core (`core_*`, which return
  # `%VFS.Error{}`). Kept for direct callers and tested by `s3_test.exs`; they
  # render errors as the Python-style strings Pyex historically surfaced.

  @spec read(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(%__MODULE__{} = fs, path), do: legacy(core_get(fs, path))

  @spec write(t(), String.t(), String.t(), :write | :append) ::
          {:ok, t()} | {:error, String.t()}
  def write(%__MODULE__{} = fs, path, content, mode),
    do: legacy(core_put(fs, path, content, mode))

  # Object existence (a single HEAD). The VFS `stat`/`exists?` add
  # implicit-directory detection on top; this bare helper stays cheap.
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{} = fs, path) do
    case check_path(path) do
      {:error, _} ->
        false

      :ok ->
        case Req.head(object_url(fs, path), req_opts(fs)) do
          {:ok, %{status: 200}} -> true
          _ -> false
        end
    end
  end

  @spec list_dir(t(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_dir(%__MODULE__{} = fs, path), do: legacy(core_readdir(fs, path))

  @spec delete(t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def delete(%__MODULE__{} = fs, path), do: legacy(core_delete(fs, path, recursive: false))

  @spec legacy({:ok, payload} | {:error, VFS.Error.t()}) ::
          {:ok, payload} | {:error, String.t()}
        when payload: term()
  defp legacy({:ok, _} = ok), do: ok

  defp legacy({:error, %VFS.Error{kind: :enoent, path: p}}),
    do: {:error, "FileNotFoundError: [Errno 2] No such file or directory: '#{p}'"}

  defp legacy({:error, %VFS.Error{message: m}}) when is_binary(m), do: {:error, "IOError: #{m}"}
  defp legacy({:error, %VFS.Error{kind: kind, path: p}}), do: {:error, "IOError: #{kind}: '#{p}'"}

  # ── structured core ───────────────────────────────────────────────────────
  #
  # Each returns `{:ok, payload} | {:error, %VFS.Error{}}`. The 404→`:enoent`
  # and HTTP-status→`:eio` mapping (carrying the original status/body in the
  # message) is the single source of truth both the legacy strings and the
  # `VFS.Mountable` impl derive from.

  @doc false
  @spec core_get(t(), String.t()) :: {:ok, binary()} | {:error, VFS.Error.t()}
  def core_get(%__MODULE__{} = fs, path) do
    with :ok <- check_path(path) do
      case Req.get(object_url(fs, path), req_opts(fs, decode_body: false)) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: 404}} -> {:error, VFS.Error.new(:enoent, path: path)}
        {:ok, %{status: s, body: b}} -> {:error, http_error(path, "S3 returned #{s}", b)}
        {:error, reason} -> {:error, transport_error(path, reason)}
      end
    end
  end

  @doc false
  @spec core_put(t(), String.t(), binary(), :write | :append) ::
          {:ok, t()} | {:error, VFS.Error.t()}
  def core_put(%__MODULE__{} = fs, path, content, mode) do
    with :ok <- check_path(path) do
      full_content =
        case mode do
          :write ->
            content

          :append ->
            case core_get(fs, path) do
              {:ok, existing} -> existing <> content
              {:error, _} -> content
            end
        end

      case Req.put(object_url(fs, path), [{:body, full_content} | req_opts(fs)]) do
        {:ok, %{status: s}} when s in [200, 201] -> {:ok, fs}
        {:ok, %{status: s, body: b}} -> {:error, http_error(path, "S3 PUT returned #{s}", b)}
        {:error, reason} -> {:error, transport_error(path, reason)}
      end
    end
  end

  # HEAD the object for a file stat; if absent, a non-empty listing under
  # `path/` makes it an implicit directory (S3 has no real directories).
  @doc false
  @spec core_stat(t(), String.t()) ::
          {:ok, %{type: :regular | :directory, size: non_neg_integer()}}
          | {:error, VFS.Error.t()}
  def core_stat(%__MODULE__{} = fs, path) do
    with :ok <- check_path(path) do
      case Req.head(object_url(fs, path), req_opts(fs)) do
        {:ok, %{status: 200} = resp} ->
          {:ok, %{type: :regular, size: object_size(resp)}}

        {:ok, %{status: 404}} ->
          if implicit_dir?(fs, path),
            do: {:ok, %{type: :directory, size: 0}},
            else: {:error, VFS.Error.new(:enoent, path: path)}

        {:ok, %{status: s, body: b}} ->
          {:error, http_error(path, "S3 HEAD returned #{s}", b)}

        {:error, reason} ->
          {:error, transport_error(path, reason)}
      end
    end
  end

  @doc false
  @spec core_readdir(t(), String.t()) :: {:ok, [String.t()]} | {:error, VFS.Error.t()}
  def core_readdir(%__MODULE__{} = fs, path) do
    with :ok <- check_path(path) do
      case list_request(fs, dir_prefix(fs, path), delimiter: true) do
        {:ok, body, prefix} -> {:ok, parse_list_response(body, prefix)}
        {:error, _} = error -> error
      end
    end
  end

  # Non-recursive deletes one object; recursive lists every key under the
  # prefix (no delimiter) and deletes each.
  @doc false
  @spec core_delete(t(), String.t(), keyword()) :: {:ok, t()} | {:error, VFS.Error.t()}
  def core_delete(%__MODULE__{} = fs, path, opts) do
    with :ok <- check_path(path) do
      if Keyword.get(opts, :recursive, false),
        do: delete_tree(fs, path),
        else: delete_object(fs, path)
    end
  end

  @spec delete_object(t(), String.t()) :: {:ok, t()} | {:error, VFS.Error.t()}
  defp delete_object(fs, path) do
    case Req.delete(object_url(fs, path), req_opts(fs)) do
      {:ok, %{status: s}} when s in [200, 204] -> {:ok, fs}
      {:ok, %{status: s, body: b}} -> {:error, http_error(path, "S3 DELETE returned #{s}", b)}
      {:error, reason} -> {:error, transport_error(path, reason)}
    end
  end

  @spec delete_tree(t(), String.t()) :: {:ok, t()} | {:error, VFS.Error.t()}
  defp delete_tree(fs, path) do
    case list_request(fs, dir_prefix(fs, path), delimiter: false) do
      {:ok, body, _prefix} ->
        body
        |> all_keys()
        |> Enum.reduce_while({:ok, fs}, fn key, {:ok, fs} ->
          case Req.delete(base_url(fs) <> "/#{key}", req_opts(fs)) do
            {:ok, %{status: s}} when s in [200, 204] ->
              {:cont, {:ok, fs}}

            {:ok, %{status: s, body: b}} ->
              {:halt, {:error, http_error(path, "S3 DELETE returned #{s}", b)}}

            {:error, reason} ->
              {:halt, {:error, transport_error(path, reason)}}
          end
        end)

      {:error, _} = error ->
        error
    end
  end

  @spec implicit_dir?(t(), String.t()) :: boolean()
  defp implicit_dir?(fs, path) do
    case list_request(fs, dir_prefix(fs, path), delimiter: true, max_keys: 1) do
      {:ok, body, prefix} -> parse_list_response(body, prefix) != []
      {:error, _} -> false
    end
  end

  @spec list_request(t(), String.t(), keyword()) ::
          {:ok, binary() | map(), String.t()} | {:error, VFS.Error.t()}
  defp list_request(fs, prefix, opts) do
    params =
      [{"list-type", "2"}, {"prefix", prefix}]
      |> maybe_param(Keyword.get(opts, :delimiter, false), {"delimiter", "/"})
      |> maybe_param(Keyword.get(opts, :max_keys), fn n -> {"max-keys", to_string(n)} end)

    case Req.get(base_url(fs) <> "/", [{:params, params} | req_opts(fs, decode_body: false)]) do
      {:ok, %{status: 200, body: body}} -> {:ok, body, prefix}
      {:ok, %{status: s, body: b}} -> {:error, http_error(prefix, "S3 LIST returned #{s}", b)}
      {:error, reason} -> {:error, transport_error(prefix, reason)}
    end
  end

  @spec dir_prefix(t(), String.t()) :: String.t()
  defp dir_prefix(fs, path) do
    case s3_key(fs, path) do
      "" -> ""
      key -> String.trim_trailing(key, "/") <> "/"
    end
  end

  defp maybe_param(params, false, _entry), do: params
  defp maybe_param(params, nil, _entry), do: params
  defp maybe_param(params, value, fun) when is_function(fun, 1), do: params ++ [fun.(value)]
  defp maybe_param(params, _value, entry), do: params ++ [entry]

  @spec object_size(map()) :: non_neg_integer()
  defp object_size(resp) do
    case Req.Response.get_header(resp, "content-length") do
      [len | _] -> String.to_integer(len)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @spec all_keys(binary() | map()) :: [String.t()]
  defp all_keys(body) when is_binary(body) do
    ~r/<Key>([^<]+)<\/Key>/ |> Regex.scan(body) |> Enum.map(fn [_, key] -> key end)
  end

  defp all_keys(_), do: []

  @spec http_error(String.t(), String.t(), term()) :: VFS.Error.t()
  defp http_error(path, prefix, body),
    do: VFS.Error.new(:eio, path: path, message: "#{prefix}: #{inspect(body)}")

  @spec transport_error(String.t(), term()) :: VFS.Error.t()
  defp transport_error(path, reason),
    do: VFS.Error.new(:eio, path: path, message: inspect(reason))

  @spec check_path(String.t()) :: :ok | {:error, VFS.Error.t()}
  defp check_path(path) do
    if String.contains?(String.trim_leading(path, "/"), ".."),
      do:
        {:error,
         VFS.Error.new(:einval, path: path, message: "path traversal not allowed: '#{path}'")},
      else: :ok
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

defimpl VFS.Mountable, for: Pyex.Filesystem.S3 do
  @moduledoc false
  use VFS.Skeleton

  alias Pyex.Filesystem.S3
  alias VFS.Stat

  @epoch DateTime.from_unix!(0)

  # S3 has no symlinks and no per-object POSIX modes. `:mkdir` is advertised
  # because `mkdir/3` succeeds (directories are implicit prefixes); the
  # capability set must agree with the behavior.
  def capabilities(_), do: MapSet.new([:read, :write, :mkdir])

  def stat(%S3{} = s3, path) do
    case S3.core_stat(s3, path) do
      {:ok, %{type: :regular, size: size}} -> {:ok, Stat.regular(size, @epoch), s3}
      {:ok, %{type: :directory}} -> {:ok, Stat.directory(@epoch), s3}
      {:error, err} -> {:error, err}
    end
  end

  def exists?(%S3{} = s3, path), do: {match?({:ok, _}, S3.core_stat(s3, path)), s3}

  def stream_read(%S3{} = s3, path, opts) do
    case S3.core_get(s3, path) do
      {:ok, body} ->
        # Honor the documented :chunk_size / :byte_range / :line_range opts via
        # the same helper VFS.Memory uses, so a direct VFS.stream_read against
        # S3 behaves like any other backend.
        case VFS.StreamOptions.apply(body, opts) do
          {:ok, stream} -> {:ok, stream, s3}
          {:error, reason} -> {:error, VFS.Error.new(reason, path: path)}
        end

      {:error, err} ->
        {:error, err}
    end
  end

  def write_file(%S3{} = s3, path, content, _opts) do
    S3.core_put(s3, path, content, :write)
  end

  def readdir(%S3{} = s3, path) do
    case S3.core_readdir(s3, path) do
      {:ok, names} -> {:ok, names, s3}
      {:error, err} -> {:error, err}
    end
  end

  def rm(%S3{} = s3, path, opts) do
    S3.core_delete(s3, path, recursive: Keyword.get(opts, :recursive, false))
  end

  # Object writes create the implied prefix, so an explicit mkdir is a no-op.
  def mkdir(%S3{} = s3, _path, _opts), do: {:ok, s3}
end
