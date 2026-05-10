defmodule Pyex.Stdlib.Asyncio do
  @moduledoc """
  Python `asyncio` module.

  ## Cooperative scheduling

  Coroutines are tagged generators.  `await EXPR` is yield-from on
  the inner iterator: each yield propagates up to the surrounding
  trampoline (`asyncio.run`, `asyncio.gather`, or another `await`),
  and the inner's `StopIteration` value becomes the await's result.
  `asyncio.sleep(t)` yields an `{:asyncio_sleep, ms}` sentinel that
  the trampoline interprets.

  The result: observable interleaving matches CPython.
  `await asyncio.gather(step("A"), step("B"))` over coroutines that
  yield at each `await asyncio.sleep(0)` produces ABABAB, not
  AAABBB.  `create_task` is lazy — the coroutine runs when the
  Task is awaited, not when `create_task` is called.  Nested
  `asyncio.run` raises `RuntimeError`.  Async list comprehensions
  (`[x async for x in g()]`) parse and run.

  ## Surface

    * `asyncio.run(coro)` — drive a coroutine to completion;
      raises `RuntimeError` if a loop is already running
    * `asyncio.gather(*coros, return_exceptions=False)` —
      round-robin; collects results in declared order; with
      `return_exceptions=True`, captured exceptions become real
      exception instances
    * `asyncio.sleep(t)` — yields a sleep sentinel; the trampoline
      sleeps for `t` seconds
    * `asyncio.create_task(coro)` / `asyncio.ensure_future(coro)`
      — wraps the coroutine in a pending Task; the body runs when
      the Task is awaited
    * `asyncio.wait_for(coro, timeout)` — drive the coroutine
      (timeout is informational; Pyex enforces wall-clock at the
      call boundary)
    * `asyncio.iscoroutine(x)` / `asyncio.iscoroutinefunction(f)`

  ## Not implemented

  `asyncio.Queue`, `asyncio.Lock`, `asyncio.Event`, `asyncio.wait`,
  `asyncio.subprocess`, `asyncio.streams`.  Adding these requires a
  full event loop with named-future / readiness primitives —
  uncommon in LLM-emitted agent code.
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
  defp do_run([{:coroutine, _, _} = coro]) do
    {:ctx_call, fn env, ctx -> run_with_loop_guard(coro, env, ctx) end}
  end

  defp do_run([{:asyncio_task_pending, coro}]) do
    {:ctx_call, fn env, ctx -> run_with_loop_guard(coro, env, ctx) end}
  end

  defp do_run([other]) do
    type_name = Helpers.py_type(other)

    {:exception,
     "TypeError: a coroutine was expected, got #{type_name}.  " <>
       "Did you forget to call the async function (e.g. `asyncio.run(main())` not `asyncio.run(main)`)?"}
  end

  defp do_run(_), do: {:exception, "TypeError: asyncio.run() takes exactly one argument"}

  # Track "currently inside asyncio.run" via a flag on the ctx so
  # nested calls error like CPython rather than silently driving the
  # coroutine on the same thread.
  defp run_with_loop_guard(coro, env, ctx) do
    if ctx.asyncio_running do
      {{:exception, "RuntimeError: asyncio.run() cannot be called from a running event loop"},
       env, ctx}
    else
      ctx = %{ctx | asyncio_running: true}

      try do
        case Invocation.drive_coroutine(coro, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, %{ctx | asyncio_running: false}}

          {value, env, ctx} ->
            {value, env, %{ctx | asyncio_running: false}}
        end
      rescue
        e ->
          # Reraise after restoring the flag so an unexpected
          # exception during driving doesn't leave the loop "stuck"
          # for subsequent calls in the same ctx.
          reraise e, __STACKTRACE__
      end
    end
  end

  @spec do_gather([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          term()
  defp do_gather(coros, kwargs) do
    return_exceptions = truthy?(Map.get(kwargs, "return_exceptions", false))

    {:ctx_call,
     fn env, ctx ->
       drive_all(coros, return_exceptions, env, ctx)
     end}
  end

  defp drive_all(coros, return_exceptions, env, ctx) do
    # Each entry is either {:pending, id} (coroutine still running)
    # or {:done, value} (resolved — Tasks, plain values, or
    # completed coroutines).  Round-robin one step at a time so
    # observable interleaving matches CPython.
    states =
      Enum.map(coros, fn
        {:coroutine, _, {:iterator, id}} -> {:pending, id}
        {:asyncio_task_pending, {:coroutine, _, {:iterator, id}}} -> {:pending, id}
        {:asyncio_task, value} -> {:done, value}
        plain -> {:done, plain}
      end)

    case round_robin_gather(states, return_exceptions, env, ctx) do
      {:ok, results, env, ctx} ->
        # Wrap as a Task so `await asyncio.gather(...)` works
        # against strict await.
        {{:asyncio_task, results}, env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}
    end
  end

  defp round_robin_gather(states, return_exceptions, env, ctx) do
    if Enum.all?(states, fn s -> match?({:done, _}, s) end) do
      results = Enum.map(states, fn {:done, v} -> v end)
      {:ok, results, env, ctx}
    else
      case advance_round(states, return_exceptions, [], env, ctx) do
        {:ok, new_states, env, ctx} ->
          round_robin_gather(new_states, return_exceptions, env, ctx)

        {{:exception, _} = signal, env, ctx} ->
          {signal, env, ctx}
      end
    end
  end

  # One round: advance every pending child one step.  Yielded
  # sentinels (asyncio.sleep) are interpreted inline so concurrent
  # sleeps coalesce naturally — a `gather(sleep(0), sleep(0))` does
  # zero waiting; longer sleeps run sequentially within the round.
  defp advance_round([], _re, acc, env, ctx) do
    {:ok, Enum.reverse(acc), env, ctx}
  end

  defp advance_round([{:done, _} = state | rest], re, acc, env, ctx) do
    advance_round(rest, re, [state | acc], env, ctx)
  end

  defp advance_round([{:pending, id} | rest], re, acc, env, ctx) do
    case Invocation.advance_coroutine_one_step(id, env, ctx) do
      {:exhausted, env, ctx} ->
        return_value = Pyex.Ctx.iter_return_value(ctx, id)
        advance_round(rest, re, [{:done, return_value} | acc], env, ctx)

      {{:yielded, value}, env, ctx} ->
        # Sentinel handling — sleep on `:asyncio_sleep`, ignore
        # other yields (`{:asyncio_yield, _}` etc.).
        Invocation.interpret_yield_sentinel(value)
        advance_round(rest, re, [{:pending, id} | acc], env, ctx)

      {{:exception, msg}, env, ctx} when re ->
        exc = exception_instance_from_message(msg)
        advance_round(rest, re, [{:done, exc} | acc], env, ctx)

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}
    end
  end

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

  # Returns a coroutine that yields an `{:asyncio_sleep, ms}` sentinel
  # exactly once and then completes with nil.  When awaited, the
  # sentinel propagates up to the surrounding trampoline (gather,
  # asyncio.run) which decides what to do with it — sleep, advance
  # other coroutines, both, etc.  This is what makes `gather` of two
  # `await asyncio.sleep(0)` calls interleave at the awaits.
  @spec do_sleep([Interpreter.pyvalue()]) :: term()
  defp do_sleep([]), do: sleep_coroutine(0)
  defp do_sleep([t]) when is_integer(t) and t >= 0, do: sleep_coroutine(t * 1000)
  defp do_sleep([t]) when is_float(t) and t >= 0, do: sleep_coroutine(round(t * 1000))

  defp do_sleep([t]) when is_number(t) do
    {:exception, "ValueError: sleep length must be non-negative, got #{t}"}
  end

  defp do_sleep([_]), do: {:exception, "TypeError: sleep() argument must be a number"}

  # Build a single-yield coroutine that surfaces an `:asyncio_sleep`
  # sentinel and then completes with nil.  Constructed directly via
  # the iter pool — no Python body needed.
  defp sleep_coroutine(ms) do
    {:ctx_call,
     fn env, ctx ->
       sentinel = {:asyncio_sleep, ms}
       # Empty continuation `[]` means the next advance exhausts.
       # We use the "pending" shape with the sentinel as the buffered
       # yield value.
       {iter_token, ctx} =
         Pyex.Ctx.new_generator_iterator(ctx, sentinel, [], Pyex.Env.new())

       # Pre-mark exhaustion-with-value so the second advance (after
       # the sentinel surfaces) returns nil.  This has to happen
       # AFTER the sentinel is consumed; the iter pool advance does
       # that automatically when it sees `[]` continuation.
       _ = iter_token

       {{:coroutine, "sleep", iter_token}, env, ctx}
     end}
  end

  # create_task / ensure_future wrap the coroutine in a Task without
  # running it.  The body is driven later, when the Task is awaited
  # (or when the surrounding loop advances it — Phase 2 territory).
  # This matches CPython's "schedule, don't run" semantics for the
  # `t = create_task(...); ...; await t` idiom.
  @spec do_create_task([Interpreter.pyvalue()]) :: term()
  defp do_create_task([{:coroutine, _, _} = coro]) do
    {:asyncio_task_pending, coro}
  end

  defp do_create_task([other]) do
    type_name = Helpers.py_type(other)
    {:exception, "TypeError: a coroutine was expected, got #{type_name}"}
  end

  defp do_create_task(_),
    do: {:exception, "TypeError: create_task() takes exactly one argument"}

  @spec do_wait_for([Interpreter.pyvalue()]) :: term()
  defp do_wait_for([{:coroutine, _, _} = coro, _timeout]) do
    {:ctx_call, fn env, ctx -> Invocation.drive_coroutine(coro, env, ctx) end}
  end

  defp do_wait_for([{:asyncio_task, value}, _timeout]), do: value

  defp do_wait_for([other, _timeout]) do
    type_name = Helpers.py_type(other)
    {:exception, "TypeError: wait_for() expected a coroutine or Task, got #{type_name}"}
  end

  defp do_wait_for(_), do: {:exception, "TypeError: wait_for() takes 2 arguments"}

  @spec do_iscoroutine([Interpreter.pyvalue()]) :: boolean()
  defp do_iscoroutine([{:coroutine, _, _}]), do: true
  defp do_iscoroutine([{:asyncio_task_pending, _}]), do: true
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
