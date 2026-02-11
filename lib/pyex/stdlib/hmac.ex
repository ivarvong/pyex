defmodule Pyex.Stdlib.Hmac do
  @moduledoc """
  Python `hmac` module for keyed-hash message authentication codes.

  Provides `hmac.new(key, msg, digestmod)` which returns an HMAC object
  with `.hexdigest()`, `.digest()`, `.update()`, `.copy()` methods.
  Also provides `hmac.digest(key, msg, digest)` for one-shot HMAC
  computation and `hmac.compare_digest(a, b)` for constant-time comparison.

  Backed by Erlang's `:crypto.mac/4`.
  """

  @behaviour Pyex.Stdlib.Module

  @algorithms %{
    "md5" => :md5,
    "sha1" => :sha,
    "sha224" => :sha224,
    "sha256" => :sha256,
    "sha384" => :sha384,
    "sha512" => :sha512
  }

  @digest_sizes %{
    "md5" => 16,
    "sha1" => 20,
    "sha224" => 28,
    "sha256" => 32,
    "sha384" => 48,
    "sha512" => 64
  }

  @block_sizes %{
    "md5" => 64,
    "sha1" => 64,
    "sha224" => 64,
    "sha256" => 64,
    "sha384" => 128,
    "sha512" => 128
  }

  @doc """
  Returns the module value map with HMAC functions.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "new" => {:builtin, &do_new/1},
      "digest" => {:builtin, &do_digest/1},
      "compare_digest" => {:builtin, &do_compare_digest/1}
    }
  end

  @spec do_new([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_new([key, msg, digestmod]) when is_binary(key) and is_binary(msg) do
    case resolve_digestmod(digestmod) do
      {:ok, algo_name} -> make_hmac_object(algo_name, key, msg)
      {:error, reason} -> {:exception, reason}
    end
  end

  defp do_new([key, msg]) when is_binary(key) and is_binary(msg) do
    {:exception, "TypeError: hmac.new() missing required argument: 'digestmod'"}
  end

  defp do_new([key]) when is_binary(key) do
    {:exception, "TypeError: hmac.new() missing required argument: 'digestmod'"}
  end

  defp do_new(_), do: {:exception, "TypeError: hmac.new() arguments must be strings"}

  @spec do_digest([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_digest([key, msg, digestmod]) when is_binary(key) and is_binary(msg) do
    case resolve_digestmod(digestmod) do
      {:ok, algo_name} ->
        erlang_algo = Map.fetch!(@algorithms, algo_name)
        :crypto.mac(:hmac, erlang_algo, key, msg) |> Base.encode16(case: :lower)

      {:error, reason} ->
        {:exception, reason}
    end
  end

  defp do_digest(_),
    do: {:exception, "TypeError: hmac.digest() requires key, msg, and digest arguments"}

  @spec do_compare_digest([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_compare_digest([a, b]) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp do_compare_digest(_) do
    {:exception, "TypeError: compare_digest() arguments must be strings"}
  end

  @spec resolve_digestmod(Pyex.Interpreter.pyvalue()) :: {:ok, String.t()} | {:error, String.t()}
  defp resolve_digestmod(digestmod) when is_binary(digestmod) do
    algo = String.downcase(digestmod) |> String.replace("-", "")

    if Map.has_key?(@algorithms, algo) do
      {:ok, algo}
    else
      {:error, "ValueError: unsupported hash type #{digestmod}"}
    end
  end

  defp resolve_digestmod({:builtin, _} = builtin_fn) do
    case builtin_fn do
      {:builtin, fun} when is_function(fun) ->
        result = fun.([])

        case result do
          {:instance, _, %{"name" => name}} when is_binary(name) ->
            if Map.has_key?(@algorithms, name),
              do: {:ok, name},
              else: {:error, "ValueError: unsupported hash type"}

          _ ->
            {:error, "TypeError: digestmod must be a string name or hashlib constructor"}
        end
    end
  end

  defp resolve_digestmod(_) do
    {:error, "TypeError: digestmod must be a string name or hashlib constructor"}
  end

  @spec make_hmac_object(String.t(), binary(), binary()) :: Pyex.Interpreter.pyvalue()
  defp make_hmac_object(algo_name, key, msg) do
    erlang_algo = Map.fetch!(@algorithms, algo_name)
    mac = :crypto.mac(:hmac, erlang_algo, key, msg)
    hex = Base.encode16(mac, case: :lower)

    digest_size = Map.fetch!(@digest_sizes, algo_name)
    block_size = Map.fetch!(@block_sizes, algo_name)

    update_fn =
      {:builtin,
       fn
         [new_data] when is_binary(new_data) ->
           make_hmac_object(algo_name, key, msg <> new_data)

         _ ->
           {:exception, "TypeError: update() argument must be a string"}
       end}

    hexdigest_fn =
      {:builtin,
       fn
         [_self] -> hex
         [] -> hex
       end}

    digest_fn =
      {:builtin,
       fn
         [_self] -> mac
         [] -> mac
       end}

    copy_fn =
      {:builtin,
       fn
         [_self] -> make_hmac_object(algo_name, key, msg)
         [] -> make_hmac_object(algo_name, key, msg)
       end}

    hmac_class =
      {:class, "_hmac.HMAC", [], %{}}

    {:instance, hmac_class,
     %{
       "name" => algo_name,
       "digest_size" => digest_size,
       "block_size" => block_size,
       "update" => update_fn,
       "hexdigest" => hexdigest_fn,
       "digest" => digest_fn,
       "copy" => copy_fn
     }}
  end
end
