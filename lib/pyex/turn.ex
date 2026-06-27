defmodule Pyex.Turn do
  @moduledoc """
  The **turn contract** — what a single `Pyex.run` is, and how to observe it.

  A turn is one execution of a program against a context:

      (source, ctx) -> {:ok, result, ctx'} | {:error, error}

  It is the unit a host (a Durable Object, a worker-pool job, a request
  handler) runs. The contract the host relies on:

    * **Pure function of `(source, ctx)`.** The entire footprint of a turn is
      the returned `ctx'`. pyex owns no global or process state across turns
      (enforced by `Pyex.BannedCallTracer`), and even libraries that *do* use
      the process dictionary — e.g. `Decimal` — are snapshotted and restored to
      the caller's prior *value*, so a turn cannot change the caller's behaviour.
      (One inert artifact: a default-valued `$decimal_context` key may remain
      where the caller had none — `Process.*` is banned, so it can't be cleared
      — but it is behaviourally identical to unset.)
    * **Atomic on failure.** A turn that errors returns `{:error, _}` and the
      host never receives a `ctx'` — so committing only on `{:ok, …}` makes a
      failed turn commit nothing. Durability and the load→run→commit cycle are
      the host's job; pyex just threads state as values.
    * **Deterministic, modulo explicit entropy.** Two turns with the same
      `(source, ctx)` produce the same `ctx'` — *unless* the program reads
      ambient nondeterminism (`time`, `random`, `uuid`, `secrets`), which today
      come from the wall clock / `:rand` rather than the context. Those turns
      are not replay-safe; see "Determinism boundary" below.

  ## Observability follows the same host/pyex cut

  pyex emits `:telemetry` for the turn lifecycle and never talks to an
  exporter — exporting (OpenTelemetry, logs, per-tenant billing) is the
  host's job, exactly like persistence. The host attaches a handler and turns
  each turn into a span:

      [:pyex, :run, :start]      # measurements: %{system_time}
      [:pyex, :run, :stop]       # measurements: Pyex.Turn.footprint(ctx')
      [:pyex, :run, :exception]  # measurements: footprint, metadata: %{error}

  `footprint/1` is the span's attribute set — a faithful, deterministic
  summary of everything the turn did. Because a turn is pure, the footprint
  *is* its effects: an empty-stdout turn reports `output_bytes: 0`, a turn
  that wrote a file reports `file_ops > 0`, and two identical pure turns
  report identical footprints — making purity observable, not just asserted.

  ### Reference OpenTelemetry bridge (host-side)

      :telemetry.attach("otel-turn", [:pyex, :run, :stop], fn _e, measurements, _meta, _cfg ->
        OpenTelemetry.Tracer.with_span "pyex.turn", %{attributes: measurements} do
          :ok
        end
      end, nil)

  Keep the OTel SDK in the host. pyex depends on `:telemetry` only.

  ## Determinism boundary

  `time`/`random`/`uuid`/`secrets` read ambient entropy/clock today, so a
  turn using them is not deterministic and `random.seed/1` mutates per-process
  `:rand` state rather than the context. Full replay-safety wants a
  *context-provided* clock and seed (entropy as a capability, like storage) —
  a known next step, not yet built. `ambient?/1` is a placeholder marker for
  where that flag will live; for now, treat a turn that imports those modules
  as non-replayable.
  """

  alias Pyex.Ctx

  @typedoc "The observable summary of a turn — the OTel span's attributes."
  @type footprint :: %{
          compute: integer(),
          duration_ms: float(),
          event_count: non_neg_integer(),
          file_ops: non_neg_integer(),
          steps: non_neg_integer(),
          memory_bytes: non_neg_integer(),
          output_bytes: non_neg_integer()
        }

  @doc """
  The per-turn footprint of `ctx` — the numeric summary a host attaches to a
  span. Used by the `[:pyex, :run, :stop]` telemetry and safe to call on any
  final context.
  """
  @spec footprint(Ctx.t()) :: footprint()
  def footprint(%Ctx{} = ctx) do
    %{
      compute: ctx |> Ctx.compute_time() |> round(),
      duration_ms: ctx.duration_ms || 0.0,
      event_count: ctx.event_count,
      file_ops: ctx.file_ops,
      steps: ctx.steps,
      memory_bytes: ctx.memory_bytes,
      output_bytes: ctx.output_bytes
    }
  end
end
