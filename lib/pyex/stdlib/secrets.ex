defmodule Pyex.Stdlib.Secrets do
  @moduledoc """
  Python `secrets` module for generating cryptographically strong random
  numbers suitable for managing secrets such as account authentication,
  tokens, and similar.

  Provides `secrets.token_hex(nbytes)`, `secrets.token_urlsafe(nbytes)`,
  `secrets.token_bytes(nbytes)`, `secrets.randbelow(n)`,
  and `secrets.compare_digest(a, b)`.

  Backed by Erlang's `:crypto.strong_rand_bytes/1`.
  """

  @behaviour Pyex.Stdlib.Module

  @default_nbytes 32

  @doc """
  Returns the module value map with secrets functions.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "token_hex" => {:builtin, &do_token_hex/1},
      "token_urlsafe" => {:builtin, &do_token_urlsafe/1},
      "token_bytes" => {:builtin, &do_token_bytes/1},
      "randbelow" => {:builtin, &do_randbelow/1},
      "compare_digest" => {:builtin, &do_compare_digest/1},
      "choice" => {:builtin, &do_choice/1}
    }
  end

  @spec do_token_hex([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_token_hex([]) do
    :crypto.strong_rand_bytes(@default_nbytes) |> Base.encode16(case: :lower)
  end

  defp do_token_hex([nbytes]) when is_integer(nbytes) and nbytes >= 0 do
    :crypto.strong_rand_bytes(nbytes) |> Base.encode16(case: :lower)
  end

  defp do_token_hex([nil]) do
    do_token_hex([])
  end

  defp do_token_hex(_) do
    {:exception, "TypeError: token_hex() argument must be a non-negative integer"}
  end

  @spec do_token_urlsafe([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_token_urlsafe([]) do
    :crypto.strong_rand_bytes(@default_nbytes) |> Base.url_encode64(padding: false)
  end

  defp do_token_urlsafe([nbytes]) when is_integer(nbytes) and nbytes >= 0 do
    :crypto.strong_rand_bytes(nbytes) |> Base.url_encode64(padding: false)
  end

  defp do_token_urlsafe([nil]) do
    do_token_urlsafe([])
  end

  defp do_token_urlsafe(_) do
    {:exception, "TypeError: token_urlsafe() argument must be a non-negative integer"}
  end

  @spec do_token_bytes([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_token_bytes([]) do
    :crypto.strong_rand_bytes(@default_nbytes)
  end

  defp do_token_bytes([nbytes]) when is_integer(nbytes) and nbytes >= 0 do
    :crypto.strong_rand_bytes(nbytes)
  end

  defp do_token_bytes([nil]) do
    do_token_bytes([])
  end

  defp do_token_bytes(_) do
    {:exception, "TypeError: token_bytes() argument must be a non-negative integer"}
  end

  @spec do_randbelow([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_randbelow([n]) when is_integer(n) and n > 0 do
    :rand.uniform(n) - 1
  end

  defp do_randbelow([n]) when is_integer(n) do
    {:exception, "ValueError: Upper bound must be positive"}
  end

  defp do_randbelow(_) do
    {:exception, "TypeError: randbelow() argument must be a positive integer"}
  end

  @spec do_compare_digest([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_compare_digest([a, b]) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp do_compare_digest(_) do
    {:exception, "TypeError: compare_digest() arguments must be strings"}
  end

  @spec do_choice([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_choice([sequence]) when is_list(sequence) and length(sequence) > 0 do
    Enum.random(sequence)
  end

  defp do_choice([sequence]) when is_binary(sequence) and byte_size(sequence) > 0 do
    String.graphemes(sequence) |> Enum.random()
  end

  defp do_choice([_]) do
    {:exception, "IndexError: Cannot choose from an empty sequence"}
  end

  defp do_choice(_) do
    {:exception, "TypeError: choice() argument must be a non-empty sequence"}
  end
end
