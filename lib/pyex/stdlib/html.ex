defmodule Pyex.Stdlib.HTML do
  @moduledoc """
  Python `html` module for HTML entity escaping.

  Provides `html.escape(s[, quote=True])` and `html.unescape(s)`.
  `unescape` resolves named entities (amp, lt, gt, quot, apos) and
  numeric character references in decimal (`&#65;`) or hex (`&#x41;`).
  """

  @behaviour Pyex.Stdlib.Module

  @doc """
  Returns the module value map.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "escape" => {:builtin_kw, &do_escape/2},
      "unescape" => {:builtin, &do_unescape/1}
    }
  end

  @spec do_escape([Pyex.Interpreter.pyvalue()], map()) :: Pyex.Interpreter.pyvalue()
  defp do_escape([s], kwargs) when is_binary(s) do
    quote? = Map.get(kwargs, "quote", true)
    escape(s, quote?)
  end

  defp do_escape([s, quote?], _kwargs) when is_binary(s) do
    escape(s, quote?)
  end

  defp do_escape(_, _) do
    {:exception, "TypeError: html.escape() argument must be a string"}
  end

  @spec escape(String.t(), boolean()) :: String.t()
  defp escape(s, true) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#x27;")
  end

  defp escape(s, _) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @spec do_unescape([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_unescape([s]) when is_binary(s) do
    # First resolve named entities, then numeric references.
    s
    |> replace_named_entities()
    |> replace_numeric_refs()
  end

  defp do_unescape(_) do
    {:exception, "TypeError: html.unescape() argument must be a string"}
  end

  @named_entities %{
    "&quot;" => "\"",
    "&apos;" => "'",
    "&lt;" => "<",
    "&gt;" => ">",
    "&nbsp;" => " "
  }

  @spec replace_named_entities(String.t()) :: String.t()
  defp replace_named_entities(s) do
    s =
      Enum.reduce(@named_entities, s, fn {entity, char}, acc ->
        String.replace(acc, entity, char)
      end)

    # &amp; must be resolved last so we don't clobber other entities.
    String.replace(s, "&amp;", "&")
  end

  @spec replace_numeric_refs(String.t()) :: String.t()
  defp replace_numeric_refs(s) do
    # Hex: &#xNN; or &#XNN;  Decimal: &#NN;
    s = Regex.replace(~r/&#[xX]([0-9a-fA-F]+);/, s, &hex_to_char/2)
    Regex.replace(~r/&#([0-9]+);/, s, &dec_to_char/2)
  end

  @spec hex_to_char(String.t(), String.t()) :: String.t()
  defp hex_to_char(_full, hex) do
    case Integer.parse(hex, 16) do
      {cp, ""} when cp >= 0 and cp <= 0x10FFFF -> <<cp::utf8>>
      _ -> "?"
    end
  end

  @spec dec_to_char(String.t(), String.t()) :: String.t()
  defp dec_to_char(_full, dec) do
    case Integer.parse(dec) do
      {cp, ""} when cp >= 0 and cp <= 0x10FFFF -> <<cp::utf8>>
      _ -> "?"
    end
  end
end
