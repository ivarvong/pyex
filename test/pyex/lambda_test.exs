defmodule Pyex.LambdaTest do
  use ExUnit.Case, async: true

  alias Pyex.Lambda
  alias Pyex.Error

  describe "invoke/2" do
    test "basic GET returns 200 with handler result" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/hello")
      def hello():
          return {"message": "hello world"}
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/hello"})
      assert resp.status == 200
      assert resp.headers == %{"content-type" => "application/json"}
      assert resp.body == %{"message" => "hello world"}
    end

    test "path parameter with integer coercion" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/users/{user_id}")
      def get_user(user_id):
          return {"id": user_id, "type": type(user_id)}
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/users/42"})
      assert resp.status == 200
      assert resp.body["id"] == 42
      {:instance, _, %{"__name__" => name}} = resp.body["type"]
      assert name == "int"
    end

    test "path parameter kept as string when not numeric" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/users/{name}")
      def get_user(name):
          return {"name": name}
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/users/alice"})
      assert resp.status == 200
      assert resp.body == %{"name" => "alice"}
    end

    test "multiple routes dispatch correctly" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/")
      def root():
          return {"route": "root"}

      @app.get("/items")
      def list_items():
          return {"route": "list"}

      @app.post("/items")
      def create_item():
          return {"route": "create"}
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/"})
      assert resp.body == %{"route" => "root"}

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/items"})
      assert resp.body == %{"route" => "list"}

      assert {:ok, resp} = Lambda.invoke(source, %{method: "POST", path: "/items"})
      assert resp.body == %{"route" => "create"}
    end

    test "404 on no matching route" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/hello")
      def hello():
          return {"message": "hi"}
      """

      assert {:error, %Error{message: msg}} =
               Lambda.invoke(source, %{method: "GET", path: "/nonexistent"})

      assert msg =~ "no route matches"
      assert msg =~ "GET"
      assert msg =~ "/nonexistent"
    end

    test "404 on wrong HTTP method" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/hello")
      def hello():
          return {"message": "hi"}
      """

      assert {:error, %Error{message: msg}} =
               Lambda.invoke(source, %{method: "POST", path: "/hello"})

      assert msg =~ "no route matches"
      assert msg =~ "POST"
    end

    test "handler with default argument" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/greet/{name}")
      def greet(name, greeting="Hello"):
          return {"text": greeting + " " + name}
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/greet/World"})
      assert resp.status == 200
      assert resp.body == %{"text" => "Hello World"}
    end

    test "handler returning a list" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/numbers")
      def numbers():
          return [1, 2, 3]
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/numbers"})
      assert resp.status == 200
      assert resp.body == [1, 2, 3]
    end

    test "handler with computation" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/fib/{n}")
      def fib(n):
          if n <= 1:
              return n
          a = 0
          b = 1
          for i in range(2, n + 1):
              c = a + b
              a = b
              b = c
          return {"n": n, "fib": b}
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/fib/10"})
      assert resp.status == 200
      assert resp.body == %{"n" => 10, "fib" => 55}
    end

    test "no app variable returns error" do
      source = """
      x = 1 + 2
      """

      assert {:error, %Error{message: msg}} =
               Lambda.invoke(source, %{method: "GET", path: "/hello"})

      assert msg =~ "no 'app' variable found"
    end

    test "app is not a FastAPI instance returns error" do
      source = """
      app = 42
      """

      assert {:error, %Error{message: msg}} =
               Lambda.invoke(source, %{method: "GET", path: "/hello"})

      assert msg =~ "app is not a FastAPI instance"
    end

    test "method is case-insensitive" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/hello")
      def hello():
          return {"ok": True}
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "get", path: "/hello"})
      assert resp.status == 200
      assert resp.body == %{"ok" => true}
    end

    test "multiple path parameters" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/users/{user_id}/posts/{post_id}")
      def get_post(user_id, post_id):
          return {"user": user_id, "post": post_id}
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/users/5/posts/99"})
      assert resp.status == 200
      assert resp.body == %{"user" => 5, "post" => 99}
    end

    test "PUT and DELETE methods" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.put("/items/{id}")
      def update_item(id):
          return {"updated": id}

      @app.delete("/items/{id}")
      def delete_item(id):
          return {"deleted": id}
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "PUT", path: "/items/7"})
      assert resp.body == %{"updated" => 7}

      assert {:ok, resp} = Lambda.invoke(source, %{method: "DELETE", path: "/items/7"})
      assert resp.body == %{"deleted" => 7}
    end

    test "no side effects between invocations" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/count")
      def count():
          return {"n": 1}
      """

      assert {:ok, resp1} = Lambda.invoke(source, %{method: "GET", path: "/count"})
      assert {:ok, resp2} = Lambda.invoke(source, %{method: "GET", path: "/count"})
      assert resp1.body == resp2.body
    end
  end

  describe "haversine distance endpoint" do
    @source """
    import fastapi
    import math

    app = fastapi.FastAPI()

    @app.get("/distance")
    def distance(lat1, lng1, lat2, lng2):
        lat1 = float(lat1)
        lng1 = float(lng1)
        lat2 = float(lat2)
        lng2 = float(lng2)
        dlat = math.radians(lat2 - lat1)
        dlng = math.radians(lng2 - lng1)
        rlat1 = math.radians(lat1)
        rlat2 = math.radians(lat2)
        a = math.sin(dlat / 2) ** 2 + math.cos(rlat1) * math.cos(rlat2) * math.sin(dlng / 2) ** 2
        c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
        km = 6371.0 * c
        nm = 3440.065 * c
        return {"km": round(km, 1), "nm": round(nm, 1), "from": [lat1, lng1], "to": [lat2, lng2]}

    @app.get("/health")
    def health():
        return {"status": "ok"}
    """

    test "JFK to LAX" do
      request = %{
        method: "GET",
        path: "/distance",
        query_params: %{
          "lat1" => "40.6392",
          "lng1" => "-73.7639",
          "lat2" => "33.9382",
          "lng2" => "-118.3866"
        }
      }

      assert {:ok, resp} = Lambda.invoke(@source, request)
      assert resp.status == 200
      assert resp.body["km"] == 3973.9
      assert resp.body["nm"] == 2145.7
      assert resp.body["from"] == [40.6392, -73.7639]
      assert resp.body["to"] == [33.9382, -118.3866]
    end

    test "PDX to LAX" do
      request = %{
        method: "GET",
        path: "/distance",
        query_params: %{
          "lat1" => "45.5958",
          "lng1" => "-122.6092",
          "lat2" => "33.9382",
          "lng2" => "-118.3866"
        }
      }

      assert {:ok, resp} = Lambda.invoke(@source, request)
      assert resp.status == 200
      assert resp.body["km"] == 1345.0
      assert resp.body["nm"] == 726.3
    end

    test "same point returns zero" do
      request = %{
        method: "GET",
        path: "/distance",
        query_params: %{
          "lat1" => "45.5958",
          "lng1" => "-122.6092",
          "lat2" => "45.5958",
          "lng2" => "-122.6092"
        }
      }

      assert {:ok, resp} = Lambda.invoke(@source, request)
      assert resp.status == 200
      assert resp.body["km"] == 0.0
      assert resp.body["nm"] == 0.0
    end

    test "health endpoint coexists" do
      request = %{method: "GET", path: "/health"}
      assert {:ok, resp} = Lambda.invoke(@source, request)
      assert resp.body == %{"status" => "ok"}
    end

    test "missing route returns error" do
      request = %{method: "GET", path: "/unknown"}
      assert {:error, %Error{message: msg}} = Lambda.invoke(@source, request)
      assert msg =~ "no route matches"
    end

    test "wrong method returns error" do
      request = %{method: "POST", path: "/distance"}
      assert {:error, %Error{message: msg}} = Lambda.invoke(@source, request)
      assert msg =~ "no route matches"
    end
  end

  describe "request body (t82)" do
    test "POST handler receives request.json() as parsed dict" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.post("/items")
      def create_item(request):
          data = request.json()
          return {"name": data["name"], "price": data["price"]}
      """

      req = %{
        method: "POST",
        path: "/items",
        body: ~s({"name": "widget", "price": 9.99})
      }

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 200
      assert resp.body == %{"name" => "widget", "price" => 9.99}
    end

    test "POST handler accesses request.body for raw string" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.post("/echo")
      def echo(request):
          return {"raw": request.body}
      """

      req = %{method: "POST", path: "/echo", body: "hello raw body"}

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 200
      assert resp.body == %{"raw" => "hello raw body"}
    end

    test "request.method and request.headers are accessible" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.post("/info")
      def info(request):
          return {"method": request.method, "ct": request.headers["content-type"]}
      """

      req = %{
        method: "POST",
        path: "/info",
        headers: %{"content-type" => "application/json"}
      }

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 200
      assert resp.body == %{"method" => "POST", "ct" => "application/json"}
    end

    test "request.query_params gives access to query string values" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/search")
      def search(request):
          q = request.query_params["q"]
          return {"query": q}
      """

      req = %{method: "GET", path: "/search", query_params: %{"q" => "elixir"}}

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 200
      assert resp.body == %{"query" => "elixir"}
    end

    test "PUT handler with JSON body" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.put("/items/{item_id}")
      def update_item(item_id, request):
          data = request.json()
          return {"id": item_id, "updated": data}
      """

      req = %{
        method: "PUT",
        path: "/items/42",
        body: ~s({"name": "updated widget"})
      }

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 200
      assert resp.body == %{"id" => 42, "updated" => %{"name" => "updated widget"}}
    end

    test "handler with path params and request object" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.post("/users/{user_id}/comments")
      def add_comment(user_id, request):
          data = request.json()
          return {"user_id": user_id, "comment": data["text"], "method": request.method}
      """

      req = %{
        method: "POST",
        path: "/users/7/comments",
        body: ~s({"text": "great post!"})
      }

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 200
      assert resp.body == %{"user_id" => 7, "comment" => "great post!", "method" => "POST"}
    end

    test "request.json() with invalid JSON returns error" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.post("/parse")
      def parse(request):
          data = request.json()
          return data
      """

      req = %{method: "POST", path: "/parse", body: "not valid json{"}

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 500
      assert resp.body["detail"] =~ "invalid JSON body"
    end

    test "request.json() with no body returns error" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.post("/parse")
      def parse(request):
          data = request.json()
          return data
      """

      req = %{method: "POST", path: "/parse"}

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 500
      assert resp.body["detail"] =~ "request body is empty"
    end

    test "request.body is None when no body provided" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/check")
      def check(request):
          return {"has_body": request.body is not None}
      """

      req = %{method: "GET", path: "/check"}

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 200
      assert resp.body == %{"has_body" => false}
    end
  end

  describe "HTMLResponse / JSONResponse" do
    test "handler returning HTMLResponse sets content-type to text/html" do
      source = """
      import fastapi
      from fastapi import HTMLResponse
      app = fastapi.FastAPI()

      @app.get("/page")
      def page():
          return HTMLResponse("<h1>Hello</h1>")
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/page"})
      assert resp.status == 200
      assert resp.headers == %{"content-type" => "text/html"}
      assert resp.body == "<h1>Hello</h1>"
    end

    test "HTMLResponse with custom status code" do
      source = """
      import fastapi
      from fastapi import HTMLResponse
      app = fastapi.FastAPI()

      @app.get("/not-found")
      def not_found():
          return HTMLResponse("<h1>Not Found</h1>", status_code=404)
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/not-found"})
      assert resp.status == 404
      assert resp.headers == %{"content-type" => "text/html"}
      assert resp.body == "<h1>Not Found</h1>"
    end

    test "handler returning JSONResponse preserves application/json content-type" do
      source = """
      import fastapi
      from fastapi import JSONResponse
      app = fastapi.FastAPI()

      @app.get("/data")
      def data():
          return JSONResponse({"items": [1, 2, 3]}, status_code=201)
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/data"})
      assert resp.status == 201
      assert resp.headers == %{"content-type" => "application/json"}
      assert resp.body == %{"items" => [1, 2, 3]}
    end

    test "handler returning plain dict still works as 200 JSON" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/plain")
      def plain():
          return {"ok": True}
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/plain"})
      assert resp.status == 200
      assert resp.headers == %{"content-type" => "application/json"}
      assert resp.body == %{"ok" => true}
    end

    test "from fastapi.responses import HTMLResponse via dotted module" do
      source = """
      from fastapi.responses import HTMLResponse
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/page")
      def page():
          return HTMLResponse("<p>dotted import works</p>")
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/page"})
      assert resp.status == 200
      assert resp.headers == %{"content-type" => "text/html"}
      assert resp.body == "<p>dotted import works</p>"
    end

    test "boot/handle with HTMLResponse threads ctx" do
      ctx = Pyex.Ctx.new(filesystem: Pyex.Filesystem.Memory.new())

      source = """
      import fastapi
      from fastapi import HTMLResponse
      app = fastapi.FastAPI()

      @app.get("/")
      def index():
          return HTMLResponse("<html><body>Hi</body></html>")
      """

      assert {:ok, app} = Lambda.boot(source, ctx: ctx)
      assert {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/"})
      assert resp.status == 200
      assert resp.headers == %{"content-type" => "text/html"}
      assert resp.body == "<html><body>Hi</body></html>"
    end
  end

  describe "invoke!/2" do
    test "returns response directly on success" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/hello")
      def hello():
          return {"ok": True}
      """

      resp = Lambda.invoke!(source, %{method: "GET", path: "/hello"})
      assert resp.status == 200
      assert resp.body == %{"ok" => true}
    end

    test "raises on error" do
      source = """
      x = 1
      """

      assert_raise RuntimeError, ~r/no 'app' variable found/, fn ->
        Lambda.invoke!(source, %{method: "GET", path: "/hello"})
      end
    end
  end

  describe "pydantic body parameters" do
    test "POST handler with pydantic model auto-parses JSON body" do
      source = """
      import fastapi
      from pydantic import BaseModel

      app = fastapi.FastAPI()

      class CreateUser(BaseModel):
          name: str
          age: int

      @app.post("/users")
      def create_user(body: CreateUser):
          return {"name": body.name, "age": body.age}
      """

      req = %{
        method: "POST",
        path: "/users",
        body: ~s({"name": "Alice", "age": 30})
      }

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 200
      assert resp.body == %{"name" => "Alice", "age" => 30}
    end

    test "pydantic body with type coercion" do
      source = """
      import fastapi
      from pydantic import BaseModel

      app = fastapi.FastAPI()

      class Item(BaseModel):
          name: str
          price: float
          quantity: int

      @app.post("/items")
      def create_item(item: Item):
          return {"name": item.name, "total": item.price * item.quantity}
      """

      req = %{
        method: "POST",
        path: "/items",
        body: ~s({"name": "Widget", "price": "9.99", "quantity": "3"})
      }

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 200
      assert resp.body["name"] == "Widget"
      assert_in_delta resp.body["total"], 29.97, 0.001
    end

    test "pydantic body validation error returns 422" do
      source = """
      import fastapi
      from pydantic import BaseModel

      app = fastapi.FastAPI()

      class CreateUser(BaseModel):
          name: str
          age: int

      @app.post("/users")
      def create_user(body: CreateUser):
          return {"name": body.name}
      """

      req = %{
        method: "POST",
        path: "/users",
        body: ~s({"name": "Alice"})
      }

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 422
      assert resp.body["detail"] =~ "age"
    end

    test "pydantic body with path params combined" do
      source = """
      import fastapi
      from pydantic import BaseModel

      app = fastapi.FastAPI()

      class UpdateUser(BaseModel):
          name: str

      @app.put("/users/{user_id}")
      def update_user(user_id, body: UpdateUser):
          return {"id": user_id, "name": body.name}
      """

      req = %{
        method: "PUT",
        path: "/users/42",
        body: ~s({"name": "Bob"})
      }

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 200
      assert resp.body == %{"id" => 42, "name" => "Bob"}
    end

    test "pydantic body with query params combined" do
      source = """
      import fastapi
      from pydantic import BaseModel

      app = fastapi.FastAPI()

      class SearchFilter(BaseModel):
          min_price: float
          max_price: float

      @app.post("/search")
      def search(page, filters: SearchFilter):
          return {"page": int(page), "min": filters.min_price, "max": filters.max_price}
      """

      req = %{
        method: "POST",
        path: "/search",
        query_params: %{"page" => "2"},
        body: ~s({"min_price": 10.0, "max_price": 99.99})
      }

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 200
      assert resp.body == %{"page" => 2, "min" => 10.0, "max" => 99.99}
    end

    test "pydantic body with default fields" do
      source = """
      import fastapi
      from pydantic import BaseModel

      app = fastapi.FastAPI()

      class Config(BaseModel):
          name: str
          debug: bool = False
          port: int = 8080

      @app.post("/config")
      def create_config(cfg: Config):
          return {"name": cfg.name, "debug": cfg.debug, "port": cfg.port}
      """

      req = %{
        method: "POST",
        path: "/config",
        body: ~s({"name": "prod"})
      }

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 200
      assert resp.body == %{"name" => "prod", "debug" => false, "port" => 8080}
    end

    test "pydantic body with Field constraints validates" do
      source = """
      import fastapi
      from pydantic import BaseModel, Field

      app = fastapi.FastAPI()

      class Product(BaseModel):
          name: str = Field(min_length=1)
          price: float = Field(gt=0)

      @app.post("/products")
      def create_product(product: Product):
          return {"name": product.name, "price": product.price}
      """

      req = %{
        method: "POST",
        path: "/products",
        body: ~s({"name": "", "price": -5})
      }

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 422
    end

    test "boot/handle with pydantic body" do
      source = """
      import fastapi
      from pydantic import BaseModel

      app = fastapi.FastAPI()

      class NewItem(BaseModel):
          name: str

      @app.post("/items")
      def create_item(item: NewItem):
          return {"name": item.name, "created": True}
      """

      assert {:ok, app} = Lambda.boot(source)

      assert {:ok, resp, _app} =
               Lambda.handle(app, %{
                 method: "POST",
                 path: "/items",
                 body: ~s({"name": "Widget"})
               })

      assert resp.status == 200
      assert resp.body == %{"name" => "Widget", "created" => true}
    end

    test "non-pydantic annotated param falls through to nil" do
      source = """
      import fastapi

      app = fastapi.FastAPI()

      @app.get("/hello")
      def hello(name: str = "world"):
          return {"message": "hello " + name}
      """

      assert {:ok, resp} = Lambda.invoke(source, %{method: "GET", path: "/hello"})
      assert resp.status == 200
      assert resp.body == %{"message" => "hello world"}
    end

    test "model_dump on pydantic body parameter" do
      source = """
      import fastapi
      from pydantic import BaseModel

      app = fastapi.FastAPI()

      class Payload(BaseModel):
          x: int
          y: int

      @app.post("/sum")
      def compute(data: Payload):
          d = data.model_dump()
          return {"sum": d["x"] + d["y"]}
      """

      req = %{
        method: "POST",
        path: "/sum",
        body: ~s({"x": 3, "y": 7})
      }

      assert {:ok, resp} = Lambda.invoke(source, req)
      assert resp.status == 200
      assert resp.body == %{"sum" => 10}
    end
  end
end
