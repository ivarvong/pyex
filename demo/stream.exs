source = ~S"""
import fastapi
from fastapi.responses import StreamingResponse

app = fastapi.FastAPI()

@app.get("/stream")
def stream():
    def generate():
        for i in range(10):
            total = 0
            for j in range(5000):
                total = total + j * (i + 1)
            yield str(total) + "\n"
    return StreamingResponse(generate(), media_type="text/plain")

@app.get("/sse")
def sse():
    def events():
        for i in range(8):
            total = 0
            for j in range(3000):
                total = total + j * (i + 1)
            yield "data: " + str({"event": i, "result": total}) + "\n\n"
    return StreamingResponse(events(), media_type="text/event-stream")

@app.get("/html")
def html():
    def page():
        yield "<!DOCTYPE html>\n<html>\n<body>\n"
        yield "<h1>Streamed from Pyex</h1>\n"
        for i in range(5):
            total = 0
            for j in range(4000):
                total = total + j * (i + 1)
            yield "<p>Chunk " + str(i) + ": " + str(total) + "</p>\n"
        yield "</body>\n</html>\n"
    return StreamingResponse(page(), media_type="text/html")
"""

{:ok, app} = Pyex.Lambda.boot(source)
:persistent_term.put(:demo_app, app)

defmodule Demo.Plug do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  match _ do
    app = :persistent_term.get(:demo_app)
    method = conn.method
    path = conn.request_path

    case Pyex.Lambda.handle_stream(app, %{method: method, path: path}) do
      {:ok, resp, _app} ->
        conn =
          Enum.reduce(resp.headers, conn, fn {k, v}, c ->
            Plug.Conn.put_resp_header(c, k, v)
          end)

        conn = Plug.Conn.send_chunked(conn, resp.status)

        Enum.reduce_while(resp.chunks, conn, fn chunk, conn ->
          case Plug.Conn.chunk(conn, chunk) do
            {:ok, conn} -> {:cont, conn}
            {:error, :closed} -> {:halt, conn}
          end
        end)

      {:error, err} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => err.message}))
    end
  end
end

IO.puts("""
Pyex Lambda streaming demo
===========================

  curl -N localhost:4000/stream    # 10 computed chunks
  curl -N localhost:4000/sse       # server-sent events
  curl -N localhost:4000/html      # streamed HTML page

Press Ctrl+C to stop.
""")

{:ok, _} = Bandit.start_link(plug: Demo.Plug, port: 4000)
Process.sleep(:infinity)
