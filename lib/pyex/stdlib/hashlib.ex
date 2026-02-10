defmodule Pyex.Stdlib.Hashlib do
  @moduledoc """
  Python `hashlib` module for secure hash and message digest algorithms.

  Provides constructor functions `hashlib.sha256()`, `hashlib.sha1()`,
  `hashlib.md5()`, `hashlib.sha224()`, `hashlib.sha384()`, `hashlib.sha512()`,
  and the generic `hashlib.new(name)` constructor.

  Each returns a hash object with `.update(data)`, `.hexdigest()`, `.digest()`,
  and `.digest_size` / `.block_size` / `.name` attributes.

  Backed by Erlang's `:crypto` module.
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
  Returns the module value map with hash constructor functions.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "md5" => {:builtin, &do_md5/1},
      "sha1" => {:builtin, &do_sha1/1},
      "sha224" => {:builtin, &do_sha224/1},
      "sha256" => {:builtin, &do_sha256/1},
      "sha384" => {:builtin, &do_sha384/1},
      "sha512" => {:builtin, &do_sha512/1},
      "new" => {:builtin, &do_new/1}
    }
  end

  @spec do_md5([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_md5([]), do: make_hash_object("md5", <<>>)
  defp do_md5([data]) when is_binary(data), do: make_hash_object("md5", data)
  defp do_md5(_), do: {:exception, "TypeError: md5() argument must be a string"}

  @spec do_sha1([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_sha1([]), do: make_hash_object("sha1", <<>>)
  defp do_sha1([data]) when is_binary(data), do: make_hash_object("sha1", data)
  defp do_sha1(_), do: {:exception, "TypeError: sha1() argument must be a string"}

  @spec do_sha224([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_sha224([]), do: make_hash_object("sha224", <<>>)
  defp do_sha224([data]) when is_binary(data), do: make_hash_object("sha224", data)
  defp do_sha224(_), do: {:exception, "TypeError: sha224() argument must be a string"}

  @spec do_sha256([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_sha256([]), do: make_hash_object("sha256", <<>>)
  defp do_sha256([data]) when is_binary(data), do: make_hash_object("sha256", data)
  defp do_sha256(_), do: {:exception, "TypeError: sha256() argument must be a string"}

  @spec do_sha384([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_sha384([]), do: make_hash_object("sha384", <<>>)
  defp do_sha384([data]) when is_binary(data), do: make_hash_object("sha384", data)
  defp do_sha384(_), do: {:exception, "TypeError: sha384() argument must be a string"}

  @spec do_sha512([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_sha512([]), do: make_hash_object("sha512", <<>>)
  defp do_sha512([data]) when is_binary(data), do: make_hash_object("sha512", data)
  defp do_sha512(_), do: {:exception, "TypeError: sha512() argument must be a string"}

  @spec do_new([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_new([name]) when is_binary(name) do
    algo = String.downcase(name) |> String.replace("-", "")

    if Map.has_key?(@algorithms, algo) do
      make_hash_object(algo, <<>>)
    else
      {:exception, "ValueError: unsupported hash type #{name}"}
    end
  end

  defp do_new([name, data]) when is_binary(name) and is_binary(data) do
    algo = String.downcase(name) |> String.replace("-", "")

    if Map.has_key?(@algorithms, algo) do
      make_hash_object(algo, data)
    else
      {:exception, "ValueError: unsupported hash type #{name}"}
    end
  end

  defp do_new(_), do: {:exception, "TypeError: new() requires a string algorithm name"}

  @spec make_hash_object(String.t(), binary()) :: Pyex.Interpreter.pyvalue()
  defp make_hash_object(algo_name, data) do
    erlang_algo = Map.fetch!(@algorithms, algo_name)
    digest = :crypto.hash(erlang_algo, data)
    hex = Base.encode16(digest, case: :lower)

    digest_size = Map.fetch!(@digest_sizes, algo_name)
    block_size = Map.fetch!(@block_sizes, algo_name)

    update_fn =
      {:builtin,
       fn
         [new_data] when is_binary(new_data) ->
           make_hash_object(algo_name, data <> new_data)

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
         [_self] -> digest
         [] -> digest
       end}

    copy_fn =
      {:builtin,
       fn
         [_self] -> make_hash_object(algo_name, data)
         [] -> make_hash_object(algo_name, data)
       end}

    hash_class =
      {:class, "_hashlib.HASH", [], %{}}

    {:instance, hash_class,
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
