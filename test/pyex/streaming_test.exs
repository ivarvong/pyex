defmodule Pyex.StreamingTest do
  @moduledoc """
  Tests for streaming responses via Lambda.handle_stream/2.

  Covers StreamingResponse with generators, lists, plain strings,
  and the fallback behavior when handle_stream is called on
  non-streaming handlers. Also tests that handle/2 concatenates
  streaming chunks into a single body for backward compatibility.
  """
  use ExUnit.Case, async: true

  alias Pyex.Lambda
  alias Pyex.Error

  @generator_app """
  import fastapi
  from fastapi.responses import StreamingResponse

  app = fastapi.FastAPI()

  @app.get("/stream")
  def stream():
      def generate():
          yield "Hello, "
          yield "world!"
      return StreamingResponse(generate(), media_type="text/plain")
  """

  @html_chunks_app """
  import fastapi
  from fastapi.responses import StreamingResponse

  app = fastapi.FastAPI()

  @app.get("/page")
  def page():
      def chunks():
          yield "<html><body>"
          yield "<h1>Title</h1>"
          yield "<p>Content</p>"
          yield "</body></html>"
      return StreamingResponse(chunks(), media_type="text/html")
  """

  @list_app """
  import fastapi
  from fastapi.responses import StreamingResponse

  app = fastapi.FastAPI()

  @app.get("/csv")
  def csv_data():
      rows = ["name,age\\n", "alice,30\\n", "bob,25\\n"]
      return StreamingResponse(rows, media_type="text/csv")
  """

  @json_lines_app """
  import fastapi
  from fastapi.responses import StreamingResponse
  import json

  app = fastapi.FastAPI()

  @app.get("/events")
  def events():
      def generate():
          for i in range(3):
              yield json.dumps({"event": i}) + "\\n"
      return StreamingResponse(generate(), media_type="application/x-ndjson")
  """

  @mixed_app """
  import fastapi
  from fastapi.responses import StreamingResponse, JSONResponse

  app = fastapi.FastAPI()

  @app.get("/stream")
  def stream():
      def generate():
          yield "chunk1"
          yield "chunk2"
      return StreamingResponse(generate(), media_type="text/plain")

  @app.get("/json")
  def json_endpoint():
      return JSONResponse({"key": "value"})

  @app.get("/plain")
  def plain():
      return {"message": "hello"}
  """

  @status_headers_app """
  import fastapi
  from fastapi.responses import StreamingResponse

  app = fastapi.FastAPI()

  @app.get("/download")
  def download():
      def data():
          yield "file content here"
      return StreamingResponse(
          data(),
          status_code=206,
          media_type="application/octet-stream",
          headers={"content-disposition": "attachment; filename=data.bin"}
      )
  """

  @single_string_app """
  import fastapi
  from fastapi.responses import StreamingResponse

  app = fastapi.FastAPI()

  @app.get("/single")
  def single():
      return StreamingResponse("just a string", media_type="text/plain")
  """

  @empty_generator_app """
  import fastapi
  from fastapi.responses import StreamingResponse

  app = fastapi.FastAPI()

  @app.get("/empty")
  def empty():
      def generate():
          items = []
          for x in items:
              yield str(x)
      return StreamingResponse(generate(), media_type="text/plain")
  """

  @numeric_chunks_app """
  import fastapi
  from fastapi.responses import StreamingResponse

  app = fastapi.FastAPI()

  @app.get("/numbers")
  def numbers():
      def generate():
          for i in range(5):
              yield str(i)
      return StreamingResponse(generate(), media_type="text/plain")
  """

  @param_stream_app """
  import fastapi
  from fastapi.responses import StreamingResponse

  app = fastapi.FastAPI()

  @app.get("/repeat/{word}")
  def repeat(word):
      def generate():
          for i in range(3):
              yield word + " "
      return StreamingResponse(generate(), media_type="text/plain")
  """

  describe "handle_stream/2 with generator-based StreamingResponse" do
    test "returns chunks from generator function" do
      {:ok, app} = Lambda.boot(@generator_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/stream"})

      assert resp.status == 200
      assert resp.headers["content-type"] == "text/plain"
      assert Enum.to_list(resp.chunks) == ["Hello, ", "world!"]
    end

    test "HTML chunks from generator" do
      {:ok, app} = Lambda.boot(@html_chunks_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/page"})

      assert resp.status == 200
      assert resp.headers["content-type"] == "text/html"
      chunks = Enum.to_list(resp.chunks)
      assert length(chunks) == 4
      assert Enum.at(chunks, 0) == "<html><body>"
      assert Enum.at(chunks, 1) == "<h1>Title</h1>"
      assert Enum.join(chunks) =~ "<html><body><h1>Title</h1>"
    end

    test "JSON lines from generator with loop" do
      {:ok, app} = Lambda.boot(@json_lines_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/events"})

      assert resp.status == 200
      assert resp.headers["content-type"] == "application/x-ndjson"
      chunks = Enum.to_list(resp.chunks)
      assert length(chunks) == 3

      Enum.each(chunks, fn chunk ->
        line = String.trim(chunk)
        assert {:ok, _} = Jason.decode(line)
      end)

      first = Jason.decode!(String.trim(Enum.at(chunks, 0)))
      assert first == %{"event" => 0}
    end

    test "numeric string chunks from generator" do
      {:ok, app} = Lambda.boot(@numeric_chunks_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/numbers"})

      assert Enum.to_list(resp.chunks) == ["0", "1", "2", "3", "4"]
    end

    test "path params work with streaming handlers" do
      {:ok, app} = Lambda.boot(@param_stream_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/repeat/hey"})

      assert Enum.to_list(resp.chunks) == ["hey ", "hey ", "hey "]
    end
  end

  describe "handle_stream/2 with list-based StreamingResponse" do
    test "returns chunks from plain list" do
      {:ok, app} = Lambda.boot(@list_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/csv"})

      assert resp.status == 200
      assert resp.headers["content-type"] == "text/csv"
      assert Enum.to_list(resp.chunks) == ["name,age\n", "alice,30\n", "bob,25\n"]
    end
  end

  describe "handle_stream/2 with single string StreamingResponse" do
    test "wraps string in single chunk" do
      {:ok, app} = Lambda.boot(@single_string_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/single"})

      assert resp.status == 200
      assert Enum.to_list(resp.chunks) == ["just a string"]
    end
  end

  describe "handle_stream/2 with empty generator" do
    test "returns empty chunks list" do
      {:ok, app} = Lambda.boot(@empty_generator_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/empty"})

      assert resp.status == 200
      assert Enum.to_list(resp.chunks) == []
    end
  end

  describe "handle_stream/2 with status and custom headers" do
    test "preserves status code and merges custom headers" do
      {:ok, app} = Lambda.boot(@status_headers_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/download"})

      assert resp.status == 206
      assert resp.headers["content-type"] == "application/octet-stream"
      assert resp.headers["content-disposition"] == "attachment; filename=data.bin"
      assert Enum.to_list(resp.chunks) == ["file content here"]
    end
  end

  describe "handle_stream/2 fallback for non-streaming responses" do
    test "wraps JSON response body as single chunk" do
      {:ok, app} = Lambda.boot(@mixed_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/json"})

      assert resp.status == 200
      assert resp.headers["content-type"] == "application/json"
      chunks = Enum.to_list(resp.chunks)
      assert length(chunks) == 1
      decoded = Jason.decode!(hd(chunks))
      assert decoded == %{"key" => "value"}
    end

    test "wraps plain dict return as single JSON chunk" do
      {:ok, app} = Lambda.boot(@mixed_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/plain"})

      assert resp.status == 200
      chunks = Enum.to_list(resp.chunks)
      assert length(chunks) == 1
      decoded = Jason.decode!(hd(chunks))
      assert decoded == %{"message" => "hello"}
    end
  end

  describe "handle/2 with StreamingResponse (backward compat)" do
    test "concatenates chunks into single body string" do
      {:ok, app} = Lambda.boot(@generator_app)
      {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/stream"})

      assert resp.status == 200
      assert resp.headers["content-type"] == "text/plain"
      assert resp.body == "Hello, world!"
    end

    test "HTML chunks concatenated" do
      {:ok, app} = Lambda.boot(@html_chunks_app)
      {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/page"})

      assert resp.body == "<html><body><h1>Title</h1><p>Content</p></body></html>"
    end

    test "preserves status code and headers when concatenating" do
      {:ok, app} = Lambda.boot(@status_headers_app)
      {:ok, resp, _app} = Lambda.handle(app, %{method: "GET", path: "/download"})

      assert resp.status == 206
      assert resp.headers["content-disposition"] == "attachment; filename=data.bin"
      assert resp.body == "file content here"
    end
  end

  describe "handle_stream/2 error handling" do
    test "route not found returns error" do
      {:ok, app} = Lambda.boot(@generator_app)

      {:error, %Error{kind: :route_not_found}} =
        Lambda.handle_stream(app, %{method: "GET", path: "/missing"})
    end

    test "handler error returns 500 with detail chunk" do
      source = """
      import fastapi
      from fastapi.responses import StreamingResponse

      app = fastapi.FastAPI()

      @app.get("/fail")
      def fail():
          raise ValueError("something broke")
          return StreamingResponse("nope", media_type="text/plain")
      """

      {:ok, app} = Lambda.boot(source)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/fail"})

      assert resp.status == 500
      chunks = Enum.to_list(resp.chunks)
      assert length(chunks) == 1
      detail = Jason.decode!(hd(chunks))
      assert detail["detail"] =~ "ValueError"
    end
  end

  describe "handle_stream/2 stateful across requests" do
    test "ctx threads through multiple streaming requests with filesystem" do
      fs = Pyex.Filesystem.Memory.new(%{"log.txt" => ""})
      ctx = Pyex.Ctx.new(filesystem: fs)

      source = """
      import fastapi
      from fastapi.responses import StreamingResponse

      app = fastapi.FastAPI()

      @app.get("/log")
      def log(request):
          msg = request.query_params.get("msg", "default")
          f = open("log.txt", "r")
          old = f.read()
          f.close()
          new_content = old + msg + "\\n"
          f = open("log.txt", "w")
          f.write(new_content)
          f.close()
          lines = new_content.strip().split("\\n")
          def generate():
              for line in lines:
                  yield line + "\\n"
          return StreamingResponse(generate(), media_type="text/plain")
      """

      {:ok, app} = Lambda.boot(source, ctx: ctx)

      {:ok, resp1, app} =
        Lambda.handle_stream(app, %{
          method: "GET",
          path: "/log",
          query_params: %{"msg" => "first"}
        })

      assert Enum.to_list(resp1.chunks) == ["first\n"]

      {:ok, resp2, _app} =
        Lambda.handle_stream(app, %{
          method: "GET",
          path: "/log",
          query_params: %{"msg" => "second"}
        })

      assert Enum.to_list(resp2.chunks) == ["first\n", "second\n"]
    end
  end

  describe "StreamingResponse in FastAPI stdlib" do
    test "available via from fastapi import StreamingResponse" do
      source = """
      from fastapi import StreamingResponse

      app_val = StreamingResponse("hello", media_type="text/html")
      app_val
      """

      {:ok, result, _ctx} = Pyex.run(source)
      assert result["__response__"] == true
      assert result["__streaming__"] == true
      assert result["body"] == ["hello"]
      assert result["headers"]["content-type"] == "text/html"
    end

    test "available via from fastapi.responses import StreamingResponse" do
      source = """
      from fastapi.responses import StreamingResponse

      resp = StreamingResponse("test", media_type="text/plain")
      resp
      """

      {:ok, result, _ctx} = Pyex.run(source)
      assert result["__streaming__"] == true
    end

    test "missing content raises TypeError" do
      source = """
      from fastapi import StreamingResponse
      StreamingResponse()
      """

      {:error, %Error{message: msg}} = Pyex.run(source)
      assert msg =~ "TypeError"
      assert msg =~ "StreamingResponse"
    end

    test "generator content is extracted to list of strings" do
      source = """
      from fastapi import StreamingResponse

      def gen():
          yield 1
          yield 2
          yield 3

      resp = StreamingResponse(gen(), media_type="text/plain")
      resp["body"]
      """

      {:ok, result, _ctx} = Pyex.run(source)
      assert result == ["1", "2", "3"]
    end

    test "list content is extracted to list of strings" do
      source = """
      from fastapi import StreamingResponse

      resp = StreamingResponse(["a", "b", "c"], media_type="text/plain")
      resp["body"]
      """

      {:ok, result, _ctx} = Pyex.run(source)
      assert result == ["a", "b", "c"]
    end

    test "default media_type is text/plain" do
      source = """
      from fastapi import StreamingResponse

      resp = StreamingResponse("content")
      resp["headers"]["content-type"]
      """

      {:ok, result, _ctx} = Pyex.run(source)
      assert result == "text/plain"
    end
  end

  describe "lazy streaming behavior" do
    test "chunks is a lazy Stream, not a list" do
      {:ok, app} = Lambda.boot(@generator_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/stream"})

      assert is_function(resp.chunks) or
               (is_struct(resp.chunks) and resp.chunks.__struct__ == Stream)

      refute is_list(resp.chunks)

      assert Enum.to_list(resp.chunks) == ["Hello, ", "world!"]
    end

    test "Enum.take/2 returns partial chunks" do
      {:ok, app} = Lambda.boot(@numeric_chunks_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/numbers"})

      taken = Enum.take(resp.chunks, 2)
      assert taken == ["0", "1"]
    end

    test "Enum.reduce_while early halt stops after N chunks" do
      {:ok, app} = Lambda.boot(@numeric_chunks_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/numbers"})

      collected =
        Enum.reduce_while(resp.chunks, [], fn chunk, acc ->
          new_acc = acc ++ [chunk]
          if length(new_acc) >= 3, do: {:halt, new_acc}, else: {:cont, new_acc}
        end)

      assert collected == ["0", "1", "2"]
    end

    test "early halt cleans up child process" do
      {:ok, app} = Lambda.boot(@numeric_chunks_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/numbers"})

      _taken = Enum.take(resp.chunks, 1)

      Process.sleep(50)

      pids =
        Process.list()
        |> Enum.filter(fn pid ->
          info = Process.info(pid, [:dictionary])

          case info do
            [{:dictionary, dict}] ->
              Keyword.get(dict, :"$initial_call") ==
                {Pyex.Lambda, :handle_stream, 2}

            _ ->
              false
          end
        end)

      assert pids == []
    end

    test "Phoenix-style reduce_while pattern" do
      {:ok, app} = Lambda.boot(@html_chunks_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/page"})

      {chunks, :ok} =
        Enum.reduce_while(resp.chunks, {[], :ok}, fn chunk, {acc, :ok} ->
          new_acc = acc ++ [chunk]

          if length(new_acc) >= 2 do
            {:halt, {new_acc, :ok}}
          else
            {:cont, {new_acc, :ok}}
          end
        end)

      assert chunks == ["<html><body>", "<h1>Title</h1>"]
    end

    test "full consumption via Enum.each works" do
      {:ok, app} = Lambda.boot(@numeric_chunks_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/numbers"})

      collected = :ets.new(:test_chunks, [:ordered_set])

      resp.chunks
      |> Enum.with_index()
      |> Enum.each(fn {chunk, idx} ->
        :ets.insert(collected, {idx, chunk})
      end)

      result = :ets.tab2list(collected) |> Enum.map(&elem(&1, 1))
      :ets.delete(collected)

      assert result == ["0", "1", "2", "3", "4"]
    end

    test "Stream.map transforms chunks lazily" do
      {:ok, app} = Lambda.boot(@numeric_chunks_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/numbers"})

      uppercased =
        resp.chunks
        |> Stream.map(&String.upcase/1)
        |> Enum.to_list()

      assert uppercased == ["0", "1", "2", "3", "4"]
    end

    test "Stream.map with take composes lazily" do
      {:ok, app} = Lambda.boot(@numeric_chunks_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/numbers"})

      result =
        resp.chunks
        |> Stream.map(fn chunk -> "[#{chunk}]" end)
        |> Enum.take(3)

      assert result == ["[0]", "[1]", "[2]"]
    end

    test "chunks are delivered incrementally via back-pressure, not all at once" do
      {:ok, app} = Lambda.boot(@numeric_chunks_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/numbers"})

      delay_ms = 20

      timestamps =
        Enum.map(resp.chunks, fn chunk ->
          Process.sleep(delay_ms)
          {chunk, System.monotonic_time(:millisecond)}
        end)

      assert length(timestamps) == 5

      gaps =
        timestamps
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [{_, t1}, {_, t2}] -> t2 - t1 end)

      assert length(gaps) == 4

      assert Enum.all?(gaps, fn gap -> gap >= div(delay_ms, 2) end),
             "Expected each gap >= #{div(delay_ms, 2)}ms (consumer sleep is #{delay_ms}ms), " <>
               "got gaps: #{inspect(gaps)}ms. Chunks would arrive simultaneously if not back-pressured."
    end

    test "child blocks until consumer requests next chunk" do
      {:ok, app} = Lambda.boot(@numeric_chunks_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/numbers"})

      delay_ms = 30

      timestamps =
        resp.chunks
        |> Stream.transform(nil, fn chunk, _acc ->
          ts = System.monotonic_time(:millisecond)
          Process.sleep(delay_ms)
          {[{chunk, ts}], nil}
        end)
        |> Enum.to_list()

      assert length(timestamps) == 5
      chunks = Enum.map(timestamps, &elem(&1, 0))
      assert chunks == ["0", "1", "2", "3", "4"]

      gaps =
        timestamps
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [{_, t1}, {_, t2}] -> t2 - t1 end)

      assert Enum.all?(gaps, fn gap -> gap >= div(delay_ms, 2) end),
             "Expected gaps >= #{div(delay_ms, 2)}ms between chunk arrivals " <>
               "(consumer sleeps #{delay_ms}ms), got gaps: #{inspect(gaps)}ms. " <>
               "If chunks were not back-pressured, gaps would be near-zero."
    end
  end

  describe "true lazy generator execution" do
    @expensive_app """
    import fastapi
    from fastapi.responses import StreamingResponse

    app = fastapi.FastAPI()

    @app.get("/compute")
    def compute():
        def generate():
            for i in range(5):
                total = 0
                for j in range(2000):
                    total = total + j * (i + 1)
                yield str(total) + "\\n"
        return StreamingResponse(generate(), media_type="text/plain")
    """

    test "chunks arrive as they are computed, not all at once" do
      {:ok, app} = Lambda.boot(@expensive_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/compute"})

      timestamps =
        Enum.map(resp.chunks, fn chunk ->
          {chunk, System.monotonic_time(:microsecond)}
        end)

      assert length(timestamps) == 5

      chunks = Enum.map(timestamps, fn {c, _} -> String.trim(c) end)
      assert chunks == ["1999000", "3998000", "5997000", "7996000", "9995000"]

      gaps_us =
        timestamps
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [{_, t1}, {_, t2}] -> t2 - t1 end)

      avg_gap_us = Enum.sum(gaps_us) / length(gaps_us)

      assert avg_gap_us > 100,
             "Expected avg gap > 100µs between chunks (generator does real work), " <>
               "got avg #{Float.round(avg_gap_us, 1)}µs, gaps: #{inspect(gaps_us)}µs. " <>
               "If all chunks were materialized before delivery, gaps would be near-zero."
    end

    test "time to first chunk is fast (metadata arrives before all computation)" do
      {:ok, app} = Lambda.boot(@expensive_app)

      t_start = System.monotonic_time(:microsecond)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/compute"})

      first_chunk = Enum.take(resp.chunks, 1)
      t_first = System.monotonic_time(:microsecond)

      assert length(first_chunk) == 1

      time_to_first_us = t_first - t_start

      assert time_to_first_us < 500_000,
             "Expected time to first chunk < 500ms, got #{time_to_first_us}µs. " <>
               "Deferred generators should not block on all computation before first yield."
    end

    test "early halt skips remaining computation" do
      {:ok, app} = Lambda.boot(@expensive_app)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/compute"})

      t_start = System.monotonic_time(:microsecond)
      taken = Enum.take(resp.chunks, 2)
      t_done = System.monotonic_time(:microsecond)

      assert length(taken) == 2
      assert String.trim(Enum.at(taken, 0)) == "1999000"
      assert String.trim(Enum.at(taken, 1)) == "3998000"

      elapsed_us = t_done - t_start

      assert elapsed_us < 500_000,
             "Taking 2 of 5 chunks should complete quickly, got #{elapsed_us}µs"
    end
  end

  describe "invoke/3 with StreamingResponse" do
    test "invoke concatenates streaming response" do
      {:ok, resp} = Lambda.invoke(@generator_app, %{method: "GET", path: "/stream"})

      assert resp.status == 200
      assert resp.body == "Hello, world!"
    end
  end
end
