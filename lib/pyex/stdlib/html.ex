defmodule Pyex.Stdlib.Html do
  @moduledoc """
  Python `html` module for HTML entity escaping.

  Provides `html.escape(s)` and `html.unescape(s)`.
  """

  @behaviour Pyex.Stdlib.Module

  @doc """
  Returns the module value map.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "escape" => {:builtin, &do_escape/1},
      "unescape" => {:builtin, &do_unescape/1}
    }
  end

  @spec do_escape([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_escape([s]) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#x27;")
  end

  defp do_escape([s, true]) when is_binary(s) do
    do_escape([s])
  end

  defp do_escape([s, false]) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp do_escape(_) do
    {:exception, "TypeError: html.escape() argument must be a string"}
  end

  @spec do_unescape([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_unescape([s]) when is_binary(s) do
    s
    |> String.replace("&#x27;", "'")
    |> String.replace("&#39;", "'")
    |> String.replace("&quot;", "\"")
    |> String.replace("&gt;", ">")
    |> String.replace("&lt;", "<")
    |> String.replace("&amp;", "&")
  end

  defp do_unescape(_) do
    {:exception, "TypeError: html.unescape() argument must be a string"}
  end
end
