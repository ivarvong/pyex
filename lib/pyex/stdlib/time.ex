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
      "sleep" => {:builtin, &do_sleep/1}
    }
  end

  @spec do_time([Pyex.Interpreter.pyvalue()]) :: float()
  defp do_time([]) do
    :os.system_time(:millisecond) / 1000.0
  end

  @spec do_time_ns([Pyex.Interpreter.pyvalue()]) :: integer()
  defp do_time_ns([]) do
    :os.system_time(:nanosecond)
  end

  @spec do_monotonic([Pyex.Interpreter.pyvalue()]) :: float()
  defp do_monotonic([]) do
    :erlang.monotonic_time(:millisecond) / 1000.0
  end

  @spec do_monotonic_ns([Pyex.Interpreter.pyvalue()]) :: integer()
  defp do_monotonic_ns([]) do
    :erlang.monotonic_time(:nanosecond)
  end

  @spec do_sleep([Pyex.Interpreter.pyvalue()]) ::
          {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {nil, Pyex.Env.t(), Pyex.Ctx.t()})}
          | {:exception, String.t()}
  defp do_sleep([seconds]) when is_number(seconds) and seconds >= 0 do
    capped = min(seconds, @max_sleep_seconds)
    ms = round(capped * 1000)

    {:io_call,
     fn env, ctx ->
       Process.sleep(ms)
       {nil, env, ctx}
     end}
  end

  defp do_sleep([seconds]) when is_number(seconds) do
    {:exception, "ValueError: sleep length must be non-negative"}
  end

  defp do_sleep(_args) do
    {:exception, "TypeError: sleep() argument must be a number"}
  end
end
