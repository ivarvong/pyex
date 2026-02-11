defmodule Pyex.Stdlib.Boto3 do
  @moduledoc """
  Python `boto3` module for AWS service clients.

  Currently supports `boto3.client('s3')` for S3 operations.
  The S3 client makes real HTTP calls to AWS S3 (or a
  compatible endpoint) via Req with AWS sigv4 signing.

  ## Supported S3 operations

  - `put_object(Bucket, Key, Body)` -- upload an object
  - `get_object(Bucket, Key)` -- retrieve an object
  - `delete_object(Bucket, Key)` -- delete an object
  - `list_objects_v2(Bucket, Prefix)` -- list objects

  ## Usage

      import boto3
      s3 = boto3.client('s3')
      s3.put_object(Bucket='my-bucket', Key='hello.txt', Body='world')
      obj = s3.get_object(Bucket='my-bucket', Key='hello.txt')
      data = obj['Body'].read()

  ## Testing with a local endpoint

      s3 = boto3.client('s3', endpoint_url='http://localhost:9000')
  """

  @behaviour Pyex.Stdlib.Module

  @typep s3_result ::
           {:exception, String.t()}
           | {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {term(), Pyex.Env.t(), Pyex.Ctx.t()})}

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "client" => {:builtin_kw, &create_client/2}
    }
  end

  @spec create_client(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: Pyex.Interpreter.pyvalue()
  defp create_client([service_name], kwargs) when is_binary(service_name) do
    case service_name do
      "s3" -> build_s3_client(kwargs)
      other -> {:exception, "boto3.client: unsupported service '#{other}'"}
    end
  end

  defp create_client(_, _kwargs) do
    {:exception, "TypeError: boto3.client() requires a service name string"}
  end

  @typep s3_config :: %{
           region: String.t(),
           endpoint_url: String.t() | nil,
           signing_opts: keyword() | nil
         }

  @spec build_s3_client(%{optional(String.t()) => Pyex.Interpreter.pyvalue()}) ::
          Pyex.Interpreter.pyvalue()
  defp build_s3_client(kwargs) do
    region = Map.get(kwargs, "region_name", "us-east-1")
    endpoint_url = Map.get(kwargs, "endpoint_url")
    access_key = Map.get(kwargs, "aws_access_key_id")
    secret_key = Map.get(kwargs, "aws_secret_access_key")

    signing_opts = build_signing_opts(region, access_key, secret_key)

    config = %{region: region, endpoint_url: endpoint_url, signing_opts: signing_opts}

    %{
      "__boto3_s3_client__" => true,
      "__region__" => region,
      "__endpoint_url__" => endpoint_url,
      "put_object" => {:builtin_kw, &s3_put_object(config, &1, &2)},
      "get_object" => {:builtin_kw, &s3_get_object(config, &1, &2)},
      "delete_object" => {:builtin_kw, &s3_delete_object(config, &1, &2)},
      "list_objects_v2" => {:builtin_kw, &s3_list_objects_v2(config, &1, &2)}
    }
  end

  @spec build_signing_opts(String.t(), String.t() | nil, String.t() | nil) :: keyword() | nil
  defp build_signing_opts(region, access_key, secret_key)
       when is_binary(access_key) and is_binary(secret_key) do
    [service: :s3, region: region, access_key_id: access_key, secret_access_key: secret_key]
  end

  defp build_signing_opts(_region, _access_key, _secret_key), do: nil

  @spec object_url(String.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  defp object_url(bucket, key, region, nil) do
    "https://#{bucket}.s3.#{region}.amazonaws.com/#{key}"
  end

  defp object_url(bucket, key, _region, endpoint_url) do
    base = String.trim_trailing(endpoint_url, "/")
    "#{base}/#{bucket}/#{key}"
  end

  @spec bucket_url(String.t(), String.t(), String.t() | nil) :: String.t()
  defp bucket_url(bucket, region, nil) do
    "https://#{bucket}.s3.#{region}.amazonaws.com/"
  end

  defp bucket_url(bucket, _region, endpoint_url) do
    base = String.trim_trailing(endpoint_url, "/")
    "#{base}/#{bucket}/"
  end

  @spec signing_req_opts(keyword() | nil) :: keyword()
  defp signing_req_opts(nil), do: []
  defp signing_req_opts(opts), do: [aws_sigv4: opts]

  @spec s3_put_object(s3_config(), [Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) :: s3_result()
  defp s3_put_object(config, _args, kwargs) do
    bucket = Map.get(kwargs, "Bucket")
    key = Map.get(kwargs, "Key")
    body = Map.get(kwargs, "Body", "")
    content_type = Map.get(kwargs, "ContentType")

    cond do
      not is_binary(bucket) ->
        {:exception, "ParamValidationError: Missing required parameter: 'Bucket'"}

      not is_binary(key) ->
        {:exception, "ParamValidationError: Missing required parameter: 'Key'"}

      true ->
        url = object_url(bucket, key, config.region, config.endpoint_url)
        body_bytes = if is_binary(body), do: body, else: to_string(body)

        headers =
          if is_binary(content_type),
            do: [{"content-type", content_type}],
            else: []

        req_opts =
          [body: body_bytes, headers: headers] ++ signing_req_opts(config.signing_opts)

        Pyex.Ctx.guarded_io_call(:boto3, fn env, ctx ->
          result =
            case Req.put(url, req_opts) do
              {:ok, %{status: status}} when status in [200, 201] ->
                %{"ResponseMetadata" => %{"HTTPStatusCode" => status}}

              {:ok, %{status: status, body: resp_body}} ->
                {:exception,
                 "ClientError: S3 PutObject failed (#{status}): #{inspect(resp_body)}"}

              {:error, reason} ->
                {:exception, "ClientError: #{inspect(reason)}"}
            end

          {result, env, ctx}
        end)
    end
  end

  @spec s3_get_object(s3_config(), [Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) :: s3_result()
  defp s3_get_object(config, _args, kwargs) do
    bucket = Map.get(kwargs, "Bucket")
    key = Map.get(kwargs, "Key")

    cond do
      not is_binary(bucket) ->
        {:exception, "ParamValidationError: Missing required parameter: 'Bucket'"}

      not is_binary(key) ->
        {:exception, "ParamValidationError: Missing required parameter: 'Key'"}

      true ->
        url = object_url(bucket, key, config.region, config.endpoint_url)
        req_opts = [decode_body: false] ++ signing_req_opts(config.signing_opts)

        Pyex.Ctx.guarded_io_call(:boto3, fn env, ctx ->
          result =
            case Req.get(url, req_opts) do
              {:ok, %{status: 200, body: body, headers: headers}} ->
                body_str = body

                body_obj = %{
                  "read" => {:builtin, fn [] -> body_str end},
                  "__body_bytes__" => body_str
                }

                content_type = extract_header(headers, "content-type")

                %{
                  "Body" => body_obj,
                  "ContentLength" => byte_size(body_str),
                  "ContentType" => content_type,
                  "ResponseMetadata" => %{"HTTPStatusCode" => 200}
                }

              {:ok, %{status: 404}} ->
                {:exception,
                 "ClientError: An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist."}

              {:ok, %{status: status, body: resp_body}} ->
                {:exception,
                 "ClientError: S3 GetObject failed (#{status}): #{inspect(resp_body)}"}

              {:error, reason} ->
                {:exception, "ClientError: #{inspect(reason)}"}
            end

          {result, env, ctx}
        end)
    end
  end

  @spec s3_delete_object(s3_config(), [Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) :: s3_result()
  defp s3_delete_object(config, _args, kwargs) do
    bucket = Map.get(kwargs, "Bucket")
    key = Map.get(kwargs, "Key")

    cond do
      not is_binary(bucket) ->
        {:exception, "ParamValidationError: Missing required parameter: 'Bucket'"}

      not is_binary(key) ->
        {:exception, "ParamValidationError: Missing required parameter: 'Key'"}

      true ->
        url = object_url(bucket, key, config.region, config.endpoint_url)
        req_opts = signing_req_opts(config.signing_opts)

        Pyex.Ctx.guarded_io_call(:boto3, fn env, ctx ->
          result =
            case Req.delete(url, req_opts) do
              {:ok, %{status: status}} when status in [200, 204] ->
                %{"ResponseMetadata" => %{"HTTPStatusCode" => status}}

              {:ok, %{status: status, body: resp_body}} ->
                {:exception,
                 "ClientError: S3 DeleteObject failed (#{status}): #{inspect(resp_body)}"}

              {:error, reason} ->
                {:exception, "ClientError: #{inspect(reason)}"}
            end

          {result, env, ctx}
        end)
    end
  end

  @spec s3_list_objects_v2(s3_config(), [Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) :: s3_result()
  defp s3_list_objects_v2(config, _args, kwargs) do
    bucket = Map.get(kwargs, "Bucket")
    prefix = Map.get(kwargs, "Prefix", "")

    if not is_binary(bucket) do
      {:exception, "ParamValidationError: Missing required parameter: 'Bucket'"}
    else
      base = bucket_url(bucket, config.region, config.endpoint_url)
      url = "#{base}?list-type=2&prefix=#{URI.encode(prefix)}"
      req_opts = signing_req_opts(config.signing_opts)

      Pyex.Ctx.guarded_io_call(:boto3, fn env, ctx ->
        result =
          case Req.get(url, req_opts) do
            {:ok, %{status: 200, body: body}} ->
              contents = parse_list_response(body, prefix)

              %{
                "Contents" => contents,
                "KeyCount" => length(contents),
                "Prefix" => prefix,
                "ResponseMetadata" => %{"HTTPStatusCode" => 200}
              }

            {:ok, %{status: status, body: resp_body}} ->
              {:exception,
               "ClientError: S3 ListObjectsV2 failed (#{status}): #{inspect(resp_body)}"}

            {:error, reason} ->
              {:exception, "ClientError: #{inspect(reason)}"}
          end

        {result, env, ctx}
      end)
    end
  end

  @spec parse_list_response(String.t() | term(), String.t()) :: [map()]
  defp parse_list_response(body, _prefix) when is_binary(body) do
    Regex.scan(~r/<Key>([^<]+)<\/Key>/, body)
    |> Enum.map(fn [_, key] -> %{"Key" => key} end)
  end

  defp parse_list_response(_body, _prefix), do: []

  @spec extract_header(%{optional(String.t()) => [String.t()]}, String.t()) :: String.t()
  defp extract_header(headers, name) do
    case Map.get(headers, name) do
      [value | _] -> value
      _ -> "application/octet-stream"
    end
  end
end
