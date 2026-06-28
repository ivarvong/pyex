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

      {:iter_any, val} ->
        iter_to_collection(val, &Enum.any?(&1, fn x -> Builtins.truthy?(x) end), env, ctx)

      {:iter_all, val} ->
        iter_to_collection(val, &Enum.all?(&1, fn x -> Builtins.truthy?(x) end), env, ctx)

      {:iter_enumerate, val, start} ->
        iter_to_collection(
          val,
          fn items ->
            items |> Enum.with_index(start) |> Enum.map(fn {v, i} -> {:tuple, [i, v]} end)
          end,
          env,
          ctx
        )

      {:iter_instance, inst} ->
        handle_iter_instance(inst, env, ctx)

      {:make_iter, items} ->
        {token, ctx} = Ctx.new_iterator(ctx, items)
        {token, env, ctx}

      {:iter_next, id} ->
        case Ctx.iter_next(ctx, id) do
          {:ok, item, ctx} ->
            {item, env, ctx}

          :exhausted ->
            {{:exception, "StopIteration"}, env, ctx}

          {:instance, inst} ->
            Interpreter.eval_instance_next(inst, id, :no_default, env, ctx)

          {:gen_sync, _started?, cont, gen_env} ->
            advance_gen_sync(id, cont, gen_env, :next, env, ctx)

          {:gen_pending, val, cont, gen_env} ->
            step_generator(id, val, cont, gen_env, env, ctx)

          {:gen_awaiting_send, _val, cont, gen_env} ->
            # next(g) == send(None): advance continuation with nil sent value
            advance_with_sent_value(id, cont, gen_env, nil, env, ctx)
        end

      {:iter_next_default, id, default} ->
        case Ctx.iter_next(ctx, id) do
          {:ok, item, ctx} ->
            {item, env, ctx}

          :exhausted ->
            {default, env, ctx}

          {:instance, inst} ->
            Interpreter.eval_instance_next(inst, id, {:default, default}, env, ctx)

          {:gen_sync, _started?, cont, gen_env} ->
            case advance_gen_sync(id, cont, gen_env, :next, env, ctx) do
              {{:exception, "StopIteration"}, env, ctx} -> {default, env, ctx}
              other -> other
            end

          {:gen_pending, val, cont, gen_env} ->
            case step_generator(id, val, cont, gen_env, env, ctx) do
              {{:exception, "StopIteration"}, env, ctx} -> {default, env, ctx}
              other -> other
            end

          {:gen_awaiting_send, _val, cont, gen_env} ->
            case advance_with_sent_value(id, cont, gen_env, nil, env, ctx) do
              {{:exception, "StopIteration"}, env, ctx} -> {default, env, ctx}
              other -> other
            end
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

      {:iter_sum, val, start} ->
        case Interpreter.to_iterable(val, env, ctx) do
          {:ok, items, env, ctx} ->
            result =
              Enum.reduce_while(items, start, fn x, acc ->
                case sum_step(x, acc) do
                  {:exception, _} = exc -> {:halt, exc}
                  v -> {:cont, v}
                end
              end)

            {result, env, ctx}

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

      {:islice_call, iter, start, stop, step} ->
        eval_islice(iter, start, stop, step, env, ctx)

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

      {:mutate_arg, index, new_object, return_value} ->
        {:mutate_arg, index, new_object, return_value, ctx}

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

      {:iter_enumerate, val, start} ->
        iter_to_collection(
          val,
          fn items ->
            items |> Enum.with_index(start) |> Enum.map(fn {v, i} -> {:tuple, [i, v]} end)
          end,
          env,
          ctx
        )

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
          {:exception, _} = signal ->
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

  # Mirror Pyex.Builtins.sum_step/2: accumulates for numeric and common
  # container types used with sum([...], start).
  @spec sum_step(Interpreter.pyvalue(), Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp sum_step(x, acc) when is_number(x) and is_number(acc), do: acc + x

  defp sum_step({:py_list, xr, xlen}, {:py_list, ar, alen}),
    do: {:py_list, xr ++ ar, alen + xlen}

  defp sum_step({:py_list, xr, xlen}, list) when is_list(list),
    do: {:py_list, xr ++ Enum.reverse(list), length(list) + xlen}

  defp sum_step(x, acc) when is_list(x) and is_list(acc), do: acc ++ x
  defp sum_step({:tuple, x}, {:tuple, acc}), do: {:tuple, acc ++ x}
  defp sum_step(x, acc) when is_binary(x) and is_binary(acc), do: acc <> x

  # Type-mismatched accumulation (e.g. sum of strings off the default int 0)
  # is a Python TypeError, not an Elixir crash — the reduce halts on it.
  defp sum_step(x, acc),
    do:
      {:exception,
       "TypeError: unsupported operand type(s) for +: " <>
         "'#{Helpers.py_type(acc)}' and '#{Helpers.py_type(x)}'"}

  @doc """
  Primes a just-started generator (equivalent to `next/1`). CPython treats
  `gen.send(None)` on an unstarted generator as `next(gen)`; the `send` method
  delegates here for that case.
  """
  @spec prime_generator(non_neg_integer(), Env.t(), Ctx.t()) :: eval_result()
  def prime_generator(id, env, ctx) do
    case Ctx.iter_entry(ctx, id) do
      {:gen_sync, _started?, cont, gen_env} ->
        advance_gen_sync(id, cont, gen_env, :next, env, ctx)

      {:gen_pending, val, cont, gen_env} ->
        step_generator(id, val, cont, gen_env, env, ctx)

      {:gen_awaiting_send, _val, cont, gen_env} ->
        advance_with_sent_value(id, cont, gen_env, nil, env, ctx)

      _ ->
        {{:exception, "StopIteration"}, env, ctx}
    end
  end

  @typep gen_resume :: :next | {:send, term()} | {:throw, String.t()}

  @doc """
  Advance a **lazy** sync generator one step. `resume` selects the driver:
  `:next` (resume sending `None`), `{:send, value}`, or `{:throw, exc_msg}`.

  Runs the live continuation in `:defer_inner` mode, then stores the new
  suspension (`{:gen_sync, true, new_cont, env}`) or the terminal state and
  returns the yielded value — or `StopIteration` / a propagated exception.
  No value is pre-computed: side effects happen exactly when the caller
  advances, matching CPython's lazy generator semantics.
  """
  @spec advance_gen_sync(non_neg_integer(), [term()], term(), gen_resume(), Env.t(), Ctx.t()) ::
          eval_result()
  def advance_gen_sync(id, cont, gen_env, resume, env, ctx) do
    case advance_gen_sync_raw(id, cont, gen_env, resume, ctx) do
      {:yield, val, _new_cont, _new_gen_env, ctx} -> {val, env, ctx}
      {:return, _return_value, ctx} -> {{:exception, "StopIteration"}, env, ctx}
      {:exhausted, ctx} -> {{:exception, "StopIteration"}, env, ctx}
      {:raise, msg, ctx} -> {{:exception, msg}, env, ctx}
    end
  end

  @typep gen_step ::
           {:yield, term(), [term()], term(), Ctx.t()}
           | {:return, term(), Ctx.t()}
           | {:exhausted, Ctx.t()}
           | {:raise, term(), Ctx.t()}

  @doc """
  Advance a lazy sync generator one step, returning a *normalized* outcome
  (`:yield` / `:return` / `:exhausted` / `:raise`) plus the updated ctx, with
  the pool entry already restored to its new suspension or terminal state.

  This is the building block for both `advance_gen_sync/6` (which maps it to
  the `next()`/`send()` value-or-`StopIteration` protocol) and the `yield
  from` frames (which need the sub-generator's return value, not
  `StopIteration`).
  """
  @spec advance_gen_sync_raw(non_neg_integer(), [term()], term(), gen_resume(), Ctx.t()) ::
          gen_step()
  def advance_gen_sync_raw(id, cont, gen_env, resume, ctx) do
    saved_mode = ctx.generator_mode
    inner_ctx = %{ctx | generator_mode: :defer_inner}

    result =
      case resume do
        :next -> Interpreter.resume_generator(cont, gen_env, inner_ctx)
        {:send, value} -> Interpreter.resume_generator_with_send(cont, gen_env, inner_ctx, value)
        {:throw, exc} -> Interpreter.resume_generator_with_throw(cont, gen_env, inner_ctx, exc)
      end

    case result do
      {{:yielded, val, new_cont}, new_gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.set_gen_sync(ctx, id, true, new_cont, new_gen_env)
        {:yield, val, new_cont, new_gen_env, ctx}

      {{:done_with_value, return_value}, _new_gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_done_with_value(ctx, id, return_value)
        {:return, return_value, ctx}

      {:done, _new_gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_exhausted(ctx, id)
        {:exhausted, ctx}

      {{:exception, msg}, _new_gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_exhausted(ctx, id)
        {:raise, msg, ctx}
    end
  end

  # Pop the queued yield value, then resume the generator (with the
  # interpreter back in `:defer_inner` mode) so the next `next()` call
  # finds the new pending value. Mirrors what `eval_for_generator_iter`
  # does for the for-loop path.
  @spec step_generator(non_neg_integer(), term(), [term()], Env.t(), Env.t(), Ctx.t()) ::
          eval_result()
  defp step_generator(id, val, [{:cont_bind_sent, _name} | _] = cont, gen_env, env, ctx) do
    # The continuation expects a sent value before proceeding.
    # Save as awaiting-send so next()/send() can supply the value lazily.
    ctx = Ctx.set_gen_awaiting_send(ctx, id, val, cont, gen_env)
    {val, env, ctx}
  end

  defp step_generator(id, val, cont, gen_env, env, ctx) do
    saved_mode = ctx.generator_mode
    inner_ctx = %{ctx | generator_mode: :defer_inner}

    case Interpreter.resume_generator(cont, gen_env, inner_ctx) do
      {{:yielded, next_val, [{:cont_bind_sent, _name} | _] = next_cont}, next_gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.set_gen_awaiting_send(ctx, id, next_val, next_cont, next_gen_env)
        {val, env, ctx}

      {{:yielded, next_val, next_cont}, next_gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.set_gen_pending(ctx, id, next_val, next_cont, next_gen_env)
        {val, env, ctx}

      {{:done_with_value, return_value}, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_done_with_value(ctx, id, return_value)
        {val, env, ctx}

      {:done, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_exhausted(ctx, id)
        {val, env, ctx}

      {{:exception, _} = signal, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_exhausted(ctx, id)
        {signal, env, ctx}
    end
  end

  @doc false
  @spec send_to_awaiting_generator(
          non_neg_integer(),
          [term()],
          Env.t(),
          term(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  def send_to_awaiting_generator(id, cont, gen_env, sent_value, env, ctx) do
    advance_with_sent_value(id, cont, gen_env, sent_value, env, ctx)
  end

  @spec advance_with_sent_value(
          non_neg_integer(),
          [term()],
          Env.t(),
          term(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp advance_with_sent_value(id, cont, gen_env, sent_value, env, ctx) do
    saved_mode = ctx.generator_mode
    inner_ctx = %{ctx | generator_mode: :defer_inner}

    case Interpreter.resume_generator_with_send(cont, gen_env, inner_ctx, sent_value) do
      {{:yielded, next_val, next_cont}, next_gen_env, ctx} ->
        # send()/next() returns next_val NOW; the lookahead model requires we
        # queue the value AFTER it (not next_val again). step_generator does
        # exactly that: returns next_val and advances next_cont by one yield.
        ctx = %{ctx | generator_mode: saved_mode}
        step_generator(id, next_val, next_cont, next_gen_env, env, ctx)

      {{:done_with_value, return_value}, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_done_with_value(ctx, id, return_value)
        {{:exception, "StopIteration"}, env, ctx}

      {:done, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_exhausted(ctx, id)
        {{:exception, "StopIteration"}, env, ctx}

      {{:exception, _} = signal, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_exhausted(ctx, id)
        {signal, env, ctx}
    end
  end

  @doc """
  Resume a suspended generator by raising `exc_msg` at its current `yield`
  (the `gen.throw()` path). The exception unwinds through the saved
  continuation; if an enclosing `try` catches it the generator may resume and
  yield again, otherwise the exception propagates out and the generator is done.

  Mirrors `advance_with_sent_value/6`'s post-yield bookkeeping so a generator
  thrown-into and re-yielded ends up in the same iterator state it would after
  a normal `send`.
  """
  @spec throw_into_generator(
          non_neg_integer(),
          [term()],
          Env.t(),
          String.t(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  def throw_into_generator(id, cont, gen_env, exc_msg, env, ctx) do
    saved_mode = ctx.generator_mode
    inner_ctx = %{ctx | generator_mode: :defer_inner}

    case Interpreter.resume_generator_with_throw(cont, gen_env, inner_ctx, exc_msg) do
      {{:yielded, next_val, next_cont}, next_gen_env, ctx} ->
        # throw() that lands in an except and re-yields returns next_val NOW;
        # queue the value after it (see advance_with_sent_value).
        ctx = %{ctx | generator_mode: saved_mode}
        step_generator(id, next_val, next_cont, next_gen_env, env, ctx)

      {{:done_with_value, return_value}, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_done_with_value(ctx, id, return_value)
        {{:exception, "StopIteration"}, env, ctx}

      {{:exception, _} = signal, _gen_env, ctx} ->
        ctx = %{ctx | generator_mode: saved_mode}
        ctx = Ctx.mark_iter_exhausted(ctx, id)
        {signal, env, ctx}
    end
  end

  @spec eval_islice(
          Interpreter.pyvalue(),
          non_neg_integer(),
          non_neg_integer() | :infinity,
          pos_integer(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp eval_islice({:iterator, id}, start, stop, step, env, ctx) do
    case skip_iter(id, start, env, ctx) do
      {:exhausted, env, ctx} ->
        {[], env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {:ok, env, ctx} ->
        # Items to collect = ceil((stop - start) / step) for finite stop.
        # `collect_islice` then advances by `step` between each kept item.
        take_count =
          case stop do
            :infinity ->
              :infinity

            n when is_integer(n) ->
              span = max(n - start, 0)
              div(span + step - 1, step)
          end

        collect_islice(id, take_count, step, [], env, ctx)
    end
  end

  defp skip_iter(_id, 0, env, ctx), do: {:ok, env, ctx}

  defp skip_iter(id, n, env, ctx) when n > 0 do
    case advance_iter(id, env, ctx) do
      {:exhausted, env, ctx} -> {:exhausted, env, ctx}
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
      {{:ok, _val}, env, ctx} -> skip_iter(id, n - 1, env, ctx)
    end
  end

  defp collect_islice(_id, 0, _step, acc, env, ctx) do
    {Enum.reverse(acc), env, ctx}
  end

  defp collect_islice(id, n, step, acc, env, ctx) do
    case advance_iter(id, env, ctx) do
      {:exhausted, env, ctx} ->
        {Enum.reverse(acc), env, ctx}

      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {{:ok, val}, env, ctx} ->
        acc = [val | acc]
        next_n = if n == :infinity, do: :infinity, else: n - 1

        if next_n == 0 do
          {Enum.reverse(acc), env, ctx}
        else
          case skip_iter(id, step - 1, env, ctx) do
            {:exhausted, env, ctx} -> {Enum.reverse(acc), env, ctx}
            {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
            {:ok, env, ctx} -> collect_islice(id, next_n, step, acc, env, ctx)
          end
        end
    end
  end

  # Advance an iterator one step, normalizing the various tagged
  # entries (`:list`, `:gen_pending`, `:gen_awaiting_send`,
  # `:instance`) to a single `{:ok, val} | :exhausted | exception`
  # outcome.
  defp advance_iter(id, env, ctx) do
    case Ctx.iter_next(ctx, id) do
      {:ok, item, ctx} ->
        {{:ok, item}, env, ctx}

      :exhausted ->
        {:exhausted, env, ctx}

      {:gen_sync, _started?, cont, gen_env} ->
        case advance_gen_sync(id, cont, gen_env, :next, env, ctx) do
          {{:exception, "StopIteration" <> _}, env, ctx} -> {:exhausted, env, ctx}
          {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
          {value, env, ctx} -> {{:ok, value}, env, ctx}
        end

      {:gen_pending, val, cont, gen_env} ->
        case step_generator(id, val, cont, gen_env, env, ctx) do
          {{:exception, "StopIteration" <> _}, env, ctx} -> {:exhausted, env, ctx}
          {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
          {value, env, ctx} -> {{:ok, value}, env, ctx}
        end

      {:gen_awaiting_send, _val, cont, gen_env} ->
        case advance_with_sent_value(id, cont, gen_env, nil, env, ctx) do
          {{:exception, "StopIteration" <> _}, env, ctx} -> {:exhausted, env, ctx}
          {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
          {value, env, ctx} -> {{:ok, value}, env, ctx}
        end

      {:instance, inst} ->
        case Interpreter.eval_instance_next(inst, id, :no_default, env, ctx) do
          {{:exception, "StopIteration" <> _}, env, ctx} -> {:exhausted, env, ctx}
          {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
          {value, env, ctx} -> {{:ok, value}, env, ctx}
        end
    end
  end
end
