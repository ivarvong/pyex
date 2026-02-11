defmodule Pyex.Stdlib.Base64Encode do
  @moduledoc """
  Python `base64` module for Base16, Base32, and Base64 encoding/decoding.

  Provides `base64.b64encode()`, `base64.b64decode()`,
  `base64.urlsafe_b64encode()`, `base64.urlsafe_b64decode()`,
  `base64.b32encode()`, `base64.b32decode()`,
  `base64.b16encode()`, `base64.b16decode()`.

  In Python these operate on bytes and return bytes; since Pyex has no
  bytes type, all functions accept and return strings.

  Backed by Erlang's `:base64` module and Elixir's `Base`.
  """

  @behaviour Pyex.Stdlib.Module

  @doc """
  Returns the module value map with encoding/decoding functions.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "b64encode" => {:builtin, &do_b64encode/1},
      "b64decode" => {:builtin, &do_b64decode/1},
      "urlsafe_b64encode" => {:builtin, &do_urlsafe_b64encode/1},
      "urlsafe_b64decode" => {:builtin, &do_urlsafe_b64decode/1},
      "b32encode" => {:builtin, &do_b32encode/1},
      "b32decode" => {:builtin, &do_b32decode/1},
      "b16encode" => {:builtin, &do_b16encode/1},
      "b16decode" => {:builtin, &do_b16decode/1}
    }
  end

  @spec do_b64encode([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_b64encode([data]) when is_binary(data), do: Base.encode64(data)
  defp do_b64encode(_), do: {:exception, "TypeError: b64encode() argument must be a string"}

  @spec do_b64decode([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_b64decode([data]) when is_binary(data) do
    case Base.decode64(data, ignore: :whitespace) do
      {:ok, decoded} -> decoded
      :error -> {:exception, "binascii.Error: Invalid base64-encoded string"}
    end
  end

  defp do_b64decode(_), do: {:exception, "TypeError: b64decode() argument must be a string"}

  @spec do_urlsafe_b64encode([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_urlsafe_b64encode([data]) when is_binary(data), do: Base.url_encode64(data)

  defp do_urlsafe_b64encode(_),
    do: {:exception, "TypeError: urlsafe_b64encode() argument must be a string"}

  @spec do_urlsafe_b64decode([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_urlsafe_b64decode([data]) when is_binary(data) do
    padded = pad_base64(data)

    case Base.url_decode64(padded) do
      {:ok, decoded} -> decoded
      :error -> {:exception, "binascii.Error: Invalid base64-encoded string"}
    end
  end

  defp do_urlsafe_b64decode(_),
    do: {:exception, "TypeError: urlsafe_b64decode() argument must be a string"}

  @spec do_b32encode([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_b32encode([data]) when is_binary(data), do: Base.encode32(data)
  defp do_b32encode(_), do: {:exception, "TypeError: b32encode() argument must be a string"}

  @spec do_b32decode([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_b32decode([data]) when is_binary(data) do
    case Base.decode32(data, case: :mixed) do
      {:ok, decoded} -> decoded
      :error -> {:exception, "binascii.Error: Invalid base32-encoded string"}
    end
  end

  defp do_b32decode(_), do: {:exception, "TypeError: b32decode() argument must be a string"}

  @spec do_b16encode([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_b16encode([data]) when is_binary(data), do: Base.encode16(data)
  defp do_b16encode(_), do: {:exception, "TypeError: b16encode() argument must be a string"}

  @spec do_b16decode([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_b16decode([data]) when is_binary(data) do
    case Base.decode16(data, case: :mixed) do
      {:ok, decoded} -> decoded
      :error -> {:exception, "binascii.Error: Invalid base16-encoded string"}
    end
  end

  defp do_b16decode(_), do: {:exception, "TypeError: b16decode() argument must be a string"}

  @spec pad_base64(String.t()) :: String.t()
  defp pad_base64(data) do
    case rem(byte_size(data), 4) do
      0 -> data
      2 -> data <> "=="
      3 -> data <> "="
      _ -> data
    end
  end
end
