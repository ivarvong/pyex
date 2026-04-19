defmodule Pyex.Stdlib.Urllib do
  @moduledoc """
  `urllib.parse` and a minimal `urllib.request.urlopen` that delegates to
  the same HTTP client as `requests.get`, so network policy, telemetry,
  and I/O-budget accounting are identical.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.{Interpreter, PyDict}
  alias Pyex.Stdlib.Requests

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    parse_attrs = %{
      "urljoin" => {:builtin, &urljoin/1},
      "quote" => {:builtin, &url_quote/1},
      "unquote" => {:builtin, &url_unquote/1},
      "urlparse" => {:builtin, &urlparse/1},
      "urlencode" => {:builtin, &urlencode/1}
    }

    request_attrs = %{
      "urlopen" => {:builtin, &urlopen/1}
    }

    error_attrs = %{
      "URLError" => "urllib.error.URLError",
      "HTTPError" => "urllib.error.HTTPError"
    }

    %{
      "parse" => {:module, "urllib.parse", parse_attrs},
      "request" => {:module, "urllib.request", request_attrs},
      "error" => {:module, "urllib.error", error_attrs}
    }
  end

  @spec urlopen([Interpreter.pyvalue()]) ::
          {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {term(), Pyex.Env.t(), Pyex.Ctx.t()})}
          | {:exception, String.t()}
  defp urlopen([url]) when is_binary(url) do
    {:io_call, inner} = Requests.request_io_call(:get, url, %{})

    {:io_call,
     fn env, ctx ->
       case inner.(env, ctx) do
         {{:exception, _} = signal, env, ctx} ->
           {signal, env, ctx}

         {response, env, ctx} ->
           {build_urlopen_response(response), env, ctx}
       end
     end}
  end

  defp urlopen(_), do: {:exception, "TypeError: urlopen() expects a URL string"}

  @spec build_urlopen_response(Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp build_urlopen_response({:py_dict, _, _} = resp) do
    status = PyDict.get(resp, "status_code", 0)
    text = PyDict.get(resp, "text", "")
    headers = PyDict.get(resp, "headers", PyDict.from_pairs([]))

    getheader = fn
      [name] when is_binary(name) ->
        PyDict.get(headers, String.downcase(name), nil)

      [name, default] when is_binary(name) ->
        PyDict.get(headers, String.downcase(name), default)

      _ ->
        {:exception, "TypeError: getheader() expects a header name"}
    end

    read = fn
      [] -> text
      [n] when is_integer(n) and n >= 0 -> String.slice(text, 0, n)
      _ -> {:exception, "TypeError: read() expects 0 or 1 integer argument"}
    end

    PyDict.from_pairs([
      {"status", status},
      {"code", status},
      {"read", {:builtin, read}},
      {"getheader", {:builtin, getheader}},
      {"headers", headers}
    ])
  end

  defp build_urlopen_response(other), do: other

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
       uri_part(uri.scheme),
       uri_part(uri.authority),
       uri_part(uri.path),
       uri_part(uri.query),
       uri_part(uri.fragment)
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

  @spec uri_part(String.t() | nil) :: String.t()
  defp uri_part(nil), do: ""
  defp uri_part(value), do: value
end
