defmodule Pyex.Stdlib.Uuid do
  @moduledoc """
  Python `uuid` module for generating universally unique identifiers.

  Provides `uuid.uuid4()` (random UUID) and `uuid.uuid7()` (time-ordered UUID).
  Returns UUID objects with `.hex`, `.int`, `.version`, and `.urn` attributes.
  `str(u)` produces the standard `8-4-4-4-12` hyphenated hex format.
  `repr(u)` produces `UUID('...')`.
  """

  @behaviour Pyex.Stdlib.Module

  @doc """
  Returns the module value map with uuid4, uuid7, and UUID constructor.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "uuid4" => {:builtin, &do_uuid4/1},
      "uuid7" => {:builtin, &do_uuid7/1},
      "UUID" => {:builtin, &do_uuid_constructor/1}
    }
  end

  @spec do_uuid4([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_uuid4([]) do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<int::128>> = <<a::48, 4::4, b::12, 0b10::2, c::62>>
    make_uuid_object(int, 4)
  end

  @spec do_uuid7([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_uuid7([]) do
    ms = System.system_time(:millisecond)
    <<_::4, rand_a::12, _::2, rand_b::62>> = :crypto.strong_rand_bytes(10)
    <<int::128>> = <<ms::48, 7::4, rand_a::12, 0b10::2, rand_b::62>>
    make_uuid_object(int, 7)
  end

  @spec do_uuid_constructor([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_uuid_constructor([hex_str]) when is_binary(hex_str) do
    cleaned =
      hex_str
      |> String.replace(~r/[-{}]/, "")
      |> String.downcase()

    cleaned =
      if String.starts_with?(cleaned, "urn:uuid:") do
        String.replace_prefix(cleaned, "urn:uuid:", "")
      else
        cleaned
      end

    if byte_size(cleaned) != 32 or not String.match?(cleaned, ~r/^[0-9a-f]{32}$/) do
      {:exception, "ValueError: badly formed hexadecimal UUID string"}
    else
      int = String.to_integer(cleaned, 16)
      <<_::48, ver::4, _::12, _::2, _::62>> = <<int::128>>
      make_uuid_object(int, ver)
    end
  end

  defp do_uuid_constructor(_) do
    {:exception, "TypeError: UUID() requires a hex string argument"}
  end

  @spec make_uuid_object(non_neg_integer(), non_neg_integer()) :: Pyex.Interpreter.pyvalue()
  defp make_uuid_object(int, version) do
    hex = int_to_hex32(int)
    str_value = format_uuid(hex)

    str_fn =
      {:builtin,
       fn [_self] ->
         str_value
       end}

    repr_fn =
      {:builtin,
       fn [_self] ->
         "UUID('#{str_value}')"
       end}

    eq_fn =
      {:builtin,
       fn
         [_self, {:instance, _, %{"int" => other_int}}] ->
           int == other_int

         [_self, _other] ->
           false
       end}

    uuid_class =
      {:class, "UUID", [],
       %{
         "__str__" => str_fn,
         "__repr__" => repr_fn,
         "__eq__" => eq_fn
       }}

    {:instance, uuid_class,
     %{
       "hex" => hex,
       "int" => int,
       "version" => version,
       "urn" => "urn:uuid:" <> str_value
     }}
  end

  @spec format_uuid(String.t()) :: String.t()
  defp format_uuid(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>) do
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  @spec int_to_hex32(non_neg_integer()) :: String.t()
  defp int_to_hex32(int) do
    int
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(32, "0")
  end
end
