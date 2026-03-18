defmodule Pyex.Interpreter.Exceptions do
  @moduledoc """
  Exception construction and `raise` evaluation helpers for `Pyex.Interpreter`.

  Keeps exception statement semantics together so the main interpreter can
  dispatch without carrying all raise-specific branches inline.
  """

  alias Pyex.{Ctx, Env, Interpreter, Parser}
  alias Pyex.Interpreter.Helpers

  @typep eval_result :: {Interpreter.pyvalue() | tuple(), Env.t(), Ctx.t()}

  @doc """
  Evaluates a `raise` statement.
  """
  @spec eval_raise(Parser.ast_node() | nil, Parser.meta(), Env.t(), Ctx.t()) :: eval_result()
  def eval_raise(nil, _meta, env, ctx) do
    case Env.get(env, "__current_exception__") do
      {:ok, msg} ->
        {{:exception, msg}, env, ctx}

      :undefined ->
        {{:exception, "RuntimeError: No active exception to re-raise"}, env, ctx}
    end
  end

  def eval_raise(expr, meta, env, ctx) do
    case expr do
      {:call, _, [{:var, _, [exc_name]}, args]} when is_list(args) ->
        eval_raise_exc_class(exc_name, args, meta, env, ctx)

      {:call, _, [{:var, _, [exc_name]}, args, _kwargs]} when is_list(args) ->
        eval_raise_exc_class(exc_name, args, meta, env, ctx)

      {:var, _, [exc_name]} ->
        {{:exception, exc_name}, env, ctx}

      _ ->
        case Interpreter.eval(expr, env, ctx) do
          {{:exception, _} = signal, _env, _ctx} ->
            {signal, env, ctx}

          {value, env, ctx} ->
            msg =
              case value do
                msg when is_binary(msg) -> "Exception: #{msg}"
                _ -> "Exception: #{inspect(value)}"
              end

            {{:exception, msg}, env, ctx}
        end
    end
  end

  @doc false
  @spec synthesize_exception_instance(String.t()) :: Interpreter.pyvalue()
  def synthesize_exception_instance(message) do
    {class_name, msg} =
      case String.split(message, ": ", parts: 2) do
        [name, m] -> {name, m}
        [name] -> {name, ""}
      end

    {:instance, {:class, class_name, [], %{}}, %{"args" => {:tuple, [msg]}}}
  end

  @spec eval_raise_exc_class(String.t(), [Parser.ast_node()], Parser.meta(), Env.t(), Ctx.t()) ::
          eval_result()
  defp eval_raise_exc_class(exc_name, args, _meta, env, ctx) do
    case Env.get(env, exc_name) do
      {:ok, {:class, _, _, _} = class} ->
        case Interpreter.eval_list(args, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {rev_values, env, ctx} ->
            values = Enum.reverse(rev_values)
            msg = format_exc_msg(exc_name, values)

            case Interpreter.call_function(class, values, %{}, env, ctx) do
              {{:exception, _}, env, ctx} ->
                instance = {:instance, class, %{"args" => {:tuple, values}}}
                ctx = %{ctx | exception_instance: instance}
                {{:exception, msg}, env, ctx}

              {instance, env, ctx} ->
                derefed = Ctx.deref(ctx, instance)
                ctx = %{ctx | exception_instance: derefed}
                {{:exception, msg}, env, ctx}
            end
        end

      _ ->
        case Interpreter.eval_list(args, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {rev_values, env, ctx} ->
            values = Enum.reverse(rev_values)
            msg = format_exc_msg(exc_name, values)

            instance =
              {:instance, {:class, exc_name, [], %{}}, %{"args" => {:tuple, values}}}

            ctx = %{ctx | exception_instance: instance}
            {{:exception, msg}, env, ctx}
        end
    end
  end

  @spec format_exc_msg(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp format_exc_msg(exc_name, values) do
    case values do
      [] -> exc_name
      [m] when is_binary(m) -> "#{exc_name}: #{m}"
      [m] -> "#{exc_name}: #{Helpers.py_str(m)}"
      _ -> "#{exc_name}: #{values |> Enum.map(&Helpers.py_str/1) |> Enum.join(", ")}"
    end
  end
end
