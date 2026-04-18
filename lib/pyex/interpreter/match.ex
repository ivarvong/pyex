defmodule Pyex.Interpreter.Match do
  @moduledoc """
  Structural pattern matching for `match`/`case` statements (Python 3.10+).

  Handles wildcard, capture, or-pattern, sequence, mapping, class,
  literal, and attribute patterns. Bindings are accumulated as a
  flat list of `{name, value}` pairs and applied to the environment
  when a case arm matches.
  """

  alias Pyex.{Ctx, Env, Interpreter, PyDict}

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
    subject = Ctx.deref(ctx, subject)

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
                Interpreter.eval_statements(body, env, ctx)
              else
                eval_match_cases(subject, rest, env, ctx)
              end
          end
        else
          Interpreter.eval_statements(body, env, ctx)
        end

      :no_match ->
        eval_match_cases(subject, rest, env, ctx)
    end
  end

  @spec match_pattern(Interpreter.pyvalue(), term(), Env.t(), Ctx.t()) ::
          {:ok, match_bindings()} | :no_match
  defp match_pattern({:ref, _} = ref, pattern, env, ctx) do
    match_pattern(Ctx.deref(ctx, ref), pattern, env, ctx)
  end

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
        {:py_list, reversed, _} -> Enum.reverse(reversed)
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

  defp match_pattern({:py_dict, _, _} = subject, {:match_mapping, _, pairs}, env, ctx) do
    match_mapping_patterns(subject, pairs, env, ctx, [])
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
      {:instance, {:class, ^class_name, _, class_attrs}, _attrs} = inst ->
        match_class_patterns(inst, class_attrs, pos_patterns, kw_patterns, env, ctx)

      # Exception-class pattern support: reify via the hierarchy module.
      {:instance, {:class, subj_name, _, class_attrs}, _attrs} = inst ->
        if class_is_subclass?(subj_name, class_name, env) do
          match_class_patterns(inst, class_attrs, pos_patterns, kw_patterns, env, ctx)
        else
          :no_match
        end

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

  @spec class_is_subclass?(String.t(), String.t(), Env.t()) :: boolean()
  defp class_is_subclass?(subj, subj, _env), do: true

  defp class_is_subclass?(subj, target, env) do
    cond do
      Pyex.ExceptionsHierarchy.subclass?(subj, target) ->
        true

      match?({:ok, {:class, _, _, _}}, Env.get(env, subj)) ->
        {:ok, {:class, _, bases, _}} = Env.get(env, subj)

        Enum.any?(bases, fn
          {:class, bn, _, _} -> class_is_subclass?(bn, target, env)
          {:var, _, [bn]} -> class_is_subclass?(bn, target, env)
          _ -> false
        end)

      true ->
        false
    end
  end

  @spec match_sequence_patterns(
          [Interpreter.pyvalue()],
          [term()],
          Env.t(),
          Ctx.t(),
          match_bindings()
        ) ::
          {:ok, match_bindings()} | :no_match
  defp match_sequence_patterns(items, patterns, env, ctx, acc) do
    # CPython allows at most one star in a sequence pattern, and it may
    # appear in any position.  Split the patterns at the star (if any)
    # and match head + tail against the corresponding slices of items.
    case Enum.find_index(patterns, &match?({:match_star, _, _}, &1)) do
      nil ->
        match_fixed_sequence(items, patterns, env, ctx, acc)

      idx ->
        head = Enum.take(patterns, idx)
        [{:match_star, _, [star_name]} | tail] = Enum.drop(patterns, idx)

        items_len = length(items)
        head_len = length(head)
        tail_len = length(tail)

        if items_len < head_len + tail_len do
          :no_match
        else
          star_count = items_len - head_len - tail_len
          head_items = Enum.take(items, head_len)
          tail_items = Enum.drop(items, head_len + star_count)
          star_items = items |> Enum.drop(head_len) |> Enum.take(star_count)

          with {:ok, acc1} <- match_fixed_sequence(head_items, head, env, ctx, acc),
               acc1 =
                 if(star_name, do: [{star_name, star_items} | acc1], else: acc1),
               {:ok, acc2} <- match_fixed_sequence(tail_items, tail, env, ctx, acc1) do
            {:ok, acc2}
          end
        end
    end
  end

  @spec match_fixed_sequence(
          [Interpreter.pyvalue()],
          [term()],
          Env.t(),
          Ctx.t(),
          match_bindings()
        ) :: {:ok, match_bindings()} | :no_match
  defp match_fixed_sequence([], [], _env, _ctx, acc), do: {:ok, acc}
  defp match_fixed_sequence([], _, _env, _ctx, _acc), do: :no_match
  defp match_fixed_sequence(_, [], _env, _ctx, _acc), do: :no_match

  defp match_fixed_sequence([item | items], [pattern | patterns], env, ctx, acc) do
    case match_pattern(item, pattern, env, ctx) do
      {:ok, bindings} ->
        match_fixed_sequence(items, patterns, env, ctx, Enum.reverse(bindings) ++ acc)

      :no_match ->
        :no_match
    end
  end

  @spec match_mapping_patterns(
          map() | PyDict.t(),
          [{term(), term()}],
          Env.t(),
          Ctx.t(),
          match_bindings()
        ) ::
          {:ok, match_bindings()} | :no_match
  defp match_mapping_patterns(_subject, [], _env, _ctx, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp match_mapping_patterns(
         {:py_dict, _, _} = subject,
         [{key_node, value_pattern} | rest],
         env,
         ctx,
         acc
       ) do
    {key_val, _, _} = Interpreter.eval(key_node, env, ctx)

    case PyDict.fetch(subject, key_val) do
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
          Interpreter.pyvalue(),
          %{optional(String.t()) => Interpreter.pyvalue()},
          [term()],
          [{String.t(), term()}],
          Env.t(),
          Ctx.t()
        ) :: {:ok, match_bindings()} | :no_match
  defp match_class_patterns(inst, class_attrs, pos_patterns, kw_patterns, env, ctx) do
    {:instance, _, inst_attrs} = inst

    with {:ok, pos_bindings} <- match_positional(inst_attrs, class_attrs, pos_patterns, env, ctx),
         {:ok, kw_bindings} <- match_keyword(inst_attrs, kw_patterns, env, ctx) do
      {:ok, pos_bindings ++ kw_bindings}
    end
  end

  @spec match_positional(
          map(),
          map(),
          [term()],
          Env.t(),
          Ctx.t()
        ) :: {:ok, match_bindings()} | :no_match
  defp match_positional(_inst_attrs, _class_attrs, [], _env, _ctx), do: {:ok, []}

  defp match_positional(inst_attrs, class_attrs, patterns, env, ctx) do
    # Class pattern Point(0, y) resolves positional patterns to attribute
    # names via the class's __match_args__ tuple.  Without it, positional
    # patterns are only valid for single-arg class patterns matching
    # built-in classes that accept a self-value (int, str, etc.), but
    # we don't implement that edge case.
    case Map.get(class_attrs, "__match_args__") do
      {:tuple, arg_names} when length(arg_names) >= length(patterns) ->
        pairs = Enum.zip(arg_names, patterns)

        Enum.reduce_while(pairs, {:ok, []}, fn {arg_name, pattern}, {:ok, acc} ->
          case Map.fetch(inst_attrs, arg_name) do
            {:ok, val} ->
              case match_pattern(val, pattern, env, ctx) do
                {:ok, bindings} -> {:cont, {:ok, acc ++ bindings}}
                :no_match -> {:halt, :no_match}
              end

            :error ->
              {:halt, :no_match}
          end
        end)

      _ ->
        :no_match
    end
  end

  @spec match_keyword(
          map(),
          [{String.t(), term()}],
          Env.t(),
          Ctx.t()
        ) :: {:ok, match_bindings()} | :no_match
  defp match_keyword(inst_attrs, kw_patterns, env, ctx) do
    Enum.reduce_while(kw_patterns, {:ok, []}, fn {attr_name, pattern}, {:ok, acc} ->
      case Map.fetch(inst_attrs, attr_name) do
        {:ok, val} ->
          case match_pattern(val, pattern, env, ctx) do
            {:ok, bindings} -> {:cont, {:ok, acc ++ bindings}}
            :no_match -> {:halt, :no_match}
          end

        :error ->
          {:halt, :no_match}
      end
    end)
  end
end
