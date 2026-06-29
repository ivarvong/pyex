defmodule Pyex.Stdlib.Time do
  @moduledoc """
  Python `time` module backed by Erlang's `:os` and `:timer`.

  Provides `time`, `sleep`, `monotonic`, and `time_ns`.

  `sleep()` is bounded to a maximum of 30 seconds and runs
  as an I/O call so the compute budget is not consumed while
  the process is sleeping.
  """

  @behaviour Pyex.Stdlib.Module

  @max_sleep_seconds 30

  @doc """
  Returns the module value map.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "time" => {:builtin, &do_time/1},
      "time_ns" => {:builtin, &do_time_ns/1},
      "monotonic" => {:builtin, &do_monotonic/1},
      "monotonic_ns" => {:builtin, &do_monotonic_ns/1},
      "perf_counter" => {:builtin, &do_monotonic/1},
      "perf_counter_ns" => {:builtin, &do_monotonic_ns/1},
      "process_time" => {:builtin, &do_monotonic/1},
      "process_time_ns" => {:builtin, &do_monotonic_ns/1},
      "sleep" => {:builtin, &do_sleep/1}
    }
  end

  # time.time()/time_ns() return the host-pinned `clock:` when set (a
  # deterministic, replayable turn), else the wall clock.
  @spec do_time([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_time([]) do
    {:ctx_call,
     fn env, ctx ->
       t =
         if is_number(ctx.clock), do: ctx.clock / 1.0, else: :os.system_time(:nanosecond) / 1.0e9

       {t, env, ctx}
     end}
  end

  @spec do_time_ns([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_time_ns([]) do
    {:ctx_call,
     fn env, ctx ->
       ns =
         if is_number(ctx.clock), do: round(ctx.clock * 1.0e9), else: :os.system_time(:nanosecond)

       {ns, env, ctx}
     end}
  end

  @spec do_monotonic([Pyex.Interpreter.pyvalue()]) :: float()
  defp do_monotonic([]) do
    :erlang.monotonic_time(:nanosecond) / 1.0e9
  end

  @spec do_monotonic_ns([Pyex.Interpreter.pyvalue()]) :: integer()
  defp do_monotonic_ns([]) do
    :erlang.monotonic_time(:nanosecond)
  end

  @spec do_sleep([Pyex.Interpreter.pyvalue()]) ::
          {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {nil, Pyex.Env.t(), Pyex.Ctx.t()})}
          | {:exception, String.t()}
  defp do_sleep([seconds]) when is_number(seconds) and seconds >= 0 do
    {:io_call,
     fn env, ctx ->
       # Never block the host longer than the run's own timeout budget — a guest
       # with `timeout: 1500` must not be able to sleep for the full 30s cap.
       capped = min(seconds, sleep_cap_seconds(ctx))
       Process.sleep(round(capped * 1000))
       {nil, env, ctx}
     end}
  end

  defp do_sleep([seconds]) when is_number(seconds) do
    {:exception, "ValueError: sleep length must be non-negative"}
  end

  defp do_sleep(_args) do
    {:exception, "TypeError: sleep() argument must be a number"}
  end

  # The 30s hard cap, further bounded by whatever timeout the run was given.
  @spec sleep_cap_seconds(Pyex.Ctx.t()) :: number()
  defp sleep_cap_seconds(%Pyex.Ctx{limits: %Pyex.Limits{timeout: t}}) when is_integer(t),
    do: min(@max_sleep_seconds, t / 1000)

  defp sleep_cap_seconds(_ctx), do: @max_sleep_seconds
end
