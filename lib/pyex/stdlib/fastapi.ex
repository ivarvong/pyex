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

  alias Pyex.Interpreter

  @type route :: {{String.t(), String.t()}, Interpreter.pyvalue()}

  @type compiled_route ::
          {String.t(), [String.t() | :param], [String.t()], Interpreter.pyvalue()}

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "FastAPI" => {:builtin, &create_app/1},
      "responses" => %{
        "HTMLResponse" => {:builtin_kw, &html_response/2},
        "JSONResponse" => {:builtin_kw, &json_response/2},
        "StreamingResponse" => {:builtin_kw, &streaming_response/2}
      },
      "HTMLResponse" => {:builtin_kw, &html_response/2},
      "JSONResponse" => {:builtin_kw, &json_response/2},
      "StreamingResponse" => {:builtin_kw, &streaming_response/2}
    }
  end

  @spec html_response([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          Interpreter.pyvalue()
  defp html_response([content], kwargs) when is_binary(content) do
    status = Map.get(kwargs, "status_code", 200)
    extra = Map.get(kwargs, "headers", %{})
    headers = Map.merge(%{"content-type" => "text/html"}, extra)

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
    headers = Map.merge(%{"content-type" => "application/json"}, extra)

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
    headers = Map.merge(%{"content-type" => media}, extra)

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
          [String.t()] | {:generator_suspended, term(), term(), Pyex.Env.t()}
  defp extract_chunks({:generator_suspended, _, _, _} = suspended), do: suspended
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
      "get" => {:builtin, &route_decorator("GET", &1)},
      "post" => {:builtin, &route_decorator("POST", &1)},
      "put" => {:builtin, &route_decorator("PUT", &1)},
      "delete" => {:builtin, &route_decorator("DELETE", &1)}
    }
  end

  @spec route_decorator(String.t(), [Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp route_decorator(method, [path]) when is_binary(path) do
    {:builtin,
     fn [handler] ->
       {:register_route, method, path, handler}
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
end
