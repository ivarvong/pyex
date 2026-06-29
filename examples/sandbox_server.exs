# A tiny HTTP sandbox: POST Python source, get a structured verdict back.
#
# Demonstrates the "Pyex is processless; the caller owns the process" model, and
# the telemetry discipline that follows from it:
#
#   * The HTTP status describes the SANDBOX SERVICE, never the guest program.
#     Running and bounding a job is a successful request (200); the program's
#     verdict — ok / error / timeout / out_of_memory / host_fault — is a field
#     in the body. The guest must not be able to move your 5xx rate (that would
#     hand it your circuit breakers, health checks, and on-call pager). Only the
#     SERVICE failing is a 5xx; a malformed HTTP request is a 4xx.
#
#   * Every verdict that produced a result also carries `usage` (the resource
#     footprint) and `trace` (the host capability ledger — an unforgeable span
#     tree of what the program touched). The ledger is present even when the
#     program FAILED: "what did it touch before it crashed?" matters most then.
#     Pyex emits it on both [:pyex, :run, :stop] and [:pyex, :run, :exception].
#
#   * A `host_fault` (the guest tripped a CONTAINED interpreter bug) is still a
#     200 — the service stayed up and contained it — but it ALSO fires a
#     dedicated high-severity signal, because containment failing is a real
#     incident. Service health and containment health are different channels.
#
# Run it:    mix run examples/sandbox_server.exs
#
#   curl -s localhost:4599/run --data-binary 'print(sum(range(1000)))'        # verdict ok
#   curl -s localhost:4599/run --data-binary '1 / 0'                          # verdict error
#   curl -s localhost:4599/run --data-binary $'while True:\n    pass'         # verdict timeout
#   curl -s localhost:4599/run --data-binary \
#     $'x = []\ni = 0\nwhile True:\n    x.append(i * i)\n    i += 1'           # verdict out_of_memory
#   # the ledger survives failure — this errors, but `trace` shows the writes it did first:
#   curl -s localhost:4599/run --data-binary \
#     $'import store\nstore.set("audit", "started")\nstore.get("audit")\n1 / 0' | jq -r .trace

require Logger

defmodule SandboxServer do
  use Plug.Router

  @wall_ms 3_000
  @heap_bytes 64_000_000
  # Time is bounded cooperatively by Pyex; memory and any native hang are bounded
  # by the per-request *process*. In production keep Pyex's max_memory/max_steps
  # on too — here max_memory is :infinity so the BEAM heap cap is the visible
  # memory ceiling. (A real service would also clamp client-requested limits to
  # these as a ceiling — the caller may ask for *tighter*, never looser.)
  @limits [
    timeout: @wall_ms - 500,
    max_steps: :infinity,
    max_memory_bytes: :infinity,
    max_output_bytes: 1_000_000
  ]

  plug(:match)
  plug(:dispatch)

  post "/run" do
    {status, body} =
      case Plug.Conn.read_body(conn, length: 2_000_000) do
        {:ok, "", _} -> {400, %{error: "empty body — POST Python source"}}
        {:ok, source, _} -> {200, run_sandboxed(source)}
        {:more, _, _} -> {413, %{error: "program too large"}}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  match(_, do: send_resp(conn, 404, ~s({"error":"POST Python source to /run"})))

  # The request process is the sandbox supervisor: it spawns a monitored worker
  # (spawn_monitor, not link, so a guest OOM can't take the request down), caps
  # the worker's heap, and watchdogs the wall clock. The HTTP layer never sees
  # the guest's behavior — only this function's verdict.
  defp run_sandboxed(source) do
    run_id = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: div(@heap_bytes, :erlang.system_info(:wordsize)),
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        # Fresh, isolated in-memory store per request.
        run_opts = [limits: @limits, storage: Pyex.Storage.Memory.new()]

        body =
          case Pyex.run(source, run_opts) do
            {:ok, value, ctx} ->
              with_telemetry(%{verdict: "ok", stdout: Pyex.output(ctx), value: inspect(value)})

            {:error, %Pyex.Error{kind: :timeout, message: m}} ->
              with_telemetry(%{verdict: "timeout", detail: m})

            {:error, %Pyex.Error{} = e} ->
              with_telemetry(%{
                verdict: "error",
                error: %{type: e.exception_type, kind: e.kind, message: e.message, line: e.line}
              })
          end

        send(parent, {:done, self(), body})
      end)

    base = %{run_id: run_id}

    receive do
      {:done, ^pid, body} ->
        Process.demonitor(ref, [:flush])
        Map.merge(base, body)

      # max_heap_size killed the worker (reason :killed): a clean memory verdict.
      {:DOWN, ^ref, :process, ^pid, :killed} ->
        Map.put(base, :verdict, "out_of_memory")

      # The worker died some other way — the guest tripped a contained interpreter
      # bug. Still a 200 verdict to the caller, but a real containment incident:
      # fire a dedicated, guest-uninfluenced alert. (HTTP health stays clean.)
      {:DOWN, ^ref, :process, ^pid, reason} ->
        Logger.error("[sandbox] host_fault run=#{run_id} reason=#{inspect(reason)}")
        Map.put(base, :verdict, "host_fault")
    after
      @wall_ms ->
        Process.exit(pid, :kill)
        receive(do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok), after: (100 -> :ok))
        Map.merge(base, %{verdict: "timeout", detail: "wall-clock watchdog"})
    end
  end

  # Folds the run's footprint + capability ledger (captured from Pyex's telemetry
  # in THIS worker process) into the verdict body. Present whenever the run
  # produced a result — including failures.
  defp with_telemetry(body) do
    case Process.get(:pyex_run) do
      {footprint, metadata} ->
        spans = Map.get(metadata, :runtime_spans, [])

        body
        |> Map.put(:usage, %{
          steps: footprint[:steps],
          compute_ms: footprint[:compute],
          duration_ms: footprint[:duration_ms],
          memory_bytes: footprint[:memory_bytes],
          output_bytes: footprint[:output_bytes]
        })
        |> Map.put(:trace, Pyex.SpanTree.render(spans, title: "runtime · scope=pyex"))

      _ ->
        body
    end
  end
end

# One telemetry handler captures each run's footprint + capability ledger into
# the emitting worker's process dictionary (handlers run in the caller's
# process), for `with_telemetry/1` to read back. Covers success and failure.
:telemetry.attach_many(
  "sandbox-capture",
  [[:pyex, :run, :stop], [:pyex, :run, :exception]],
  fn _event, measurements, metadata, _ -> Process.put(:pyex_run, {measurements, metadata}) end,
  nil
)

port = String.to_integer(System.get_env("PORT", "4599"))
{:ok, _} = Bandit.start_link(plug: SandboxServer, port: port)
IO.puts("Pyex sandbox server on http://localhost:#{port}  (POST Python to /run; Ctrl-C to stop)")
Process.sleep(:infinity)
