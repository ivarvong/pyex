defmodule Pyex.Stdlib.Asyncio do
  @moduledoc """
  Python `asyncio` module — Phase 1.

  ## Trampoline model

  Coroutines are driven by a synchronous trampoline
  (`Pyex.Interpreter.Invocation.drive_coroutine/3`).  `asyncio.run`
  drives one to completion; `asyncio.gather` drives a list of
  coroutines in declared order.

  This produces CPython-equivalent values for code that does not
  rely on real fan-out concurrency.  When CPython would interleave
  coroutines at `await` points (giving `gather` real parallelism),
  Phase 1 runs them sequentially and accepts a slower wall-clock.
  Same answer, slower.  A future Phase 2 will let a host-driven
  event loop take over the trampoline and dispatch awaitable
  capabilities (HTTP, DB, sleep) as real BEAM Tasks.

  ## Surface

    * `asyncio.run(coro)` — drive a coroutine to completion
    * `asyncio.gather(*coros, return_exceptions=False)` — drive each
      and collect results in order; with `return_exceptions=True`,
      captured exceptions become exception instances in the result list
    * `asyncio.sleep(t)` — sleep `t` seconds; routes through the
      sandbox's compute-time accounting (sleep counts as I/O, not
      compute)
    * `asyncio.create_task(coro)` / `asyncio.ensure_future(coro)` —
      drive the coroutine eagerly (Phase 1 simplification) and wrap
      the result in an already-done `Task` value
    * `asyncio.wait_for(coro, timeout)` — drive the coroutine; the
      timeout is informational here (Pyex enforces wall-clock at the
      call boundary)
    * `asyncio.iscoroutine(x)` / `asyncio.iscoroutinefunction(f)`

  ## Not implemented (out of scope for Phase 1)

  `asyncio.Queue`, `asyncio.Lock`, `asyncio.Event`, `asyncio.wait`,
  custom event loops, `asyncio.subprocess`, `asyncio.streams`.  These
  are either uncommon in LLM-emitted agent code or require the
  Phase 2 host-driven trampoline.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Interpreter
  alias Pyex.Interpreter.{Helpers, Invocation}

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "run" => {:builtin, &do_run/1},
      "gather" => {:builtin_kw, &do_gather/2},
      "sleep" => {:builtin, &do_sleep/1},
      "create_task" => {:builtin, &do_create_task/1},
      "ensure_future" => {:builtin, &do_create_task/1},
      "wait_for" => {:builtin, &do_wait_for/1},
      "iscoroutine" => {:builtin, &do_iscoroutine/1},
      "iscoroutinefunction" => {:builtin, &do_iscoroutinefunction/1}
    }
  end

  @spec do_run([Interpreter.pyvalue()]) :: term()
  defp do_run([{:coroutine, _, _, _} = coro]) do
    {:ctx_call, fn env, ctx -> Invocation.drive_coroutine(coro, env, ctx) end}
  end

  defp do_run([other]) do
    type_name = Helpers.py_type(other)

    {:exception,
     "TypeError: a coroutine was expected, got #{type_name}.  " <>
       "Did you forget to call the async function (e.g. `asyncio.run(main())` not `asyncio.run(main)`)?"}
  end

  defp do_run(_), do: {:exception, "TypeError: asyncio.run() takes exactly one argument"}

  @spec do_gather([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          term()
  defp do_gather(coros, kwargs) do
    return_exceptions = truthy?(Map.get(kwargs, "return_exceptions", false))

    {:ctx_call,
     fn env, ctx ->
       drive_all(coros, return_exceptions, [], env, ctx)
     end}
  end

  defp drive_all([], _re, acc, env, ctx) do
    # Wrap as a Task so the canonical CPython idiom
    # `await asyncio.gather(...)` works against Pyex's strict await.
    {{:asyncio_task, Enum.reverse(acc)}, env, ctx}
  end

  defp drive_all([coro | rest], return_exceptions, acc, env, ctx) do
    case drive_one_for_gather(coro, env, ctx) do
      {{:exception, msg}, env, ctx} when return_exceptions ->
        # Build a real exception instance so callers can do
        # `isinstance(r, ValueError)` on a gather result.
        exc_instance = exception_instance_from_message(msg)
        drive_all(rest, return_exceptions, [exc_instance | acc], env, ctx)

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        drive_all(rest, return_exceptions, [value | acc], env, ctx)
    end
  end

  # gather accepts coroutines, Tasks, or already-resolved values
  # (CPython is strict here; Pyex matches CPython for coroutine /
  # Task and passes through plain values for the common pattern of
  # mixing constants into a gather call).
  defp drive_one_for_gather({:coroutine, _, _, _} = coro, env, ctx),
    do: Invocation.drive_coroutine(coro, env, ctx)

  defp drive_one_for_gather({:asyncio_task, value}, env, ctx), do: {value, env, ctx}
  defp drive_one_for_gather(value, env, ctx), do: {value, env, ctx}

  # Best-effort reconstruction of an exception instance from a Pyex
  # error message (the shape `"TypeName: details (line N)"`).  Used
  # by gather(return_exceptions=True) so the result list mirrors
  # CPython.
  defp exception_instance_from_message(msg) when is_binary(msg) do
    {type_name, details} = parse_exception_message(msg)
    # Build a real {:class, ...} value via the same machinery the
    # interpreter uses for `raise ValueError(x)` so isinstance checks
    # walk the exception hierarchy correctly.
    cls = Interpreter.exception_instance_class({:exception_class, type_name})
    {:instance, cls, %{"args" => {:tuple, [details]}}}
  end

  defp parse_exception_message(msg) do
    case String.split(msg, ":", parts: 2) do
      [type_name, rest] ->
        details =
          rest
          |> String.trim_leading()
          |> String.replace(~r/ \(line \d+\)$/, "")

        {String.trim(type_name), details}

      _ ->
        {"Exception", msg}
    end
  end

  # Returns a Task wrapping nil so the canonical
  # `await asyncio.sleep(t)` works against Pyex's strict await.  The
  # sleep itself happens here (Process.sleep), counted as I/O time
  # rather than compute time per the existing sandbox accounting.
  @spec do_sleep([Interpreter.pyvalue()]) :: term()
  defp do_sleep([]), do: {:asyncio_task, nil}

  defp do_sleep([t]) when is_integer(t) and t >= 0 do
    Process.sleep(t * 1000)
    {:asyncio_task, nil}
  end

  defp do_sleep([t]) when is_float(t) and t >= 0 do
    Process.sleep(round(t * 1000))
    {:asyncio_task, nil}
  end

  defp do_sleep([t]) when is_number(t) do
    {:exception, "ValueError: sleep length must be non-negative, got #{t}"}
  end

  defp do_sleep([_]), do: {:exception, "TypeError: sleep() argument must be a number"}

  # create_task / ensure_future drive eagerly in Phase 1 and wrap the
  # result in an already-done Task.  The trade-off vs. CPython:
  # CPython schedules the coroutine for cooperative interleaving;
  # Pyex runs it now and the resulting Task always reports done.
  @spec do_create_task([Interpreter.pyvalue()]) :: term()
  defp do_create_task([{:coroutine, _, _, _} = coro]) do
    {:ctx_call,
     fn env, ctx ->
       case Invocation.drive_coroutine(coro, env, ctx) do
         {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
         {value, env, ctx} -> {{:asyncio_task, value}, env, ctx}
       end
     end}
  end

  defp do_create_task([other]) do
    type_name = Helpers.py_type(other)
    {:exception, "TypeError: a coroutine was expected, got #{type_name}"}
  end

  defp do_create_task(_),
    do: {:exception, "TypeError: create_task() takes exactly one argument"}

  @spec do_wait_for([Interpreter.pyvalue()]) :: term()
  defp do_wait_for([{:coroutine, _, _, _} = coro, _timeout]) do
    {:ctx_call, fn env, ctx -> Invocation.drive_coroutine(coro, env, ctx) end}
  end

  defp do_wait_for([{:asyncio_task, value}, _timeout]), do: value

  defp do_wait_for([other, _timeout]) do
    type_name = Helpers.py_type(other)
    {:exception, "TypeError: wait_for() expected a coroutine or Task, got #{type_name}"}
  end

  defp do_wait_for(_), do: {:exception, "TypeError: wait_for() takes 2 arguments"}

  @spec do_iscoroutine([Interpreter.pyvalue()]) :: boolean()
  defp do_iscoroutine([{:coroutine, _, _, _}]), do: true
  defp do_iscoroutine([_]), do: false

  @spec do_iscoroutinefunction([Interpreter.pyvalue()]) :: boolean()
  defp do_iscoroutinefunction([{:function, _, _, _, _, _, :async}]), do: true
  defp do_iscoroutinefunction([_]), do: false

  @spec truthy?(Interpreter.pyvalue()) :: boolean()
  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(0), do: false
  defp truthy?(_), do: true
end
