defmodule Pyex.Interpreter.Iterables do
  @moduledoc """
  Iterable and iterator protocol helpers for `Pyex.Interpreter`.

  Keeps iterable coercion, iterator draining, and instance-backed iterator state
  updates separate from the main evaluator.
  """

  alias Pyex.{Builtins, Ctx, Env, Interpreter, PyDict}
  alias Pyex.Interpreter.{Dunder, Helpers}

  @doc false
  @spec to_iterable(Interpreter.pyvalue(), Env.t(), Ctx.t()) ::
          {:ok, [Interpreter.pyvalue()], Env.t(), Ctx.t()} | {:exception, String.t()}
  def to_iterable({:ref, _} = ref, env, ctx) do
    to_iterable(Ctx.deref(ctx, ref), env, ctx)
  end

  def to_iterable({:py_list, reversed, _len}, env, ctx),
    do: {:ok, Enum.reverse(reversed), env, ctx}

  def to_iterable(list, env, ctx) when is_list(list), do: {:ok, list, env, ctx}
  def to_iterable(str, env, ctx) when is_binary(str), do: {:ok, String.codepoints(str), env, ctx}

  def to_iterable({:py_dict, _, _} = dict, env, ctx) do
    {:ok, PyDict.keys(Builtins.visible_dict(dict)), env, ctx}
  end

  def to_iterable(map, env, ctx) when is_map(map),
    do: {:ok, map |> Builtins.visible_dict() |> Map.keys(), env, ctx}

  def to_iterable({:tuple, elements}, env, ctx), do: {:ok, elements, env, ctx}
  def to_iterable({:set, set}, env, ctx), do: {:ok, MapSet.to_list(set), env, ctx}
  def to_iterable({:frozenset, set}, env, ctx), do: {:ok, MapSet.to_list(set), env, ctx}

  # Iterating bytes/bytearray yields its integer byte values, as in CPython.
  def to_iterable({:bytes, bin}, env, ctx), do: {:ok, :binary.bin_to_list(bin), env, ctx}
  def to_iterable({:bytearray, bin}, env, ctx), do: {:ok, :binary.bin_to_list(bin), env, ctx}

  def to_iterable({:range, _, _, _} = range, env, ctx) do
    case Builtins.range_to_list(range) do
      {:exception, _} = err -> err
      list -> {:ok, list, env, ctx}
    end
  end

  def to_iterable({:deque, _, _, _, _} = d, env, ctx),
    do: {:ok, Pyex.Methods.deque_to_list(d), env, ctx}

  def to_iterable({:generator, items}, env, ctx), do: {:ok, items, env, ctx}

  # Iterating an enum class yields its members in definition order.
  def to_iterable({:class, _, _, %{"__enum_members__" => members}}, env, ctx) do
    {:ok, Enum.map(members, fn {_n, inst} -> inst end), env, ctx}
  end

  def to_iterable({:generator_error, items, _msg}, env, ctx), do: {:ok, items, env, ctx}

  # Iterating a file handle yields its remaining lines, each preserving
  # its trailing newline, advancing the handle to EOF.
  def to_iterable({:file_handle, id}, env, ctx) do
    case Ctx.readlines_handle(ctx, id) do
      {:ok, lines, ctx} -> {:ok, lines, env, ctx}
      {:error, msg} -> {:exception, msg}
    end
  end

  def to_iterable({:iterator, id}, env, ctx) do
    case Ctx.iter_entry(ctx, id) do
      {:gen_pending, _val, _cont, _gen_env} ->
        drain_generator_iter(id, env, ctx)

      :gen_done ->
        {:ok, [], env, ctx}

      _ ->
        {:ok, Ctx.iter_items(ctx, id), env, ctx}
    end
  end

  def to_iterable({:generator_suspended, val, cont, gen_env}, env, ctx) do
    # An unbound suspended generator (legacy `:defer` mode result, or
    # a generator passed through internal paths). Drain by stepping
    # `resume_generator` until done. Used by materialisers like
    # `list(gen())`.
    drain_generator(val, cont, gen_env, [val], env, ctx)
  end

  def to_iterable({:instance, _, attrs} = inst, env, ctx) do
    case Dunder.call_dunder(inst, "__iter__", [], env, ctx) do
      {:ok, raw_result, env, ctx} ->
        result = Ctx.deref(ctx, raw_result)

        case result do
          {:exception, _} = signal ->
            signal

          {:instance, _, _} = iter ->
            drain_iterator(iter, [], env, ctx)

          other ->
            to_iterable(other, env, ctx)
        end

      :not_found ->
        # Subclasses of builtin types (`class MyList(list)`) carry their
        # underlying value in `__wrapped__`.  Fall back to iterating it.
        case Map.fetch(attrs, "__wrapped__") do
          {:ok, wrapped} -> to_iterable(Ctx.deref(ctx, wrapped), env, ctx)
          :error -> {:exception, "TypeError: '#{Helpers.py_type(inst)}' object is not iterable"}
        end
    end
  end

  def to_iterable(val, _env, _ctx) do
    {:exception, "TypeError: '#{Helpers.py_type(val)}' object is not iterable"}
  end

  @doc false
  @spec drain_generator_iter(non_neg_integer(), Env.t(), Ctx.t()) ::
          {:ok, [Interpreter.pyvalue()], Env.t(), Ctx.t()} | {:exception, String.t()}
  def drain_generator_iter(id, env, ctx) do
    case Ctx.iter_entry(ctx, id) do
      {:gen_pending, val, cont, gen_env} ->
        ctx = Ctx.mark_iter_exhausted(ctx, id)
        drain_generator(val, cont, gen_env, [val], env, ctx)

      :gen_done ->
        {:ok, [], env, ctx}

      nil ->
        {:ok, [], env, ctx}
    end
  end

  @spec drain_generator(
          Interpreter.pyvalue(),
          [term()],
          Env.t(),
          [Interpreter.pyvalue()],
          Env.t(),
          Ctx.t()
        ) :: {:ok, [Interpreter.pyvalue()], Env.t(), Ctx.t()} | {:exception, String.t()}
  defp drain_generator(_first_val, cont, gen_env, acc, env, ctx) do
    # Resume must run with `:defer_inner` so internal `yield` reaches
    # its proper handler. The outer mode is restored after.
    saved_mode = ctx.generator_mode
    inner_ctx = %{ctx | generator_mode: :defer_inner}

    case Interpreter.resume_generator(cont, gen_env, inner_ctx) do
      {{:yielded, val, next_cont}, next_env, ctx} ->
        drain_generator(val, next_cont, next_env, [val | acc], env, ctx)

      {done, _gen_env, ctx} when done == :done or elem(done, 0) == :done_with_value ->
        # Plain `:done` and `{:done_with_value, _}` both terminate
        # the drain.  The return value is preserved on the iterator
        # entry by the caller; this drain just collects yields.
        ctx = %{ctx | generator_mode: saved_mode}
        {:ok, Enum.reverse(acc), env, ctx}

      {{:exception, _} = signal, _gen_env, _ctx} ->
        signal
    end
  end

  @doc false
  @spec eval_instance_next(
          Interpreter.pyvalue(),
          non_neg_integer(),
          :no_default | {:default, Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: {Interpreter.pyvalue() | tuple(), Env.t(), Ctx.t()}
  def eval_instance_next(inst, id, default_opt, env, ctx) do
    case Dunder.call_dunder_mut(inst, "__next__", [], env, ctx) do
      {:ok, _new_inst, {:exception, "StopIteration" <> _}, env, ctx} ->
        ctx = Ctx.delete_iterator(ctx, id)

        case default_opt do
          {:default, default} -> {default, env, ctx}
          :no_default -> {{:exception, "StopIteration"}, env, ctx}
        end

      {:ok, _new_inst, {:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {:ok, new_inst, value, env, ctx} ->
        ctx = Ctx.update_instance_iterator(ctx, id, new_inst)
        {value, env, ctx}

      :not_found ->
        {{:exception, "TypeError: object has no __next__"}, env, ctx}
    end
  end

  @spec drain_iterator(Interpreter.pyvalue(), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          {:ok, [Interpreter.pyvalue()], Env.t(), Ctx.t()} | {:exception, String.t()}
  defp drain_iterator(iter, acc, env, ctx) do
    case Dunder.call_dunder_mut(iter, "__next__", [], env, ctx) do
      {:ok, new_iter, {:exception, "StopIteration" <> _}, env, ctx} ->
        _ = new_iter
        {:ok, Enum.reverse(acc), env, ctx}

      {:ok, _new_iter, {:exception, _} = signal, _env, _ctx} ->
        signal

      {:ok, new_iter, value, env, ctx} ->
        drain_iterator(new_iter, [value | acc], env, ctx)

      :not_found ->
        {:exception, "TypeError: '#{Helpers.py_type(iter)}' object is not an iterator"}
    end
  end
end
