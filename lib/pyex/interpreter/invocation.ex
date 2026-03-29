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
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  def call_user_function(func, name, params, body, closure_env, args, kwargs, env, ctx) do
    case Ctx.check_step(ctx) do
      {:exceeded, msg} ->
        {{:exception, msg}, env, ctx}

      {:ok, ctx} ->
        do_call_user_function(func, name, params, body, closure_env, args, kwargs, env, ctx)
    end
  end

  defp do_call_user_function(func, name, params, body, closure_env, args, kwargs, env, ctx) do
    if ctx.call_depth >= ctx.max_call_depth do
      {{:exception, "RecursionError: maximum recursion depth exceeded"}, env, ctx}
    else
      ctx = %{ctx | call_depth: ctx.call_depth + 1}

      fresh_closure =
        Env.put_global_scope(closure_env, Env.global_scope(env), Env.global_scope_id(env))

      base_env = Env.push_scope(Env.put(fresh_closure, name, func))

      case CallSupport.bind_params(params, args, kwargs, base_env, ctx) do
        {:exception, msg, ctx} ->
          ctx = %{ctx | call_depth: ctx.call_depth - 1}
          {{:exception, msg}, env, ctx}

        {call_env, ctx} ->
          t0 = if ctx.profile, do: System.monotonic_time(:microsecond)

          result =
            if Interpreter.contains_yield?(body) do
              eval_generator_function(body, call_env, env, ctx)
            else
              eval_regular_function(func, fresh_closure, body, call_env, env, ctx)
            end

          result = maybe_record_profile(result, name, t0)
          CallSupport.decrement_depth(result)
      end
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
        {:function, fname, params, body, closure_env},
        defining_class,
        args,
        kwargs,
        env,
        ctx
      ) do
    method_args = [instance | args]

    fresh_closure =
      Env.put_global_scope(closure_env, Env.global_scope(env), Env.global_scope_id(env))

    func = {:function, fname, params, body, closure_env}
    base_env = Env.push_scope(Env.put(fresh_closure, fname, func))

    base_env =
      if defining_class, do: Env.put(base_env, "__class__", defining_class), else: base_env

    case CallSupport.bind_params(params, method_args, kwargs, base_env, ctx) do
      {:exception, msg, ctx} ->
        {{:exception, msg}, env, ctx}

      {call_env, ctx} ->
        {result, post_call_env, ctx} = Interpreter.eval_statements(body, call_env, ctx)
        env = Env.propagate_scopes(env, fresh_closure, post_call_env)
        return_val = Helpers.unwrap_function_result(result)

        case instance do
          {:ref, _} ->
            {return_val, env, ctx}

          _ ->
            updated_self =
              case Env.get(post_call_env, "self") do
                {:ok, {:instance, _, _} = updated} -> updated
                _ -> instance
              end

            {:mutate, updated_self, return_val, env, ctx}
        end
    end
  end

  @doc false
  @spec call_builtin((list() -> term()), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          Interpreter.call_result()
  def call_builtin(fun, args, env, ctx) do
    derefed_args = Enum.map(args, &Ctx.deep_deref(ctx, &1))

    result =
      try do
        fun.(derefed_args)
      rescue
        FunctionClauseError ->
          {:exception, "TypeError: invalid arguments"}

        e in [ArithmeticError, ArgumentError, Enum.EmptyError] ->
          {:exception, "TypeError: #{Exception.message(e)}"}
      end

    BuiltinResults.handle_builtin_result(result, env, ctx)
  end

  @doc false
  @spec call_builtin_raw((list() -> term()), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          Interpreter.call_result()
  def call_builtin_raw(fun, args, env, ctx) do
    result =
      try do
        fun.(args)
      rescue
        FunctionClauseError ->
          {:exception, "TypeError: invalid arguments"}

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
    derefed_args = Enum.map(args, &Ctx.deep_deref(ctx, &1))
    derefed_kwargs = Map.new(kwargs, fn {k, v} -> {k, Ctx.deep_deref(ctx, v)} end)

    result =
      try do
        fun.(derefed_args, derefed_kwargs)
      rescue
        FunctionClauseError ->
          {:exception, "TypeError: invalid arguments"}

        e in [ArithmeticError, ArgumentError, Enum.EmptyError] ->
          {:exception, "TypeError: #{Exception.message(e)}"}
      end

    BuiltinResults.handle_builtin_kw_result(result, env, ctx)
  end

  @doc false
  @spec call_builtin_kw_raw(
          (list(), %{optional(String.t()) => Interpreter.pyvalue()} -> term()),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: Interpreter.call_result()
  def call_builtin_kw_raw(fun, args, kwargs, env, ctx) do
    result =
      try do
        fun.(args, kwargs)
      rescue
        FunctionClauseError ->
          {:exception, "TypeError: invalid arguments"}

        e in [ArithmeticError, ArgumentError, Enum.EmptyError] ->
          {:exception, "TypeError: #{Exception.message(e)}"}
      end

    BuiltinResults.handle_builtin_kw_result(result, env, ctx)
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
  def call_class({:class, _, _, _} = class, name, args, kwargs, env, ctx) do
    instance = {:instance, class, %{}}

    case ClassLookup.resolve_class_attr_with_owner(class, "__init__") do
      {:ok, {:function, init_name, params, body, closure_env}, defining_class} ->
        call_class_init(
          instance,
          init_name,
          params,
          body,
          closure_env,
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
            {ref, ctx} = Ctx.heap_alloc(ctx, updated_instance)
            {ref, env, ctx}

          {:exception, _} = signal ->
            {signal, env, ctx}
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
      {:ok, {:function, _, _, _, _} = func} ->
        Interpreter.call_function({:bound_method, instance, func}, args, kwargs, env, ctx)

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
        output_buffer: gen_ctx.output_buffer
    }
  end

  @spec call_class_init(
          Interpreter.pyvalue(),
          String.t(),
          [Parser.param()],
          [Parser.ast_node()],
          Env.t(),
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
         defining_class,
         args,
         kwargs,
         env,
         ctx
       ) do
    init_args = [instance | args]

    fresh_closure =
      Env.put_global_scope(closure_env, Env.global_scope(env), Env.global_scope_id(env))

    init_fn = {:function, init_name, params, body, closure_env}
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
              case Env.get(post_call_env, "self") do
                {:ok, {:instance, _, _} = updated} -> updated
                _ -> instance
              end

            {ref, ctx} = Ctx.heap_alloc(ctx, final_self)
            {ref, env, ctx}
        end
    end
  end
end
