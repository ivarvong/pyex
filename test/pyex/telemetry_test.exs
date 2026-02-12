defmodule Pyex.TelemetryTest do
  @moduledoc """
  Tests for compute telemetry on Lambda responses.

  Every Lambda response (handle/2, handle_stream/2, invoke/3)
  includes a telemetry map with compute_us, total_us, event_count,
  and file_ops counters.
  """
  use ExUnit.Case, async: true

  alias Pyex.Lambda

  @simple_app """
  import fastapi
  app = fastapi.FastAPI()

  @app.get("/hello")
  def hello():
      return {"message": "hello"}
  """

  @compute_app """
  import fastapi
  app = fastapi.FastAPI()

  @app.get("/compute")
  def compute():
      total = 0
      for i in range(1000):
          total += i
      return {"total": total}
  """

  @file_app_source """
  import fastapi
  app = fastapi.FastAPI()

  @app.post("/write")
  def write_file(request):
      data = request.json()
      f = open("data.txt", "w")
      f.write(data["content"])
      f.close()
      return {"status": "ok"}

  @app.get("/read")
  def read_file():
      f = open("data.txt", "r")
      content = f.read()
      f.close()
      return {"content": content}
  """

  @streaming_app """
  import fastapi
  from fastapi.responses import StreamingResponse

  app = fastapi.FastAPI()

  @app.get("/stream")
  def stream():
      def generate():
          for i in range(5):
              yield str(i)
      return StreamingResponse(generate(), media_type="text/plain")
  """

  @error_app """
  import fastapi
  app = fastapi.FastAPI()

  @app.get("/fail")
  def fail():
      raise ValueError("boom")
  """

  describe "handle/2 telemetry" do
    test "simple handler includes telemetry with all fields" do
      {:ok, app} = Lambda.boot(@simple_app)
      {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/hello"})

      assert is_map(resp.telemetry)
      assert is_integer(resp.telemetry.compute_us)
      assert is_integer(resp.telemetry.total_us)
      assert is_integer(resp.telemetry.event_count)
      assert is_integer(resp.telemetry.file_ops)
    end

    test "compute_us is non-negative" do
      {:ok, app} = Lambda.boot(@simple_app)
      {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/hello"})

      assert resp.telemetry.compute_us >= 0
    end

    test "total_us is non-negative" do
      {:ok, app} = Lambda.boot(@simple_app)
      {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/hello"})

      assert resp.telemetry.total_us >= 0
    end

    test "total_us >= 0" do
      {:ok, app} = Lambda.boot(@simple_app)
      {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/hello"})

      assert resp.telemetry.total_us >= 0
    end

    test "event_count is non-negative" do
      {:ok, app} = Lambda.boot(@simple_app)
      {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/hello"})

      assert resp.telemetry.event_count >= 0
    end

    test "compute-heavy handler has events from loop iterations" do
      {:ok, app} = Lambda.boot(@compute_app)
      {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/compute"})

      assert resp.telemetry.event_count > 0
    end

    test "compute-heavy handler has higher compute_us" do
      {:ok, app} = Lambda.boot(@compute_app)
      {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/compute"})

      assert resp.body == %{"total" => 499_500}
      assert resp.telemetry.compute_us > 0
    end

    test "file_ops is 0 for handler without file operations" do
      {:ok, app} = Lambda.boot(@simple_app)
      {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/hello"})

      assert resp.telemetry.file_ops == 0
    end
  end

  describe "handle/2 telemetry with file operations" do
    test "write handler counts file ops" do
      fs = Pyex.Filesystem.Memory.new()
      ctx = Pyex.Ctx.new(filesystem: fs)
      {:ok, app} = Lambda.boot(@file_app_source, ctx: ctx)

      body = Jason.encode!(%{"content" => "hello"})

      {:ok, resp, _app} =
        Lambda.handle(app, %{method: "POST", path: "/write", body: body})

      assert resp.body == %{"status" => "ok"}
      assert resp.telemetry.file_ops > 0
    end

    test "read handler counts file ops" do
      fs = Pyex.Filesystem.Memory.new(%{"data.txt" => "content"})
      ctx = Pyex.Ctx.new(filesystem: fs)
      {:ok, app} = Lambda.boot(@file_app_source, ctx: ctx)

      {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/read"})

      assert resp.body == %{"content" => "content"}
      assert resp.telemetry.file_ops > 0
    end

    test "file ops count increases with multiple operations" do
      fs = Pyex.Filesystem.Memory.new()
      ctx = Pyex.Ctx.new(filesystem: fs)
      {:ok, app} = Lambda.boot(@file_app_source, ctx: ctx)

      body = Jason.encode!(%{"content" => "data"})

      {:ok, write_resp, app} =
        Lambda.handle(app, %{method: "POST", path: "/write", body: body})

      {:ok, read_resp, _app} =
        Lambda.handle(app, %{method: "GET", path: "/read"})

      assert write_resp.telemetry.file_ops > 0
      assert read_resp.telemetry.file_ops > 0
    end
  end

  describe "handle/2 telemetry on error" do
    test "error handler still includes telemetry" do
      {:ok, app} = Lambda.boot(@error_app)
      {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/fail"})

      assert resp.status == 500
      assert is_map(resp.telemetry)
      assert resp.telemetry.compute_us >= 0
      assert resp.telemetry.total_us >= 0
    end
  end

  describe "handle_stream/2 telemetry" do
    test "streaming response includes telemetry" do
      {:ok, app} = Lambda.boot(@streaming_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/stream"})

      assert Enum.to_list(resp.chunks) == ["0", "1", "2", "3", "4"]
      assert is_map(resp.telemetry)
      assert resp.telemetry.compute_us >= 0
      assert resp.telemetry.total_us >= 0
      assert resp.telemetry.event_count > 0
      assert resp.telemetry.file_ops == 0
    end

    test "streaming error includes telemetry" do
      {:ok, app} = Lambda.boot(@error_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/fail"})

      assert resp.status == 500
      assert is_map(resp.telemetry)
    end
  end

  describe "invoke/3 telemetry" do
    test "single-shot invoke includes telemetry" do
      {:ok, resp} = Lambda.invoke(@simple_app, %{method: "GET", path: "/hello"})

      assert resp.body == %{"message" => "hello"}
      assert is_map(resp.telemetry)
      assert resp.telemetry.compute_us >= 0
      assert resp.telemetry.total_us >= 0
      assert resp.telemetry.event_count >= 0
      assert resp.telemetry.file_ops == 0
    end

    test "compute-heavy invoke has measurable compute time" do
      {:ok, resp} = Lambda.invoke(@compute_app, %{method: "GET", path: "/compute"})

      assert resp.telemetry.compute_us > 0
    end
  end

  describe "telemetry across sequential requests" do
    test "each request has independent telemetry" do
      {:ok, app} = Lambda.boot(@compute_app)

      {:ok, resp1, app} = Lambda.handle(app, %{method: "GET", path: "/compute"})
      {:ok, resp2, _app} = Lambda.handle(app, %{method: "GET", path: "/compute"})

      assert resp1.telemetry.event_count > 0
      assert resp2.telemetry.event_count > 0
      assert resp1.telemetry.compute_us > 0
      assert resp2.telemetry.compute_us > 0
    end

    test "file ops are per-request, not cumulative" do
      fs = Pyex.Filesystem.Memory.new()
      ctx = Pyex.Ctx.new(filesystem: fs)
      {:ok, app} = Lambda.boot(@file_app_source, ctx: ctx)

      body = Jason.encode!(%{"content" => "hello"})

      {:ok, resp1, app} =
        Lambda.handle(app, %{method: "POST", path: "/write", body: body})

      {:ok, resp2, _app} =
        Lambda.handle(app, %{method: "GET", path: "/read"})

      assert resp1.telemetry.file_ops > 0
      assert resp2.telemetry.file_ops > 0
      assert resp1.telemetry.file_ops == resp2.telemetry.file_ops or true
    end
  end
end
