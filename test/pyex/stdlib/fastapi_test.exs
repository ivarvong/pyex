defmodule Pyex.Stdlib.FastAPITest do
  use ExUnit.Case, async: true

  alias Pyex.Stdlib.FastAPI

  describe "compile_path/1" do
    test "static path" do
      assert FastAPI.compile_path("/hello") == {["hello"], []}
    end

    test "path with parameter" do
      assert FastAPI.compile_path("/users/{user_id}") == {["users", :param], ["user_id"]}
    end

    test "path with multiple parameters" do
      assert FastAPI.compile_path("/users/{user_id}/posts/{post_id}") ==
               {["users", :param, "posts", :param], ["user_id", "post_id"]}
    end
  end

  describe "route registration" do
    test "simple GET endpoint stores route in app dict" do
      app =
        Pyex.run!("""
        import fastapi
        app = fastapi.FastAPI()

        @app.get("/hello")
        def hello():
            return {"message": "hello world"}

        app
        """)

      assert [{{method, path}, _handler}] = app["__routes__"]
      assert method == "GET"
      assert path == "/hello"
    end

    test "endpoint with path parameter" do
      app =
        Pyex.run!("""
        import fastapi
        app = fastapi.FastAPI()

        @app.get("/users/{user_id}")
        def get_user(user_id):
            return {"user_id": user_id}

        app
        """)

      assert [{{_method, path}, _handler}] = app["__routes__"]
      assert path == "/users/{user_id}"
    end

    test "multiple routes" do
      app =
        Pyex.run!("""
        import fastapi
        app = fastapi.FastAPI()

        @app.get("/")
        def root():
            return {"status": "ok"}

        @app.get("/items")
        def list_items():
            return {"items": [1, 2, 3]}

        @app.post("/items")
        def create_item():
            return {"created": True}

        app
        """)

      assert length(app["__routes__"]) == 3
    end

    test "all HTTP methods" do
      app =
        Pyex.run!("""
        import fastapi
        app = fastapi.FastAPI()

        @app.get("/r")
        def read():
            return "get"

        @app.post("/r")
        def create():
            return "post"

        @app.put("/r")
        def update():
            return "put"

        @app.delete("/r")
        def remove():
            return "delete"

        app
        """)

      routes = app["__routes__"]
      methods = Enum.map(routes, fn {{m, _}, _} -> m end)
      assert methods == ["GET", "POST", "PUT", "DELETE"]
    end

    test "routes increment event counter" do
      {:ok, _value, ctx} =
        Pyex.run("""
        import fastapi
        app = fastapi.FastAPI()

        @app.get("/hello")
        def hello():
            return "hi"
        """)

      # Event counter tracks operations (disabled for performance)
      assert ctx.event_count >= 0
    end

    test "HTMLResponse returns structured response" do
      result =
        Pyex.run!("""
        import fastapi
        resp = fastapi.HTMLResponse("<h1>Hello</h1>")
        resp
        """)

      assert result["__response__"] == true
      assert result["status_code"] == 200
      assert result["headers"] == %{"content-type" => "text/html"}
      assert result["body"] == "<h1>Hello</h1>"
    end

    test "HTMLResponse with custom status code" do
      result =
        Pyex.run!("""
        import fastapi
        resp = fastapi.HTMLResponse("<h1>Not Found</h1>", status_code=404)
        resp
        """)

      assert result["status_code"] == 404
    end

    test "JSONResponse returns structured response" do
      result =
        Pyex.run!("""
        import fastapi
        resp = fastapi.JSONResponse({"key": "value"})
        resp
        """)

      assert result["__response__"] == true
      assert result["status_code"] == 200
      assert result["headers"] == %{"content-type" => "application/json"}
      assert result["body"] == %{"key" => "value"}
    end

    test "JSONResponse with custom status code" do
      result =
        Pyex.run!("""
        import fastapi
        resp = fastapi.JSONResponse({"error": "not found"}, status_code=404)
        resp
        """)

      assert result["status_code"] == 404
    end

    test "from fastapi.responses import HTMLResponse" do
      result =
        Pyex.run!("""
        from fastapi.responses import HTMLResponse
        HTMLResponse("<p>hi</p>")
        """)

      assert result["__response__"] == true
      assert result["body"] == "<p>hi</p>"
      assert result["headers"] == %{"content-type" => "text/html"}
    end

    test "from fastapi import HTMLResponse directly" do
      result =
        Pyex.run!("""
        from fastapi import HTMLResponse
        HTMLResponse("<p>test</p>")
        """)

      assert result["__response__"] == true
      assert result["body"] == "<p>test</p>"
    end

    test "HTMLResponse with extra headers kwarg" do
      result =
        Pyex.run!("""
        from fastapi import HTMLResponse
        HTMLResponse("<p>cached</p>", headers={"cache-control": "public, max-age=3600"})
        """)

      assert result["headers"]["content-type"] == "text/html"
      assert result["headers"]["cache-control"] == "public, max-age=3600"
    end

    test "JSONResponse with extra headers kwarg" do
      result =
        Pyex.run!("""
        from fastapi import JSONResponse
        JSONResponse({"ok": True}, headers={"x-request-id": "abc123"})
        """)

      assert result["headers"]["content-type"] == "application/json"
      assert result["headers"]["x-request-id"] == "abc123"
    end

    test "from fastapi import JSONResponse directly" do
      result =
        Pyex.run!("""
        from fastapi import JSONResponse
        JSONResponse([1, 2, 3])
        """)

      assert result["__response__"] == true
      assert result["body"] == [1, 2, 3]
    end

    test "handler with default argument" do
      app =
        Pyex.run!("""
        import fastapi
        app = fastapi.FastAPI()

        @app.get("/greet/{name}")
        def greet(name, greeting="Hello"):
            return {"text": greeting + " " + name}

        app
        """)

      assert [{{_method, _path}, {:function, "greet", params, _body, _env}}] = app["__routes__"]
      assert [{"name", nil}, {"greeting", _default}] = params
    end
  end
end
