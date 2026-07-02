defmodule Pyex.Wasm do
  @moduledoc """
  WasmGC entry point for embedding Pyex as a sandboxed Python runtime.

  This is the surface `mix wasm.build` compiles to WebAssembly. The host loads the module once
  and calls `pyrun/3` per turn:

      mix wasm.build --module Pyex.Wasm --export "pyrun:bin,bin,int->term"

  Each call is isolated (a fresh `Pyex.Ctx`), bounded (`max_steps` caps execution deterministically —
  a runaway loop fails with a `LimitError` instead of hanging), and sandboxed (an in-memory virtual
  filesystem, no host disk/network). The host seeds the VFS with a JSON `%{path => content}` map and
  gets back the final filesystem + the turn's OpenTelemetry spans + resource footprint — everything a
  code-executing agent needs to see and audit.
  """

  @doc """
  Run a Python program in the sandbox and report everything observable about the turn.

    * `source` — the Python program.
    * `files_json` — JSON `{"/path": "content", ...}` seeding the virtual filesystem (`""`/`"{}"` = empty).
    * `max_steps` — deterministic step budget; `0` uses Pyex's default.

  Returns `{:ok, stdout, footprint, files_json, spans_json}`:
    * `stdout` — what `print()` emitted.
    * `footprint` — deterministic resource map (the OTel span attributes for the turn).
    * `files_json` — the virtual filesystem AFTER the run, as JSON (what the program wrote).
    * `spans_json` — the runtime spans (`file.open`, `db.get`, …) as JSON, for the trace viewer.

  Or `{:error, message}` for any Python-level or runtime error. Never raises across the Wasm boundary.
  """
  @spec pyrun(String.t(), String.t(), non_neg_integer()) ::
          {:ok, String.t(), map(), String.t(), String.t()} | {:error, String.t()}
  def pyrun(source, files_json, max_steps) do
    # limits via a struct LITERAL — a keyword `[max_steps: n]` would route through Pyex.Limits.new/1 ->
    # Kernel.struct/2 (unlowered). Seed the VFS from the host-provided JSON map.
    base = [filesystem: VFS.Memory.new(decode_seed(files_json))]

    opts =
      if max_steps > 0, do: [{:limits, %Pyex.Limits{max_steps: max_steps}} | base], else: base

    try do
      case Pyex.run(source, opts) do
        {:ok, _value, ctx} ->
          {:ok, Pyex.output(ctx), footprint(ctx), dump_fs(ctx), spans_json(ctx)}

        {:error, error} ->
          {:error, to_string(Map.get(error, :message, "error"))}
      end
    rescue
      # Exception.message/1 is protocol-shaped dispatch the wasm target can't lower;
      # a Map.get + binary guard keeps the error path flat and type-safe.
      e ->
        msg = Map.get(e, :message)
        msg = if is_binary(msg), do: msg, else: inspect(msg)
        {:error, "#{inspect(Map.get(e, :__struct__))}: #{msg}"}
    end
  end

  defp decode_seed(json) when json in ["", "{}"], do: %{}

  defp decode_seed(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  # The final virtual filesystem as JSON (%{path => content}) — VFS.Memory keeps a flat `tree`.
  defp dump_fs(%Pyex.Ctx{filesystem: %VFS.Memory{tree: tree}}), do: Jason.encode!(tree)
  defp dump_fs(_ctx), do: "{}"

  # Every span this turn — the runtime's own (scope "pyex": file.open, db.get, …) PLUS the app spans
  # the Python code created via the `opentelemetry` module (scope = its tracer name). Both are OTel-
  # shaped (id, parent_id, name, scope, kind, attributes, start_seq, end_seq) and deterministic.
  defp spans_json(ctx) do
    runtime = Pyex.Ctx.runtime_spans(ctx)
    app = Enum.reverse(ctx.app_spans)
    Jason.encode!(runtime ++ app)
  end

  # The turn's observable resource footprint — deterministic, host-independent. Exactly the attribute
  # set Pyex emits as an OpenTelemetry span (`[:pyex, :run, :stop]`).
  defp footprint(ctx) do
    %{
      steps: ctx.steps,
      memory_bytes: ctx.memory_bytes,
      output_bytes: ctx.output_bytes,
      file_ops: ctx.file_ops,
      event_count: ctx.event_count
    }
  end
end
