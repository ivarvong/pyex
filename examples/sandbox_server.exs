# A tiny HTTP sandbox: POST Python source, get the result back.
#
# Demonstrates the "Pyex is processless; the caller owns the process" model
# from the README. An HTTP server already gives you one process per request,
# so the request handler IS the isolation boundary: it spawns a monitored
# worker, caps that worker's heap (GC-enforced), runs the untrusted code, and
# acts as a wall-clock watchdog. Pyex itself never spawns.
#
# Run it:
#
#     mix run examples/sandbox_server.exs
#
# Then hit it. Running and bounding the job is a successful request (HTTP 200);
# the verdict is the body's "status" field (ok / error / timeout / out_of_memory).
#
#     curl -s localhost:4599/run --data-binary 'print(sum(range(1000)))'   # status: ok
#     curl -s localhost:4599/run --data-binary '1 / 0'                      # status: error
#     curl -s localhost:4599/run --data-binary $'while True:\n    pass'     # status: timeout
#     curl -s localhost:4599/run --data-binary \
#       $'x = []\ni = 0\nwhile True:\n    x.append(i * i)\n    i += 1'       # status: out_of_memory
#
# Successful responses also carry "trace": the host capability ledger — an
# unforgeable, host-rendered span tree of every storage op the program caused.
# The program cannot suppress or forge it. Try one that touches storage:
#
#     curl -s localhost:4599/run --data-binary \
#       $'import store\nstore.set("user:1", {"n": 7})\nprint(store.get("user:1"))' | jq -r .trace

defmodule SandboxServer do
  use Plug.Router

  # The watchdog wall clock; the worker's hard memory ceiling.
  @wall_ms 3_000
  @heap_bytes 64_000_000

  # Time is bounded cooperatively by Pyex; memory and any native hang are
  # bounded by the per-request *process*. In production keep Pyex's
  # max_memory/max_steps on as well — here max_memory is :infinity purely so
  # the BEAM heap cap is the visible memory ceiling in the demo.
  @limits [
    timeout: @wall_ms - 500,
    max_steps: :infinity,
    max_memory_bytes: :infinity,
    max_output_bytes: 1_000_000
  ]

  plug(:match)
  plug(:dispatch)

  post "/run" do
    {status, payload} =
      case Plug.Conn.read_body(conn, length: 2_000_000) do
        {:ok, "", _conn} -> {400, %{error: "empty body — POST Python source"}}
        {:ok, source, _conn} -> run_sandboxed(source)
        {:more, _, _conn} -> {413, %{error: "program too large"}}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  match _ do
    send_resp(conn, 404, ~s({"error":"POST Python source to /run"}))
  end

  # The request process is the sandbox supervisor: spawn_monitor (not link) so a
  # guest that blows the heap can't take the request down, cap the worker's heap,
  # and watchdog the wall clock.
  #
  # The HTTP status describes the API call, not the program: running and bounding
  # the job is a successful request (200) whose verdict — ok / error / timeout /
  # out_of_memory — is a field in the body. Only a fault in the *sandbox itself*
  # is a 500. (There is no honest HTTP code for "the guest used too much memory.")
  defp run_sandboxed(source) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: div(@heap_bytes, :erlang.system_info(:wordsize)),
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        # A fresh, isolated in-memory store per request. With a real backend
        # (and the same one threaded across requests) the program becomes a
        # persistent service; attenuate with Pyex.Storage.View for least authority.
        run_opts = [limits: @limits, storage: Pyex.Storage.Memory.new()]

        result =
          case Pyex.run(source, run_opts) do
            # The trace is the host's own record of what touched the world —
            # rendered here and returned to the caller.
            {:ok, value, ctx} -> {:ok, Pyex.output(ctx), inspect(value), Pyex.Turn.render(ctx)}
            {:error, %Pyex.Error{kind: :timeout, message: m}} -> {:timeout, m}
            {:error, %Pyex.Error{kind: k, message: m}} -> {:py_error, k, m}
          end

        send(parent, {:result, self(), result})
      end)

    receive do
      {:result, ^pid, {:ok, output, value, trace}} ->
        Process.demonitor(ref, [:flush])
        {200, %{status: "ok", output: output, value: value, trace: trace}}

      {:result, ^pid, {:timeout, m}} ->
        Process.demonitor(ref, [:flush])
        {200, %{status: "timeout", detail: m}}

      {:result, ^pid, {:py_error, k, m}} ->
        Process.demonitor(ref, [:flush])
        {200, %{status: "error", kind: k, message: m}}

      {:DOWN, ^ref, :process, ^pid, :killed} ->
        {200, %{status: "out_of_memory"}}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {500, %{status: "host_fault", reason: inspect(reason)}}
    after
      @wall_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          100 -> :ok
        end

        {200, %{status: "timeout"}}
    end
  end
end

port = String.to_integer(System.get_env("PORT", "4599"))
{:ok, _} = Bandit.start_link(plug: SandboxServer, port: port)
IO.puts("Pyex sandbox server on http://localhost:#{port}  (POST Python to /run; Ctrl-C to stop)")
Process.sleep(:infinity)
