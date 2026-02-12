defmodule Pyex.ReadmeTest do
  @moduledoc """
  Tests that exercise every code example in README.md.

  If a test here breaks, the README probably needs updating too.
  """
  use ExUnit.Case, async: true

  alias Pyex.{Error, Lambda}

  # ------------------------------------------------------------------
  # Hero example
  # ------------------------------------------------------------------

  describe "hero example" do
    test "sorted([3, 1, 2]) returns [1, 2, 3]" do
      assert Pyex.run!("sorted([3, 1, 2])") == [1, 2, 3]
    end
  end

  # ------------------------------------------------------------------
  # API section -- four public functions
  # ------------------------------------------------------------------

  describe "API: compile/1" do
    test "compile returns {:ok, ast}" do
      assert {:ok, ast} = Pyex.compile("40 + 2")
      assert is_tuple(ast)
    end

    test "compile returns {:error, msg} on bad syntax" do
      assert {:error, msg} = Pyex.compile("(1 +")
      assert is_binary(msg)
    end
  end

  describe "API: run/2 with pre-compiled AST" do
    test "compile then run" do
      {:ok, ast} = Pyex.compile("40 + 2")
      {:ok, 42, _ctx} = Pyex.run(ast)
    end

    test "compile then run with options" do
      {:ok, ast} = Pyex.compile("import os\nos.environ['KEY']")
      {:ok, "val", _ctx} = Pyex.run(ast, env: %{"KEY" => "val"})
    end
  end

  describe "API: run/2" do
    test "{:ok, value, ctx} on success" do
      assert {:ok, 42, _ctx} = Pyex.run("40 + 2")
    end
  end

  describe "API: run!/2" do
    test "returns value directly" do
      assert 42 = Pyex.run!("40 + 2")
    end
  end

  describe "API: output/1" do
    test "extracts print output from ctx" do
      {:ok, _val, ctx} = Pyex.run("print('hello')")
      assert "hello" = Pyex.output(ctx)
    end
  end

  # ------------------------------------------------------------------
  # Getting Data In
  # ------------------------------------------------------------------

  describe "environment variables" do
    test "os.environ reads :env option" do
      {:ok, result, _ctx} =
        Pyex.run(
          "import os\nos.environ['API_KEY']",
          env: %{"API_KEY" => "sk-..."}
        )

      assert result == "sk-..."
    end
  end

  describe "filesystem" do
    test "Memory filesystem with Pyex.run keyword API" do
      alias Pyex.Filesystem.Memory

      fs = Memory.new(%{"data.json" => ~s({"users": ["alice", "bob"]})})

      {:ok, result, _ctx} =
        Pyex.run(
          """
          import json
          f = open("data.json", "r")
          data = json.loads(f.read())
          f.close()
          data["users"]
          """,
          filesystem: fs
        )

      assert result == ["alice", "bob"]
    end
  end

  describe "custom modules" do
    test "inject modules with :builtin functions" do
      result =
        Pyex.run!(
          """
          import auth
          auth.get_user()
          """,
          modules: %{
            "auth" => %{"get_user" => {:builtin, fn [] -> "alice" end}}
          }
        )

      assert result == "alice"
    end
  end

  # ------------------------------------------------------------------
  # Sandbox Controls
  # ------------------------------------------------------------------

  describe "compute budget" do
    test "timeout returns {:error, %Error{kind: :timeout}}" do
      assert {:error, %Error{kind: :timeout}} =
               Pyex.run(
                 """
                 while True:
                     x = 1
                 """,
                 timeout_ms: 50
               )
    end
  end

  describe "network access" do
    test "denied by default" do
      assert {:error, %Error{kind: :python, message: msg}} =
               Pyex.run("""
               import requests
               requests.get("http://example.com")
               """)

      assert msg =~ "network access is disabled"
    end

    test "allowed_hosts permits matching host" do
      assert {:error, %Error{message: msg}} =
               Pyex.run(
                 """
                 import requests
                 requests.get("http://other.com")
                 """,
                 network: [allowed_hosts: ["api.example.com"]]
               )

      assert msg =~ "URL is not allowed"
    end
  end

  describe "I/O capabilities" do
    test "sql denied by default" do
      assert {:error, %Error{message: msg}} =
               Pyex.run(
                 """
                 import sql
                 sql.query("SELECT 1")
                 """,
                 env: %{"DATABASE_URL" => "postgres://localhost/fake"}
               )

      assert msg =~ "sql is disabled"
    end

    test "boto3 denied by default" do
      assert {:error, %Error{message: msg}} =
               Pyex.run("""
               import boto3
               s3 = boto3.client("s3")
               s3.put_object(Bucket="b", Key="k", Body="x")
               """)

      assert msg =~ "boto3 is disabled"
    end
  end

  # ------------------------------------------------------------------
  # Error Handling
  # ------------------------------------------------------------------

  describe "error kinds" do
    test "syntax error" do
      assert {:error, %Error{kind: :syntax}} = Pyex.run("def")
    end

    test "python runtime error" do
      assert {:error, %Error{kind: :python}} = Pyex.run("1 / 0")
    end

    test "timeout error" do
      assert {:error, %Error{kind: :timeout}} =
               Pyex.run("while True:\n    x = 1", timeout_ms: 50)
    end

    test "import error" do
      assert {:error, %Error{kind: :import}} = Pyex.run("import nonexistent_xyz")
    end

    test "io error" do
      alias Pyex.Filesystem.Memory

      assert {:error, %Error{kind: :io}} =
               Pyex.run(
                 """
                 f = open("missing.txt", "r")
                 """,
                 filesystem: Memory.new()
               )
    end

    test "route_not_found error" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.get("/hello")
      def hello():
          return "hi"
      """

      {:ok, app} = Lambda.boot(source)

      assert {:error, %Error{kind: :route_not_found}} =
               Lambda.handle(app, %{method: "GET", path: "/missing"})
    end
  end

  # ------------------------------------------------------------------
  # Print Output
  # ------------------------------------------------------------------

  describe "print output" do
    test "for loop with print produces 0\\n1\\n2" do
      {:ok, _val, ctx} = Pyex.run("for i in range(3):\n    print(i)")
      assert Pyex.output(ctx) == "0\n1\n2"
    end
  end

  # ------------------------------------------------------------------
  # FastAPI / Lambda
  # ------------------------------------------------------------------

  describe "FastAPI / Lambda" do
    @fastapi_source """
    import fastapi
    app = fastapi.FastAPI()

    @app.get("/hello/{name}")
    def hello(name):
        return {"message": f"hello {name}"}
    """

    test "boot and handle GET" do
      {:ok, app} = Lambda.boot(@fastapi_source)

      {:ok, resp, _app} =
        Lambda.handle(app, %{method: "GET", path: "/hello/world"})

      assert resp.status == 200
      assert resp.body == %{"message" => "hello world"}
    end

    test "POST with JSON body" do
      source = """
      import fastapi
      app = fastapi.FastAPI()

      @app.post("/items")
      def create_item(request):
          data = request.json()
          return {"name": data["name"], "qty": data["qty"]}
      """

      {:ok, app} = Lambda.boot(source)

      {:ok, resp, _app} =
        Lambda.handle(app, %{
          method: "POST",
          path: "/items",
          body: ~s({"name": "widget", "qty": 3})
        })

      assert resp.status == 200
      assert resp.body == %{"name" => "widget", "qty" => 3}
    end
  end

  describe "streaming" do
    @sse_source """
    import fastapi
    from fastapi.responses import StreamingResponse

    app = fastapi.FastAPI()

    @app.get("/events")
    def events():
        def gen():
            for i in range(5):
                yield f"data: {i}\\n\\n"
        return StreamingResponse(gen(), media_type="text/event-stream")
    """

    test "handle_stream with Enum.take" do
      {:ok, app} = Lambda.boot(@sse_source)

      {:ok, resp, _app} =
        Lambda.handle_stream(app, %{method: "GET", path: "/events"})

      assert Enum.take(resp.chunks, 3) == [
               "data: 0\n\n",
               "data: 1\n\n",
               "data: 2\n\n"
             ]
    end
  end
end
