defmodule EvalServer.Plug do
  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  post "/run" do
    source = conn.body_params["source"] || ""

    case Pyex.run(source, timeout: 5_000) do
      {:ok, value, ctx} ->
        body =
          Jason.encode!(%{
            ok: true,
            value: value,
            output: Pyex.output(ctx)
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)

      {:error, err} ->
        body =
          Jason.encode!(%{
            ok: false,
            kind: err.kind,
            message: err.message
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, body)
    end
  end

  match _ do
    body =
      Jason.encode!(%{
        ok: false,
        message: "Use POST /run with JSON body: {\"source\": \"...\"}"
      })

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(404, body)
  end
end

{:ok, _} = Bandit.start_link(plug: EvalServer.Plug, port: 4000)
IO.puts("Listening on http://localhost:4000")
Process.sleep(:infinity)
