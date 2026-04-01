defmodule Pyex.Stdlib.Crypto do
  @moduledoc """
  Python `crypto` module for cryptographic signing operations.

  Provides `crypto.sign_rs256(data, pem_key)` for RSA-SHA256 signing
  using PKCS1-v1.5. Backed by Erlang's `:public_key` module.

  This is a Pyex-specific module (not part of CPython's stdlib) that
  provides the minimal crypto primitives needed for JWT signing flows
  like Google service account authentication.
  """

  @behaviour Pyex.Stdlib.Module

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "sign_rs256" => {:builtin, &do_sign_rs256/1}
    }
  end

  @spec do_sign_rs256([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_sign_rs256([data, pem]) when is_binary(data) and is_binary(pem) do
    case pem_decode_private_key(pem) do
      {:ok, private_key} ->
        :public_key.sign(data, :sha256, private_key)

      {:error, reason} ->
        {:exception, "ValueError: #{reason}"}
    end
  end

  defp do_sign_rs256([_, _]),
    do: {:exception, "TypeError: sign_rs256() arguments must be strings"}

  defp do_sign_rs256(_),
    do: {:exception, "TypeError: sign_rs256() requires exactly 2 arguments (data, pem_key)"}

  @spec pem_decode_private_key(binary()) ::
          {:ok, :public_key.private_key()} | {:error, String.t()}
  defp pem_decode_private_key(pem) do
    case :public_key.pem_decode(pem) do
      [] ->
        {:error, "could not decode PEM data"}

      [entry | _] ->
        try do
          {:ok, :public_key.pem_entry_decode(entry)}
        rescue
          e -> {:error, "could not decode private key: #{Exception.message(e)}"}
        end
    end
  end
end
