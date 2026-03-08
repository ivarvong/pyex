defmodule Pyex.Interpreter.ControlFlow do
  @moduledoc """
  Control-flow evaluation helpers for `Pyex.Interpreter`.

  Keeps branching, loops, and try/except handling together so the main
  interpreter can focus on dispatch while preserving `eval/3`.
  """

  alias Pyex.{Ctx, Env, Interpreter, Parser}
  alias Pyex.Interpreter.{Exceptions, Helpers}

  @typep eval_result :: {Interpreter.pyvalue() | tuple(), Env.t(), Ctx.t()}

  @doc """
  Evaluates an `if` statement.
  """
  @spec eval_if(
          [
            {Parser.ast_node(), [Parser.ast_node()]} | {:else, [Parser.ast_node()]}
          ],
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  def eval_if(clauses, env, ctx), do: eval_if_clauses(clauses, env, ctx)

  @doc """
  Evaluates a `while` loop.
  """
  @spec eval_while(
          Parser.ast_node(),
          [Parser.ast_node()],
          [Parser.ast_node()] | nil,
          Env.t(),
          Ctx.t()
        ) ::
          eval_result()
  def eval_while(condition, body, else_body, env, ctx) do
    case Ctx.check_deadline(ctx) do
      {:exceeded, _} ->
        {{:exception, "TimeoutError: execution exceeded time limit"}, env, ctx}

      :ok ->
        eval_while_body(condition, body, else_body, env, ctx)
    end
  end

  @doc """
  Evaluates a `for` loop.
  """
  @spec eval_for(
          String.t() | [String.t()],
          Parser.ast_node(),
          [Parser.ast_node()],
          [Parser.ast_node()] | nil,
          Env.t(),
          Ctx.t()
        ) ::
          eval_result()
  def eval_for(var_name, iterable_expr, body, else_body, env, ctx) do
    case Interpreter.eval(iterable_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {{:generator_error, items, exception_msg}, env, ctx} ->
        case eval_for_items(var_name, items, body, else_body, env, ctx) do
          {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
          {{:returned, _} = signal, env, ctx} -> {signal, env, ctx}
          {{:break}, env, ctx} -> {{:exception, exception_msg}, env, ctx}
          {_, env, ctx} -> {{:exception, exception_msg}, env, ctx}
        end

      {iterable, env, ctx} ->
        case Interpreter.to_iterable(iterable, env, ctx) do
          {:ok, items, env, ctx} -> eval_for_items(var_name, items, body, else_body, env, ctx)
          {:exception, msg} -> {{:exception, msg}, env, ctx}
        end
    end
  end

  @doc false
  @spec eval_for_items(
          String.t() | [String.t()],
          [Interpreter.pyvalue()],
          [Parser.ast_node()],
          [Parser.ast_node()] | nil,
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  def eval_for_items(var_name, items, body, else_body, env, ctx) do
    do_eval_for_items(var_name, items, body, else_body, env, ctx)
  end

  @doc false
  @spec bind_loop_var(String.t() | [String.t()], Interpreter.pyvalue(), Env.t()) ::
          Env.t() | {:exception, String.t()}
  def bind_loop_var(var_name, item, env) when is_binary(var_name) do
    Env.smart_put(env, var_name, item)
  end

  def bind_loop_var(var_names, item, env) when is_list(var_names) do
    case unpack_for_item(var_names, item) do
      {:ok, bindings} ->
        Enum.reduce(bindings, env, fn {name, val}, acc -> Env.smart_put(acc, name, val) end)

      {:exception, _} = error ->
        error
    end
  end

  @doc """
  Evaluates a `try` statement.
  """
  @spec eval_try(
          [Parser.ast_node()],
          [{String.t() | nil, String.t() | nil, [Parser.ast_node()]}],
          [Parser.ast_node()] | nil,
          [Parser.ast_node()] | nil,
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  def eval_try(body, handlers, else_body, finally_body, env, ctx) do
    result =
      case Interpreter.eval_statements(body, env, ctx) do
        {{:exception, msg}, body_env, ctx} ->
          match_handler(handlers, msg, body_env, ctx)

        {val, env, ctx} ->
          if else_body do
            Interpreter.eval_statements(else_body, env, ctx)
          else
            {val, env, ctx}
          end
      end

    run_finally(result, finally_body)
  end

  @spec eval_if_clauses(
          [
            {Parser.ast_node(), [Parser.ast_node()]} | {:else, [Parser.ast_node()]}
          ],
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp eval_if_clauses([], env, ctx), do: {nil, env, ctx}

  defp eval_if_clauses([{:else, body} | _], env, ctx) do
    Interpreter.eval_statements(body, env, ctx)
  end

  defp eval_if_clauses([{condition, body} | rest], env, ctx) do
    case Interpreter.eval(condition, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        {taken, env, ctx} = Interpreter.eval_truthy(value, env, ctx)

        if taken do
          Interpreter.eval_statements(body, env, ctx)
        else
          eval_if_clauses(rest, env, ctx)
        end
    end
  end

  @spec eval_while_body(
          Parser.ast_node(),
          [Parser.ast_node()],
          [Parser.ast_node()] | nil,
          Env.t(),
          Ctx.t()
        ) ::
          eval_result()
  defp eval_while_body(condition, body, else_body, env, ctx) do
    case Interpreter.eval(condition, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        {taken, env, ctx} = Interpreter.eval_truthy(value, env, ctx)

        if taken do
          case Interpreter.eval_statements(body, env, ctx) do
            {{:returned, _} = signal, env, ctx} ->
              {signal, env, ctx}

            {{:break}, env, ctx} ->
              {nil, env, ctx}

            {{:exception, _} = signal, env, ctx} ->
              {signal, env, ctx}

            {{:yielded, val, cont}, env, ctx} ->
              {{:yielded, val, cont ++ [{:cont_while, condition, body, else_body}]}, env, ctx}

            {{:continue}, env, ctx} ->
              eval_while(condition, body, else_body, env, ctx)

            {_, env, ctx} ->
              eval_while(condition, body, else_body, env, ctx)
          end
        else
          eval_loop_else(else_body, env, ctx)
        end
    end
  end

  @spec do_eval_for_items(
          String.t() | [String.t()],
          [Interpreter.pyvalue()],
          [Parser.ast_node()],
          [Parser.ast_node()] | nil,
          Env.t(),
          Ctx.t()
        ) ::
          eval_result()
  defp do_eval_for_items(_var_name, [], _body, else_body, env, ctx) do
    eval_loop_else(else_body, env, ctx)
  end

  defp do_eval_for_items(var_names, [item | rest], body, else_body, env, ctx)
       when is_list(var_names) do
    case Ctx.check_deadline(ctx) do
      {:exceeded, _} ->
        {{:exception, "TimeoutError: execution exceeded time limit"}, env, ctx}

      :ok ->
        ctx = Ctx.record(ctx, :loop, nil)

        case unpack_for_item(var_names, item) do
          {:ok, bindings} ->
            env =
              Enum.reduce(bindings, env, fn {name, val}, acc -> Env.smart_put(acc, name, val) end)

            case Interpreter.eval_statements(body, env, ctx) do
              {{:returned, _} = signal, env, ctx} ->
                {signal, env, ctx}

              {{:break}, env, ctx} ->
                {nil, env, ctx}

              {{:exception, _} = signal, env, ctx} ->
                {signal, env, ctx}

              {{:yielded, val, cont}, env, ctx} ->
                {{:yielded, val, cont ++ [{:cont_for, var_names, rest, body, else_body}]}, env,
                 ctx}

              {{:continue}, env, ctx} ->
                do_eval_for_items(var_names, rest, body, else_body, env, ctx)

              {_, env, ctx} ->
                do_eval_for_items(var_names, rest, body, else_body, env, ctx)
            end

          {:exception, msg} ->
            {{:exception, msg}, env, ctx}
        end
    end
  end

  defp do_eval_for_items(var_name, [item | rest], body, else_body, env, ctx) do
    case Ctx.check_deadline(ctx) do
      {:exceeded, _} ->
        {{:exception, "TimeoutError: execution exceeded time limit"}, env, ctx}

      :ok ->
        ctx = Ctx.record(ctx, :loop, nil)
        env = Env.smart_put(env, var_name, item)

        case Interpreter.eval_statements(body, env, ctx) do
          {{:returned, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {{:break}, env, ctx} ->
            {nil, env, ctx}

          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {{:yielded, val, cont}, env, ctx} ->
            {{:yielded, val, cont ++ [{:cont_for, var_name, rest, body, else_body}]}, env, ctx}

          {{:continue}, env, ctx} ->
            do_eval_for_items(var_name, rest, body, else_body, env, ctx)

          {_, env, ctx} ->
            do_eval_for_items(var_name, rest, body, else_body, env, ctx)
        end
    end
  end

  @spec eval_loop_else([Parser.ast_node()] | nil, Env.t(), Ctx.t()) :: eval_result()
  defp eval_loop_else(nil, env, ctx), do: {nil, env, ctx}
  defp eval_loop_else(else_body, env, ctx), do: Interpreter.eval_statements(else_body, env, ctx)

  @spec unpack_for_item([String.t()], Interpreter.pyvalue()) ::
          {:ok, [{String.t(), Interpreter.pyvalue()}]} | {:exception, String.t()}
  defp unpack_for_item(names, {:tuple, items}), do: unpack_for_list(names, items)

  defp unpack_for_item(names, {:py_list, reversed, _}),
    do: unpack_for_list(names, Enum.reverse(reversed))

  defp unpack_for_item(names, items) when is_list(items), do: unpack_for_list(names, items)

  defp unpack_for_item(_names, val) do
    {:exception, "TypeError: cannot unpack non-iterable #{Helpers.py_type(val)} object"}
  end

  @spec unpack_for_list([String.t()], [Interpreter.pyvalue()]) ::
          {:ok, [{String.t(), Interpreter.pyvalue()}]} | {:exception, String.t()}
  defp unpack_for_list(names, items) do
    if length(names) == length(items) do
      {:ok, Enum.zip(names, items)}
    else
      {:exception,
       "ValueError: not enough values to unpack (expected #{length(names)}, got #{length(items)})"}
    end
  end

  @spec run_finally(eval_result(), [Parser.ast_node()] | nil) :: eval_result()
  defp run_finally(result, nil), do: result

  defp run_finally({original_signal, env, ctx}, finally_body) do
    case Interpreter.eval_statements(finally_body, env, ctx) do
      {{:exception, _} = new_signal, env, ctx} ->
        {new_signal, env, ctx}

      {{:returned, _} = new_signal, env, ctx} ->
        {new_signal, env, ctx}

      {_val, env, ctx} ->
        {original_signal, env, ctx}
    end
  end

  @spec match_handler(
          [{String.t() | [String.t()] | nil, String.t() | nil, [Parser.ast_node()]}],
          String.t(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp match_handler([], message, env, ctx) do
    {{:exception, message}, env, ctx}
  end

  defp match_handler([{nil, nil, handler_body} | _], message, env, ctx) do
    env = Env.put(env, "__current_exception__", message)
    ctx = %{ctx | exception_instance: nil}
    Interpreter.eval_statements(handler_body, env, ctx)
  end

  defp match_handler([{exc_names, var_name, handler_body} | rest], message, env, ctx) do
    matches =
      case exc_names do
        names when is_list(names) -> Enum.any?(names, &exception_matches?(&1, message))
        name -> exception_matches?(name, message)
      end

    if matches do
      env = Env.put(env, "__current_exception__", message)

      env =
        if var_name do
          exc_value =
            case ctx.exception_instance do
              {:instance, _, _} = inst -> inst
              _ -> Exceptions.synthesize_exception_instance(message)
            end

          Env.put(env, var_name, exc_value)
        else
          env
        end

      ctx = %{ctx | exception_instance: nil}
      Interpreter.eval_statements(handler_body, env, ctx)
    else
      match_handler(rest, message, env, ctx)
    end
  end

  @spec exception_matches?(String.t(), String.t()) :: boolean()
  defp exception_matches?("Exception", _message), do: true

  defp exception_matches?(exc_name, message),
    do: message == exc_name or String.starts_with?(message, exc_name <> ":")
end
