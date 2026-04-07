defmodule Pyex.Stdlib.Requests do
  @moduledoc """
  Python `requests` module backed by Req.

  Provides `requests.get`, `requests.post`, `requests.put`,
  `requests.patch`, `requests.delete`, `requests.head`, and
  `requests.options` which return an object with `.text`,
  `.status_code`, `.ok`, `.headers`, `.json()`, and
  `.raise_for_status()` attributes, matching the real
  `requests.Response` interface.

  Also provides `requests.Session()` for persistent headers and
  `requests.HTTPError` for exception catching.

  All HTTP calls emit `:telemetry` events (`[:pyex, :request, :start]`
  and `[:pyex, :request, :stop]`). I/O time is excluded from the
  compute budget via `{:io_call, fn}` signals.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.PyDict

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
      "options" => {:builtin_kw, &do_options/2},
      "Session" => {:builtin, fn [] -> build_session() end},
      "HTTPError" => "requests.HTTPError",
      "__version__" => "2.31.0"
    }
  end

  @doc """
  Public entry point used by `urllib.request.urlopen` to reuse the same
  HTTP client, network-policy enforcement, and telemetry pipeline as
  `requests.get/post/...`. Returns an `{:io_call, fn}` whose result is
  the same response py_dict as `requests.get`.
  """
  @spec request_io_call(
          atom(),
          String.t(),
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {term(), Pyex.Env.t(), Pyex.Ctx.t()})}
  def request_io_call(method, url, kwargs), do: do_request(method, url, kwargs)

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

  # ── Session ─────────────────────────────────────────────────────

  @spec build_session() :: Pyex.Interpreter.pyvalue()
  defp build_session do
    # Allocate a heap slot for the session headers dict. The heap_id is
    # captured by closures so they always read/write the current value
    # through ctx, matching Python's mutable Session semantics without
    # using a process or agent.
    {:ctx_call,
     fn env, ctx ->
       {ref, ctx} = Pyex.Ctx.heap_alloc(ctx, PyDict.new())
       {:ref, headers_id} = ref

       session_method = fn method ->
         {:builtin_kw,
          fn [url], kwargs when is_binary(url) ->
            {:ctx_call,
             fn env2, ctx2 ->
               current_headers = Map.get(ctx2.heap, headers_id, PyDict.new())
               merged_kwargs = merge_session_headers(kwargs, current_headers)

               {:io_call, inner_fn} = do_request(method, url, merged_kwargs)
               ctx2 = Pyex.Ctx.pause_compute(ctx2)
               {result, env2, ctx2} = inner_fn.(env2, ctx2)
               {result, env2, Pyex.Ctx.resume_compute(ctx2)}
             end}
          end}
       end

       headers_obj =
         PyDict.from_pairs([
           {"update",
            {:builtin,
             fn [new_headers] ->
               {:ctx_call,
                fn env2, ctx2 ->
                  current = Map.get(ctx2.heap, headers_id, PyDict.new())

                  updated =
                    case new_headers do
                      {:py_dict, _, _} = h -> PyDict.merge(current, h)
                      %{} = m -> PyDict.merge_map(current, m)
                      _ -> current
                    end

                  {nil, env2, Pyex.Ctx.heap_put(ctx2, headers_id, updated)}
                end}
             end}},
           {"__setitem__",
            {:builtin,
             fn [key, value] ->
               {:ctx_call,
                fn env2, ctx2 ->
                  current = Map.get(ctx2.heap, headers_id, PyDict.new())
                  updated = PyDict.put(current, key, value)
                  {nil, env2, Pyex.Ctx.heap_put(ctx2, headers_id, updated)}
                end}
             end}}
         ])

       session_dict =
         PyDict.from_pairs([
           {"headers", headers_obj},
           {"get", session_method.(:get)},
           {"post", session_method.(:post)},
           {"put", session_method.(:put)},
           {"patch", session_method.(:patch)},
           {"delete", session_method.(:delete)},
           {"head", session_method.(:head)},
           {"options", session_method.(:options)}
         ])

       {session_dict, env, ctx}
     end}
  end

  @spec merge_session_headers(
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()},
          PyDict.t()
        ) :: %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
  defp merge_session_headers(kwargs, session_headers) do
    per_request = Map.get(kwargs, "headers")

    merged =
      case per_request do
        {:py_dict, _, _} = h -> PyDict.merge(session_headers, h)
        _ -> session_headers
      end

    if PyDict.empty?(merged) do
      kwargs
    else
      Map.put(kwargs, "headers", merged)
    end
  end

  # ── Core request ────────────────────────────────────────────────

  @spec do_request(
          atom(),
          String.t(),
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {term(), Pyex.Env.t(), Pyex.Ctx.t()})}
  defp do_request(method, url, kwargs) do
    user_headers = build_headers(kwargs)
    method_str = method |> Atom.to_string() |> String.upcase()
    url = append_params(url, kwargs)

    {:io_call,
     fn env, ctx ->
       case Pyex.Ctx.check_network_access(ctx, method_str, url) do
         {:denied, reason} ->
           {{:exception, reason}, env, ctx}

         {:ok, inject_headers} ->
           # Injected headers override user-provided ones (host config wins)
           headers = merge_headers(user_headers, inject_headers)

           req_opts =
             [headers: headers, method: method, url: url, redirect: false, retry: false] ++
               body_opts(kwargs) ++
               timeout_opts(kwargs)

           start_mono = System.monotonic_time()
           telemetry_meta = %{method: method_str, url: url}

           :telemetry.execute(
             [:pyex, :request, :start],
             %{system_time: System.system_time()},
             telemetry_meta
           )

           result =
             case Req.request(req_opts) do
               {:ok, resp} ->
                 response = build_response(resp)
                 duration = System.monotonic_time() - start_mono

                 :telemetry.execute([:pyex, :request, :stop], %{duration: duration}, %{
                   method: method_str,
                   url: url,
                   status: resp.status,
                   response_body_size: byte_size(PyDict.get(response, "text"))
                 })

                 response

               {:error, reason} ->
                 duration = System.monotonic_time() - start_mono

                 :telemetry.execute([:pyex, :request, :stop], %{duration: duration}, %{
                   method: method_str,
                   url: url,
                   error: inspect(reason)
                 })

                 {:exception, "requests.#{method} failed: #{inspect(reason)}"}
             end

           {result, env, ctx}
       end
     end}
  end

  @spec merge_headers([{String.t(), String.t()}], [{String.t(), String.t()}]) :: [
          {String.t(), String.t()}
        ]
  defp merge_headers(user_headers, []), do: user_headers

  defp merge_headers(user_headers, inject_headers) do
    inject_keys = MapSet.new(inject_headers, fn {k, _} -> String.downcase(k) end)

    filtered = Enum.reject(user_headers, fn {k, _} -> String.downcase(k) in inject_keys end)
    filtered ++ inject_headers
  end

  # ── params= kwarg ───────────────────────────────────────────────

  @spec append_params(String.t(), %{optional(String.t()) => Pyex.Interpreter.pyvalue()}) ::
          String.t()
  defp append_params(url, kwargs) do
    case Map.get(kwargs, "params") do
      {:py_dict, _, _} = params ->
        query =
          params
          |> PyDict.items()
          |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
          |> URI.encode_query()

        separator = if String.contains?(url, "?"), do: "&", else: "?"
        url <> separator <> query

      _ ->
        url
    end
  end

  # ── body opts ───────────────────────────────────────────────────

  @spec body_opts(%{optional(String.t()) => Pyex.Interpreter.pyvalue()}) :: keyword()
  defp body_opts(kwargs) do
    json_data = Map.get(kwargs, "json")
    data = Map.get(kwargs, "data")

    cond do
      json_data != nil -> [json: to_jason_compatible(json_data)]
      data != nil && is_binary(data) -> [body: data]
      data != nil -> [body: form_encode(data)]
      true -> []
    end
  end

  @spec timeout_opts(%{optional(String.t()) => Pyex.Interpreter.pyvalue()}) :: keyword()
  defp timeout_opts(kwargs) do
    case Map.get(kwargs, "timeout") do
      seconds when is_number(seconds) and seconds > 0 ->
        [receive_timeout: round(seconds * 1000)]

      _ ->
        []
    end
  end

  @spec form_encode(Pyex.Interpreter.pyvalue()) :: String.t()
  defp form_encode({:py_dict, _, _} = dict) do
    dict
    |> PyDict.items()
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> URI.encode_query()
  end

  defp form_encode(%{} = map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> URI.encode_query()
  end

  # ── Response ────────────────────────────────────────────────────

  @spec build_response(Req.Response.t()) :: Pyex.Interpreter.pyvalue()
  defp build_response(%Req.Response{status: status, body: body, headers: resp_headers}) do
    text =
      if is_binary(body) do
        body
      else
        case Jason.encode(body) do
          {:ok, json} -> json
          {:error, _} -> inspect(body)
        end
      end

    headers_map =
      Enum.map(resp_headers, fn {k, v} -> {String.downcase(k), v} end)
      |> PyDict.from_pairs()

    error_kind =
      cond do
        status >= 400 and status < 500 -> "Client Error"
        status >= 500 -> "Server Error"
        true -> nil
      end

    PyDict.from_pairs([
      {"text", text},
      {"content", text},
      {"status_code", status},
      {"ok", status >= 200 and status < 300},
      {"headers", headers_map},
      {"json",
       {:builtin,
        fn [] ->
          case Jason.decode(text) do
            {:ok, value} -> value
            {:error, reason} -> {:exception, "json.JSONDecodeError: #{inspect(reason)}"}
          end
        end}},
      {"raise_for_status",
       {:builtin,
        fn [] ->
          if error_kind do
            {:exception, "requests.HTTPError: #{status} #{error_kind}"}
          else
            nil
          end
        end}}
    ])
  end

  @spec build_headers(%{optional(String.t()) => Pyex.Interpreter.pyvalue()}) :: [
          {String.t(), String.t()}
        ]
  defp build_headers(kwargs) do
    case Map.get(kwargs, "headers") do
      {:py_dict, _, _} = h ->
        Enum.map(PyDict.items(h), fn {k, v} -> {to_string(k), to_string(v)} end)

      %{} = h ->
        Enum.map(h, fn {k, v} -> {to_string(k), to_string(v)} end)

      _ ->
        []
    end
  end

  @spec to_jason_compatible(Pyex.Interpreter.pyvalue()) :: term()
  defp to_jason_compatible({:tuple, items}), do: Enum.map(items, &to_jason_compatible/1)
  defp to_jason_compatible(list) when is_list(list), do: Enum.map(list, &to_jason_compatible/1)

  defp to_jason_compatible({:py_dict, _, _} = dict) do
    pairs = Enum.map(PyDict.items(dict), fn {k, v} -> {to_string(k), to_jason_compatible(v)} end)
    Map.new(pairs)
  end

  defp to_jason_compatible(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_jason_compatible(v)} end)
  end

  defp to_jason_compatible(val), do: val
end
