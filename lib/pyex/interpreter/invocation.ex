defmodule Pyex.Interpreter.Invocation do
  @moduledoc """
  User-function and bound-method invocation for `Pyex.Interpreter`.

  Keeps the closure setup, generator handling, and method rebinding paths out
  of the main interpreter module while preserving `call_function/5` as the
  public entrypoint.
  """

  alias Pyex.{Ctx, Env, Interpreter, Parser}
  alias Pyex.Interpreter.{BuiltinResults, CallSupport, ClassLookup, Helpers}

  @doc false
  @spec call_user_function(
          Interpreter.pyvalue(),
          String.t(),
          [Parser.param()],
          [Parser.ast_node()],
          Env.t(),
          boolean(),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  def call_user_function(
        func,
        name,
        params,
        body,
        closure_env,
        is_generator,
        args,
        kwargs,
        env,
        ctx
      ) do
    case Ctx.check_step(ctx) do
      {:exceeded, msg} ->
        {{:exception, msg}, env, ctx}

      {:ok, ctx} ->
        do_call_user_function(
          func,
          name,
          params,
          body,
          closure_env,
          is_generator,
          args,
          kwargs,
          env,
          ctx
        )
    end
  end

  defp do_call_user_function(
         func,
         name,
         params,
         body,
         closure_env,
         is_generator,
         args,
         kwargs,
         env,
         ctx
       ) do
    if ctx.call_depth >= ctx.max_call_depth do
      {{:exception, "RecursionError: maximum recursion depth exceeded"}, env, ctx}
    else
      ctx = %{ctx | call_depth: ctx.call_depth + 1}

      fresh_closure = Env.refresh_from_caller(closure_env, env)

      # Bind `name` to the caller's current binding when available so
      # decorators (like @lru_cache) that wrap this function are visible
      # during recursive self-calls.  Falling back to the raw `func`
      # matters for ordinary recursion in nested/local scopes where the
      # name isn't in the caller's globals yet.
      self_binding =
        case Env.get(env, name) do
          {:ok, existing} -> existing
          :undefined -> func
        end

      base_env = Env.push_scope(Env.put(fresh_closure, name, self_binding))

      case CallSupport.bind_params(params, args, kwargs, base_env, ctx) do
        {:exception, msg, ctx} ->
          ctx = %{ctx | call_depth: ctx.call_depth - 1}
          {{:exception, msg}, env, ctx}

        {call_env, ctx} ->
          t0 = if ctx.profile, do: System.monotonic_time(:microsecond)

          result =
            if is_generator do
              eval_generator_function(body, call_env, env, ctx)
            else
              eval_regular_function(func, fresh_closure, body, call_env, env, ctx)
            end

          result = maybe_record_profile(result, name, t0)
          CallSupport.decrement_depth(result)
      end
    end
  end

  @doc """
  Build a coroutine from an `async def` call.

  Runs the body in `:lazy_iter` mode (the same machinery sync
  generators use): the body executes up to its first `await`, then
  suspends.  The resulting `:coroutine` value wraps the iterator
  token, so subsequent `await` advances the same state.

  For an awaitless body, the entire body runs and the return value
  is captured on the iterator entry via PEP 380 semantics.
  `await` then surfaces it directly.
  """
  @spec build_coroutine(
          String.t(),
          [Parser.param()],
          [Parser.ast_node()],
          Env.t(),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  def build_coroutine(name, params, body, closure_env, args, kwargs, env, ctx) do
    fresh_closure = Env.refresh_from_caller(closure_env, env)
    base_env = Env.push_scope(fresh_closure)

    case CallSupport.bind_params(params, args, kwargs, base_env, ctx) do
      {:exception, msg, ctx} ->
        {{:exception, msg}, env, ctx}

      {call_env, ctx} ->
        # CPython parity: calling an async def does NOT run the body.
        # Stage the body in a `:gen_unstarted` pool entry so the
        # first advance (via `await` / `asyncio.run`) runs it.
        {iter_token, ctx} = Ctx.new_unstarted_coroutine_iterator(ctx, body, call_env)
        {{:coroutine, name, iter_token}, env, ctx}
    end
  end

  @doc """
  Drive a coroutine (or already-resolved Task) to completion via
  the cooperative trampoline.

  Used by `asyncio.run` / `asyncio.gather` (and any other top-level
  driver) to consume a coroutine end-to-end.  Yielded values are
  sentinels — `{:asyncio_sleep, ms}` makes the trampoline sleep,
  unrecognized yields are silently consumed.  Returns the captured
  `StopIteration` value when the inner iterator exhausts.

  For `await EXPR` inside an async body, use `initiate_await/3` and
  the `:cont_await_iter` frame — that path yields *up* to the
  surrounding trampoline rather than consuming yields locally.

  Strict on input shape: anything that is not `:coroutine` or
  `:asyncio_task` raises a CPython-shaped TypeError.
  """
  @spec drive_coroutine(Interpreter.pyvalue(), Env.t(), Ctx.t()) :: Interpreter.call_result()
  def drive_coroutine({:coroutine, _name, {:iterator, id}}, env, ctx) do
    drive_iter_to_completion(id, env, ctx)
  end

  def drive_coroutine({:asyncio_task, value}, env, ctx) do
    {value, env, ctx}
  end

  def drive_coroutine({:asyncio_task_pending, coro}, env, ctx) do
    drive_coroutine(coro, env, ctx)
  end

  def drive_coroutine(other, env, ctx) do
    type_name = Helpers.py_type(other)

    {{:exception, "TypeError: object #{type_name} can't be used in 'await' expression"}, env, ctx}
  end

  @doc """
  First step of an `await EXPR`: evaluate the awaitable, then either
  return its value immediately (if already resolved) or yield its
  first yielded value up to the surrounding trampoline with a
  `:cont_await_iter` frame attached for resumption.
  """
  @spec initiate_await(Interpreter.pyvalue(), Env.t(), Ctx.t()) :: Interpreter.call_result()
  def initiate_await({:coroutine, _name, {:iterator, id}}, env, ctx) do
    advance_await_step(id, env, ctx)
  end

  def initiate_await({:asyncio_task, value}, env, ctx) do
    {value, env, ctx}
  end

  def initiate_await({:asyncio_task_pending, coro}, env, ctx) do
    # Awaiting a pending Task drives its wrapped coroutine to
    # completion (yielding sentinels up to the surrounding
    # trampoline).  After this, the Task is conceptually done.
    initiate_await(coro, env, ctx)
  end

  def initiate_await(other, env, ctx) do
    type_name = Helpers.py_type(other)

    {{:exception, "TypeError: object #{type_name} can't be used in 'await' expression"}, env, ctx}
  end

  @doc """
  Resume an in-progress `await` (called by the `:cont_await_iter`
  frame in `resume_generator`).  Advances the awaited iterator one
  step; either yields up again, surfaces the return value as the
  await's result, or propagates an exception.
  """
  @spec continue_await(non_neg_integer(), Env.t(), Ctx.t()) :: Interpreter.call_result()
  def continue_await(id, env, ctx) do
    advance_await_step(id, env, ctx)
  end

  # Internal: one step of an await.  Either yields up (with
  # cont_await_iter so resumption advances the same iterator) or
  # surfaces the awaited iterator's return value as the await's
  # result.
  defp advance_await_step(id, env, ctx) do
    case advance_iter_one(id, env, ctx) do
      {:exhausted, env, ctx} ->
        return_value = Ctx.iter_return_value(ctx, id)
        {return_value, env, ctx}

      {{:yielded, value}, env, ctx} ->
        {{:yielded, value, [{:cont_await_iter, id}]}, env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}
    end
  end

  # Top-level driver — used by asyncio.run.  Pumps to completion,
  # interpreting known sentinels (asyncio.sleep) and dispatching
  # capability calls along the way.
  #
  # `mode` controls how `:gen_pending` is advanced:
  #
  #   :buffered — surface the buffered val (next(g) semantics).  Used on
  #               entry, before any capability has been resumed.
  #   :fresh    — run the cont and surface what it produces.  Used after a
  #               capability resume, so a re-advance does not re-surface
  #               the already-dispatched sentinel.
  #
  # The mode latches to `:fresh` after the first capability dispatch
  # and stays there for the rest of the drive.
  defp drive_iter_to_completion(id, env, ctx, mode \\ :buffered) do
    case advance_by_mode(id, env, ctx, mode) do
      {:exhausted, env, ctx} ->
        return_value = Ctx.iter_return_value(ctx, id)
        {return_value, env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {{:yielded, {:asyncio_capability_call, cap_id, fun, args}}, env, ctx} ->
        # Capability sentinel: dispatch the host fn inline (sequential
        # mode), feed the result back, then continue driving with fresh
        # semantics so the re-advance does not re-surface the already
        # handled sentinel.  `asyncio.gather` overrides this with a
        # parallel batch path — see `Pyex.Stdlib.Asyncio.round_robin_gather`.
        case dispatch_capability(cap_id, fun, args, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {_, env, ctx} ->
            drive_iter_to_completion(id, env, ctx, :fresh)
        end

      {{:yielded, value}, env, ctx} ->
        interpret_yield_sentinel(value)
        drive_iter_to_completion(id, env, ctx, mode)
    end
  end

  defp advance_by_mode(id, env, ctx, :buffered), do: advance_iter_one(id, env, ctx)
  defp advance_by_mode(id, env, ctx, :fresh), do: advance_iter_fresh(id, env, ctx)

  # Like advance_iter_one but for trampoline use: when the outer
  # iter is :gen_pending, runs the continuation and returns the
  # NEW yield (or exhaustion).  The buffered-yield semantics in
  # advance_iter_one are correct for `next(g)` — they re-surface
  # the previous yield so a Python iterator user sees each value
  # exactly once.  The trampoline already consumed the buffered
  # value upstream and wants what the cont produces next.
  defp advance_iter_fresh(id, env, ctx) do
    case Ctx.iter_next(ctx, id) do
      :exhausted ->
        {:exhausted, env, ctx}

      {:gen_pending, val, cont, gen_env} ->
        case step_via_continuation(id, val, cont, gen_env, env, ctx) do
          {:exhausted, env, ctx} -> {:exhausted, env, ctx}
          {{:yielded, next_val}, env, ctx} -> {{:yielded, next_val}, env, ctx}
          {{:exception, _} = sig, env, ctx} -> {sig, env, ctx}
        end

      _ ->
        # For other states (unstarted, awaiting_send, instance),
        # buffered-yield semantics are correct or irrelevant.
        advance_iter_one(id, env, ctx)
    end
  end

  @doc """
  Advance a capability iter (in `:gen_awaiting_send` state with a
  `{:asyncio_capability_call, ...}` sentinel) by supplying the
  trampoline-computed result.  The sent value flows through the iter's
  saved continuation (`[:cont_capability_resume, ...]`) and lands
  wherever the surrounding `await` expression was waiting
  (`r = await cap()` → binds via `:cont_bind_sent`; `return await cap()`
  → returns via `:cont_return_value`).
  """
  @spec resume_capability(non_neg_integer(), Interpreter.pyvalue(), Env.t(), Ctx.t()) ::
          {:exhausted, Env.t(), Ctx.t()} | {{:exception, String.t()}, Env.t(), Ctx.t()}
  def resume_capability(id, value, env, ctx) do
    case Ctx.iter_entry(ctx, id) do
      {:gen_awaiting_send, {:asyncio_capability_call, _, _, _}, cont, gen_env} ->
        case step_via_send(id, cont, gen_env, value, env, ctx) do
          {:exhausted, env, ctx} -> {:exhausted, env, ctx}
          {{:yielded, _val}, env, ctx} -> {:exhausted, env, ctx}
          {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
        end

      other ->
        {{:exception, "InvalidStateError: capability iter not awaiting (got #{inspect(other)})"},
         env, ctx}
    end
  end

  @doc """
  Invoke a capability function, normalizing args (deref + python-view).
  Used by both the synchronous trampoline and parallel gather.
  """
  @spec invoke_capability((list() -> term()), [Interpreter.pyvalue()], Ctx.t()) ::
          Interpreter.pyvalue()
  def invoke_capability(fun, args, ctx) do
    derefed = Enum.map(args, &Ctx.deep_deref(ctx, &1))

    try do
      fun.(derefed)
    rescue
      e -> {:exception, "RuntimeError: capability raised: #{Exception.message(e)}"}
    end
  end

  @doc """
  Invoke a single capability and resume its iter with the result.

  The sequential trampoline uses this directly per `{:asyncio_capability_call, ...}`
  sentinel.  `asyncio.gather`'s parallel path inlines a fan-out version
  (`Task.async_stream` over invoke, then a reduce over resume_capability)
  because the two steps need to be split across host threads.
  """
  @spec dispatch_capability(
          non_neg_integer(),
          (list() -> term()),
          [Interpreter.pyvalue()],
          Env.t(),
          Ctx.t()
        ) ::
          {:exhausted, Env.t(), Ctx.t()} | {{:exception, String.t()}, Env.t(), Ctx.t()}
  def dispatch_capability(cap_id, fun, args, env, ctx) do
    result = invoke_capability(fun, args, ctx)
    resume_capability(cap_id, result, env, ctx)
  end

  @doc """
  Advance a coroutine's iterator one step.  Public so the asyncio
  module can build round-robin schedulers (gather, the main loop)
  on top of the same primitive `await` uses internally.

  Uses fresh-yield semantics: after a capability has been resumed,
  re-advancing returns the NEXT yielded value (not the previously
  buffered sentinel).  This is what trampolines want; Python-level
  `next(g)` keeps using the buffered semantics in `advance_iter_one`.
  """
  @spec advance_coroutine_one_step(non_neg_integer(), Env.t(), Ctx.t()) ::
          {:exhausted, Env.t(), Ctx.t()}
          | {{:yielded, Interpreter.pyvalue() | Interpreter.coroutine_signal()}, Env.t(), Ctx.t()}
          | {{:exception, String.t()}, Env.t(), Ctx.t()}
  def advance_coroutine_one_step(id, env, ctx), do: advance_iter_fresh(id, env, ctx)

  @doc """
  Interpret a sentinel yielded by an awaitable.  Currently the only
  sentinel is `{:asyncio_sleep, ms}` — anything else is silently
  consumed.  Public so `asyncio.gather` can re-use the same
  interpretation when round-robin-driving children.
  """
  @spec interpret_yield_sentinel(Interpreter.pyvalue() | Interpreter.coroutine_signal()) :: any()
  def interpret_yield_sentinel({:asyncio_sleep, ms}) when is_integer(ms) and ms >= 0 do
    Process.sleep(ms)
  end

  def interpret_yield_sentinel(_), do: :ok

  # One-step iterator advance: returns either an exhaustion signal,
  # a yielded value (with the value extracted), or an exception.
  # Mirrors the islice helper's pattern but for one step.
  defp advance_iter_one(id, env, ctx) do
    case Ctx.iter_next(ctx, id) do
      :exhausted ->
        {:exhausted, env, ctx}

      {:gen_unstarted, body, gen_env} ->
        # First advance of an unstarted coroutine: run the body
        # (in lazy_iter mode) up to its first yield or to completion.
        # Whatever the body produces *is* the result of this advance.
        run_unstarted(id, body, gen_env, env, ctx)

      {:gen_pending, {:asyncio_capability_call, cap_id, _, _} = val, cont, gen_env} ->
        # Capability sentinel in the pending slot.  Two sub-cases:
        #
        # (a) Cap still in-flight (its own iter still in `:gen_awaiting_send`
        #     state with the sentinel): re-surface the sentinel so the
        #     trampoline can dispatch it.  The continuation must still be run
        #     to prepare the NEXT state (same as regular buffered semantics).
        #
        # (b) Cap already resolved (`{:gen_done, _}`): the trampoline already
        #     handled this sentinel in a previous round but a nested `await`
        #     chain caused `advance_iter_one` to be called again before the
        #     outer coroutine had a chance to observe the result.  Re-surfacing
        #     the stale sentinel would make the trampoline attempt a second
        #     `resume_capability` → crash.  Use fresh semantics: run the
        #     continuation now and return whatever it produces (the coroutine's
        #     actual next state, which is usually exhaustion + return value).
        case Ctx.iter_entry(ctx, cap_id) do
          {:gen_awaiting_send, {:asyncio_capability_call, _, _, _}, _, _} ->
            case step_via_continuation(id, val, cont, gen_env, env, ctx) do
              {:exhausted, env, ctx} -> {{:yielded, val}, env, ctx}
              {{:yielded, _next_val}, env, ctx} -> {{:yielded, val}, env, ctx}
              {{:exception, _} = sig, env, ctx} -> {sig, env, ctx}
            end

          _ ->
            # Cap done — drive continuation forward (fresh semantics).
            case step_via_continuation(id, val, cont, gen_env, env, ctx) do
              {:exhausted, env, ctx} -> {:exhausted, env, ctx}
              {{:yielded, next_val}, env, ctx} -> {{:yielded, next_val}, env, ctx}
              {{:exception, _} = sig, env, ctx} -> {sig, env, ctx}
            end
        end

      {:gen_pending, val, cont, gen_env} ->
        # Regular yield — standard buffered semantics: surface the pending
        # value and stage the next step.  Same semantics as next(g) in CPython.
        case step_via_continuation(id, val, cont, gen_env, env, ctx) do
          {:exhausted, env, ctx} -> {{:yielded, val}, env, ctx}
          {{:yielded, _next_val}, env, ctx} -> {{:yielded, val}, env, ctx}
          {{:exception, _} = sig, env, ctx} -> {sig, env, ctx}
        end

      {:gen_awaiting_send, {:asyncio_capability_call, _, _, _} = sentinel, _cont, _gen_env} ->
        # Capability protocol: surface the sentinel WITHOUT advancing.  The
        # trampoline must dispatch the underlying call and resume this iter
        # via `resume_capability/4` with the result.
        {{:yielded, sentinel}, env, ctx}

      {:gen_awaiting_send, val, cont, gen_env} ->
        # Python send protocol: `r = yield X` paused waiting for `.send(v)`.
        # `next(g)` (or any unguarded advance) implicitly sends `nil`.
        case step_via_send(id, cont, gen_env, nil, env, ctx) do
          {:exhausted, env, ctx} -> {{:yielded, val}, env, ctx}
          {{:yielded, _next_val}, env, ctx} -> {{:yielded, val}, env, ctx}
          {{:exception, _} = sig, env, ctx} -> {sig, env, ctx}
        end

      {:instance, inst} ->
        case Interpreter.eval_instance_next(inst, id, :no_default, env, ctx) do
          {{:exception, "StopIteration" <> _}, env, ctx} -> {:exhausted, env, ctx}
          {{:exception, _} = sig, env, ctx} -> {sig, env, ctx}
          {value, env, ctx} -> {{:yielded, value}, env, ctx}
        end
    end
  end

  # Start a fresh coroutine: run the body in defer_inner mode (so
  # internal yields suspend), update the iter pool entry to reflect
  # the new state.  Returns the first yielded value, exhaustion (with
  # return value captured), or exception.
  defp run_unstarted(id, body, gen_env, env, ctx) do
    saved_mode = ctx.generator_mode
    inner_ctx = %{ctx | generator_mode: :defer_inner}

    case Interpreter.eval_statements(body, gen_env, inner_ctx) do
      {{:yielded, val, [{:cont_bind_sent, _} | _] = cont}, post_env, post_ctx} ->
        ctx = sync_generator_ctx(ctx, post_ctx)
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.set_gen_awaiting_send(ctx, id, val, cont, post_env)
        {{:yielded, val}, env, ctx}

      {{:yielded, val, cont}, post_env, post_ctx} ->
        ctx = sync_generator_ctx(ctx, post_ctx)
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.set_gen_pending(ctx, id, val, cont, post_env)
        {{:yielded, val}, env, ctx}

      {{:exception, _} = signal, _post_env, post_ctx} ->
        ctx = sync_generator_ctx(ctx, post_ctx)
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_exhausted(ctx, id)
        {signal, env, ctx}

      {result, _post_env, post_ctx} ->
        ctx = sync_generator_ctx(ctx, post_ctx)
        ctx = %{ctx | generator_mode: saved_mode}
        return_value = Helpers.unwrap_function_result(result)
        ctx = Ctx.mark_iter_done_with_value(ctx, id, return_value)
        {:exhausted, env, ctx}
    end
  end

  # Run the continuation forward one step, updating the iter pool
  # entry to reflect the new state (pending / awaiting-send / done).
  defp step_via_continuation(id, _val, cont, gen_env, env, ctx) do
    saved_mode = ctx.generator_mode
    inner_ctx = %{ctx | generator_mode: :defer_inner}

    case Interpreter.resume_generator(cont, gen_env, inner_ctx) do
      {{:yielded, next_val, [{:cont_bind_sent, _} | _] = next_cont}, next_gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.set_gen_awaiting_send(ctx, id, next_val, next_cont, next_gen_env)
        {{:yielded, next_val}, env, ctx}

      {{:yielded, next_val, next_cont}, next_gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.set_gen_pending(ctx, id, next_val, next_cont, next_gen_env)
        {{:yielded, next_val}, env, ctx}

      {{:done_with_value, return_value}, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_done_with_value(ctx, id, return_value)
        {:exhausted, env, ctx}

      {:done, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_exhausted(ctx, id)
        {:exhausted, env, ctx}

      {{:exception, _} = signal, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_exhausted(ctx, id)
        {signal, env, ctx}
    end
  end

  defp step_via_send(id, cont, gen_env, sent_value, env, ctx) do
    saved_mode = ctx.generator_mode
    inner_ctx = %{ctx | generator_mode: :defer_inner}

    case Interpreter.resume_generator_with_send(cont, gen_env, inner_ctx, sent_value) do
      {{:yielded, next_val, [{:cont_bind_sent, _} | _] = next_cont}, next_gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.set_gen_awaiting_send(ctx, id, next_val, next_cont, next_gen_env)
        {{:yielded, next_val}, env, ctx}

      {{:yielded, next_val, next_cont}, next_gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.set_gen_pending(ctx, id, next_val, next_cont, next_gen_env)
        {{:yielded, next_val}, env, ctx}

      {{:done_with_value, return_value}, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_done_with_value(ctx, id, return_value)
        {:exhausted, env, ctx}

      {:done, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_exhausted(ctx, id)
        {:exhausted, env, ctx}

      {{:exception, _} = signal, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_exhausted(ctx, id)
        {signal, env, ctx}
    end
  end

  @doc false
  @spec call_bound_method(
          Interpreter.pyvalue(),
          Interpreter.pyvalue(),
          Interpreter.pyvalue() | nil,
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  def call_bound_method(
        instance,
        {:function, fname, params, body, closure_env, is_generator, kind},
        defining_class,
        args,
        kwargs,
        env,
        ctx
      ) do
    method_args = [instance | args]

    # Async methods are coroutines: bind self+args into the call env
    # and produce a coroutine value rather than running the body
    # inline.  Sync methods fall through to the existing path below.
    if kind == :async do
      Interpreter.call_function(
        {:function, fname, params, body, closure_env, is_generator, :async},
        method_args,
        kwargs,
        env,
        ctx
      )
    else
      call_bound_sync_method(
        instance,
        fname,
        params,
        body,
        closure_env,
        is_generator,
        defining_class,
        method_args,
        kwargs,
        env,
        ctx
      )
    end
  end

  @spec call_bound_sync_method(
          Interpreter.pyvalue(),
          String.t(),
          [Parser.param()],
          [Parser.ast_node()],
          Env.t(),
          boolean(),
          Interpreter.pyvalue() | nil,
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  defp call_bound_sync_method(
         instance,
         fname,
         params,
         body,
         closure_env,
         is_generator,
         defining_class,
         method_args,
         kwargs,
         env,
         ctx
       ) do
    fresh_closure = Env.refresh_from_caller(closure_env, env)

    func = {:function, fname, params, body, closure_env, is_generator, :sync}
    base_env = Env.push_scope(Env.put(fresh_closure, fname, func))

    base_env =
      if defining_class, do: Env.put(base_env, "__class__", defining_class), else: base_env

    case CallSupport.bind_params(params, method_args, kwargs, base_env, ctx) do
      {:exception, msg, ctx} ->
        {{:exception, msg}, env, ctx}

      {call_env, ctx} ->
        if is_generator do
          eval_generator_function(body, call_env, env, ctx)
        else
          {result, post_call_env, ctx} = Interpreter.eval_statements(body, call_env, ctx)
          env = Env.propagate_scopes(env, fresh_closure, post_call_env)
          return_val = Helpers.unwrap_function_result(result)

          case instance do
            {:ref, _} ->
              {return_val, env, ctx}

            _ ->
              # The instance is bound to the method's FIRST parameter, whatever
              # it's named — `self` is convention, not a keyword. Read the
              # (possibly mutated) instance back by that name, not a hardcoded
              # "self", so `def __init__(s): s.n = 1` persists like CPython.
              updated_self =
                case Env.get(post_call_env, self_param_name(params)) do
                  {:ok, {:instance, _, _} = updated} -> updated
                  _ -> instance
                end

              {:mutate, updated_self, return_val, env, ctx}
          end
        end
    end
  end

  # The name the instance is bound to inside a method body = its first
  # positional parameter (conventionally `self`). Falls back to "self" for a
  # malformed/empty parameter list.
  @spec self_param_name([tuple()]) :: String.t()
  defp self_param_name([{name, _} | _]) when is_binary(name), do: name
  defp self_param_name([{name, _, _} | _]) when is_binary(name), do: name
  defp self_param_name(_), do: "self"

  # Identity-preserving materializers (list/tuple/reversed/sorted) take a
  # shallow deref so element refs survive; everything else deep-derefs.
  @spec deref_args_for((... -> term()), [Interpreter.pyvalue()], Ctx.t()) ::
          [Interpreter.pyvalue()]
  defp deref_args_for(fun, args, ctx) do
    deref = if Pyex.Builtins.shallow_arg_builtin?(fun), do: &Ctx.deref/2, else: &Ctx.deep_deref/2

    Enum.map(args, fn arg ->
      # Resolve any instance's embedded class snapshot to its live class so
      # introspection builtins (getattr/hasattr/dir/vars/…) observe class
      # mutations made after the instance was created.
      case deref.(ctx, arg) do
        {:instance, {:class, _, _, _} = cls, attrs} ->
          {:instance, Ctx.live_class(ctx, cls), attrs}

        other ->
          other
      end
    end)
  end

  @doc false
  @spec call_builtin((list() -> term()), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          Interpreter.call_result()
  def call_builtin(fun, args, env, ctx) do
    case maybe_drain_args(fun, args, env, ctx) do
      {:exception, _} = signal ->
        {signal, env, ctx}

      {drained_args, env, ctx} ->
        derefed_args = deref_args_for(fun, drained_args, ctx)

        case maybe_coerce_index_args(fun, derefed_args, env, ctx) do
          {:exception, _} = signal ->
            {signal, env, ctx}

          {coerced_args, env, ctx} ->
            run_builtin(fun, coerced_args, env, ctx)
        end
    end
  end

  # PEP 357: builtins that want integers (range/hex/oct/bin/chr) coerce
  # instance/bool arguments through __index__ before dispatch.
  @spec maybe_coerce_index_args((list() -> term()), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          {[Interpreter.pyvalue()], Env.t(), Ctx.t()} | {:exception, String.t()}
  defp maybe_coerce_index_args(fun, args, env, ctx) do
    if Pyex.Builtins.index_coercing_builtin?(fun) do
      Enum.reduce_while(args, {[], env, ctx}, fn arg, {acc, env, ctx} ->
        case coerce_one_index(arg, env, ctx) do
          {:ok, v, env, ctx} -> {:cont, {[v | acc], env, ctx}}
          {:exception, _} = signal -> {:halt, signal}
        end
      end)
      |> case do
        {:exception, _} = signal -> signal
        {acc, env, ctx} -> {Enum.reverse(acc), env, ctx}
      end
    else
      {args, env, ctx}
    end
  end

  @spec coerce_one_index(Interpreter.pyvalue(), Env.t(), Ctx.t()) ::
          {:ok, Interpreter.pyvalue(), Env.t(), Ctx.t()} | {:exception, String.t()}
  defp coerce_one_index(true, env, ctx), do: {:ok, 1, env, ctx}
  defp coerce_one_index(false, env, ctx), do: {:ok, 0, env, ctx}

  defp coerce_one_index({:instance, _, _} = inst, env, ctx) do
    case Interpreter.Dunder.call_dunder(inst, "__index__", [], env, ctx) do
      {:ok, i, env, ctx} when is_integer(i) -> {:ok, i, env, ctx}
      {:ok, _other, _env, _ctx} -> {:exception, "TypeError: __index__ returned non-int"}
      :not_found -> {:ok, inst, env, ctx}
    end
  end

  defp coerce_one_index(arg, env, ctx), do: {:ok, arg, env, ctx}

  @spec run_builtin((list() -> term()), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          {Interpreter.pyvalue() | tuple(), Env.t(), Ctx.t()}
  defp run_builtin(fun, derefed_args, env, ctx) do
    result =
      try do
        fun.(derefed_args)
      rescue
        FunctionClauseError ->
          {:exception, builtin_clause_error_message(fun, derefed_args)}

        e in [ArithmeticError, ArgumentError, Enum.EmptyError] ->
          {:exception, "TypeError: #{Exception.message(e)}"}
      end

    BuiltinResults.handle_builtin_result(result, env, ctx)
  end

  @spec maybe_drain_args(
          (list() -> term()),
          [Interpreter.pyvalue()],
          Env.t(),
          Ctx.t()
        ) :: {[Interpreter.pyvalue()], Env.t(), Ctx.t()} | {:exception, String.t()}
  defp maybe_drain_args(fun, args, env, ctx) do
    if Pyex.Builtins.no_drain_builtin?(fun) do
      {args, env, ctx}
    else
      drain_gen_args(args, env, ctx)
    end
  end

  @spec drain_gen_args([Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          {[Interpreter.pyvalue()], Env.t(), Ctx.t()} | {:exception, String.t()}
  defp drain_gen_args(args, env, ctx) do
    Enum.reduce_while(args, {[], env, ctx}, fn arg, {acc, env, ctx} ->
      case maybe_drain_gen_iter(arg, env, ctx) do
        {:exception, _} = signal -> {:halt, signal}
        {coerced, env, ctx} -> {:cont, {[coerced | acc], env, ctx}}
      end
    end)
    |> case do
      {:exception, _} = signal -> signal
      {acc, env, ctx} -> {Enum.reverse(acc), env, ctx}
    end
  end

  @spec maybe_drain_gen_iter(Interpreter.pyvalue(), Env.t(), Ctx.t()) ::
          {Interpreter.pyvalue(), Env.t(), Ctx.t()} | {:exception, String.t()}
  defp maybe_drain_gen_iter({:iterator, id} = iter, env, ctx) do
    case Ctx.iter_entry(ctx, id) do
      {:gen_sync, _started?, _, _} ->
        case Pyex.Interpreter.Iterables.to_iterable(iter, env, ctx) do
          {:ok, items, env, ctx} -> {{:generator, items}, env, ctx}
          {:exception, _} = signal -> signal
        end

      {:gen_pending, _, _, _} ->
        case Pyex.Interpreter.Iterables.drain_generator_iter(id, env, ctx) do
          {:ok, items, env, ctx} -> {{:generator, items}, env, ctx}
          {:exception, _} = signal -> signal
        end

      :gen_done ->
        {{:generator, []}, env, ctx}

      {:gen_done, _value} ->
        {{:generator, []}, env, ctx}

      _ ->
        {iter, env, ctx}
    end
  end

  defp maybe_drain_gen_iter(arg, env, ctx), do: {arg, env, ctx}

  @doc false
  @spec call_builtin_raw((list() -> term()), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          Interpreter.call_result()
  def call_builtin_raw(fun, args, env, ctx) do
    result =
      try do
        fun.(args)
      rescue
        FunctionClauseError ->
          {:exception, builtin_clause_error_message(fun, args)}

        e in [ArithmeticError, ArgumentError, Enum.EmptyError] ->
          {:exception, "TypeError: #{Exception.message(e)}"}
      end

    BuiltinResults.handle_builtin_result(result, env, ctx)
  end

  @doc false
  @spec call_builtin_kw(
          (list(), %{optional(String.t()) => Interpreter.pyvalue()} -> term()),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  def call_builtin_kw(fun, args, kwargs, env, ctx) do
    case drain_gen_args(args, env, ctx) do
      {:exception, _} = signal ->
        {signal, env, ctx}

      {drained_args, env, ctx} ->
        derefed_args = deref_args_for(fun, drained_args, ctx)
        derefed_kwargs = Map.new(kwargs, fn {k, v} -> {k, Ctx.deep_deref(ctx, v)} end)

        result =
          try do
            fun.(derefed_args, derefed_kwargs)
          rescue
            FunctionClauseError ->
              {:exception, builtin_clause_error_message(fun, derefed_args, derefed_kwargs)}

            e in [ArithmeticError, ArgumentError, Enum.EmptyError] ->
              {:exception, "TypeError: #{Exception.message(e)}"}
          end

        BuiltinResults.handle_builtin_kw_result(result, env, ctx)
    end
  end

  @doc false
  @spec call_bound_builtin_kw(
          Interpreter.pyvalue(),
          (list(), %{optional(String.t()) => Interpreter.pyvalue()} -> term()),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  def call_bound_builtin_kw(instance, fun, args, kwargs, env, ctx) do
    derefed_instance = Ctx.deep_deref(ctx, instance)
    derefed_args = Enum.map(args, &Ctx.deep_deref(ctx, &1))
    derefed_kwargs = Map.new(kwargs, fn {k, v} -> {k, Ctx.deep_deref(ctx, v)} end)

    case BuiltinResults.handle_builtin_kw_result(
           fun.([derefed_instance | derefed_args], derefed_kwargs),
           env,
           ctx
         ) do
      {:mutate, new_obj, return_val, new_ctx} -> {:mutate, new_obj, return_val, new_ctx}
      other -> other
    end
  end

  # Builds a diagnostic Python-level TypeError message when a builtin
  # raises FunctionClauseError — i.e. the user passed args that hit no
  # clause head.  Includes the builtin's name (via `Function.info/1`)
  # and a short summary of the arg shapes, so the LLM consuming the
  # error can fix its call.  The generic fallback "TypeError: invalid
  # arguments" is uninformative for self-healing.
  @spec builtin_clause_error_message(
          (... -> term()),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()}
        ) :: String.t()
  defp builtin_clause_error_message(fun, args, kwargs \\ %{}) do
    name = builtin_name(fun)
    arg_summary = Enum.map_join(args, ", ", &arg_type_summary/1)
    kwarg_summary = if map_size(kwargs) == 0, do: "", else: ", " <> kwargs_summary(kwargs)

    "TypeError: #{name}(#{arg_summary}#{kwarg_summary}): no matching clause" <>
      " (wrong number or types of arguments)"
  end

  @spec builtin_name((... -> term())) :: String.t()
  defp builtin_name(fun) do
    info = Function.info(fun)
    mod = Keyword.get(info, :module)
    name = Keyword.get(info, :name)
    arity = Keyword.get(info, :arity)

    cond do
      mod == nil or name == nil -> "<builtin>"
      true -> "#{inspect(mod)}.#{name}/#{arity}"
    end
  end

  @spec arg_type_summary(Interpreter.pyvalue()) :: String.t()
  defp arg_type_summary(value) do
    case value do
      v when is_integer(v) -> "int"
      v when is_float(v) -> "float"
      v when is_boolean(v) -> "bool"
      v when is_binary(v) -> "str"
      nil -> "None"
      {:py_list, _, _} -> "list"
      {:py_dict, _, _} -> "dict"
      {:py_set, _, _} -> "set"
      {:tuple, _} -> "tuple"
      {:pyex_decimal, _} -> "Decimal"
      {:builtin, _} -> "builtin"
      {:function, _, _, _, _, _, _} -> "function"
      {:class, _, _, _} -> "class"
      {:instance, _, _, _} -> "instance"
      {:generator, _} -> "generator"
      {:iterator, _} -> "iterator"
      {tag, _} when is_atom(tag) -> Atom.to_string(tag)
      {tag, _, _} when is_atom(tag) -> Atom.to_string(tag)
      _ -> "?"
    end
  end

  @spec kwargs_summary(%{optional(String.t()) => Interpreter.pyvalue()}) :: String.t()
  defp kwargs_summary(kwargs) do
    Enum.map_join(kwargs, ", ", fn {k, v} -> "#{k}=#{arg_type_summary(v)}" end)
  end

  @doc false
  @spec call_bound_builtin(
          Interpreter.pyvalue(),
          (list() -> term()),
          [Interpreter.pyvalue()],
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  def call_bound_builtin(instance, fun, args, env, ctx) do
    derefed_instance = Ctx.deep_deref(ctx, instance)
    derefed_args = Enum.map(args, &Ctx.deep_deref(ctx, &1))

    BuiltinResults.handle_builtin_result(fun.([derefed_instance | derefed_args]), env, ctx)
    |> case do
      {:mutate, new_obj, return_val, new_ctx} -> {:mutate, new_obj, return_val, new_ctx}
      other -> other
    end
  end

  @doc false
  @spec call_class(
          Interpreter.pyvalue(),
          String.t(),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  def call_class({:class, "type", [], _} = class, name, args, kwargs, env, ctx) do
    # `type(x)` returns the class/type of x; `type(name, bases, attrs)`
    # constructs a new class.  Kwargs are not meaningful for the 1-arg
    # form in CPython — fall through to instance construction if given.
    case {args, map_size(kwargs)} do
      {[val], 0} ->
        derefed = Ctx.deep_deref(ctx, val)
        {Pyex.Builtins.builtin_type_of(derefed), env, ctx}

      {[cls_name, bases_val, ns_val], 0} ->
        build_dynamic_class(cls_name, bases_val, ns_val, env, ctx)

      _ ->
        call_class_generic(class, name, args, kwargs, env, ctx)
    end
  end

  def call_class({:class, _, _, _} = class, name, args, kwargs, env, ctx) do
    call_class_generic(class, name, args, kwargs, env, ctx)
  end

  # `type(name, bases, namespace)` constructs a new class at runtime.
  @spec build_dynamic_class(
          Interpreter.pyvalue(),
          Interpreter.pyvalue(),
          Interpreter.pyvalue(),
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  defp build_dynamic_class(cls_name, bases_val, ns_val, env, ctx) do
    with name when is_binary(name) <- Ctx.deref(ctx, cls_name),
         {:tuple, bases} <- normalize_class_bases(Ctx.deref(ctx, bases_val)),
         {:py_dict, _, _} = ns <- Ctx.deref(ctx, ns_val) do
      attrs =
        ns
        |> Pyex.PyDict.keys()
        |> Enum.filter(&is_binary/1)
        |> Map.new(fn k -> {k, elem(Pyex.PyDict.fetch(ns, k), 1)} end)
        |> Map.put("__name__", name)

      class = {:class, name, bases, attrs}
      ctx = Ctx.register_class(ctx, class)
      {class, env, ctx}
    else
      _ ->
        {{:exception, "TypeError: type() argument 1 must be str, 2 a tuple, 3 a dict"}, env, ctx}
    end
  end

  defp normalize_class_bases({:tuple, _} = t), do: t
  defp normalize_class_bases(_), do: :error

  @spec call_class_generic(
          Interpreter.pyvalue(),
          String.t(),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  defp call_class_generic({:class, _, _, _} = class, name, args, kwargs, env, ctx) do
    case resolve_user_new(class) do
      {:ok, new_func, owner} ->
        construct_via_new(class, {new_func, owner}, name, args, kwargs, env, ctx)

      :none ->
        run_init({:instance, class, %{}}, class, name, args, kwargs, env, ctx)
    end
  end

  # A user-defined `__new__` (object's default is implicit and never stored).
  @spec resolve_user_new(Interpreter.pyvalue()) ::
          {:ok, Interpreter.pyvalue(), Interpreter.pyvalue()} | :none
  defp resolve_user_new(class) do
    case ClassLookup.resolve_class_attr_with_owner(class, "__new__") do
      {:ok, {:function, _, _, _, _, _, _} = func, owner} -> {:ok, func, owner}
      _ -> :none
    end
  end

  # `cls(...)` with an overridden `__new__`: call `__new__(cls, *args)`, then
  # run `__init__` on the result iff it is an instance of `cls` (CPython rule).
  @spec construct_via_new(
          Interpreter.pyvalue(),
          {Interpreter.pyvalue(), Interpreter.pyvalue()},
          String.t(),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  defp construct_via_new(class, {new_func, owner}, name, args, kwargs, env, ctx) do
    case call_new(new_func, owner, [class | args], kwargs, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        case Ctx.deref(ctx, value) do
          {:instance, inst_class, _} = inst ->
            if instance_of_class?(inst_class, class) do
              run_init(inst, class, name, args, kwargs, env, ctx)
            else
              {value, env, ctx}
            end

          _ ->
            {value, env, ctx}
        end
    end
  end

  # Invoke `__new__` like a staticmethod: `cls` is passed explicitly in
  # `new_args` (no `self`/`cls` auto-binding), but `__class__` must be set so a
  # zero-arg `super()` inside the body resolves.
  @spec call_new(
          Interpreter.pyvalue(),
          Interpreter.pyvalue(),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  defp call_new(
         {:function, fname, params, body, closure_env, is_generator, _kind},
         owner,
         new_args,
         kwargs,
         env,
         ctx
       ) do
    fresh_closure = Env.refresh_from_caller(closure_env, env)
    new_fn = {:function, fname, params, body, closure_env, is_generator, :sync}
    base_env = Env.push_scope(Env.put(fresh_closure, fname, new_fn))
    base_env = Env.put(base_env, "__class__", owner)

    case CallSupport.bind_params(params, new_args, kwargs, base_env, ctx) do
      {:exception, msg, ctx} ->
        {{:exception, msg}, env, ctx}

      {call_env, ctx} ->
        {result, post_call_env, ctx} = Interpreter.eval_statements(body, call_env, ctx)
        env = Env.propagate_scopes(env, fresh_closure, post_call_env)
        {Helpers.unwrap_function_result(result), env, ctx}
    end
  end

  @spec instance_of_class?(Interpreter.pyvalue(), Interpreter.pyvalue()) :: boolean()
  defp instance_of_class?({:class, _, _, _} = cls, {:class, _, _, _} = target),
    do: cls == target or is_strict_subclass?(cls, target)

  defp instance_of_class?(_, _), do: false

  @spec run_init(
          Interpreter.pyvalue(),
          Interpreter.pyvalue(),
          String.t(),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  defp run_init(instance, {:class, _, _, _} = class, name, args, kwargs, env, ctx) do
    case ClassLookup.resolve_class_attr_with_owner(class, "__init__") do
      {:ok, {:function, init_name, params, body, closure_env, is_generator, _kind},
       defining_class} ->
        call_class_init(
          instance,
          init_name,
          params,
          body,
          closure_env,
          is_generator,
          defining_class,
          args,
          kwargs,
          env,
          ctx
        )

      {:ok, {:builtin_kw, fun}, _defining_class} ->
        derefed_args = Enum.map(args, &Ctx.deep_deref(ctx, &1))
        derefed_kwargs = Map.new(kwargs, fn {k, v} -> {k, Ctx.deep_deref(ctx, v)} end)

        case fun.([instance | derefed_args], derefed_kwargs) do
          {:instance, _, _} = updated_instance ->
            # Preserve subclass identity: if a stdlib parent __init__
            # returned an instance tagged with the parent class, rebind
            # it to the subclass being constructed.
            rebound = rebind_to_subclass(updated_instance, class)
            {ref, ctx} = Ctx.heap_alloc(ctx, rebound)
            {ref, env, ctx}

          {:mutate, new_instance, _ret} ->
            rebound = rebind_to_subclass(new_instance, class)
            {ref, ctx} = Ctx.heap_alloc(ctx, rebound)
            {ref, env, ctx}

          # Builtin __init__ that needs to call back into the interpreter
          # (e.g. dataclass field with default_factory=lambda: ...).
          {:ctx_call, ctx_fun} ->
            case ctx_fun.(env, ctx) do
              {{:instance, _, _} = updated_instance, env, ctx} ->
                rebound = rebind_to_subclass(updated_instance, class)
                {ref, ctx} = Ctx.heap_alloc(ctx, rebound)
                {ref, env, ctx}

              {{:exception, _} = signal, env, ctx} ->
                {signal, env, ctx}

              {_, env, ctx} ->
                {ref, ctx} = Ctx.heap_alloc(ctx, instance)
                {ref, env, ctx}
            end

          {:exception, _} = signal ->
            {signal, env, ctx}

          _ ->
            {ref, ctx} = Ctx.heap_alloc(ctx, instance)
            {ref, env, ctx}
        end

      # A builtin __init__ (e.g. the one synthesized for built-in
      # exception classes) takes `self` as its first arg and may return
      # {:mutate, new_instance, _} to replace the instance.
      {:ok, {:builtin, fun}, _defining_class} ->
        derefed_args = Enum.map(args, &Ctx.deep_deref(ctx, &1))

        case fun.([instance | derefed_args]) do
          {:mutate, new_instance, _ret} ->
            rebound = rebind_to_subclass(new_instance, class)
            {ref, ctx} = Ctx.heap_alloc(ctx, rebound)
            {ref, env, ctx}

          {:instance, _, _} = updated_instance ->
            rebound = rebind_to_subclass(updated_instance, class)
            {ref, ctx} = Ctx.heap_alloc(ctx, rebound)
            {ref, env, ctx}

          {:exception, _} = signal ->
            {signal, env, ctx}

          _ ->
            {ref, ctx} = Ctx.heap_alloc(ctx, instance)
            {ref, env, ctx}
        end

      :error ->
        if args == [] do
          {ref, ctx} = Ctx.heap_alloc(ctx, instance)
          {ref, env, ctx}
        else
          {{:exception, "TypeError: #{name}() takes 0 arguments but #{length(args)} were given"},
           env, ctx}
        end
    end
  end

  @spec rebind_to_subclass(Interpreter.pyvalue(), Interpreter.pyvalue()) ::
          Interpreter.pyvalue()
  defp rebind_to_subclass({:instance, current_class, attrs} = inst, requested_class) do
    # The parent's builtin __init__ returns `{:instance, ParentClass, ...}`.
    # If the caller asked for a subclass, retag the instance so
    # `type(obj) is Subclass` and `isinstance(obj, Subclass)` hold.
    # Only rebind when `requested_class` is a strict descendant of
    # `current_class` so we don't accidentally broaden an instance.
    if is_strict_subclass?(requested_class, current_class) do
      {:instance, requested_class, attrs}
    else
      inst
    end
  end

  defp rebind_to_subclass(other, _class), do: other

  @spec is_strict_subclass?(Interpreter.pyvalue(), Interpreter.pyvalue()) :: boolean()
  defp is_strict_subclass?({:class, _, _, _} = sub, {:class, _, _, _} = sup)
       when sub != sup do
    mro = Pyex.Interpreter.ClassLookup.c3_linearize(sub)
    Enum.any?(mro, fn cls -> cls == sup end)
  end

  defp is_strict_subclass?(_, _), do: false

  @doc false
  @spec call_callable_instance(
          Interpreter.pyvalue(),
          Interpreter.pyvalue(),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  def call_callable_instance(instance, class, args, kwargs, env, ctx) do
    case ClassLookup.resolve_class_attr(class, "__call__") do
      {:ok, {:function, _, _, _, _, _, _} = func} ->
        Interpreter.call_function({:bound_method, instance, func}, args, kwargs, env, ctx)

      {:ok, {:builtin, fun}} ->
        # Builtins don't take `self`, so callers emulate the Python
        # signature directly.  Used by stdlib classes that are really
        # callable factories (e.g. `itertools.chain`).
        derefed_args = Enum.map(args, &Ctx.deep_deref(ctx, &1))
        {fun.(derefed_args), env, ctx}

      {:ok, {:builtin_kw, fun}} ->
        derefed_args = Enum.map(args, &Ctx.deep_deref(ctx, &1))
        derefed_kwargs = Map.new(kwargs, fn {k, v} -> {k, Ctx.deep_deref(ctx, v)} end)
        {fun.(derefed_args, derefed_kwargs), env, ctx}

      _ ->
        {{:exception, "TypeError: '#{Helpers.py_type(instance)}' object is not callable"}, env,
         ctx}
    end
  end

  @spec eval_generator_function([Parser.ast_node()], Env.t(), Env.t(), Ctx.t()) ::
          Interpreter.call_result()
  defp eval_generator_function(body, call_env, env, ctx) do
    case ctx.generator_mode do
      :defer ->
        gen_ctx = %{ctx | generator_mode: :defer_inner}

        case Interpreter.eval_statements(body, call_env, gen_ctx) do
          {{:yielded, val, cont}, gen_env, gen_ctx} ->
            ctx = sync_generator_ctx(ctx, gen_ctx)
            {{:generator_suspended, val, cont, gen_env}, env, ctx}

          {{:exception, _} = signal, _post_env, gen_ctx} ->
            ctx = sync_generator_ctx(ctx, gen_ctx)
            {signal, env, ctx}

          {_, _post_env, gen_ctx} ->
            ctx = sync_generator_ctx(ctx, gen_ctx)
            {{:generator, []}, env, ctx}
        end

      mode when mode in [:lazy_iter, :defer_inner] ->
        # CPython semantics: calling a generator function runs NONE of its
        # body. Stage the whole body as a continuation in a lazy `:gen_sync`
        # pool entry; the first `next(g)`/`send(g, …)`/`for x in g` runs it up
        # to the first `yield`. This makes side effects fire exactly when the
        # generator is advanced (not at creation) and keeps suspension points
        # intact for `send`/`throw`/`close`/`yield from`.
        #
        # `:defer_inner` callers are themselves generator bodies: an inner
        # `inner()` call must also be lazy so `yield from inner()` interleaves
        # yields rather than running inner eagerly.
        {iter_token, ctx} = Ctx.new_sync_generator(ctx, [{:cont_stmts, body}], call_env)
        {iter_token, env, ctx}

      _ ->
        prev_acc = ctx.generator_acc
        gen_ctx = %{ctx | generator_mode: :accumulate, generator_acc: []}
        {result, _post_call_env, gen_ctx} = Interpreter.eval_statements(body, call_env, gen_ctx)
        yields = Enum.reverse(gen_ctx.generator_acc || [])

        ctx = %{
          ctx
          | compute: gen_ctx.compute,
            compute_started_at: gen_ctx.compute_started_at,
            generator_mode: ctx.generator_mode,
            generator_acc: prev_acc,
            event_count: gen_ctx.event_count,
            file_ops: gen_ctx.file_ops,
            heap: gen_ctx.heap,
            next_heap_id: gen_ctx.next_heap_id,
            output_buffer: gen_ctx.output_buffer
        }

        case result do
          {:exception, "TimeoutError:" <> _ = msg} ->
            {{:exception, msg}, env, ctx}

          {:exception, msg} ->
            {{:generator_error, yields, msg}, env, ctx}

          _ ->
            {{:generator, yields}, env, ctx}
        end
    end
  end

  @spec eval_regular_function(
          Interpreter.pyvalue(),
          Env.t(),
          [Parser.ast_node()],
          Env.t(),
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  defp eval_regular_function(func, fresh_closure, body, call_env, env, ctx) do
    {result, post_call_env, ctx} = Interpreter.eval_statements(body, call_env, ctx)
    env = Env.propagate_scopes(env, fresh_closure, post_call_env)
    return_val = Helpers.unwrap_function_result(result)

    if Helpers.has_scope_declarations?(post_call_env) do
      return_val = Helpers.refresh_closure(return_val, post_call_env)
      updated_func = Helpers.refresh_closure(func, post_call_env)
      {return_val, env, ctx, updated_func}
    else
      updated_func = Helpers.update_closure_env(func, post_call_env)
      {return_val, env, ctx, updated_func}
    end
  end

  @spec maybe_record_profile(Interpreter.call_result(), String.t(), integer() | nil) ::
          Interpreter.call_result()
  defp maybe_record_profile(result, _name, nil), do: result

  defp maybe_record_profile(result, name, t0) do
    elapsed_us = System.monotonic_time(:microsecond) - t0
    elapsed_ms = elapsed_us / 1000.0
    CallSupport.update_profile_in_result(result, name, elapsed_ms)
  end

  @spec sync_generator_ctx(Ctx.t(), Ctx.t()) :: Ctx.t()
  defp sync_generator_ctx(ctx, gen_ctx) do
    %{
      ctx
      | compute: gen_ctx.compute,
        compute_started_at: gen_ctx.compute_started_at,
        event_count: gen_ctx.event_count,
        file_ops: gen_ctx.file_ops,
        heap: gen_ctx.heap,
        next_heap_id: gen_ctx.next_heap_id,
        output_buffer: gen_ctx.output_buffer,
        # Propagate iterator-pool mutations: a generator running in
        # `:defer_inner` may have allocated nested generator iterators
        # (e.g. `yield from inner()` — inner gets a pool slot before
        # this generator wraps itself). Without copying these back, the
        # next allocation collides with inner's id and overwrites it.
        iterators: gen_ctx.iterators,
        next_iterator_id: gen_ctx.next_iterator_id
    }
  end

  @spec call_class_init(
          Interpreter.pyvalue(),
          String.t(),
          [Parser.param()],
          [Parser.ast_node()],
          Env.t(),
          boolean(),
          Interpreter.pyvalue(),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  defp call_class_init(
         instance,
         init_name,
         params,
         body,
         closure_env,
         is_generator,
         defining_class,
         args,
         kwargs,
         env,
         ctx
       ) do
    init_args = [instance | args]

    fresh_closure = Env.refresh_from_caller(closure_env, env)

    init_fn = {:function, init_name, params, body, closure_env, is_generator, :sync}
    base_env = Env.push_scope(Env.put(fresh_closure, init_name, init_fn))
    base_env = Env.put(base_env, "__class__", defining_class)

    case CallSupport.bind_params(params, init_args, kwargs, base_env, ctx) do
      {:exception, msg, ctx} ->
        {{:exception, msg}, env, ctx}

      {call_env, ctx} ->
        {result, post_call_env, ctx} = Interpreter.eval_statements(body, call_env, ctx)
        env = Env.propagate_scopes(env, fresh_closure, post_call_env)

        case result do
          {:exception, _} = signal ->
            {signal, env, ctx}

          _ ->
            final_self =
              case Env.get(post_call_env, self_param_name(params)) do
                {:ok, {:instance, _, _} = updated} -> updated
                _ -> instance
              end

            {ref, ctx} = Ctx.heap_alloc(ctx, final_self)
            {ref, env, ctx}
        end
    end
  end
end
