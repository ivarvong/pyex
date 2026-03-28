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
  def call_dunder_mut({:ref, _} = ref, method, args, env, ctx) do
    call_dunder_mut(Ctx.deref(ctx, ref), method, args, env, ctx)
  end

  # StringIO context manager support
  def call_dunder_mut({:stringio, _} = sio, "__enter__", [], env, ctx) do
    {:ok, sio, sio, env, ctx}
  end

  def call_dunder_mut({:stringio, _} = sio, "__exit__", _args, env, ctx) do
    {:ok, sio, false, env, ctx}
  end

  # _GeneratorContextManager needs special dispatch before the general instance clause
  # so that the generator-based __enter__/__exit__ are used.

  def call_dunder_mut(
        {:instance, {:class, "_GeneratorContextManager", _, _}, _} = inst,
        method,
        args,
        env,
        ctx
      )
      when method in ["__enter__", "__exit__"] do
    call_dunder_mut_generator_cm(inst, method, args, env, ctx)
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

  def call_dunder_mut(_, _, _, _, _), do: :not_found

  # ------ private helpers --------------------------------------------------

  @spec call_dunder_mut_generator_cm(
          Interpreter.pyvalue(),
          String.t(),
          [Interpreter.pyvalue()],
          Env.t(),
          Ctx.t()
        ) :: {:ok, Interpreter.pyvalue(), Interpreter.pyvalue(), Env.t(), Ctx.t()} | :not_found
  defp call_dunder_mut_generator_cm(
         {:instance, _, inst_attrs} = inst,
         "__enter__",
         [],
         env,
         ctx
       ) do
    gen = Map.get(inst_attrs, "__gen__")

    case run_generator_to_next(gen, env, ctx) do
      {:yielded, value, suspended_gen, env, ctx} ->
        new_inst = put_elem(inst, 2, Map.put(inst_attrs, "__gen__", suspended_gen))
        {:ok, new_inst, value, env, ctx}

      {:done, env, ctx} ->
        {:ok, inst, nil, env, ctx}

      {{:exception, _} = exc, env, ctx} ->
        {exc, env, ctx}
    end
  end

  defp call_dunder_mut_generator_cm(
         {:instance, _, inst_attrs} = inst,
         "__exit__",
         _args,
         env,
         ctx
       ) do
    gen = Map.get(inst_attrs, "__gen__")

    case run_generator_to_next(gen, env, ctx) do
      {:yielded, _value, _suspended_gen, env, ctx} ->
        {:ok, inst, false, env, ctx}

      {:done, env, ctx} ->
        {:ok, inst, false, env, ctx}

      {{:exception, msg}, env, ctx} when is_binary(msg) ->
        if String.starts_with?(msg, "StopIteration") do
          {:ok, inst, false, env, ctx}
        else
          {{:exception, msg}, env, ctx}
        end
    end
  end

  @typep gen_result ::
           {:yielded, Interpreter.pyvalue(), Interpreter.pyvalue(), Env.t(), Ctx.t()}
           | {:done, Env.t(), Ctx.t()}
           | {{:exception, String.t()}, Env.t(), Ctx.t()}

  @spec run_generator_to_next(Interpreter.pyvalue(), Env.t(), Ctx.t()) :: gen_result()
  defp run_generator_to_next({:generator, [value | rest]}, env, ctx) do
    {:yielded, value, {:generator, rest}, env, ctx}
  end

  defp run_generator_to_next({:generator, []}, env, ctx) do
    {:done, env, ctx}
  end

  defp run_generator_to_next({:generator_suspended, value, continuation, gen_env}, env, ctx) do
    # The generator has already yielded `value` and is paused at the yield point.
    # Return value as-is; save the continuation for the next advance (__exit__).
    {:yielded, value, {:generator_suspended_waiting, continuation, gen_env}, env, ctx}
  end

  defp run_generator_to_next({:generator_suspended_waiting, continuation, gen_env}, env, ctx) do
    # __exit__: advance past the saved yield point to run cleanup code
    case Interpreter.resume_generator(continuation, gen_env, ctx) do
      {:done, _gen_env, ctx} ->
        {:done, env, ctx}

      {:yielded, _next_val, _next_cont, _next_gen_env, ctx} ->
        {:done, env, ctx}

      {{:exception, _} = exc, _gen_env, ctx} ->
        {exc, env, ctx}
    end
  end

  defp run_generator_to_next({:function, _, _, _, _} = func, env, ctx) do
    # Execute the generator function in defer mode to get first yield
    ctx_defer = %{ctx | generator_mode: :defer}

    case Interpreter.call_function(func, [], %{}, env, ctx_defer) do
      {{:exception, _} = exc, env, ctx} ->
        {exc, env, ctx}

      {result, env, ctx, _} ->
        ctx = %{ctx | generator_mode: nil}
        run_generator_to_next(result, env, ctx)

      {result, env, ctx} ->
        ctx = %{ctx | generator_mode: nil}
        run_generator_to_next(result, env, ctx)
    end
  end

  defp run_generator_to_next(_, env, ctx), do: {:done, env, ctx}
end
