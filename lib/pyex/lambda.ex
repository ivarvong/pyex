defmodule Pyex.Lambda do
  @moduledoc """
  Lambda-style execution of Pyex FastAPI programs.

  Interprets a Python source string containing FastAPI route
  definitions, matches an incoming request against the route
  table, calls the handler, and returns a response map. No
  server process, no ports -- routes are plain data in the
  interpreter environment, fully serializable and observable.

  ## Single-shot (stateless)

      source = \"\"\"
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/hello")
      def hello():
          return {"message": "hello world"}
      \"\"\"

      {:ok, resp} = Pyex.Lambda.invoke(source, %{method: "GET", path: "/hello"})
      resp.status  #=> 200
      resp.body    #=> %{"message" => "hello world"}

  ## Boot + handle (stateful)

  For programs that persist state across requests (e.g. via
  the filesystem), boot the program once and handle requests
  against the returned app. The `Ctx` (with filesystem) is
  threaded through each call.

      {:ok, app} = Pyex.Lambda.boot(source, ctx: ctx)
      {:ok, resp, app} = Pyex.Lambda.handle(app, %{method: "POST", path: "/todos", body: body})
      {:ok, resp, app} = Pyex.Lambda.handle(app, %{method: "GET", path: "/todos"})
  """

  alias Pyex.{Builtins, Ctx, Env, Error, Interpreter}
  alias Pyex.Stdlib.FastAPI
  alias Pyex.Stdlib.Pydantic

  @type request :: %{
          required(:method) => String.t(),
          required(:path) => String.t(),
          optional(:headers) => %{optional(String.t()) => String.t()},
          optional(:query) => %{optional(String.t()) => String.t()},
          optional(:body) => String.t() | nil
        }

  @type telemetry :: %{
          compute_us: non_neg_integer(),
          total_us: non_neg_integer(),
          event_count: non_neg_integer(),
          file_ops: non_neg_integer()
        }

  @type response :: %{
          status: non_neg_integer(),
          headers: %{optional(String.t()) => String.t()},
          body: Interpreter.pyvalue(),
          telemetry: telemetry()
        }

  @type stream_response :: %{
          status: non_neg_integer(),
          headers: %{optional(String.t()) => String.t()},
          chunks: [String.t()],
          telemetry: telemetry()
        }

  @type compiled_route ::
          {String.t(), [String.t() | :param], [String.t()], Interpreter.pyvalue()}

  @type app :: %{
          routes: [compiled_route()],
          env: Env.t(),
          ctx: Ctx.t()
        }

  @doc """
  Executes a Python FastAPI program against a single request.

  Interprets `source`, extracts the route table from the `app`
  variable, matches the request, calls the handler, and returns
  a response map.

  Options:
  - `:ctx` -- a `Pyex.Ctx` to use (e.g. with `:environ` for `os.environ`)

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @spec invoke(String.t(), request(), keyword()) :: {:ok, response()} | {:error, Error.t()}
  def invoke(source, request, opts \\ []) do
    ctx = Keyword.get(opts, :ctx, Ctx.new())

    with {:ok, env, ctx} <- interpret(source, ctx),
         {:ok, routes} <- extract_routes(env),
         {:ok, handler, path_params} <- match(routes, request) do
      execute(handler, path_params, request, ctx)
    end
  end

  @doc """
  Like `invoke/3` but raises on error.
  """
  @spec invoke!(String.t(), request(), keyword()) :: response()
  def invoke!(source, request, opts \\ []) do
    case invoke(source, request, opts) do
      {:ok, response} -> response
      {:error, %Error{message: msg}} -> raise msg
    end
  end

  @doc """
  Boots a FastAPI program, returning a reusable app.

  Interprets the source once, extracts routes, and captures
  the environment and context. The app can then be used with
  `handle/2` to dispatch multiple requests while threading
  the context (including filesystem state) through each call.

  Options:
  - `:ctx` -- a `Pyex.Ctx` to use (default: `Ctx.new()`)

  ## Example

      ctx = Pyex.Ctx.new(filesystem: fs, fs_module: Memory)
      {:ok, app} = Pyex.Lambda.boot(source, ctx: ctx)
  """
  @spec boot(String.t(), keyword()) :: {:ok, app()} | {:error, Error.t()}
  def boot(source, opts \\ []) do
    ctx = Keyword.get(opts, :ctx, Ctx.new())

    with {:ok, env, ctx} <- interpret(source, ctx),
         {:ok, routes} <- extract_routes(env) do
      {:ok, %{routes: routes, env: env, ctx: ctx}}
    end
  end

  @doc """
  Dispatches a request against a booted app.

  Matches the request, calls the handler, and returns the
  response along with the updated app (whose `ctx` reflects
  any side effects like filesystem writes).

  ## Example

      {:ok, resp, app} = Pyex.Lambda.handle(app, %{method: "GET", path: "/todos"})
      resp.body  #=> [...]
  """
  @spec handle(app(), request()) :: {:ok, response(), app()} | {:error, Error.t()}
  def handle(%{routes: routes, env: _env, ctx: ctx} = app, request) do
    case match(routes, request) do
      {:ok, handler, path_params} ->
        {:ok, response, new_ctx, updated_handler} =
          execute_with_ctx(handler, path_params, request, ctx)

        new_routes = update_route_handler(routes, handler, updated_handler)
        {:ok, response, %{app | ctx: new_ctx, routes: new_routes}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Dispatches a request and returns a streaming response.

  When the handler returns a `StreamingResponse`, the body is
  returned as a lazy `Enumerable` of string chunks, suitable
  for piping to Phoenix/Plug chunk-by-chunk. A linked process
  is spawned to run the Python handler; generator `yield`
  statements produce chunks lazily via message passing.

  When the handler returns a non-streaming response, the body
  is wrapped in a single-element list for a uniform API.

  The spawned process is linked to the caller. If the caller
  dies (e.g. client disconnect), the interpreter process is
  cleaned up automatically.

  ## Return

      {:ok, stream_response, app}

  where `stream_response` has the shape:

      %{status: 200, headers: %{...}, chunks: stream, telemetry: %{...}}

  ## Phoenix integration

      {:ok, resp, app} = Pyex.Lambda.handle_stream(app, request)
      conn = Plug.Conn.send_chunked(conn, resp.status)

      Enum.reduce_while(resp.chunks, conn, fn chunk, conn ->
        case Plug.Conn.chunk(conn, chunk) do
          {:ok, conn} -> {:cont, conn}
          {:error, :closed} -> {:halt, conn}
        end
      end)

  ## Example

      {:ok, resp, app} = Pyex.Lambda.handle_stream(app, %{method: "GET", path: "/stream"})
      Enum.each(resp.chunks, fn chunk -> IO.write(chunk) end)
  """
  @spec handle_stream(app(), request()) :: {:ok, stream_response(), app()} | {:error, Error.t()}
  def handle_stream(%{routes: routes, env: _env, ctx: ctx} = app, request) do
    case match(routes, request) do
      {:ok, handler, path_params} ->
        t0 = System.monotonic_time(:microsecond)
        events_before = length(ctx.log)
        compute_us_before = Ctx.compute_time_us(ctx)
        stream_ctx = %{ctx | generator_mode: :defer}

        case call_handler_safe(handler, path_params, request, stream_ctx) do
          {:ok, result, new_ctx, updated_handler} ->
            response = unwrap_stream_response(result)
            telem = build_telemetry(t0, events_before, compute_us_before, new_ctx)
            meta = %{status: response.status, headers: response.headers, telemetry: telem}

            chunks =
              case response.chunks do
                {:generator_suspended, first_val, cont, gen_env} ->
                  generator_stream(first_val, cont, gen_env, new_ctx)

                items when is_list(items) ->
                  items
              end

            new_routes = update_route_handler(routes, handler, updated_handler)
            {:ok, Map.put(meta, :chunks, chunks), %{app | ctx: new_ctx, routes: new_routes}}

          {:error, msg, new_ctx, updated_handler} ->
            telem = build_telemetry(t0, events_before, compute_us_before, new_ctx)

            error_body =
              case Jason.encode(%{"detail" => msg}) do
                {:ok, json} -> json
                {:error, _} -> ~s({"detail":"internal error"})
              end

            meta = %{
              status: 500,
              headers: %{"content-type" => "application/json"},
              telemetry: telem,
              chunks: [error_body]
            }

            new_routes = update_route_handler(routes, handler, updated_handler)
            {:ok, meta, %{app | ctx: new_ctx, routes: new_routes}}
        end

      {:error, _} = err ->
        err
    end
  end

  @spec interpret(String.t(), Ctx.t()) :: {:ok, Env.t(), Ctx.t()} | {:error, Error.t()}
  defp interpret(source, ctx) do
    case Pyex.compile(source) do
      {:ok, ast} ->
        ctx = %{ctx | compute_ns: 0, compute_started_at: System.monotonic_time(:nanosecond)}

        case Interpreter.run_with_ctx(ast, Builtins.env(), ctx) do
          {:ok, _value, env, ctx} -> {:ok, env, ctx}
          {:error, msg} -> {:error, Error.from_message(msg)}
        end

      {:error, msg} ->
        {:error, Error.syntax(msg)}
    end
  end

  @spec extract_routes(Env.t()) :: {:ok, [compiled_route()]} | {:error, Error.t()}
  defp extract_routes(env) do
    case Env.get(env, "app") do
      {:ok, %{"__routes__" => raw_routes}} when is_list(raw_routes) ->
        compiled =
          Enum.map(raw_routes, fn {{method, path_template}, handler} ->
            {segments, param_names} = FastAPI.compile_path(path_template)
            {method, segments, param_names, handler}
          end)

        {:ok, compiled}

      {:ok, _} ->
        {:error, Error.from_message("app is not a FastAPI instance")}

      :undefined ->
        {:error, Error.from_message("no 'app' variable found -- define app = fastapi.FastAPI()")}
    end
  end

  @spec match([compiled_route()], request()) ::
          {:ok, Interpreter.pyvalue(), %{optional(String.t()) => String.t()}}
          | {:error, Error.t()}
  defp match(routes, request) do
    method = String.upcase(request.method)
    segments = String.split(request.path, "/", trim: true)

    case find_route(routes, method, segments) do
      {:ok, _handler, _params} = result ->
        result

      :not_found ->
        {:error, Error.route_not_found("no route matches #{method} #{request.path}")}
    end
  end

  @spec find_route([compiled_route()], String.t(), [String.t()]) ::
          {:ok, Interpreter.pyvalue(), %{optional(String.t()) => String.t()}} | :not_found
  defp find_route([], _method, _segments), do: :not_found

  defp find_route([{route_method, pattern, param_names, handler} | rest], method, segments) do
    if route_method == method and segments_match?(pattern, segments) do
      params = extract_params(pattern, param_names, segments)
      {:ok, handler, params}
    else
      find_route(rest, method, segments)
    end
  end

  @spec segments_match?([String.t() | :param], [String.t()]) :: boolean()
  defp segments_match?(pattern, segments) when length(pattern) != length(segments), do: false

  defp segments_match?(pattern, segments) do
    Enum.zip(pattern, segments)
    |> Enum.all?(fn
      {:param, _} -> true
      {literal, literal} -> true
      _ -> false
    end)
  end

  @spec extract_params([String.t() | :param], [String.t()], [String.t()]) ::
          %{optional(String.t()) => String.t()}
  defp extract_params(pattern, param_names, segments) do
    param_values =
      Enum.zip(pattern, segments)
      |> Enum.filter(fn {p, _} -> p == :param end)
      |> Enum.map(&elem(&1, 1))

    Enum.zip(param_names, param_values) |> Map.new()
  end

  @spec execute(
          Interpreter.pyvalue(),
          %{optional(String.t()) => String.t()},
          request(),
          Ctx.t()
        ) :: {:ok, response()}
  defp execute(handler, path_params, request, ctx) do
    {:ok, response, _ctx, _handler} = execute_with_ctx(handler, path_params, request, ctx)
    {:ok, response}
  end

  @spec execute_with_ctx(
          Interpreter.pyvalue(),
          %{optional(String.t()) => String.t()},
          request(),
          Ctx.t()
        ) :: {:ok, response(), Ctx.t(), Interpreter.pyvalue()}
  defp execute_with_ctx(handler, path_params, request, ctx) do
    t0 = System.monotonic_time(:microsecond)
    events_before = length(ctx.log)
    compute_us_before = Ctx.compute_time_us(ctx)

    try do
      {result, new_ctx, updated_handler} = call_handler(handler, path_params, request, ctx)
      telem = build_telemetry(t0, events_before, compute_us_before, new_ctx)
      {:ok, Map.put(unwrap_response(result), :telemetry, telem), new_ctx, updated_handler}
    rescue
      e ->
        telem = build_telemetry(t0, events_before, compute_us_before, ctx)

        {:ok,
         %{
           status: 500,
           headers: %{"content-type" => "application/json"},
           body: %{"detail" => Exception.message(e)},
           telemetry: telem
         }, ctx, handler}
    end
  end

  @spec unwrap_response(Interpreter.pyvalue()) :: response()
  defp unwrap_response(%{"__response__" => true, "__streaming__" => true} = resp) do
    chunks = Map.get(resp, "body", [])

    %{
      status: Map.get(resp, "status_code", 200),
      headers: Map.get(resp, "headers", %{"content-type" => "text/plain"}),
      body: Enum.join(chunks)
    }
  end

  defp unwrap_response(%{"__response__" => true} = resp) do
    %{
      status: Map.get(resp, "status_code", 200),
      headers: Map.get(resp, "headers", %{"content-type" => "application/json"}),
      body: Map.get(resp, "body")
    }
  end

  defp unwrap_response(result) do
    %{
      status: 200,
      headers: %{"content-type" => "application/json"},
      body: result
    }
  end

  @spec unwrap_stream_response(Interpreter.pyvalue()) :: stream_response()
  defp unwrap_stream_response(%{"__response__" => true, "__streaming__" => true} = resp) do
    chunks = Map.get(resp, "body", [])

    %{
      status: Map.get(resp, "status_code", 200),
      headers: Map.get(resp, "headers", %{"content-type" => "text/plain"}),
      chunks: chunks
    }
  end

  defp unwrap_stream_response(%{"__response__" => true} = resp) do
    body = Map.get(resp, "body")

    body_str =
      if is_binary(body) do
        body
      else
        case Jason.encode(body) do
          {:ok, json} -> json
          {:error, _} -> inspect(body)
        end
      end

    %{
      status: Map.get(resp, "status_code", 200),
      headers: Map.get(resp, "headers", %{"content-type" => "application/json"}),
      chunks: [body_str]
    }
  end

  defp unwrap_stream_response(result) do
    body_str =
      case Jason.encode(result) do
        {:ok, json} -> json
        {:error, _} -> inspect(result)
      end

    %{
      status: 200,
      headers: %{"content-type" => "application/json"},
      chunks: [body_str]
    }
  end

  @spec call_handler(
          Interpreter.pyvalue(),
          %{optional(String.t()) => String.t()},
          request(),
          Ctx.t()
        ) :: {Interpreter.pyvalue(), Ctx.t(), Interpreter.pyvalue()}
  defp call_handler(
         {:function, name, params, body, closure_env} = func,
         path_params,
         request,
         ctx
       ) do
    query_params = Map.get(request, :query, %{})
    request_obj = build_request_object(request)
    base_env = Env.push_scope(Env.put(closure_env, name, func))

    case bind_handler_params(params, base_env, path_params, query_params, request_obj, request,
           closure_env: closure_env,
           ctx: ctx
         ) do
      {:ok, call_env} ->
        {result, post_env, new_ctx} = Interpreter.eval({:module, [line: 1], body}, call_env, ctx)
        updated_closure = extract_closure_env(post_env, closure_env)
        updated_handler = {:function, name, params, body, updated_closure}

        case result do
          {:returned, value} -> {value, new_ctx, updated_handler}
          {:exception, msg} -> raise msg
          value -> {value, new_ctx, updated_handler}
        end

      {:validation_error, msg} ->
        {validation_error_response(msg), ctx, func}
    end
  end

  defp call_handler({:builtin, _fun} = handler, path_params, _request, ctx) do
    args = Map.values(path_params)
    {:builtin, fun} = handler
    {fun.(args), ctx, handler}
  end

  @spec call_handler_safe(
          Interpreter.pyvalue(),
          %{optional(String.t()) => String.t()},
          request(),
          Ctx.t()
        ) :: {:ok, Interpreter.pyvalue(), Ctx.t()} | {:error, String.t(), Ctx.t()}
  defp call_handler_safe(handler, path_params, request, ctx) do
    {func_name, params, body, closure_env} =
      case handler do
        {:function, name, p, b, ce} -> {name, p, b, ce}
        {:builtin, fun} -> {:builtin, nil, nil, fun}
      end

    case func_name do
      :builtin ->
        args = Map.values(path_params)
        {:ok, closure_env.(args), ctx, handler}

      _ ->
        func = handler
        query_params = Map.get(request, :query, %{})
        request_obj = build_request_object(request)
        base_env = Env.push_scope(Env.put(closure_env, func_name, func))

        case bind_handler_params(
               params,
               base_env,
               path_params,
               query_params,
               request_obj,
               request,
               closure_env: closure_env,
               ctx: ctx
             ) do
          {:ok, call_env} ->
            {result, post_env, new_ctx} =
              Interpreter.eval({:module, [line: 1], body}, call_env, ctx)

            updated_closure = extract_closure_env(post_env, closure_env)
            updated_handler = {:function, func_name, params, body, updated_closure}

            case result do
              {:returned, value} -> {:ok, value, new_ctx, updated_handler}
              {:exception, msg} -> {:error, msg, new_ctx, updated_handler}
              value -> {:ok, value, new_ctx, updated_handler}
            end

          {:validation_error, msg} ->
            {:ok, validation_error_response(msg), ctx, handler}
        end
    end
  end

  @spec bind_handler_params(
          [Pyex.Parser.param()],
          Env.t(),
          %{optional(String.t()) => String.t()},
          %{optional(String.t()) => String.t()},
          %{String.t() => Interpreter.pyvalue()},
          request(),
          keyword()
        ) :: {:ok, Env.t()} | {:validation_error, String.t()}
  defp bind_handler_params(
         params,
         base_env,
         path_params,
         query_params,
         request_obj,
         request,
         opts
       ) do
    closure_env = Keyword.fetch!(opts, :closure_env)
    ctx = Keyword.fetch!(opts, :ctx)

    Enum.reduce_while(params, {:ok, base_env}, fn param, {:ok, env} ->
      param_name = elem(param, 0)
      default = elem(param, 1)

      cond do
        param_name == "request" ->
          {:cont, {:ok, Env.put(env, "request", request_obj)}}

        Map.has_key?(path_params, param_name) ->
          {:cont,
           {:ok, Env.put(env, param_name, coerce_param(Map.fetch!(path_params, param_name)))}}

        Map.has_key?(query_params, param_name) ->
          {:cont,
           {:ok, Env.put(env, param_name, coerce_param(Map.fetch!(query_params, param_name)))}}

        default != nil ->
          {val, _env, _ctx} = Interpreter.eval(default, env, ctx)
          {:cont, {:ok, Env.put(env, param_name, val)}}

        true ->
          case resolve_pydantic_body(param, request, closure_env) do
            {:ok, instance} ->
              {:cont, {:ok, Env.put(env, param_name, instance)}}

            {:error, msg} ->
              {:halt, {:validation_error, msg}}

            :not_pydantic ->
              {:cont, {:ok, Env.put(env, param_name, nil)}}
          end
      end
    end)
  end

  @spec validation_error_response(String.t()) :: Interpreter.pyvalue()
  defp validation_error_response(msg) do
    %{
      "__response__" => true,
      "status_code" => 422,
      "headers" => %{"content-type" => "application/json"},
      "body" => %{"detail" => msg}
    }
  end

  @spec build_request_object(request()) :: %{String.t() => Interpreter.pyvalue()}
  defp build_request_object(request) do
    body = Map.get(request, :body)

    %{
      "method" => String.upcase(request.method),
      "headers" => Map.get(request, :headers, %{}),
      "query_params" => Map.get(request, :query, %{}),
      "body" => body,
      "json" =>
        {:builtin,
         fn
           [] ->
             case body do
               nil ->
                 {:exception, "request body is empty"}

               raw when is_binary(raw) ->
                 case Jason.decode(raw) do
                   {:ok, value} -> value
                   {:error, _} -> {:exception, "invalid JSON body: #{raw}"}
                 end
             end
         end}
    }
  end

  @spec coerce_param(String.t()) :: Interpreter.pyvalue()
  defp coerce_param(value) when is_binary(value) do
    case Float.parse(value) do
      {f, ""} ->
        if trunc(f) == f and not String.contains?(value, "."),
          do: trunc(f),
          else: f

      _ ->
        value
    end
  end

  @spec resolve_pydantic_body(Pyex.Parser.param(), request(), Env.t()) ::
          {:ok, Interpreter.pyvalue()} | {:error, String.t()} | :not_pydantic
  defp resolve_pydantic_body(param, request, closure_env) when tuple_size(param) == 3 do
    type_str = elem(param, 2)

    case Env.get(closure_env, type_str) do
      {:ok, class} ->
        if Pydantic.pydantic_class?(class) do
          body = Map.get(request, :body)

          case parse_request_body(body) do
            {:ok, data} -> Pydantic.validate_body(class, data)
            {:error, msg} -> {:error, msg}
          end
        else
          :not_pydantic
        end

      :undefined ->
        :not_pydantic
    end
  end

  defp resolve_pydantic_body(_param, _request, _closure_env), do: :not_pydantic

  @spec parse_request_body(String.t() | map() | nil) :: {:ok, map()} | {:error, String.t()}
  defp parse_request_body(nil), do: {:ok, %{}}
  defp parse_request_body(data) when is_map(data), do: {:ok, data}

  defp parse_request_body(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _} -> {:error, "request body is not a JSON object"}
      {:error, _} -> {:error, "invalid JSON in request body"}
    end
  end

  @spec build_telemetry(integer(), non_neg_integer(), non_neg_integer(), Ctx.t()) :: telemetry()
  defp build_telemetry(t0, events_before, compute_us_before, ctx) do
    t1 = System.monotonic_time(:microsecond)
    compute_us_after = Ctx.compute_time_us(ctx)
    events_after = length(ctx.log)
    new_event_count = max(events_after - events_before, 0)

    new_events = Enum.take(ctx.log, new_event_count)
    file_ops = Enum.count(new_events, fn {type, _, _} -> type == :file_op end)

    %{
      compute_us: max(compute_us_after - compute_us_before, 0),
      total_us: t1 - t0,
      event_count: new_event_count,
      file_ops: file_ops
    }
  end

  @spec extract_closure_env(Env.t(), Env.t()) :: Env.t()
  defp extract_closure_env(post_env, closure_env) do
    closure_depth = length(closure_env.scopes)
    post_depth = length(post_env.scopes)
    %Env{scopes: Enum.drop(post_env.scopes, post_depth - closure_depth)}
  end

  @spec update_route_handler([compiled_route()], Interpreter.pyvalue(), Interpreter.pyvalue()) ::
          [compiled_route()]
  defp update_route_handler(routes, old_handler, new_handler) do
    Enum.map(routes, fn {method, segments, param_names, handler} = route ->
      if handler == old_handler do
        {method, segments, param_names, new_handler}
      else
        route
      end
    end)
  end

  @spec generator_stream(Interpreter.pyvalue(), [term()], Env.t(), Ctx.t()) :: Enumerable.t()
  defp generator_stream(first_val, cont, gen_env, gen_ctx) do
    gen_ctx = %{gen_ctx | generator_mode: :defer_inner}

    Stream.resource(
      fn -> {:next, first_val, cont, gen_env, gen_ctx} end,
      fn
        :done ->
          {:halt, :done}

        {:next, value, continuation, env, ctx} ->
          chunk = to_string(value)

          case Interpreter.resume_generator(continuation, env, ctx) do
            {{:yielded, next_val, next_cont}, next_env, next_ctx} ->
              {[chunk], {:next, next_val, next_cont, next_env, next_ctx}}

            {:done, _env, _ctx} ->
              {[chunk], :done}

            {{:exception, msg}, _env, _ctx} ->
              error_json =
                case Jason.encode(%{"detail" => "GeneratorError: " <> msg}) do
                  {:ok, json} -> json
                  {:error, _} -> ~s({"detail":"generator error"})
                end

              {[chunk, error_json], :done}
          end
      end,
      fn _ -> :ok end
    )
  end
end
