defmodule Pyex.Stdlib.Urllib do
  @moduledoc """
  Minimal `urllib.parse` support.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Interpreter

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "parse" => %{
        "urljoin" => {:builtin, &urljoin/1},
        "quote" => {:builtin, &url_quote/1},
        "unquote" => {:builtin, &url_unquote/1},
        "urlparse" => {:builtin, &urlparse/1},
        "urlencode" => {:builtin, &urlencode/1}
      }
    }
  end

  @spec urljoin([Interpreter.pyvalue()]) :: String.t() | {:exception, String.t()}
  defp urljoin([base, url]) when is_binary(base) and is_binary(url),
    do: URI.merge(base, url) |> to_string()

  defp urljoin(_args), do: {:exception, "TypeError: urljoin() expects (base, url) strings"}

  @spec url_quote([Interpreter.pyvalue()]) :: String.t() | {:exception, String.t()}
  defp url_quote([value]) when is_binary(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp url_quote(_args), do: {:exception, "TypeError: quote() expects a string"}

  @spec url_unquote([Interpreter.pyvalue()]) :: String.t() | {:exception, String.t()}
  defp url_unquote([value]) when is_binary(value), do: URI.decode(value)
  defp url_unquote(_args), do: {:exception, "TypeError: unquote() expects a string"}

  @spec urlparse([Interpreter.pyvalue()]) :: Interpreter.pyvalue() | {:exception, String.t()}
  defp urlparse([value]) when is_binary(value) do
    uri = URI.parse(value)

    {:tuple,
     [
       uri.scheme || "",
       uri.authority || "",
       uri.path || "",
       uri.query || "",
       uri.fragment || ""
     ]}
  end

  defp urlparse(_args), do: {:exception, "TypeError: urlparse() expects a string"}

  @spec urlencode([Interpreter.pyvalue()]) :: String.t() | {:exception, String.t()}
  defp urlencode([{:py_dict, _, _} = dict]) do
    dict
    |> Pyex.PyDict.items()
    |> Map.new()
    |> URI.encode_query()
  end

  defp urlencode([map]) when is_map(map) do
    map
    |> Pyex.Builtins.visible_dict()
    |> URI.encode_query()
  end

  defp urlencode(_args), do: {:exception, "TypeError: urlencode() expects a mapping"}
end
