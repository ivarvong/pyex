defmodule Pyex.Stdlib.FastAPI do
  @moduledoc """
  Python `fastapi` module providing a FastAPI-like web framework.

  Supports route registration via decorators. Route handlers are
  stored as a list in the app dict and can be dispatched via
  `Pyex.Lambda.invoke/2`.

      import fastapi
      app = fastapi.FastAPI()

      @app.get("/hello")
      def hello():
          return {"message": "hello world"}

      @app.get("/users/{user_id}")
      def get_user(user_id):
          return {"user_id": user_id}
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.{Interpreter, PyDict}

  @type route ::
          {{String.t(), String.t()}, Interpreter.pyvalue(), integer() | nil}
          | {{String.t(), String.t()}, Interpreter.pyvalue()}

  @type compiled_route ::
          {String.t(), [String.t() | :param], [String.t()], Interpreter.pyvalue()}

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    responses_attrs = %{
      "HTMLResponse" => {:builtin_kw, &html_response/2},
      "JSONResponse" => {:builtin_kw, &json_response/2},
      "StreamingResponse" => {:builtin_kw, &streaming_response/2}
    }

    %{
      "FastAPI" => {:builtin, &create_app/1},
      "HTTPException" => http_exception_class(),
      "responses" => {:module, "fastapi.responses", responses_attrs},
      "testclient" =>
        {:module, "fastapi.testclient", %{"TestClient" => {:builtin_kw, &test_client/2}}},
      "HTMLResponse" => {:builtin_kw, &html_response/2},
      "JSONResponse" => {:builtin_kw, &json_response/2},
      "StreamingResponse" => {:builtin_kw, &streaming_response/2}
    }
  end

  # ── HTTPException ─────────────────────────────────────────────────────────

  @spec http_exception_class() :: Interpreter.pyvalue()
  defp http_exception_class do
    {:class, "HTTPException", [],
     %{
       "__name__" => "HTTPException",
       "__init__" => {:builtin_kw, &http_exception_init/2}
     }}
  end

  @spec http_exception_init(
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()}
        ) :: Interpreter.pyvalue()
  defp http_exception_init([self | pos], kwargs) do
    {:instance, class, attrs} = self
    status = Map.get(kwargs, "status_code", Enum.at(pos, 0, 500))
    detail = Map.get(kwargs, "detail", Enum.at(pos, 1))

    {:instance, class,
     Map.merge(attrs, %{
       "status_code" => status,
       "detail" => detail,
       "args" => {:tuple, [status]}
     })}
  end

  # ── TestClient ────────────────────────────────────────────────────────────

  @spec test_client([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          Interpreter.pyvalue()
  defp test_client([app | _], kwargs) do
    # Like Starlette's TestClient, an unhandled exception in a handler is
    # re-raised by default (raise_server_exceptions=True); set it False to get
    # a 500 response instead — the behaviour a deployed app exhibits.
    raise_server_exceptions = truthy(Map.get(kwargs, "raise_server_exceptions", true))

    %{
      "__testclient__" => true,
      "__app__" => app,
      "get" => client_method("GET", app, raise_server_exceptions),
      "post" => client_method("POST", app, raise_server_exceptions),
      "put" => client_method("PUT", app, raise_server_exceptions),
      "delete" => client_method("DELETE", app, raise_server_exceptions),
      "patch" => client_method("PATCH", app, raise_server_exceptions)
    }
  end

  defp test_client(_, _), do: {:exception, "TypeError: TestClient() requires an app argument"}

  @spec truthy(Interpreter.pyvalue()) :: boolean()
  defp truthy(false), do: false
  defp truthy(nil), do: false
  defp truthy(0), do: false
  defp truthy(_), do: true

  @spec client_method(String.t(), Interpreter.pyvalue(), boolean()) :: Interpreter.pyvalue()
  defp client_method(method, app, raise_server_exceptions) do
    {:builtin_kw,
     fn [path | _], kwargs when is_binary(path) ->
       {:ctx_call,
        fn env, ctx -> dispatch(method, app, path, kwargs, raise_server_exceptions, env, ctx) end}
     end}
  end

  # Matches the request against the app's routes, injects path/query/body
  # parameters into the handler, calls it, and wraps the result in a Response.
  @spec dispatch(
          String.t(),
          Interpreter.pyvalue(),
          String.t(),
          %{optional(String.t()) => Interpreter.pyvalue()},
          boolean(),
          Pyex.Env.t(),
          Pyex.Ctx.t()
        ) :: {Interpreter.pyvalue(), Pyex.Env.t(), Pyex.Ctx.t()}
  defp dispatch(method, app, full_path, kwargs, raise_server_exceptions, env, ctx) do
    {path, query} = split_query(full_path)
    routes = Map.get(app, "__routes__", [])

    case find_route(routes, method, path) do
      {:ok, handler, path_params, status} ->
        case build_handler_args(handler, path_params, query, kwargs, env, ctx) do
          {:ok, args} ->
            case Interpreter.call_function(handler, [], args, env, ctx) do
              {{:exception, msg}, env, ctx} ->
                {error_response(msg, raise_server_exceptions, ctx), env, ctx}

              {{:exception, msg}, env, ctx, _} ->
                {error_response(msg, raise_server_exceptions, ctx), env, ctx}

              {result, env, ctx} ->
                {success_response(result, status), env, ctx}

              {result, env, ctx, _} ->
                {success_response(result, status), env, ctx}
            end

          {:error, errors} ->
            # FastAPI returns 422 Unprocessable Entity for request-validation
            # failures (bad path/query coercion or an invalid body).
            {make_response(422, PyDict.from_pairs([{"detail", py_list(errors)}])), env, ctx}
        end

      :method_not_allowed ->
        {make_response(405, PyDict.from_pairs([{"detail", "Method Not Allowed"}])), env, ctx}

      :no_match ->
        {make_response(404, PyDict.from_pairs([{"detail", "Not Found"}])), env, ctx}
    end
  end

  @spec split_query(String.t()) :: {String.t(), %{String.t() => String.t()}}
  defp split_query(full_path) do
    case String.split(full_path, "?", parts: 2) do
      [path] ->
        {path, %{}}

      [path, qs] ->
        query =
          qs
          |> String.split("&", trim: true)
          |> Map.new(fn pair ->
            case String.split(pair, "=", parts: 2) do
              [k, v] -> {URI.decode(k), URI.decode(v)}
              [k] -> {URI.decode(k), ""}
            end
          end)

        {path, query}
    end
  end

  @spec find_route([route()], String.t(), String.t()) ::
          {:ok, Interpreter.pyvalue(), %{String.t() => String.t()}, integer() | nil}
          | :method_not_allowed
          | :no_match
  defp find_route(routes, method, path) do
    request_segments = String.split(path, "/", trim: true)

    # Halt on the first method+path match. If the path matches a route but the
    # method differs, remember it so we can answer 405 rather than 404.
    Enum.reduce_while(routes, :no_match, fn route, acc ->
      {{route_method, template}, handler, status} = normalize_route(route)
      {segments, param_names} = compile_path(template)

      case match_segments(segments, param_names, request_segments) do
        {:ok, path_params} when route_method == method ->
          {:halt, {:ok, handler, path_params, status}}

        {:ok, _path_params} ->
          {:cont, :method_not_allowed}

        :no_match ->
          {:cont, acc}
      end
    end)
  end

  # Routes registered before status_code support are 2-tuples; new ones carry
  # the declared status as a third element.
  defp normalize_route({{_m, _t}, _h, _s} = route), do: route
  defp normalize_route({{m, t}, h}), do: {{m, t}, h, nil}

  @spec match_segments([String.t() | :param], [String.t()], [String.t()]) ::
          {:ok, %{String.t() => String.t()}} | :no_match
  defp match_segments(segments, param_names, request_segments)
       when length(segments) == length(request_segments) do
    Enum.zip(segments, request_segments)
    |> Enum.reduce_while({:ok, %{}, param_names}, fn
      {:param, value}, {:ok, acc, [name | rest]} ->
        {:cont, {:ok, Map.put(acc, name, value), rest}}

      {seg, value}, {:ok, acc, names} when seg == value ->
        {:cont, {:ok, acc, names}}

      _, _ ->
        {:halt, :no_match}
    end)
    |> case do
      {:ok, params, _} -> {:ok, params}
      :no_match -> :no_match
    end
  end

  defp match_segments(_segments, _param_names, _request_segments), do: :no_match

  # Classifies each handler parameter as a path param (coerced to its annotated
  # type), a request body (a pydantic model built from `json=`), or a query
  # param, and builds the keyword map the handler is called with.
  @spec build_handler_args(
          Interpreter.pyvalue(),
          %{String.t() => String.t()},
          %{String.t() => String.t()},
          %{optional(String.t()) => Interpreter.pyvalue()},
          Pyex.Env.t(),
          Pyex.Ctx.t()
        ) ::
          {:ok, %{String.t() => Interpreter.pyvalue()}} | {:error, [Interpreter.pyvalue()]}
  defp build_handler_args(handler, path_params, query, kwargs, env, ctx) do
    json_body = Map.get(kwargs, "json")

    handler
    |> handler_params()
    |> Enum.reduce_while({:ok, %{}}, fn {name, _default, type}, {:ok, acc} ->
      cond do
        Map.has_key?(path_params, name) ->
          bind_coerced(acc, name, Map.get(path_params, name), type, "path")

        pydantic_param?(type, env, ctx) ->
          case build_body(type, json_body, env, ctx) do
            {:ok, instance} -> {:cont, {:ok, Map.put(acc, name, instance)}}
            {:error, errors} -> {:halt, {:error, errors}}
          end

        Map.has_key?(query, name) ->
          bind_coerced(acc, name, Map.get(query, name), type, "query")

        true ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  @spec bind_coerced(map(), String.t(), String.t(), String.t() | nil, String.t()) ::
          {:cont, {:ok, map()}} | {:halt, {:error, [Interpreter.pyvalue()]}}
  defp bind_coerced(acc, name, raw, type, location) do
    case coerce_param(raw, type) do
      {:ok, value} ->
        {:cont, {:ok, Map.put(acc, name, value)}}

      :error ->
        {:halt, {:error, [coercion_error(location, name, type)]}}
    end
  end

  @spec handler_params(Interpreter.pyvalue()) :: [{String.t(), term(), String.t() | nil}]
  defp handler_params({:func_with_attrs, func, _}), do: handler_params(func)

  defp handler_params({:function, _name, params, _body, _env, _gen, _kind}) do
    Enum.map(params, fn
      {name, default, type} -> {name, default, normalize_type(type)}
      {name, default} -> {name, default, nil}
    end)
  end

  defp handler_params(_), do: []

  @spec normalize_type(term()) :: String.t() | nil
  defp normalize_type(type) when is_binary(type) and type != "", do: type
  defp normalize_type(_), do: nil

  @spec coerce_param(String.t(), String.t() | nil) :: {:ok, Interpreter.pyvalue()} | :error
  defp coerce_param(value, "int") do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp coerce_param(value, "float") do
    case Float.parse(value) do
      {f, ""} -> {:ok, f}
      _ -> :error
    end
  end

  defp coerce_param(value, "bool"), do: {:ok, value in ["true", "1", "True"]}
  defp coerce_param(value, _), do: {:ok, value}

  @spec pydantic_param?(String.t() | nil, Pyex.Env.t(), Pyex.Ctx.t()) :: boolean()
  defp pydantic_param?(nil, _env, _ctx), do: false

  defp pydantic_param?(type, env, ctx) do
    case resolve_type(type, env, ctx) do
      {:ok, class} -> Pyex.Stdlib.Pydantic.pydantic_class?(class)
      :error -> false
    end
  end

  # Validates the request body against the pydantic model. A missing body or a
  # validation failure (wrong type, missing field, non-dict) is a 422.
  @spec build_body(String.t(), Interpreter.pyvalue() | nil, Pyex.Env.t(), Pyex.Ctx.t()) ::
          {:ok, Interpreter.pyvalue()} | {:error, [Interpreter.pyvalue()]}
  defp build_body(_type, nil, _env, _ctx),
    do: {:error, [body_error("Field required")]}

  defp build_body(type, json_body, env, ctx) do
    case resolve_type(type, env, ctx) do
      {:ok, class} ->
        case Pyex.Stdlib.Pydantic.validate_body(class, Pyex.Ctx.deref(ctx, json_body), env, ctx) do
          {:ok, instance} -> {:ok, instance}
          {:error, msg} -> {:error, [body_error(msg)]}
        end

      :error ->
        {:ok, json_body}
    end
  end

  @spec resolve_type(String.t(), Pyex.Env.t(), Pyex.Ctx.t()) ::
          {:ok, Interpreter.pyvalue()} | :error
  defp resolve_type(type, env, ctx) do
    case Pyex.Env.get(env, type) do
      {:ok, value} -> {:ok, Pyex.Ctx.deref(ctx, value)}
      _ -> :error
    end
  end

  # ── 422 validation error detail (FastAPI-shaped: a list of error objects) ──

  @spec coercion_error(String.t(), String.t(), String.t() | nil) :: Interpreter.pyvalue()
  defp coercion_error(location, name, type) do
    error_object(
      "#{type}_parsing",
      py_list([location, name]),
      "Input should be a valid #{type || "value"}"
    )
  end

  @spec body_error(String.t()) :: Interpreter.pyvalue()
  defp body_error(msg), do: error_object("value_error", py_list(["body"]), msg)

  @spec error_object(String.t(), Interpreter.pyvalue(), String.t()) :: Interpreter.pyvalue()
  defp error_object(type, loc, msg) do
    PyDict.from_pairs([{"type", type}, {"loc", loc}, {"msg", msg}])
  end

  @spec py_list([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp py_list(items), do: {:py_list, Enum.reverse(items), length(items)}

  # ── Response construction ─────────────────────────────────────────────────

  @spec success_response(Interpreter.pyvalue(), integer() | nil) :: Interpreter.pyvalue()
  # A handler that returns an explicit Response keeps its own status; otherwise
  # the route's declared status_code applies, defaulting to 200.
  defp success_response(%{"__response__" => true} = resp, _route_status) do
    make_response(Map.get(resp, "status_code", 200), Map.get(resp, "body"))
  end

  defp success_response(result, route_status),
    do: make_response(route_status || 200, to_json_body(result))

  @spec error_response(String.t(), boolean(), Pyex.Ctx.t()) ::
          Interpreter.pyvalue() | {:exception, String.t()}
  defp error_response(msg, raise_server_exceptions, ctx) do
    case ctx.exception_instance do
      {:instance, {:class, "HTTPException", _, _}, attrs} ->
        # HTTPException is always turned into a response, never re-raised.
        status = Map.get(attrs, "status_code", 500)
        detail = Map.get(attrs, "detail")
        make_response(status, PyDict.from_pairs([{"detail", detail}]))

      _ when raise_server_exceptions ->
        # Default TestClient behaviour: an unhandled handler exception
        # propagates out of the request call for debugging.
        {:exception, msg}

      _ ->
        # raise_server_exceptions=False: behave like a deployed server.
        make_response(500, PyDict.from_pairs([{"detail", "Internal Server Error"}]))
    end
  end

  # A pydantic model in a handler's return is serialized like model_dump.
  @spec to_json_body(Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp to_json_body({:instance, class, _} = inst) do
    if Pyex.Stdlib.Pydantic.pydantic_class?(class) do
      case Pyex.Stdlib.Pydantic.validate_body(class, %{}) do
        _ -> model_to_dict(inst)
      end
    else
      inst
    end
  end

  defp to_json_body(other), do: other

  @spec model_to_dict(Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp model_to_dict({:instance, _class, attrs}) do
    attrs
    |> Enum.reject(fn {k, _} -> String.starts_with?(k, "__") end)
    |> Enum.reduce(PyDict.new(), fn {k, v}, acc -> PyDict.put(acc, k, v) end)
  end

  @spec make_response(integer(), Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp make_response(status, body) do
    {:instance, response_class(),
     %{
       "status_code" => status,
       "__body__" => body,
       "text" => response_text(body)
     }}
  end

  @spec response_class() :: Interpreter.pyvalue()
  defp response_class do
    {:class, "Response", [],
     %{
       "__name__" => "Response",
       "json" => {:builtin, &response_json/1}
     }}
  end

  @spec response_json([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp response_json([{:instance, _, attrs}]), do: Map.get(attrs, "__body__")

  @spec response_text(Interpreter.pyvalue()) :: String.t()
  defp response_text(body) do
    case Pyex.Stdlib.JSON.dumps(body, %{"separators" => {",", ":"}}) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  @spec html_response([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          Interpreter.pyvalue()
  defp html_response([content], kwargs) when is_binary(content) do
    status = Map.get(kwargs, "status_code", 200)
    extra = Map.get(kwargs, "headers", %{})
    headers = Map.merge(%{"content-type" => "text/html"}, to_plain_map(extra))

    %{
      "__response__" => true,
      "status_code" => status,
      "headers" => headers,
      "body" => content
    }
  end

  defp html_response([content], _kwargs) do
    %{
      "__response__" => true,
      "status_code" => 200,
      "headers" => %{"content-type" => "text/html"},
      "body" => to_string(content)
    }
  end

  defp html_response([], _kwargs) do
    {:exception, "TypeError: HTMLResponse() missing required argument: 'content'"}
  end

  @spec json_response([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          Interpreter.pyvalue()
  defp json_response([content], kwargs) do
    status = Map.get(kwargs, "status_code", 200)
    extra = Map.get(kwargs, "headers", %{})
    headers = Map.merge(%{"content-type" => "application/json"}, to_plain_map(extra))

    %{
      "__response__" => true,
      "status_code" => status,
      "headers" => headers,
      "body" => content
    }
  end

  defp json_response([], _kwargs) do
    {:exception, "TypeError: JSONResponse() missing required argument: 'content'"}
  end

  @spec streaming_response(
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()}
        ) :: Interpreter.pyvalue()
  defp streaming_response([content], kwargs) do
    status = Map.get(kwargs, "status_code", 200)
    media = Map.get(kwargs, "media_type", "text/plain")
    extra = Map.get(kwargs, "headers", %{})
    headers = Map.merge(%{"content-type" => media}, to_plain_map(extra))

    %{
      "__response__" => true,
      "__streaming__" => true,
      "status_code" => status,
      "headers" => headers,
      "body" => extract_chunks(content),
      "__raw_content__" => content
    }
  end

  defp streaming_response([], _kwargs) do
    {:exception, "TypeError: StreamingResponse() missing required argument: 'content'"}
  end

  @spec extract_chunks(Interpreter.pyvalue()) ::
          [String.t()]
          | {:generator_suspended, term(), term(), Pyex.Env.t()}
          | {:iterator, non_neg_integer()}
  defp extract_chunks({:generator_suspended, _, _, _} = suspended), do: suspended
  # Lazy-mode generator iterators pass through; the consumer drains
  # them when finalising the response (in `Lambda.handle/2`).
  defp extract_chunks({:iterator, _id} = iter), do: iter
  defp extract_chunks({:generator, items}), do: Enum.map(items, &to_string/1)

  defp extract_chunks({:py_list, reversed, _}),
    do: reversed |> Enum.reverse() |> Enum.map(&to_string/1)

  defp extract_chunks(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp extract_chunks({:tuple, items}), do: Enum.map(items, &to_string/1)
  defp extract_chunks(str) when is_binary(str), do: [str]
  defp extract_chunks(other), do: [to_string(other)]

  @spec create_app([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp create_app([]) do
    %{
      "__routes__" => [],
      "get" => {:builtin_kw, &route_decorator("GET", &1, &2)},
      "post" => {:builtin_kw, &route_decorator("POST", &1, &2)},
      "put" => {:builtin_kw, &route_decorator("PUT", &1, &2)},
      "delete" => {:builtin_kw, &route_decorator("DELETE", &1, &2)}
    }
  end

  @spec route_decorator(String.t(), [Interpreter.pyvalue()], %{
          optional(String.t()) => Interpreter.pyvalue()
        }) :: Interpreter.pyvalue()
  defp route_decorator(method, [path | _], kwargs) when is_binary(path) do
    # @app.post("/x", status_code=201) — capture the declared status; nil means
    # the dispatch default (200) applies.
    status = Map.get(kwargs, "status_code")

    {:builtin,
     fn [handler] ->
       {:register_route, method, path, handler, status}
     end}
  end

  @doc """
  Compiles a path template into segments and parameter names.

  Path parameters use `{name}` syntax and are replaced with the
  atom `:param` in the segment list.

      iex> Pyex.Stdlib.FastAPI.compile_path("/users/{user_id}")
      {["users", :param], ["user_id"]}
  """
  @spec compile_path(String.t()) :: {[String.t() | :param], [String.t()]}
  def compile_path(path) do
    segments =
      path
      |> String.split("/", trim: true)

    {compiled, params} =
      Enum.reduce(segments, {[], []}, fn segment, {segs, params} ->
        if String.starts_with?(segment, "{") and String.ends_with?(segment, "}") do
          name = String.slice(segment, 1..-2//1)
          {[:param | segs], [name | params]}
        else
          {[segment | segs], params}
        end
      end)

    {Enum.reverse(compiled), Enum.reverse(params)}
  end

  @spec to_plain_map(Interpreter.pyvalue()) :: map()
  defp to_plain_map({:py_dict, _, _} = dict), do: PyDict.to_map(dict)
  defp to_plain_map(%{} = map), do: map
  defp to_plain_map(_), do: %{}
end
