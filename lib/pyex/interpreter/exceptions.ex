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
        eval_raise_exc_class(exc_name, args, [], meta, env, ctx)

      {:call, _, [{:var, _, [exc_name]}, args, kwargs]} when is_list(args) ->
        eval_raise_exc_class(exc_name, args, kwargs, meta, env, ctx)

      {:var, _, [exc_name]} ->
        case Env.get(env, exc_name) do
          {:ok, {:exception_class, name}} ->
            instance =
              {:instance, Interpreter.exception_instance_class({:exception_class, name}),
               %{"args" => {:tuple, []}}}

            ctx = %{ctx | exception_instance: instance}
            {{:exception, name}, env, ctx}

          # `raise some_var` where some_var holds an already-constructed
          # exception instance: bubble it up as the active exception.
          {:ok, raw} ->
            case Ctx.deref(ctx, raw) do
              {:instance, _, _} = inst ->
                eval_raise_value(inst, env, ctx)

              _ ->
                {{:exception, exc_name}, env, ctx}
            end

          _ ->
            {{:exception, exc_name}, env, ctx}
        end

      _ ->
        case Interpreter.eval(expr, env, ctx) do
          {{:exception, _} = signal, _env, _ctx} ->
            {signal, env, ctx}

          {value, env, ctx} ->
            eval_raise_value(value, env, ctx)
        end
    end
  end

  @spec eval_raise_value(Interpreter.pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  defp eval_raise_value(value, env, ctx) do
    case value do
      # An already-constructed exception instance bubbles up with the
      # class name as the error tag and the instance attached for
      # `as e:` binding.
      {:instance, {:class, name, _, _} = _cls, attrs} = inst ->
        args = Map.get(attrs, "args", {:tuple, []})
        msg = format_inst_msg(name, args)
        ctx = %{ctx | exception_instance: inst}
        {{:exception, msg}, env, ctx}

      # `raise SomeExceptionClass` with no call: synthesize an empty instance.
      {:exception_class, name} ->
        instance =
          {:instance, Interpreter.exception_instance_class({:exception_class, name}),
           %{"args" => {:tuple, []}}}

        ctx = %{ctx | exception_instance: instance}
        {{:exception, name}, env, ctx}

      msg when is_binary(msg) ->
        {{:exception, "Exception: #{msg}"}, env, ctx}

      _ ->
        {{:exception, "Exception: #{inspect(value)}"}, env, ctx}
    end
  end

  @spec format_inst_msg(String.t(), Interpreter.pyvalue()) :: String.t()
  defp format_inst_msg(name, {:tuple, []}), do: name
  defp format_inst_msg(name, {:tuple, [arg]}) when is_binary(arg), do: "#{name}: #{arg}"
  defp format_inst_msg(name, {:tuple, [arg]}), do: "#{name}: #{Helpers.py_str(arg)}"

  defp format_inst_msg(name, {:tuple, args}) do
    tuple_repr = Pyex.Builtins.py_repr({:tuple, args})
    "#{name}: #{tuple_repr}"
  end

  defp format_inst_msg(name, _), do: name

  @doc """
  Evaluates `raise expr from cause_expr`.

  First resolves the cause expression (must be an exception instance,
  None, or raise TypeError at runtime — we currently relax to accept any
  value).  Then evaluates the main raise; if it produces an exception
  instance, we attach the cause as `__cause__` on the instance.
  """
  @spec eval_raise_from(
          Parser.ast_node(),
          Parser.ast_node(),
          Parser.meta(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  def eval_raise_from(expr, cause_expr, meta, env, ctx) do
    case Interpreter.eval(cause_expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {cause_val, env, ctx} ->
        cause = Ctx.deref(ctx, cause_val)

        {signal, env, ctx} = eval_raise(expr, meta, env, ctx)

        case signal do
          {:exception, _} ->
            new_instance =
              case ctx.exception_instance do
                {:instance, cls, attrs} ->
                  {:instance, cls, Map.put(attrs, "__cause__", cause)}

                _ ->
                  nil
              end

            ctx =
              if new_instance do
                %{ctx | exception_instance: new_instance}
              else
                ctx
              end

            {signal, env, ctx}
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

    class =
      if Pyex.ExceptionsHierarchy.known?(class_name) do
        Interpreter.exception_instance_class({:exception_class, class_name})
      else
        {:class, class_name, [], %{"__name__" => class_name, "__qualname__" => class_name}}
      end

    {:instance, class, %{"args" => {:tuple, [msg]}}}
  end

  @spec eval_raise_exc_class(
          String.t(),
          [Parser.ast_node()],
          [Parser.ast_node()],
          Parser.meta(),
          Env.t(),
          Ctx.t()
        ) ::
          eval_result()
  defp eval_raise_exc_class(exc_name, args, kwargs, _meta, env, ctx) do
    # Use eval_call_args so positional args, {:kwarg, ...} entries, and
    # an explicit kwargs list are all normalized the same way regular
    # function calls are. This lets `raise SomeError("msg", code=1)`
    # work just like `SomeError("msg", code=1)` would.
    arg_exprs = args ++ List.wrap(kwargs)

    case Interpreter.eval_call_args(arg_exprs, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {values, kwargs_map, env, ctx} ->
        msg = format_exc_msg(exc_name, values)

        case Env.get(env, exc_name) do
          {:ok, {:class, _, _, _} = class} ->
            case Interpreter.call_function(class, values, kwargs_map, env, ctx) do
              {{:exception, _}, env, ctx} ->
                instance = {:instance, class, %{"args" => {:tuple, values}}}
                ctx = %{ctx | exception_instance: instance}
                {{:exception, msg}, env, ctx}

              {instance, env, ctx} ->
                derefed = Ctx.deref(ctx, instance)
                derefed = ensure_args(derefed, values)
                ctx = %{ctx | exception_instance: derefed}
                {{:exception, msg}, env, ctx}
            end

          {:ok, {:exception_class, _} = exc_cls} ->
            cls = Interpreter.exception_instance_class(exc_cls)
            instance = {:instance, cls, %{"args" => {:tuple, values}}}
            ctx = %{ctx | exception_instance: instance}
            {{:exception, msg}, env, ctx}

          _ ->
            instance =
              {:instance, {:class, exc_name, [], %{}}, %{"args" => {:tuple, values}}}

            ctx = %{ctx | exception_instance: instance}
            {{:exception, msg}, env, ctx}
        end
    end
  end

  defp ensure_args({:instance, cls, fields}, values) do
    if Map.has_key?(fields, "args") do
      {:instance, cls, fields}
    else
      {:instance, cls, Map.put(fields, "args", {:tuple, values})}
    end
  end

  defp ensure_args(other, _values), do: other

  @spec format_exc_msg(String.t(), [Interpreter.pyvalue()]) :: String.t()
  defp format_exc_msg(exc_name, values) do
    case values do
      [] ->
        exc_name

      [m] when is_binary(m) ->
        "#{exc_name}: #{m}"

      [m] ->
        "#{exc_name}: #{Helpers.py_str(m)}"

      multiple ->
        # Python's Exception.__str__ returns str(self.args).  For 2+ args
        # that renders the tuple's repr, e.g. ValueError("a", "b") -> "('a', 'b')".
        tuple_repr = Pyex.Builtins.py_repr({:tuple, multiple})
        "#{exc_name}: #{tuple_repr}"
    end
  end
end
