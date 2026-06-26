defmodule Pyex.Interpreter.Calls do
  @moduledoc """
  Call expression and mutation plumbing for `Pyex.Interpreter`.

  Keeps call-site evaluation and write-back behavior together while the main
  interpreter retains the public dispatch entrypoints.
  """

  alias Pyex.{Ctx, Env, Interpreter, Parser}
  alias Pyex.Interpreter.{Assignments, Helpers}

  @typep eval_result :: {Interpreter.pyvalue() | tuple(), Env.t(), Ctx.t()}

  @typedoc """
  Encodes enough context to write back a mutated receiver after a call
  that was suspended mid-arg-evaluation and later resumed via continuation.

  - `{:var_attr, var_name}` — receiver is a simple variable (`out.append(...)`).
  - `{:getattr_method, raw_receiver, func_expr}` — chained getattr receiver.
  - `{:general_call, func_expr}` — free-function call (setattr, list literal, etc.).
  """
  @type call_site_meta ::
          {:var_attr, String.t()}
          | {:getattr_method, Interpreter.pyvalue(), Parser.ast_node()}
          | {:general_call, Parser.ast_node()}

  @typedoc """
  Where a value belongs in a partially-evaluated argument list.

  - `:pos` — next positional slot.
  - `{:kw, name}` — named keyword.
  - `:star` — `*expr`; the value is expanded as an iterable.
  - `:dstar` — `**expr`; the value is merged into kwargs as a mapping.
  """
  @type arg_slot :: :pos | {:kw, String.t()} | :star | :dstar

  @doc """
  Evaluates a method call rooted at a variable attribute access.
  """
  @spec eval_var_attr_call(Parser.ast_node(), [Parser.ast_node()], String.t(), Env.t(), Ctx.t()) ::
          eval_result()
  def eval_var_attr_call(func_expr, arg_exprs, var_name, env, ctx) do
    case Interpreter.eval(func_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {func, env, ctx} ->
        eval_call_with_yield(func, {:var_attr, var_name}, arg_exprs, env, ctx)
    end
  end

  @doc """
  Evaluates a general call expression.
  """
  @spec eval_call_expr(Parser.ast_node(), [Parser.ast_node()], Env.t(), Ctx.t()) :: eval_result()
  def eval_call_expr(
        {:getattr, _, [receiver_expr, method_name]} = func_expr,
        arg_exprs,
        env,
        ctx
      )
      when not is_tuple(receiver_expr) or elem(receiver_expr, 0) != :var do
    # Two-phase evaluation for method calls on non-variable receivers.
    # We evaluate the receiver separately so that if the method returns
    # {:mutate, new_obj, ret}, we can write new_obj back to the receiver
    # ref (e.g. `d.setdefault("k", []).append(v)` — the list returned by
    # setdefault is a heap ref; append's mutation must update that ref).
    case Interpreter.eval(receiver_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {raw_receiver, env, ctx} ->
        case Interpreter.eval_value_attr(raw_receiver, method_name, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {func, env, ctx} ->
            eval_call_with_yield(
              func,
              {:getattr_method, raw_receiver, func_expr},
              arg_exprs,
              env,
              ctx
            )
        end
    end
  end

  @spec eval_call_expr(Parser.ast_node(), [Parser.ast_node()], Env.t(), Ctx.t()) :: eval_result()
  def eval_call_expr(func_expr, arg_exprs, env, ctx) do
    case Interpreter.eval(func_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {func, env, ctx} ->
        eval_call_with_yield(func, {:general_call, func_expr}, arg_exprs, env, ctx)
    end
  end

  @spec write_back_to_receiver(
          Interpreter.pyvalue(),
          Parser.ast_node(),
          Interpreter.pyvalue(),
          Env.t(),
          Ctx.t()
        ) ::
          {Env.t(), Ctx.t()}
  defp write_back_to_receiver({:ref, id}, _func_expr, new_object, env, ctx) do
    {env, Ctx.heap_put(ctx, id, new_object)}
  end

  defp write_back_to_receiver({:super_proxy, {:ref, id}, _}, _func_expr, new_object, env, ctx) do
    {env, Ctx.heap_put(ctx, id, new_object)}
  end

  defp write_back_to_receiver(_receiver, func_expr, new_object, env, ctx) do
    mutate_target(func_expr, new_object, env, ctx)
  end

  @doc false
  @spec call_method(
          Interpreter.pyvalue(),
          Interpreter.pyvalue(),
          [Interpreter.pyvalue()],
          %{optional(String.t()) => Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: term()
  def call_method(instance, {:function, _, _, _, _, _, _} = func, args, kwargs, env, ctx) do
    method_args = [instance | args]

    case Interpreter.call_function(func, method_args, kwargs, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {result, env, ctx, _updated} ->
        updated_instance = get_mutated_instance(env, instance)
        env = rebind_instance(env, instance, updated_instance)
        {result, env, ctx}

      {result, env, ctx} ->
        updated_instance = get_mutated_instance(env, instance)
        env = rebind_instance(env, instance, updated_instance)
        {result, env, ctx}
    end
  end

  @doc """
  Evaluate `arg_exprs`, then invoke `func`, applying mutation write-back
  according to `call_site_meta`.  Propagates `{:yielded, val, cont}` signals
  from any arg expression upward with a `{:cont_call_resume, ...}` frame so
  that `Interpreter.resume_generator_with_send` can re-enter the evaluation
  loop after the awaited value is available.
  """
  @spec eval_call_with_yield(
          Interpreter.pyvalue(),
          call_site_meta(),
          [Parser.ast_node()],
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  def eval_call_with_yield(func, meta, arg_exprs, env, ctx) do
    eval_remaining_and_call(func, meta, arg_exprs, arg_exprs, [], %{}, env, ctx)
  end

  @doc """
  Resume mid-arg-evaluation: evaluate `remaining` arg exprs, then invoke
  `func` and apply mutation write-back.  When an arg expression yields, the
  rest of the evaluation is suspended as a `{:cont_call_resume, ...}` frame
  that re-enters here once the awaited value lands.
  """
  @spec eval_remaining_and_call(
          Interpreter.pyvalue(),
          call_site_meta(),
          [Parser.ast_node()],
          [Parser.ast_node()],
          [Interpreter.pyvalue()],
          map(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  def eval_remaining_and_call(func, meta, orig_args, remaining, rev_pos, kwargs, env, ctx)

  def eval_remaining_and_call(func, meta, orig_args, [], rev_pos, kwargs, env, ctx) do
    invoke_with_mutation(func, meta, orig_args, Enum.reverse(rev_pos), kwargs, env, ctx)
  end

  def eval_remaining_and_call(func, meta, orig_args, [head | rest], rev_pos, kwargs, env, ctx) do
    {expr, slot} = arg_expr_and_slot(head)

    case Interpreter.eval(expr, env, ctx) do
      {{:exception, _} = sig, env, ctx} ->
        {sig, env, ctx}

      {{:yielded, val, cont}, env, ctx} ->
        frame = {:cont_call_resume, func, meta, orig_args, rev_pos, rest, kwargs, slot}
        {{:yielded, val, cont ++ [frame]}, env, ctx}

      {value, env, ctx} ->
        case incorporate_value(slot, value, rev_pos, kwargs, env, ctx) do
          {:ok, new_rev_pos, new_kwargs, env, ctx} ->
            eval_remaining_and_call(
              func,
              meta,
              orig_args,
              rest,
              new_rev_pos,
              new_kwargs,
              env,
              ctx
            )

          {:error, signal, env, ctx} ->
            {signal, env, ctx}
        end
    end
  end

  @spec arg_expr_and_slot(Parser.ast_node()) :: {Parser.ast_node(), arg_slot()}
  defp arg_expr_and_slot({:kwarg, _, [name, expr]}), do: {expr, {:kw, name}}
  defp arg_expr_and_slot({:star_arg, _, [expr]}), do: {expr, :star}
  defp arg_expr_and_slot({:double_star_arg, _, [expr]}), do: {expr, :dstar}
  defp arg_expr_and_slot(expr), do: {expr, :pos}

  @doc """
  Fold `value` into the accumulating argument state at `slot`.  Shared between
  forward evaluation and the `:cont_call_resume` resume path so both honor the
  same slot semantics (positional append, kwarg put, `*` expansion, `**` merge).
  """
  @spec incorporate_value(
          arg_slot(),
          Interpreter.pyvalue(),
          [Interpreter.pyvalue()],
          map(),
          Env.t(),
          Ctx.t()
        ) ::
          {:ok, [Interpreter.pyvalue()], map(), Env.t(), Ctx.t()}
          | {:error, {:exception, String.t()}, Env.t(), Ctx.t()}
  def incorporate_value(:pos, value, rev_pos, kwargs, env, ctx) do
    {:ok, [value | rev_pos], kwargs, env, ctx}
  end

  def incorporate_value({:kw, name}, value, rev_pos, kwargs, env, ctx) do
    {:ok, rev_pos, Map.put(kwargs, name, value), env, ctx}
  end

  def incorporate_value(:star, value, rev_pos, kwargs, env, ctx) do
    case Interpreter.to_iterable(value, env, ctx) do
      {:ok, items, env, ctx} ->
        {:ok, Enum.reverse(items) ++ rev_pos, kwargs, env, ctx}

      {:exception, msg} ->
        {:error, {:exception, msg}, env, ctx}
    end
  end

  def incorporate_value(:dstar, raw_value, rev_pos, kwargs, env, ctx) do
    value = Ctx.deref(ctx, raw_value)

    case merge_dstar(value, kwargs) do
      {:ok, merged} ->
        {:ok, rev_pos, merged, env, ctx}

      :error ->
        {:error,
         {:exception,
          "TypeError: argument after ** must be a mapping, not '#{Helpers.py_type(value)}'"}, env,
         ctx}
    end
  end

  defp merge_dstar({:py_dict, _, _} = dict, kwargs) do
    merged =
      Enum.reduce(Pyex.PyDict.items(dict), kwargs, fn {k, v}, acc ->
        Map.put(acc, to_string(k), v)
      end)

    {:ok, merged}
  end

  defp merge_dstar(map, kwargs) when is_map(map) do
    {:ok, Enum.reduce(map, kwargs, fn {k, v}, acc -> Map.put(acc, to_string(k), v) end)}
  end

  defp merge_dstar(_, _), do: :error

  defp invoke_with_mutation(func, meta, orig_arg_exprs, args, kwargs, env, ctx) do
    case Interpreter.call_function(func, args, kwargs, env, ctx) do
      {:mutate, new_object, return_value, new_env, ctx} ->
        {new_env, ctx} = apply_mutate(meta, orig_arg_exprs, new_object, new_env, ctx)
        {return_value, new_env, ctx}

      {:mutate_arg, index, new_object, return_value, new_env, ctx} ->
        {new_env, ctx} = mutate_target(Enum.at(orig_arg_exprs, index), new_object, new_env, ctx)
        {return_value, new_env, ctx}

      {:mutate, new_object, return_value, ctx} ->
        {env, ctx} = apply_mutate(meta, orig_arg_exprs, new_object, env, ctx)
        {return_value, env, ctx}

      {:mutate_arg, index, new_object, return_value, ctx} ->
        {env, ctx} = mutate_target(Enum.at(orig_arg_exprs, index), new_object, env, ctx)
        {return_value, env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {result, env, ctx, updated_func} ->
        {env, ctx} = apply_updated_func(meta, func, updated_func, env, ctx)
        {result, env, ctx}

      {result, env, ctx} ->
        {env, ctx} = apply_post_call(meta, env, ctx)
        {result, env, ctx}
    end
  end

  defp apply_mutate({:var_attr, var_name}, _orig_args, new_object, env, ctx) do
    case Env.get(env, var_name) do
      {:ok, {:ref, id}} -> {env, Ctx.heap_put(ctx, id, new_object)}
      _ -> {Env.put_at_source(env, var_name, new_object), ctx}
    end
  end

  defp apply_mutate({:getattr_method, raw_receiver, func_expr}, _orig_args, new_object, env, ctx) do
    write_back_to_receiver(raw_receiver, func_expr, new_object, env, ctx)
  end

  defp apply_mutate({:general_call, func_expr}, orig_arg_exprs, new_object, env, ctx) do
    target = mutate_target_expr(func_expr, orig_arg_exprs)
    mutate_target(target, new_object, env, ctx)
  end

  defp apply_updated_func({:var_attr, var_name}, _func, _updated, env, ctx) do
    {maybe_update_instance_var(env, var_name), ctx}
  end

  defp apply_updated_func({:getattr_method, _receiver, func_expr}, _func, updated_func, env, ctx) do
    {Helpers.rebind_var(env, func_expr, updated_func), ctx}
  end

  defp apply_updated_func({:general_call, func_expr}, _func, updated_func, env, ctx) do
    {Helpers.rebind_var(env, func_expr, updated_func), ctx}
  end

  defp apply_post_call({:var_attr, var_name}, env, ctx) do
    {maybe_update_instance_var(env, var_name), ctx}
  end

  defp apply_post_call(_meta, env, ctx), do: {env, ctx}

  @spec mutate_target_expr(Parser.ast_node(), [Parser.ast_node()]) :: Parser.ast_node()
  defp mutate_target_expr({:var, _, ["setattr"]}, [first_arg | _]), do: first_arg
  defp mutate_target_expr(func_expr, _arg_exprs), do: func_expr

  @spec mutate_target(Parser.ast_node(), Interpreter.pyvalue(), Env.t(), Ctx.t()) ::
          {Env.t(), Ctx.t()}
  defp mutate_target({:getattr, _, [{:var, _, [var_name]}, attr]}, new_object, env, ctx) do
    case Env.get(env, var_name) do
      {:ok, owner} ->
        case Ctx.deref(ctx, owner) do
          {:instance, class, attrs} ->
            case Map.get(attrs, attr) do
              {:ref, id} ->
                {env, Ctx.heap_put(ctx, id, new_object)}

              _ ->
                updated = {:instance, class, Map.put(attrs, attr, new_object)}

                case owner do
                  {:ref, owner_id} -> {env, Ctx.heap_put(ctx, owner_id, updated)}
                  _ -> {Env.put_at_source(env, var_name, updated), ctx}
                end
            end

          {:module, mod_name, attrs} ->
            updated = {:module, mod_name, Map.put(attrs, attr, new_object)}
            {Env.put_at_source(env, var_name, updated), ctx}

          _ ->
            {Env.smart_put(env, var_name, new_object), ctx}
        end

      _ ->
        {env, ctx}
    end
  end

  defp mutate_target(
         {:getattr, _, [{:getattr, _, [{:var, _, [var_name]}, attr]}, _method]},
         new_object,
         env,
         ctx
       ) do
    case Env.get(env, var_name) do
      {:ok, owner} ->
        case Ctx.deref(ctx, owner) do
          {:instance, _class, attrs} ->
            case Map.get(attrs, attr) do
              {:ref, id} ->
                {env, Ctx.heap_put(ctx, id, new_object)}

              _ ->
                updated_setattr = {:getattr, [], [{:var, [], [var_name]}, attr]}

                case Assignments.setattr(updated_setattr, new_object, env, ctx) do
                  {_, env, ctx} -> {env, ctx}
                end
            end

          _ ->
            case Assignments.setattr(
                   {:getattr, [], [{:var, [], [var_name]}, attr]},
                   new_object,
                   env,
                   ctx
                 ) do
              {_, env, ctx} -> {env, ctx}
            end
        end

      _ ->
        {env, ctx}
    end
  end

  defp mutate_target(
         {:getattr, _, [{:getattr, _, _} = inner_target, _method]},
         new_object,
         env,
         ctx
       ) do
    case Assignments.setattr(inner_target, new_object, env, ctx) do
      {_, env, ctx} -> {env, ctx}
    end
  end

  defp mutate_target({:getattr, _, [{:call, _, _}, _method]}, new_object, env, ctx) do
    {Env.smart_put(env, "self", new_object), ctx}
  end

  defp mutate_target(
         {:getattr, _, [{:subscript, _, [container_expr, key_expr]}, _method]},
         new_object,
         env,
         ctx
       ) do
    {raw_container, env, ctx} = Interpreter.eval(container_expr, env, ctx)
    container = Ctx.deref(ctx, raw_container)
    {key, env, ctx} = Interpreter.eval(key_expr, env, ctx)

    case Assignments.get_subscript_value(container, key) do
      {:ref, inner_id} ->
        {env, Ctx.heap_put(ctx, inner_id, new_object)}

      _ ->
        new_container = Assignments.set_subscript_value(container, key, new_object)
        mutate_target(container_expr, new_container, env, ctx)
    end
  end

  defp mutate_target({:var, _, [var_name]}, new_object, env, ctx) do
    case Env.get(env, var_name) do
      {:ok, {:ref, id}} -> {env, Ctx.heap_put(ctx, id, new_object)}
      _ -> {Env.smart_put(env, var_name, new_object), ctx}
    end
  end

  # `container[index].mutating_method()` — write `new_object` into
  # `container[index]`, then propagate the updated container up the chain.
  # (The old version dropped `index` and wrote `new_object` straight to the
  # outer container, corrupting nested `d[a][b].add(...)` writes.)
  defp mutate_target({:subscript, _, [expr, index_expr]}, new_object, env, ctx) do
    {raw_container, env, ctx} = Interpreter.eval(expr, env, ctx)
    container = Ctx.deref(ctx, raw_container)
    {index, env, ctx} = Interpreter.eval(index_expr, env, ctx)
    updated = Assignments.set_subscript_value(container, index, new_object)

    case raw_container do
      {:ref, id} -> {env, Ctx.heap_put(ctx, id, updated)}
      _ -> mutate_target(expr, updated, env, ctx)
    end
  end

  defp mutate_target(_other, _new_object, env, ctx) do
    {env, ctx}
  end

  @spec get_mutated_instance(Env.t(), Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp get_mutated_instance(env, {:instance, _, _} = original) do
    case Env.get(env, "self") do
      {:ok, {:instance, _, _} = updated} -> updated
      _ -> original
    end
  end

  @spec rebind_instance(Env.t(), Interpreter.pyvalue(), Interpreter.pyvalue()) :: Env.t()
  defp rebind_instance(env, _old, new) do
    case Env.get(env, "self") do
      {:ok, {:instance, _, _}} -> Env.smart_put(env, "self", new)
      _ -> env
    end
  end

  @spec maybe_update_instance_var(Env.t(), String.t()) :: Env.t()
  defp maybe_update_instance_var(env, var_name) do
    case Env.get(env, var_name) do
      {:ok, {:instance, _, _}} ->
        case Env.get(env, "self") do
          {:ok, {:instance, _, _} = updated_self} -> Env.smart_put(env, var_name, updated_self)
          _ -> env
        end

      _ ->
        env
    end
  end
end
