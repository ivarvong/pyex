defmodule Pyex.Interpreter.Collections do
  @moduledoc """
  Collection literal and comprehension evaluation helpers for `Pyex.Interpreter`.

  Keeps tuple/list/dict/set construction together with comprehension execution
  so the main interpreter can stay focused on dispatch.
  """

  alias Pyex.{Ctx, Env, Interpreter, Parser, PyDict}
  alias Pyex.Interpreter.{ControlFlow, Helpers}

  @typep eval_result :: {Interpreter.pyvalue() | tuple(), Env.t(), Ctx.t()}
  @typep comp_clause ::
           {:comp_for, String.t() | [String.t()], Parser.ast_node()}
           | {:comp_if, Parser.ast_node()}
  @typep dict_entry :: {Parser.ast_node(), Parser.ast_node()} | Parser.ast_node()

  @doc """
  Evaluates tuple construction.
  """
  @spec eval_tuple([Parser.ast_node()], Env.t(), Ctx.t()) :: eval_result()
  def eval_tuple(elements, env, ctx) do
    case eval_sequence_elements(elements, env, ctx) do
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
      {values, env, ctx} -> {{:tuple, Enum.reverse(values)}, env, ctx}
    end
  end

  @doc """
  Evaluates list construction.
  """
  @spec eval_list_literal([Parser.ast_node()], Env.t(), Ctx.t()) :: eval_result()
  def eval_list_literal(elements, env, ctx) do
    case eval_sequence_elements(elements, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {values, env, ctx} ->
        {ref, ctx} = Ctx.heap_alloc(ctx, {:py_list, values, length(values)})
        {ref, env, ctx}
    end
  end

  @doc """
  Evaluates dict construction.
  """
  @spec eval_dict_literal([dict_entry()], Env.t(), Ctx.t()) ::
          eval_result()
  def eval_dict_literal(entries, env, ctx) do
    case eval_dict(entries, env, ctx) do
      {{:exception, _}, _, _} = result ->
        result

      {dict, env, ctx} ->
        {ref, ctx} = Ctx.heap_alloc(ctx, dict)
        {ref, env, ctx}
    end
  end

  @doc """
  Evaluates set construction.
  """
  @spec eval_set_literal([Parser.ast_node()], Env.t(), Ctx.t()) :: eval_result()
  def eval_set_literal(elements, env, ctx) do
    case eval_sequence_elements(elements, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {values, env, ctx} ->
        {ref, ctx} = Ctx.heap_alloc(ctx, {:set, MapSet.new(Enum.reverse(values))})
        {ref, env, ctx}
    end
  end

  @doc """
  Evaluates a list comprehension.
  """
  @spec eval_list_comp(Parser.ast_node(), [comp_clause()], Env.t(), Ctx.t()) :: eval_result()
  def eval_list_comp(expr, clauses, env, ctx) do
    case eval_comp_clauses(:list, expr, clauses, [], env, ctx) do
      {result, env, ctx} when is_list(result) ->
        items = Enum.reverse(result)
        {ref, ctx} = Ctx.heap_alloc(ctx, {:py_list, Enum.reverse(items), length(items)})
        {ref, env, ctx}

      other ->
        other
    end
  end

  @doc """
  Evaluates a generator expression.
  """
  @spec eval_gen_expr(Parser.ast_node(), [comp_clause()], Env.t(), Ctx.t()) :: eval_result()
  def eval_gen_expr(expr, clauses, env, ctx) do
    case eval_comp_clauses(:list, expr, clauses, [], env, ctx) do
      {result, env, ctx} when is_list(result) -> {{:generator, Enum.reverse(result)}, env, ctx}
      other -> other
    end
  end

  @doc """
  Evaluates a dict comprehension.
  """
  @spec eval_dict_comp(Parser.ast_node(), Parser.ast_node(), [comp_clause()], Env.t(), Ctx.t()) ::
          eval_result()
  def eval_dict_comp(key_expr, val_expr, clauses, env, ctx) do
    case eval_comp_clauses(:dict, {key_expr, val_expr}, clauses, PyDict.new(), env, ctx) do
      {{:exception, _}, _, _} = result ->
        result

      {dict, env, ctx} ->
        {ref, ctx} = Ctx.heap_alloc(ctx, dict)
        {ref, env, ctx}
    end
  end

  @doc """
  Evaluates a set comprehension.
  """
  @spec eval_set_comp(Parser.ast_node(), [comp_clause()], Env.t(), Ctx.t()) :: eval_result()
  def eval_set_comp(expr, clauses, env, ctx) do
    case eval_comp_clauses(:set, expr, clauses, MapSet.new(), env, ctx) do
      {{:exception, _}, _, _} = result ->
        result

      {set, env, ctx} ->
        {ref, ctx} = Ctx.heap_alloc(ctx, {:set, set})
        {ref, env, ctx}
    end
  end

  @spec eval_comp_clauses(
          :list | :dict | :set,
          Parser.ast_node() | {Parser.ast_node(), Parser.ast_node()},
          [comp_clause()],
          [Interpreter.pyvalue()] | map() | MapSet.t() | PyDict.t(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  @dialyzer {:nowarn_function, eval_comp_clauses: 6}
  defp eval_comp_clauses(:list, expr, [], acc, env, ctx) do
    case Interpreter.eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
      {val, env, ctx} -> {[val | acc], env, ctx}
    end
  end

  defp eval_comp_clauses(:dict, {key_expr, val_expr}, [], acc, env, ctx) do
    case Interpreter.eval(key_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {key, env, ctx} ->
        case Interpreter.eval(val_expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
          {val, env, ctx} -> {PyDict.put(acc, key, val), env, ctx}
        end
    end
  end

  defp eval_comp_clauses(:set, expr, [], acc, env, ctx) do
    case Interpreter.eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
      {val, env, ctx} -> {MapSet.put(acc, val), env, ctx}
    end
  end

  defp eval_comp_clauses(kind, expr, [{:comp_if, condition} | rest_clauses], acc, env, ctx) do
    case Interpreter.eval(condition, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {cond_val, env, ctx} ->
        {taken, env, ctx} = Interpreter.eval_truthy(cond_val, env, ctx)

        if taken do
          eval_comp_clauses(kind, expr, rest_clauses, acc, env, ctx)
        else
          {acc, env, ctx}
        end
    end
  end

  defp eval_comp_clauses(
         kind,
         expr,
         [{:comp_for, var_name, iterable_expr} | rest_clauses],
         acc,
         env,
         ctx
       ) do
    case Interpreter.eval(iterable_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {iterable, env, ctx} ->
        case Interpreter.to_iterable(iterable, env, ctx) do
          {:ok, items, env, ctx} ->
            eval_comp_for_loop(kind, expr, var_name, items, rest_clauses, acc, env, ctx)

          {:exception, msg} ->
            {{:exception, msg}, env, ctx}
        end
    end
  end

  @spec eval_comp_for_loop(
          :list | :dict | :set,
          Parser.ast_node() | {Parser.ast_node(), Parser.ast_node()},
          String.t() | [String.t()],
          [Interpreter.pyvalue()],
          [comp_clause()],
          [Interpreter.pyvalue()] | map() | MapSet.t() | PyDict.t(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp eval_comp_for_loop(_kind, _expr, _var_name, [], _rest_clauses, acc, env, ctx) do
    {acc, env, ctx}
  end

  defp eval_comp_for_loop(kind, expr, var_name, [item | rest_items], rest_clauses, acc, env, ctx) do
    case Ctx.check_deadline(ctx) do
      {:exceeded, _} ->
        {{:exception, "TimeoutError: execution exceeded time limit"}, env, ctx}

      :ok ->
        case ControlFlow.bind_loop_var(var_name, item, env) do
          {:exception, msg} ->
            {{:exception, msg}, env, ctx}

          bound_env ->
            case eval_comp_clauses(kind, expr, rest_clauses, acc, bound_env, ctx) do
              {{:exception, _}, _, _} = error ->
                error

              {new_acc, _inner_env, ctx} ->
                eval_comp_for_loop(
                  kind,
                  expr,
                  var_name,
                  rest_items,
                  rest_clauses,
                  new_acc,
                  env,
                  ctx
                )
            end
        end
    end
  end

  @spec eval_sequence_elements([Parser.ast_node()], Env.t(), Ctx.t()) ::
          {[Interpreter.pyvalue()], Env.t(), Ctx.t()}
          | {{:exception, String.t()}, Env.t(), Ctx.t()}
  defp eval_sequence_elements(elements, env, ctx) do
    Enum.reduce_while(elements, {[], env, ctx}, fn
      {:star_arg, _, [expr]}, {acc, env, ctx} ->
        case Interpreter.eval(expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {:halt, {signal, env, ctx}}

          {val, env, ctx} ->
            case Interpreter.to_iterable(val, env, ctx) do
              {:ok, items, env, ctx} ->
                {:cont, {Enum.reverse(items) ++ acc, env, ctx}}

              {:exception, msg} ->
                {:halt, {{:exception, msg}, env, ctx}}
            end
        end

      expr, {acc, env, ctx} ->
        case Interpreter.eval(expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} -> {:halt, {signal, env, ctx}}
          {val, env, ctx} -> {:cont, {[val | acc], env, ctx}}
        end
    end)
  end

  @spec eval_dict([dict_entry()], Env.t(), Ctx.t()) :: eval_result()
  defp eval_dict(entries, env, ctx) do
    Enum.reduce_while(entries, {PyDict.new(), env, ctx}, fn
      {:double_star_arg, _, [expr]}, {map, env, ctx} ->
        case Interpreter.eval(expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {:halt, {signal, env, ctx}}

          {raw_val, env, ctx} ->
            case Ctx.deref(ctx, raw_val) do
              {:py_dict, _, _} = dict ->
                merged =
                  Enum.reduce(PyDict.items(dict), map, fn {k, v}, acc -> PyDict.put(acc, k, v) end)

                {:cont, {merged, env, ctx}}

              value when is_map(value) ->
                merged = Enum.reduce(value, map, fn {k, v}, acc -> PyDict.put(acc, k, v) end)
                {:cont, {merged, env, ctx}}

              value ->
                {:halt,
                 {{:exception,
                   "TypeError: argument after ** must be a mapping, not '#{Helpers.py_type(value)}'"},
                  env, ctx}}
            end
        end

      {key_expr, val_expr}, {map, env, ctx} ->
        case Interpreter.eval(key_expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {:halt, {signal, env, ctx}}

          {key, env, ctx} ->
            derefed_key = Ctx.deref(ctx, key)

            if unhashable?(derefed_key) do
              {:halt,
               {{:exception, "TypeError: unhashable type: '#{Helpers.py_type(derefed_key)}'"},
                env, ctx}}
            else
              case Interpreter.eval(val_expr, env, ctx) do
                {{:exception, _} = signal, env, ctx} -> {:halt, {signal, env, ctx}}
                {val, env, ctx} -> {:cont, {PyDict.put(map, key, val), env, ctx}}
              end
            end
        end
    end)
  end

  @spec unhashable?(Interpreter.pyvalue()) :: boolean()
  defp unhashable?(val) when is_list(val), do: true
  defp unhashable?({:py_list, _, _}), do: true
  defp unhashable?({:set, _}), do: true
  defp unhashable?(_), do: false
end
