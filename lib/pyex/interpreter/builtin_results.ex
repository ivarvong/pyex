defmodule Pyex.Interpreter.BuiltinResults do
  @moduledoc """
  Builtin call result dispatch helpers for `Pyex.Interpreter`.

  Keeps the large result-shape branching for builtin and builtin_kw calls
  separate from callable dispatch.
  """

  alias Pyex.{Builtins, Ctx, Env, Interpreter}
  alias Pyex.Interpreter.{Calls, Dunder, Helpers, Iteration, Unittest}

  @typep eval_result :: {Interpreter.pyvalue() | tuple(), Env.t(), Ctx.t()}

  @doc false
  @spec handle_builtin_result(term(), Env.t(), Ctx.t()) :: term()
  def handle_builtin_result(result, env, ctx) do
    case result do
      {:ctx_call, ctx_fun} ->
        ctx_fun.(env, ctx)

      {:io_call, io_fun} ->
        ctx = Ctx.pause_compute(ctx)
        {result, env, ctx} = io_fun.(env, ctx)
        ctx = Ctx.resume_compute(ctx)
        {result, env, ctx}

      {:mutate, new_object, return_value} ->
        {:mutate, new_object, return_value, ctx}

      {:mutate_arg, index, new_object, return_value} ->
        {:mutate_arg, index, new_object, return_value, ctx}

      {:method_call, instance, func, method_args} ->
        Calls.call_method(instance, func, method_args, %{}, env, ctx)

      {:dunder_call, instance, dunder_name, dunder_args} ->
        case Dunder.call_dunder(instance, dunder_name, dunder_args, env, ctx) do
          {:ok, value, env, ctx} ->
            {value, env, ctx}

          :not_found ->
            case Interpreter.dunder_str_fallback(instance, dunder_name, env, ctx) do
              {:ok, value, env, ctx} -> {value, env, ctx}
              :error -> {{:exception, "TypeError: object has no #{dunder_name}"}, env, ctx}
            end
        end

      {:iter_to_list, val} ->
        iter_to_collection(val, &Function.identity/1, env, ctx)

      {:iter_to_tuple, val} ->
        iter_to_collection(val, &{:tuple, &1}, env, ctx)

      {:iter_to_set, val} ->
        iter_to_collection(val, &{:set, MapSet.new(&1)}, env, ctx)

      {:iter_to_frozenset, val} ->
        iter_to_collection(val, &{:frozenset, MapSet.new(&1)}, env, ctx)

      {:iter_instance, inst} ->
        handle_iter_instance(inst, env, ctx)

      {:make_iter, items} ->
        {token, ctx} = Ctx.new_iterator(ctx, items)
        {token, env, ctx}

      {:iter_next, id} ->
        case Ctx.iter_next(ctx, id) do
          {:ok, item, ctx} -> {item, env, ctx}
          :exhausted -> {{:exception, "StopIteration"}, env, ctx}
          {:instance, inst} -> Interpreter.eval_instance_next(inst, id, :no_default, env, ctx)
        end

      {:iter_next_default, id, default} ->
        case Ctx.iter_next(ctx, id) do
          {:ok, item, ctx} ->
            {item, env, ctx}

          :exhausted ->
            {default, env, ctx}

          {:instance, inst} ->
            Interpreter.eval_instance_next(inst, id, {:default, default}, env, ctx)
        end

      {:next_instance_iter, id, default_opt} ->
        case Ctx.iter_next(ctx, id) do
          {:instance, inst} ->
            Interpreter.eval_instance_next(inst, id, default_opt, env, ctx)

          {:ok, item, ctx} ->
            {item, env, ctx}

          :exhausted ->
            case default_opt do
              {:default, default} -> {default, env, ctx}
              :no_default -> {{:exception, "StopIteration"}, env, ctx}
            end
        end

      {:next_with_default, inst, default} ->
        case Dunder.call_dunder_mut(inst, "__next__", [], env, ctx) do
          {:ok, _new_inst, {:exception, "StopIteration" <> _}, env, ctx} ->
            {default, env, ctx}

          {:ok, _new_inst, {:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {:ok, _new_inst, value, env, ctx} ->
            {value, env, ctx}

          :not_found ->
            {{:exception, "TypeError: object has no __next__"}, env, ctx}
        end

      {:iter_sum, val} ->
        case Interpreter.to_iterable(val, env, ctx) do
          {:ok, items, env, ctx} ->
            if Enum.all?(items, &is_number/1) do
              {Enum.sum(items), env, ctx}
            else
              {{:exception,
                "TypeError: unsupported operand type(s) for +: sum() requires numeric items"},
               env, ctx}
            end

          {:exception, _} = signal ->
            {signal, env, ctx}
        end

      {:print_call, print_args, sep, end_str} ->
        Interpreter.eval_print_call(print_args, sep, end_str, env, ctx)

      {:map_call, func, list} ->
        Iteration.eval_map_call(func, list, env, ctx)

      {:filter_call, func, list} ->
        Iteration.eval_filter_call(func, list, env, ctx)

      {:super_call} ->
        Interpreter.eval_super(env, ctx)

      {:starmap_call, func, items} ->
        Iteration.eval_starmap(func, items, env, ctx)

      {:takewhile_call, predicate, items} ->
        Iteration.eval_takewhile(predicate, items, env, ctx)

      {:dropwhile_call, predicate, items} ->
        Iteration.eval_dropwhile(predicate, items, env, ctx)

      {:filterfalse_call, predicate, items} ->
        Iteration.eval_filterfalse(predicate, items, env, ctx)

      {:unittest_main} ->
        Unittest.eval_unittest_main(env, ctx)

      {:assert_raises, exc_type} ->
        {{:assert_raises, exc_type}, env, ctx}

      {:register_route, _method, _path, _handler} = signal ->
        {signal, env, ctx}

      {:exception, _msg} = signal ->
        {signal, env, ctx}

      value ->
        {value, env, ctx}
    end
  end

  @doc false
  @spec handle_builtin_kw_result(term(), Env.t(), Ctx.t()) :: term()
  def handle_builtin_kw_result(result, env, ctx) do
    case result do
      {:exception, _msg} = signal ->
        {signal, env, ctx}

      {:ctx_call, ctx_fun} ->
        ctx_fun.(env, ctx)

      {:mutate, new_object, return_value} ->
        {:mutate, new_object, return_value, ctx}

      {:io_call, io_fun} ->
        ctx = Ctx.pause_compute(ctx)
        {result, env, ctx} = io_fun.(env, ctx)
        ctx = Ctx.resume_compute(ctx)
        {result, env, ctx}

      {:print_call, print_args, sep, end_str} ->
        Interpreter.eval_print_call(print_args, sep, end_str, env, ctx)

      {:sort_call, items, key_fn, reverse} ->
        Interpreter.eval_sort(items, key_fn, reverse, env, ctx)

      {:list_sort_call, items, key_fn, reverse, len} ->
        case Interpreter.eval_sort(items, key_fn, reverse, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {sorted, _env, ctx} ->
            {:mutate, {:py_list, Enum.reverse(sorted), len}, nil, ctx}
        end

      {:iter_sorted, val, key_fn, reverse} ->
        case Interpreter.to_iterable(val, env, ctx) do
          {:ok, items, env, ctx} -> Interpreter.eval_sort(items, key_fn, reverse, env, ctx)
          {:exception, _} = signal -> {signal, env, ctx}
        end

      {:min_call, items, key_fn} ->
        Interpreter.eval_minmax(items, key_fn, :min, env, ctx)

      {:max_call, items, key_fn} ->
        Interpreter.eval_minmax(items, key_fn, :max, env, ctx)

      {:accumulate_call, items, func} ->
        Iteration.eval_accumulate(items, func, env, ctx)

      {:groupby_call, items, key_func} ->
        Iteration.eval_groupby(items, key_func, env, ctx)

      {:starmap_call, func, items} ->
        Iteration.eval_starmap(func, items, env, ctx)

      {:takewhile_call, predicate, items} ->
        Iteration.eval_takewhile(predicate, items, env, ctx)

      {:dropwhile_call, predicate, items} ->
        Iteration.eval_dropwhile(predicate, items, env, ctx)

      {:filterfalse_call, predicate, items} ->
        Iteration.eval_filterfalse(predicate, items, env, ctx)

      {:reduce_call, func, iterable, initial} ->
        case Interpreter.to_iterable(iterable, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {:ok, items, env, ctx} ->
            case initial do
              :no_initial when items == [] ->
                {{:exception, "TypeError: reduce() of empty iterable with no initial value"}, env,
                 ctx}

              :no_initial ->
                [init | rest] = items
                Iteration.eval_reduce(rest, func, init, env, ctx)

              init ->
                Iteration.eval_reduce(items, func, init, env, ctx)
            end
        end

      value ->
        {value, env, ctx}
    end
  end

  @spec iter_to_collection(
          Interpreter.pyvalue(),
          ([Interpreter.pyvalue()] -> Interpreter.pyvalue()),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp iter_to_collection(val, builder, env, ctx) do
    case Interpreter.to_iterable(val, env, ctx) do
      {:ok, items, env, ctx} -> {builder.(items), env, ctx}
      {:exception, _} = signal -> {signal, env, ctx}
    end
  end

  @spec handle_iter_instance(Interpreter.pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp handle_iter_instance(inst, env, ctx) do
    case Dunder.call_dunder(inst, "__iter__", [], env, ctx) do
      {:ok, {:instance, _, _} = iter_inst, env, ctx} ->
        {token, ctx} = Ctx.new_instance_iterator(ctx, iter_inst)
        {token, env, ctx}

      {:ok, {:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {:ok, other, env, ctx} ->
        case Builtins.materialize_iterable(other) do
          {:ok, items} ->
            {token, ctx} = Ctx.new_iterator(ctx, items)
            {token, env, ctx}

          {:pass, iter} ->
            {iter, env, ctx}

          :error ->
            {{:exception, "TypeError: iter() returned non-iterator"}, env, ctx}
        end

      :not_found ->
        {{:exception, "TypeError: '#{Helpers.py_type(inst)}' object is not iterable"}, env, ctx}
    end
  end
end
