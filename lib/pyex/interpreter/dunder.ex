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
    case Ctx.check_step(ctx) do
      {:exceeded, msg} ->
        {:ok, instance, {:exception, msg}, env, ctx}

      {:ok, ctx} ->
        call_dunder_on_class(instance, class, method, args, env, ctx)
    end
  end

  def call_dunder_mut(_, _, _, _, _), do: :not_found

  # ------ private helpers --------------------------------------------------

  defp call_dunder_on_class(instance, class, method, args, env, ctx) do
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
        # Subclasses of builtin types store their underlying value in
        # `__wrapped__`.  Forward dunder calls (`__len__`, `__getitem__`,
        # `__contains__`, `__str__`, ...) to it so `class MyList(list)`
        # behaves list-like out of the box.
        forward_to_wrapped(instance, method, args, env, ctx)
    end
  end

  @spec forward_to_wrapped(
          Interpreter.pyvalue(),
          String.t(),
          [Interpreter.pyvalue()],
          Env.t(),
          Ctx.t()
        ) :: {:ok, Interpreter.pyvalue(), Interpreter.pyvalue(), Env.t(), Ctx.t()} | :not_found
  defp forward_to_wrapped({:instance, _, attrs} = instance, method, args, env, ctx) do
    case Map.fetch(attrs, "__wrapped__") do
      {:ok, wrapped} ->
        case wrapped_dunder(Ctx.deref(ctx, wrapped), method, args) do
          {:ok, value} -> {:ok, instance, value, env, ctx}
          :not_found -> :not_found
        end

      :error ->
        :not_found
    end
  end

  @spec wrapped_dunder(Interpreter.pyvalue(), String.t(), [Interpreter.pyvalue()]) ::
          {:ok, Interpreter.pyvalue()} | :not_found
  defp wrapped_dunder({:py_list, _, len}, "__len__", []), do: {:ok, len}
  defp wrapped_dunder(list, "__len__", []) when is_list(list), do: {:ok, length(list)}
  defp wrapped_dunder({:tuple, items}, "__len__", []), do: {:ok, length(items)}
  defp wrapped_dunder({:py_dict, _, _} = d, "__len__", []), do: {:ok, Pyex.PyDict.size(d)}
  defp wrapped_dunder(m, "__len__", []) when is_map(m), do: {:ok, map_size(m)}
  defp wrapped_dunder({:set, s}, "__len__", []), do: {:ok, MapSet.size(s)}
  defp wrapped_dunder(b, "__len__", []) when is_binary(b), do: {:ok, String.length(b)}

  defp wrapped_dunder({:py_list, rev, _}, "__getitem__", [i]) when is_integer(i) do
    items = Enum.reverse(rev)
    len = length(items)
    idx = if i < 0, do: len + i, else: i

    if idx < 0 or idx >= len,
      do: {:ok, {:exception, "IndexError: list index out of range"}},
      else: {:ok, Enum.at(items, idx)}
  end

  defp wrapped_dunder(items, "__getitem__", [i]) when is_list(items) and is_integer(i) do
    len = length(items)
    idx = if i < 0, do: len + i, else: i

    if idx < 0 or idx >= len,
      do: {:ok, {:exception, "IndexError: list index out of range"}},
      else: {:ok, Enum.at(items, idx)}
  end

  defp wrapped_dunder({:py_dict, _, _} = d, "__getitem__", [k]) do
    case Pyex.PyDict.fetch(d, k) do
      {:ok, v} -> {:ok, v}
      :error -> {:ok, {:exception, "KeyError: #{Pyex.Builtins.py_repr_quoted(k)}"}}
    end
  end

  defp wrapped_dunder({:py_list, rev, _}, "__contains__", [v]) do
    {:ok, v in rev}
  end

  defp wrapped_dunder(items, "__contains__", [v]) when is_list(items), do: {:ok, v in items}

  defp wrapped_dunder({:py_dict, _, _} = d, "__contains__", [k]) do
    {:ok, Pyex.PyDict.has_key?(d, k)}
  end

  defp wrapped_dunder({:set, s}, "__contains__", [v]), do: {:ok, MapSet.member?(s, v)}

  defp wrapped_dunder({:py_list, _, _} = l, "__iter__", []), do: {:ok, l}
  defp wrapped_dunder(items, "__iter__", []) when is_list(items), do: {:ok, items}
  defp wrapped_dunder({:py_dict, _, _} = d, "__iter__", []), do: {:ok, d}
  defp wrapped_dunder({:set, _} = s, "__iter__", []), do: {:ok, s}

  defp wrapped_dunder(val, "__str__", []), do: {:ok, Pyex.Interpreter.Helpers.py_str(val)}
  defp wrapped_dunder(val, "__repr__", []), do: {:ok, Pyex.Builtins.py_repr(val)}

  defp wrapped_dunder(_, _, _), do: :not_found

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
