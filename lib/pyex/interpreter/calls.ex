defmodule Pyex.Interpreter.Calls do
  @moduledoc """
  Call expression and mutation plumbing for `Pyex.Interpreter`.

  Keeps call-site evaluation and write-back behavior together while the main
  interpreter retains the public dispatch entrypoints.
  """

  alias Pyex.{Ctx, Env, Interpreter, Parser}
  alias Pyex.Interpreter.{Assignments, Helpers}

  @typep eval_result :: {Interpreter.pyvalue() | tuple(), Env.t(), Ctx.t()}

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
        case Interpreter.eval_call_args(arg_exprs, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {args, kwargs, env, ctx} ->
            case Interpreter.call_function(func, args, kwargs, env, ctx) do
              {:mutate, new_object, return_value, new_env, ctx} ->
                case Env.get(new_env, var_name) do
                  {:ok, {:ref, id}} -> {return_value, new_env, Ctx.heap_put(ctx, id, new_object)}
                  _ -> {return_value, Env.put_at_source(new_env, var_name, new_object), ctx}
                end

              {:mutate_arg, index, new_object, return_value, new_env, ctx} ->
                {new_env, ctx} =
                  mutate_target(Enum.at(arg_exprs, index), new_object, new_env, ctx)

                {return_value, new_env, ctx}

              {:mutate, new_object, return_value, ctx} ->
                case Env.get(env, var_name) do
                  {:ok, {:ref, id}} -> {return_value, env, Ctx.heap_put(ctx, id, new_object)}
                  _ -> {return_value, Env.put_at_source(env, var_name, new_object), ctx}
                end

              {:mutate_arg, index, new_object, return_value, ctx} ->
                {env, ctx} = mutate_target(Enum.at(arg_exprs, index), new_object, env, ctx)
                {return_value, env, ctx}

              {{:exception, _} = signal, env, ctx} ->
                {signal, env, ctx}

              {result, env, ctx, _updated_func} ->
                env = maybe_update_instance_var(env, var_name)
                {result, env, ctx}

              {result, env, ctx} ->
                env = maybe_update_instance_var(env, var_name)
                {result, env, ctx}
            end
        end
    end
  end

  @doc """
  Evaluates a general call expression.
  """
  @spec eval_call_expr(Parser.ast_node(), [Parser.ast_node()], Env.t(), Ctx.t()) :: eval_result()
  def eval_call_expr(func_expr, arg_exprs, env, ctx) do
    case Interpreter.eval(func_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {func, env, ctx} ->
        case Interpreter.eval_call_args(arg_exprs, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {args, kwargs, env, ctx} ->
            case Interpreter.call_function(func, args, kwargs, env, ctx) do
              {:mutate, new_object, return_value, new_env, ctx} ->
                target = mutate_target_expr(func_expr, arg_exprs)
                {new_env, ctx} = mutate_target(target, new_object, new_env, ctx)
                {return_value, new_env, ctx}

              {:mutate_arg, index, new_object, return_value, new_env, ctx} ->
                {new_env, ctx} =
                  mutate_target(Enum.at(arg_exprs, index), new_object, new_env, ctx)

                {return_value, new_env, ctx}

              {:mutate, new_object, return_value, ctx} ->
                target = mutate_target_expr(func_expr, arg_exprs)
                {env, ctx} = mutate_target(target, new_object, env, ctx)
                {return_value, env, ctx}

              {:mutate_arg, index, new_object, return_value, ctx} ->
                {env, ctx} = mutate_target(Enum.at(arg_exprs, index), new_object, env, ctx)
                {return_value, env, ctx}

              {{:exception, _} = signal, env, ctx} ->
                {signal, env, ctx}

              {result, env, ctx, updated_func} ->
                env = Helpers.rebind_var(env, func_expr, updated_func)
                {result, env, ctx}

              {result, env, ctx} ->
                {result, env, ctx}
            end
        end
    end
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
  def call_method(instance, {:function, _, _, _, _} = func, args, kwargs, env, ctx) do
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

  defp mutate_target({:subscript, _, [expr, _index]}, new_object, env, ctx) do
    mutate_target(expr, new_object, env, ctx)
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
