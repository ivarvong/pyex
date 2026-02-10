defmodule Pyex.Stdlib.Requests do
  @moduledoc """
  Python `requests` module backed by Req.

  Provides `requests.get`, `requests.post`, `requests.put`,
  `requests.patch`, `requests.delete`, `requests.head`, and
  `requests.options` which return an object with `.text`,
  `.status_code`, `.ok`, `.headers`, and `.json()` attributes,
  matching the real `requests.Response` interface.

  All HTTP calls are instrumented with OpenTelemetry spans using
  the semantic conventions for HTTP clients. I/O time is excluded
  from the compute budget via `{:io_call, fn}` signals.
  """

  @behaviour Pyex.Stdlib.Module

  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Returns the module value -- a map with callable attributes.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "get" => {:builtin_kw, &do_get/2},
      "post" => {:builtin_kw, &do_post/2},
      "put" => {:builtin_kw, &do_put/2},
      "patch" => {:builtin_kw, &do_patch/2},
      "delete" => {:builtin_kw, &do_delete/2},
      "head" => {:builtin_kw, &do_head/2},
      "options" => {:builtin_kw, &do_options/2}
    }
  end

  @spec do_get(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {term(), Pyex.Env.t(), Pyex.Ctx.t()})}
  defp do_get([url], kwargs) when is_binary(url), do: do_request(:get, url, kwargs)

  @spec do_post(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {term(), Pyex.Env.t(), Pyex.Ctx.t()})}
  defp do_post([url], kwargs) when is_binary(url), do: do_request(:post, url, kwargs)

  @spec do_put(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {term(), Pyex.Env.t(), Pyex.Ctx.t()})}
  defp do_put([url], kwargs) when is_binary(url), do: do_request(:put, url, kwargs)

  @spec do_patch(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {term(), Pyex.Env.t(), Pyex.Ctx.t()})}
  defp do_patch([url], kwargs) when is_binary(url), do: do_request(:patch, url, kwargs)

  @spec do_delete(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {term(), Pyex.Env.t(), Pyex.Ctx.t()})}
  defp do_delete([url], kwargs) when is_binary(url), do: do_request(:delete, url, kwargs)

  @spec do_head(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {term(), Pyex.Env.t(), Pyex.Ctx.t()})}
  defp do_head([url], kwargs) when is_binary(url), do: do_request(:head, url, kwargs)

  @spec do_options(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {term(), Pyex.Env.t(), Pyex.Ctx.t()})}
  defp do_options([url], kwargs) when is_binary(url), do: do_request(:options, url, kwargs)

  @spec do_request(
          atom(),
          String.t(),
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {term(), Pyex.Env.t(), Pyex.Ctx.t()})}
  defp do_request(method, url, kwargs) do
    headers = build_headers(kwargs)
    method_str = method |> Atom.to_string() |> String.upcase()

    req_opts =
      [headers: headers, method: method, url: url] ++ body_opts(kwargs)

    {:io_call,
     fn env, ctx ->
       case Pyex.Ctx.check_network_access(ctx, method_str, url) do
         {:denied, reason} ->
           {{:exception, reason}, env, ctx}

         :ok ->
           result =
             Tracer.with_span "http.request",
                              %{attributes: %{"http.method" => method_str, "http.url" => url}} do
               case Req.request(req_opts) do
                 {:ok, resp} ->
                   response = build_response(resp)
                   Tracer.set_attribute("http.status_code", resp.status)
                   Tracer.set_attribute("http.response_body_size", byte_size(response["text"]))
                   response

                 {:error, reason} ->
                   Tracer.set_attribute("error", true)
                   Tracer.set_attribute("error.message", inspect(reason))
                   {:exception, "requests.#{method} failed: #{inspect(reason)}"}
               end
             end

           {result, env, ctx}
       end
     end}
  end

  @spec body_opts(%{optional(String.t()) => Pyex.Interpreter.pyvalue()}) :: keyword()
  defp body_opts(kwargs) do
    json_data = Map.get(kwargs, "json")
    data = Map.get(kwargs, "data")

    cond do
      json_data != nil -> [json: to_jason_compatible(json_data)]
      data != nil && is_binary(data) -> [body: data]
      true -> []
    end
  end

  @spec build_response(Req.Response.t()) :: Pyex.Interpreter.pyvalue()
  defp build_response(%Req.Response{status: status, body: body, headers: resp_headers}) do
    text = if is_binary(body), do: body, else: Jason.encode!(body)

    headers_map =
      Enum.reduce(resp_headers, %{}, fn {k, v}, acc ->
        Map.put(acc, String.downcase(k), v)
      end)

    %{
      "text" => text,
      "content" => text,
      "status_code" => status,
      "ok" => status >= 200 and status < 300,
      "headers" => headers_map,
      "json" => {:builtin, fn [] -> Jason.decode!(text) end}
    }
  end

  @spec build_headers(%{optional(String.t()) => Pyex.Interpreter.pyvalue()}) :: [
          {String.t(), String.t()}
        ]
  defp build_headers(kwargs) do
    case Map.get(kwargs, "headers") do
      %{} = h -> Enum.map(h, fn {k, v} -> {to_string(k), to_string(v)} end)
      _ -> []
    end
  end

  @spec to_jason_compatible(Pyex.Interpreter.pyvalue()) :: term()
  defp to_jason_compatible({:tuple, items}), do: Enum.map(items, &to_jason_compatible/1)
  defp to_jason_compatible(list) when is_list(list), do: Enum.map(list, &to_jason_compatible/1)

  defp to_jason_compatible(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_jason_compatible(v)} end)
  end

  defp to_jason_compatible(val), do: val
end
