defmodule Pyex.Interpreter.Match do
  @moduledoc """
  Structural pattern matching for `match`/`case` statements (Python 3.10+).

  Handles wildcard, capture, or-pattern, sequence, mapping, class,
  literal, and attribute patterns. Bindings are accumulated as a
  flat list of `{name, value}` pairs and applied to the environment
  when a case arm matches.
  """

  alias Pyex.{Ctx, Env, Interpreter}

  @typep match_bindings :: [{String.t(), Interpreter.pyvalue()}]

  @doc """
  Evaluates match/case statement arms against a subject value.

  Tries each `{pattern, guard, body}` arm in order. Returns the
  result of the first matching arm's body, or `{nil, env, ctx}`
  if no arm matches.
  """
  @spec eval_match_cases(Interpreter.pyvalue(), [term()], Env.t(), Ctx.t()) ::
          {Interpreter.pyvalue() | term(), Env.t(), Ctx.t()}
  def eval_match_cases(_subject, [], env, ctx) do
    {nil, env, ctx}
  end

  def eval_match_cases(subject, [{pattern, guard, body} | rest], env, ctx) do
    case match_pattern(subject, pattern, env, ctx) do
      {:ok, bindings} ->
        env = Enum.reduce(bindings, env, fn {name, value}, env -> Env.put(env, name, value) end)

        if guard do
          case Interpreter.eval(guard, env, ctx) do
            {{:exception, _} = signal, env, ctx} ->
              {signal, env, ctx}

            {guard_val, env, ctx} ->
              {taken, env, ctx} = Interpreter.eval_truthy(guard_val, env, ctx)

              if taken do
                ctx = Ctx.record(ctx, :branch, {:match, true})
                Interpreter.eval_statements(body, env, ctx)
              else
                eval_match_cases(subject, rest, env, ctx)
              end
          end
        else
          ctx = Ctx.record(ctx, :branch, {:match, true})
          Interpreter.eval_statements(body, env, ctx)
        end

      :no_match ->
        eval_match_cases(subject, rest, env, ctx)
    end
  end

  @spec match_pattern(Interpreter.pyvalue(), term(), Env.t(), Ctx.t()) ::
          {:ok, match_bindings()} | :no_match
  defp match_pattern(_subject, {:match_wildcard, _, []}, _env, _ctx) do
    {:ok, []}
  end

  defp match_pattern(subject, {:match_capture, _, [name]}, _env, _ctx) do
    {:ok, [{name, subject}]}
  end

  defp match_pattern(subject, {:match_or, _, alternatives}, env, ctx) do
    Enum.find_value(alternatives, :no_match, fn alt ->
      case match_pattern(subject, alt, env, ctx) do
        {:ok, _} = result -> result
        :no_match -> nil
      end
    end)
  end

  defp match_pattern(subject, {:match_sequence, _, patterns}, env, ctx) do
    items =
      case subject do
        list when is_list(list) -> list
        {:tuple, elems} -> elems
        _ -> nil
      end

    if items do
      match_sequence_patterns(items, patterns, env, ctx, [])
    else
      :no_match
    end
  end

  defp match_pattern(subject, {:match_mapping, _, pairs}, env, ctx) when is_map(subject) do
    match_mapping_patterns(subject, pairs, env, ctx, [])
  end

  defp match_pattern(_subject, {:match_mapping, _, _pairs}, _env, _ctx) do
    :no_match
  end

  defp match_pattern(
         subject,
         {:match_class, _, [class_name, pos_patterns, kw_patterns]},
         env,
         ctx
       ) do
    case subject do
      {:instance, {:class, ^class_name, _, _} = _cls, attrs} ->
        match_class_patterns(attrs, pos_patterns, kw_patterns, env, ctx)

      _ ->
        :no_match
    end
  end

  defp match_pattern(subject, {:lit, _, [value]}, _env, _ctx) do
    if subject == value, do: {:ok, []}, else: :no_match
  end

  defp match_pattern(subject, {:getattr, _, [{:var, _, [obj_name]}, attr]}, env, _ctx) do
    case Env.get(env, obj_name) do
      {:ok, obj_val} ->
        attr_val =
          case obj_val do
            {:class, _, _, attrs} -> Map.get(attrs, attr)
            %{} = mod -> Map.get(mod, attr)
            _ -> nil
          end

        if subject == attr_val, do: {:ok, []}, else: :no_match

      :undefined ->
        :no_match
    end
  end

  defp match_pattern(_subject, _pattern, _env, _ctx) do
    :no_match
  end

  @spec match_sequence_patterns(
          [Interpreter.pyvalue()],
          [term()],
          Env.t(),
          Ctx.t(),
          match_bindings()
        ) ::
          {:ok, match_bindings()} | :no_match
  defp match_sequence_patterns([], [], _env, _ctx, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp match_sequence_patterns(remaining, [{:match_star, _, [name]}], _env, _ctx, acc) do
    bindings = if name, do: [{name, remaining} | acc], else: acc
    {:ok, Enum.reverse(bindings)}
  end

  defp match_sequence_patterns([], _patterns, _env, _ctx, _acc) do
    :no_match
  end

  defp match_sequence_patterns(_items, [], _env, _ctx, _acc) do
    :no_match
  end

  defp match_sequence_patterns([item | items], [pattern | patterns], env, ctx, acc) do
    case match_pattern(item, pattern, env, ctx) do
      {:ok, bindings} ->
        match_sequence_patterns(items, patterns, env, ctx, Enum.reverse(bindings) ++ acc)

      :no_match ->
        :no_match
    end
  end

  @spec match_mapping_patterns(
          map(),
          [{term(), term()}],
          Env.t(),
          Ctx.t(),
          match_bindings()
        ) ::
          {:ok, match_bindings()} | :no_match
  defp match_mapping_patterns(_subject, [], _env, _ctx, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp match_mapping_patterns(subject, [{key_node, value_pattern} | rest], env, ctx, acc) do
    {key_val, _, _} = Interpreter.eval(key_node, env, ctx)

    case Map.fetch(subject, key_val) do
      {:ok, val} ->
        case match_pattern(val, value_pattern, env, ctx) do
          {:ok, bindings} ->
            match_mapping_patterns(subject, rest, env, ctx, Enum.reverse(bindings) ++ acc)

          :no_match ->
            :no_match
        end

      :error ->
        :no_match
    end
  end

  @spec match_class_patterns(
          %{optional(String.t()) => Interpreter.pyvalue()},
          [term()],
          [{String.t(), term()}],
          Env.t(),
          Ctx.t()
        ) :: {:ok, match_bindings()} | :no_match
  defp match_class_patterns(attrs, pos_patterns, kw_patterns, env, ctx) do
    kw_result =
      Enum.reduce_while(kw_patterns, {:ok, []}, fn {attr_name, pattern}, {:ok, acc} ->
        case Map.fetch(attrs, attr_name) do
          {:ok, val} ->
            case match_pattern(val, pattern, env, ctx) do
              {:ok, bindings} -> {:cont, {:ok, bindings ++ acc}}
              :no_match -> {:halt, :no_match}
            end

          :error ->
            {:halt, :no_match}
        end
      end)

    case {kw_result, pos_patterns} do
      {{:ok, bindings}, []} -> {:ok, bindings}
      {{:ok, _}, _} -> :no_match
      {:no_match, _} -> :no_match
    end
  end
end
