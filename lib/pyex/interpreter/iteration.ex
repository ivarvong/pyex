defmodule Pyex.Interpreter.Iteration do
  @moduledoc """
  Higher-order iteration functions for the Pyex interpreter.

  Implements `map()`, `filter()`, `itertools.starmap()`,
  `itertools.takewhile()`, `itertools.dropwhile()`,
  `itertools.filterfalse()`, `itertools.accumulate()`,
  and `itertools.groupby()`.

  Each function threads the environment and context through
  a tail-recursive accumulator loop, supporting closures
  that return updated function values (4-tuple results).
  """

  alias Pyex.{Ctx, Env, Interpreter}

  @typep eval_result :: {Interpreter.pyvalue() | term(), Env.t(), Ctx.t()}

  @doc false
  @spec eval_map_call(Interpreter.pyvalue(), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          eval_result()
  def eval_map_call(func, list, env, ctx) do
    eval_map_call_acc(func, list, [], env, ctx)
  end

  defp eval_map_call_acc(_func, [], acc, env, ctx), do: {Enum.reverse(acc), env, ctx}

  defp eval_map_call_acc(func, [item | rest], acc, env, ctx) do
    case Interpreter.call_function(func, [item], %{}, env, ctx) do
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
      {val, env, ctx, updated} -> eval_map_call_acc(updated, rest, [val | acc], env, ctx)
      {val, env, ctx} -> eval_map_call_acc(func, rest, [val | acc], env, ctx)
    end
  end

  @doc false
  @spec eval_filter_call(Interpreter.pyvalue(), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          eval_result()
  def eval_filter_call(func, list, env, ctx) do
    eval_filter_call_acc(func, list, [], env, ctx)
  end

  defp eval_filter_call_acc(_func, [], acc, env, ctx), do: {Enum.reverse(acc), env, ctx}

  defp eval_filter_call_acc(func, [item | rest], acc, env, ctx) do
    case Interpreter.call_function(func, [item], %{}, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {val, env, ctx, updated} ->
        {taken, env, ctx} = Interpreter.eval_truthy(val, env, ctx)
        acc = if taken, do: [item | acc], else: acc
        eval_filter_call_acc(updated, rest, acc, env, ctx)

      {val, env, ctx} ->
        {taken, env, ctx} = Interpreter.eval_truthy(val, env, ctx)
        acc = if taken, do: [item | acc], else: acc
        eval_filter_call_acc(func, rest, acc, env, ctx)
    end
  end

  @doc false
  @spec eval_starmap(Interpreter.pyvalue(), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          eval_result()
  def eval_starmap(func, items, env, ctx) do
    eval_starmap_acc(func, items, [], env, ctx)
  end

  defp eval_starmap_acc(_func, [], acc, env, ctx), do: {Enum.reverse(acc), env, ctx}

  defp eval_starmap_acc(func, [item | rest], acc, env, ctx) do
    args =
      case item do
        {:tuple, elems} -> elems
        list when is_list(list) -> list
        other -> [other]
      end

    case Interpreter.call_function(func, args, %{}, env, ctx) do
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
      {val, env, ctx, updated} -> eval_starmap_acc(updated, rest, [val | acc], env, ctx)
      {val, env, ctx} -> eval_starmap_acc(func, rest, [val | acc], env, ctx)
    end
  end

  @doc false
  @spec eval_takewhile(Interpreter.pyvalue(), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          eval_result()
  def eval_takewhile(predicate, items, env, ctx) do
    eval_takewhile_acc(predicate, items, [], env, ctx)
  end

  defp eval_takewhile_acc(_pred, [], acc, env, ctx), do: {Enum.reverse(acc), env, ctx}

  defp eval_takewhile_acc(pred, [item | rest], acc, env, ctx) do
    case Interpreter.call_function(pred, [item], %{}, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {val, env, ctx, updated} ->
        {truthy, env, ctx} = Interpreter.eval_truthy(val, env, ctx)

        if truthy,
          do: eval_takewhile_acc(updated, rest, [item | acc], env, ctx),
          else: {Enum.reverse(acc), env, ctx}

      {val, env, ctx} ->
        {truthy, env, ctx} = Interpreter.eval_truthy(val, env, ctx)

        if truthy,
          do: eval_takewhile_acc(pred, rest, [item | acc], env, ctx),
          else: {Enum.reverse(acc), env, ctx}
    end
  end

  @doc false
  @spec eval_dropwhile(Interpreter.pyvalue(), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          eval_result()
  def eval_dropwhile(predicate, items, env, ctx) do
    eval_dropwhile_loop(predicate, items, env, ctx)
  end

  defp eval_dropwhile_loop(_pred, [], env, ctx), do: {[], env, ctx}

  defp eval_dropwhile_loop(pred, [item | rest] = items, env, ctx) do
    case Interpreter.call_function(pred, [item], %{}, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {val, env, ctx, updated} ->
        {truthy, env, ctx} = Interpreter.eval_truthy(val, env, ctx)
        if truthy, do: eval_dropwhile_loop(updated, rest, env, ctx), else: {items, env, ctx}

      {val, env, ctx} ->
        {truthy, env, ctx} = Interpreter.eval_truthy(val, env, ctx)
        if truthy, do: eval_dropwhile_loop(pred, rest, env, ctx), else: {items, env, ctx}
    end
  end

  @doc false
  @spec eval_filterfalse(Interpreter.pyvalue(), [Interpreter.pyvalue()], Env.t(), Ctx.t()) ::
          eval_result()
  def eval_filterfalse(predicate, items, env, ctx) do
    eval_filterfalse_acc(predicate, items, [], env, ctx)
  end

  defp eval_filterfalse_acc(_pred, [], acc, env, ctx), do: {Enum.reverse(acc), env, ctx}

  defp eval_filterfalse_acc(pred, [item | rest], acc, env, ctx) do
    case Interpreter.call_function(pred, [item], %{}, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {val, env, ctx, updated} ->
        {truthy, env, ctx} = Interpreter.eval_truthy(val, env, ctx)
        acc = if truthy, do: acc, else: [item | acc]
        eval_filterfalse_acc(updated, rest, acc, env, ctx)

      {val, env, ctx} ->
        {truthy, env, ctx} = Interpreter.eval_truthy(val, env, ctx)
        acc = if truthy, do: acc, else: [item | acc]
        eval_filterfalse_acc(pred, rest, acc, env, ctx)
    end
  end

  @doc false
  @spec eval_accumulate([Interpreter.pyvalue()], Interpreter.pyvalue(), Env.t(), Ctx.t()) ::
          eval_result()
  def eval_accumulate([], _func, env, ctx), do: {[], env, ctx}

  def eval_accumulate([first | rest], func, env, ctx) do
    eval_accumulate_acc(func, rest, first, [first], env, ctx)
  end

  defp eval_accumulate_acc(_func, [], _acc, result, env, ctx),
    do: {Enum.reverse(result), env, ctx}

  defp eval_accumulate_acc(func, [item | rest], acc, result, env, ctx) do
    case Interpreter.call_function(func, [acc, item], %{}, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {val, env, ctx, updated} ->
        eval_accumulate_acc(updated, rest, val, [val | result], env, ctx)

      {val, env, ctx} ->
        eval_accumulate_acc(func, rest, val, [val | result], env, ctx)
    end
  end

  @doc false
  @spec eval_groupby([Interpreter.pyvalue()], Interpreter.pyvalue(), Env.t(), Ctx.t()) ::
          eval_result()
  def eval_groupby(items, key_func, env, ctx) do
    eval_groupby_acc(key_func, items, nil, [], [], env, ctx)
  end

  defp eval_groupby_acc(_func, [], nil, _group, result, env, ctx) do
    {Enum.reverse(result), env, ctx}
  end

  defp eval_groupby_acc(_func, [], current_key, group, result, env, ctx) do
    entry = {:tuple, [current_key, Enum.reverse(group)]}
    {Enum.reverse([entry | result]), env, ctx}
  end

  defp eval_groupby_acc(func, [item | rest], current_key, group, result, env, ctx) do
    case Interpreter.call_function(func, [item], %{}, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {key, env, ctx, updated} ->
        if current_key == nil or key == current_key do
          eval_groupby_acc(updated, rest, key, [item | group], result, env, ctx)
        else
          entry = {:tuple, [current_key, Enum.reverse(group)]}
          eval_groupby_acc(updated, rest, key, [item], [entry | result], env, ctx)
        end

      {key, env, ctx} ->
        if current_key == nil or key == current_key do
          eval_groupby_acc(func, rest, key, [item | group], result, env, ctx)
        else
          entry = {:tuple, [current_key, Enum.reverse(group)]}
          eval_groupby_acc(func, rest, key, [item], [entry | result], env, ctx)
        end
    end
  end
end
