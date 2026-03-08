defmodule Pyex.Interpreter.Dunder do
  @moduledoc """
  Dunder-method dispatch for `Pyex.Interpreter`.

  Keeps instance and file-handle special method lookup separate from the main
  evaluator while preserving the interpreter's existing call semantics.
  """

  alias Pyex.{Ctx, Env, Interpreter}
  alias Pyex.Interpreter.ClassLookup

  @doc false
  @spec call_dunder(Interpreter.pyvalue(), String.t(), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          {:ok, Interpreter.pyvalue(), Env.t(), Ctx.t()} | :not_found
  def call_dunder(instance, method, args, env, ctx) do
    case call_dunder_mut(instance, method, args, env, ctx) do
      {:ok, _new_obj, return_val, env, ctx} -> {:ok, return_val, env, ctx}
      :not_found -> :not_found
    end
  end

  @doc false
  @spec call_dunder_mut(
          Interpreter.pyvalue(),
          String.t(),
          [Interpreter.pyvalue()],
          Env.t(),
          Ctx.t()
        ) :: {:ok, Interpreter.pyvalue(), Interpreter.pyvalue(), Env.t(), Ctx.t()} | :not_found
  def call_dunder_mut(
        {:instance, {:class, _, _, _} = class, _} = instance,
        method,
        args,
        env,
        ctx
      ) do
    case ClassLookup.resolve_class_attr(class, method) do
      {:ok, {:function, _, _, _, _} = func} ->
        case Interpreter.call_function({:bound_method, instance, func}, args, %{}, env, ctx) do
          {:mutate, new_obj, return_val, new_env, ctx} ->
            {:ok, new_obj, return_val, new_env, ctx}

          {{:exception, _} = signal, env, ctx} ->
            {:ok, instance, signal, env, ctx}
        end

      {:ok, {:builtin, fun}} ->
        case Interpreter.call_function({:builtin, fun}, [instance | args], %{}, env, ctx) do
          {:mutate, new_obj, return_val, ctx} ->
            {:ok, new_obj, return_val, env, ctx}

          {{:exception, _} = signal, env, ctx} ->
            {:ok, instance, signal, env, ctx}

          {return_val, env, ctx} ->
            {:ok, instance, return_val, env, ctx}
        end

      _ ->
        :not_found
    end
  end

  def call_dunder_mut({:file_handle, _id} = handle, "__enter__", [], env, ctx) do
    {:ok, handle, handle, env, ctx}
  end

  def call_dunder_mut({:file_handle, id} = handle, "__exit__", _args, env, ctx) do
    case Ctx.close_handle(ctx, id) do
      {:ok, ctx} -> {:ok, handle, nil, env, ctx}
      {:error, _} -> {:ok, handle, nil, env, ctx}
    end
  end

  def call_dunder_mut(_, _, _, _, _), do: :not_found
end
