defmodule Pyex.Interpreter.Assignments do
  @moduledoc """
  Attribute and subscript assignment helpers for `Pyex.Interpreter`.

  Keeps write-back semantics together so mutation-heavy evaluation paths
  stay isolated from the main interpreter dispatch.
  """

  alias Pyex.{Ctx, Env, Interpreter, Parser, PyDict}
  alias Pyex.Interpreter.{ClassLookup, Dunder, Helpers}

  @typep eval_result :: {Interpreter.pyvalue() | tuple(), Env.t(), Ctx.t()}

  defguardp is_py_exception(value) when is_tuple(value) and elem(value, 0) == :exception

  @doc """
  Evaluates direct attribute assignment.
  """
  @spec eval_attr_assign(Parser.ast_node(), Parser.ast_node(), Env.t(), Ctx.t()) :: eval_result()
  def eval_attr_assign(target, expr, env, ctx) do
    case Interpreter.eval(expr, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {value, env, ctx} ->
        setattr(target, value, env, ctx)
    end
  end

  @doc """
  Evaluates augmented attribute assignment.
  """
  @spec eval_aug_attr_assign(Parser.ast_node(), atom(), Parser.ast_node(), Env.t(), Ctx.t()) ::
          eval_result()
  def eval_aug_attr_assign(target, op, expr, env, ctx) do
    case Interpreter.eval(target, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {old_value, env, ctx} ->
        case Interpreter.eval(expr, env, ctx) do
          {{:exception, _} = signal, env, ctx} ->
            {signal, env, ctx}

          {rhs, env, ctx} ->
            case Interpreter.safe_binop(op, old_value, rhs) do
              {:exception, _} = signal -> {signal, env, ctx}
              new_value -> setattr(target, new_value, env, ctx)
            end
        end
    end
  end

  @doc """
  Evaluates nested subscript assignment.
  """
  @spec eval_nested_subscript_assign(
          Parser.ast_node(),
          Parser.ast_node(),
          Parser.ast_node(),
          Parser.ast_node(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  def eval_nested_subscript_assign(
        container_expr,
        outer_key_expr,
        inner_key_expr,
        val_expr,
        env,
        ctx
      ) do
    with {raw_container, env, ctx} when not is_py_exception(raw_container) <-
           Interpreter.eval(container_expr, env, ctx),
         {outer_key, env, ctx} when not is_py_exception(outer_key) <-
           Interpreter.eval(outer_key_expr, env, ctx),
         {inner_key, env, ctx} when not is_py_exception(inner_key) <-
           Interpreter.eval(inner_key_expr, env, ctx),
         {val, env, ctx} when not is_py_exception(val) <- Interpreter.eval(val_expr, env, ctx) do
      container = Ctx.deref(ctx, raw_container)

      case get_subscript_value(container, outer_key) do
        {:exception, msg} ->
          {{:exception, msg}, env, ctx}

        {:defaultdict_call_needed, factory} ->
          case Interpreter.call_function(factory, [], %{}, env, ctx) do
            {{:exception, _} = signal, env, ctx} ->
              {signal, env, ctx}

            {default_val, env, ctx, _updated_func} ->
              default_val = Ctx.deref(ctx, default_val)
              container = set_subscript_value(container, outer_key, default_val)
              updated_inner = set_subscript_value(default_val, inner_key, val)
              updated_outer = set_subscript_value(container, outer_key, updated_inner)
              write_back_subscript(container_expr, updated_outer, env, ctx)

            {default_val, env, ctx} ->
              default_val = Ctx.deref(ctx, default_val)
              container = set_subscript_value(container, outer_key, default_val)
              updated_inner = set_subscript_value(default_val, inner_key, val)
              updated_outer = set_subscript_value(container, outer_key, updated_inner)
              write_back_subscript(container_expr, updated_outer, env, ctx)
          end

        inner_container ->
          case inner_container do
            {:ref, inner_id} ->
              derefed_inner = Ctx.deref(ctx, inner_container)
              updated_inner = set_subscript_value(derefed_inner, inner_key, val)
              ctx = Ctx.heap_put(ctx, inner_id, updated_inner)
              {val, env, ctx}

            _ ->
              inner_container = Ctx.deref(ctx, inner_container)
              updated_inner = set_subscript_value(inner_container, inner_key, val)
              updated_outer = set_subscript_value(container, outer_key, updated_inner)
              write_back_subscript(container_expr, updated_outer, env, ctx)
          end
      end
    else
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  @doc """
  Evaluates attribute-backed subscript assignment.
  """
  @spec eval_attr_subscript_assign(
          Parser.ast_node(),
          Parser.ast_node(),
          Parser.ast_node(),
          Env.t(),
          Ctx.t()
        ) ::
          eval_result()
  def eval_attr_subscript_assign(target_expr, key_expr, val_expr, env, ctx) do
    with {raw_container, env, ctx} when not is_py_exception(raw_container) <-
           Interpreter.eval(target_expr, env, ctx),
         {key, env, ctx} when not is_py_exception(key) <- Interpreter.eval(key_expr, env, ctx),
         {val, env, ctx} when not is_py_exception(val) <- Interpreter.eval(val_expr, env, ctx) do
      container = Ctx.deref(ctx, raw_container)

      case container do
        {:py_dict, _, _} = dict ->
          updated = PyDict.put(dict, key, val)
          {env, ctx} = ref_or_setattr(raw_container, updated, target_expr, env, ctx)
          {val, env, ctx}

        %{} = map ->
          updated = Map.put(map, key, val)
          {env, ctx} = ref_or_setattr(raw_container, updated, target_expr, env, ctx)
          {val, env, ctx}

        {:py_list, reversed, len} when is_integer(key) ->
          real_idx = if key < 0, do: len + key, else: key
          updated = {:py_list, List.replace_at(reversed, len - 1 - real_idx, val), len}
          {env, ctx} = ref_or_setattr(raw_container, updated, target_expr, env, ctx)
          {val, env, ctx}

        list when is_list(list) and is_integer(key) ->
          updated = List.replace_at(list, key, val)
          {env, ctx} = ref_or_setattr(raw_container, updated, target_expr, env, ctx)
          {val, env, ctx}

        _ ->
          {{:exception, "TypeError: object does not support item assignment"}, env, ctx}
      end
    else
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  @doc """
  Evaluates name-backed subscript assignment.
  """
  @spec eval_name_subscript_assign(
          String.t(),
          Parser.ast_node(),
          Parser.ast_node(),
          Env.t(),
          Ctx.t()
        ) ::
          eval_result()
  def eval_name_subscript_assign(name, key_expr, val_expr, env, ctx) do
    case key_expr do
      {:slice, _, [_obj_expr, start_expr, stop_expr, step_expr]} ->
        eval_slice_assign(name, start_expr, stop_expr, step_expr, val_expr, env, ctx)

      _ ->
        eval_index_assign(name, key_expr, val_expr, env, ctx)
    end
  end

  @spec eval_slice_assign(String.t(), term(), term(), term(), term(), Env.t(), Ctx.t()) ::
          eval_result()
  defp eval_slice_assign(name, start_expr, stop_expr, step_expr, val_expr, env, ctx) do
    with {raw_container, env, ctx} when not is_py_exception(raw_container) <-
           Interpreter.eval({:var, [line: 1], [name]}, env, ctx),
         {start, env, ctx} when not is_py_exception(start) <-
           if(is_nil(start_expr),
             do: {nil, env, ctx},
             else: Interpreter.eval(start_expr, env, ctx)
           ),
         {stop, env, ctx} when not is_py_exception(stop) <-
           if(is_nil(stop_expr),
             do: {nil, env, ctx},
             else: Interpreter.eval(stop_expr, env, ctx)
           ),
         {step, env, ctx} when not is_py_exception(step) <-
           if(is_nil(step_expr),
             do: {nil, env, ctx},
             else: Interpreter.eval(step_expr, env, ctx)
           ),
         {val, env, ctx} when not is_py_exception(val) <- Interpreter.eval(val_expr, env, ctx) do
      container = Ctx.deref(ctx, raw_container)
      replacement = container_to_list(Ctx.deref(ctx, val))

      case container do
        {:py_list, reversed, _} ->
          python_list = Enum.reverse(reversed)
          n = length(python_list)
          actual_start = normalize_slice_bound(start, n, 0)
          actual_stop = normalize_slice_bound(stop, n, n)
          actual_step = if is_nil(step), do: 1, else: step

          if actual_step == 1 do
            {before, rest} = Enum.split(python_list, actual_start)
            {_removed, after_slice} = Enum.split(rest, max(actual_stop - actual_start, 0))
            updated_python = before ++ replacement ++ after_slice
            updated = {:py_list, Enum.reverse(updated_python), length(updated_python)}
            {env, ctx} = ref_write_back(raw_container, updated, name, env, ctx)
            {nil, env, ctx}
          else
            {{:exception, "NotImplementedError: slice assignment with step != 1 not supported"},
             env, ctx}
          end

        _ ->
          {{:exception, "TypeError: object does not support slice assignment"}, env, ctx}
      end
    else
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  @spec normalize_slice_bound(integer() | nil, non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp normalize_slice_bound(nil, _n, default), do: default

  defp normalize_slice_bound(idx, n, _default) when idx < 0,
    do: max(n + idx, 0)

  defp normalize_slice_bound(idx, n, _default), do: min(idx, n)

  @spec container_to_list(Interpreter.pyvalue()) :: [Interpreter.pyvalue()]
  defp container_to_list({:py_list, reversed, _}), do: Enum.reverse(reversed)
  defp container_to_list(list) when is_list(list), do: list
  defp container_to_list({:tuple, items}), do: items
  defp container_to_list(val), do: [val]

  @spec eval_index_assign(String.t(), term(), term(), Env.t(), Ctx.t()) :: eval_result()
  defp eval_index_assign(name, key_expr, val_expr, env, ctx) do
    with {raw_container, env, ctx} when not is_py_exception(raw_container) <-
           Interpreter.eval({:var, [line: 1], [name]}, env, ctx),
         {key, env, ctx} when not is_py_exception(key) <- Interpreter.eval(key_expr, env, ctx),
         {val, env, ctx} when not is_py_exception(val) <- Interpreter.eval(val_expr, env, ctx) do
      container = Ctx.deref(ctx, raw_container)

      case container do
        {:py_dict, _, _} = dict ->
          updated = PyDict.put(dict, key, val)
          {env, ctx} = ref_write_back(raw_container, updated, name, env, ctx)
          {val, env, ctx}

        %{} = map ->
          updated = Map.put(map, key, val)
          {env, ctx} = ref_write_back(raw_container, updated, name, env, ctx)
          {val, env, ctx}

        {:py_list, reversed, _len} when is_integer(key) ->
          python_list = Enum.reverse(reversed)
          real_idx = if key < 0, do: length(python_list) + key, else: key
          updated_python = List.replace_at(python_list, real_idx, val)
          updated = {:py_list, Enum.reverse(updated_python), length(updated_python)}
          {env, ctx} = ref_write_back(raw_container, updated, name, env, ctx)
          {val, env, ctx}

        {:py_list, _, _} ->
          {{:exception,
            "TypeError: list indices must be integers or slices, not #{Helpers.py_type(key)}"},
           env, ctx}

        list when is_list(list) and is_integer(key) ->
          updated = List.replace_at(list, key, val)
          {env, ctx} = ref_write_back(raw_container, updated, name, env, ctx)
          {val, env, ctx}

        list when is_list(list) and is_integer(key) ->
          updated = List.replace_at(list, key, val)
          {env, ctx} = ref_write_back(raw_container, updated, name, env, ctx)
          {val, env, ctx}

        {:instance, _, _} = inst ->
          case Dunder.call_dunder_mut(inst, "__setitem__", [key, val], env, ctx) do
            {:ok, updated_inst, _return_val, env, ctx} ->
              {env, ctx} = ref_write_back(raw_container, updated_inst, name, env, ctx)
              {val, env, ctx}

            :not_found ->
              {{:exception,
                "TypeError: '#{Helpers.py_type(inst)}' object does not support item assignment"},
               env, ctx}
          end

        _ ->
          {{:exception, "TypeError: object does not support item assignment"}, env, ctx}
      end
    else
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  @doc """
  Evaluates nested augmented subscript assignment.
  """
  @spec eval_nested_aug_subscript_assign(
          Parser.ast_node(),
          Parser.ast_node(),
          Parser.ast_node(),
          atom(),
          Parser.ast_node(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  def eval_nested_aug_subscript_assign(
        container_expr,
        outer_key_expr,
        inner_key_expr,
        op,
        val_expr,
        env,
        ctx
      ) do
    with {container, env, ctx} when not is_py_exception(container) <-
           Interpreter.eval(container_expr, env, ctx),
         {outer_key, env, ctx} when not is_py_exception(outer_key) <-
           Interpreter.eval(outer_key_expr, env, ctx),
         {inner_key, env, ctx} when not is_py_exception(inner_key) <-
           Interpreter.eval(inner_key_expr, env, ctx),
         {val, env, ctx} when not is_py_exception(val) <- Interpreter.eval(val_expr, env, ctx) do
      container = Ctx.deref(ctx, container)

      case get_subscript_value(container, outer_key) do
        {:exception, msg} ->
          {{:exception, msg}, env, ctx}

        {:defaultdict_call_needed, factory} ->
          case Interpreter.call_function(factory, [], %{}, env, ctx) do
            {{:exception, _} = signal, env, ctx} ->
              {signal, env, ctx}

            {default_val, env, ctx, _updated_func} ->
              # Auto-insert the default, then proceed with inner aug assign
              container = set_subscript_value(container, outer_key, default_val)

              do_nested_aug_inner(
                container,
                container_expr,
                outer_key,
                default_val,
                inner_key,
                op,
                val,
                env,
                ctx
              )

            {default_val, env, ctx} ->
              container = set_subscript_value(container, outer_key, default_val)

              do_nested_aug_inner(
                container,
                container_expr,
                outer_key,
                default_val,
                inner_key,
                op,
                val,
                env,
                ctx
              )
          end

        inner_container ->
          do_nested_aug_inner(
            container,
            container_expr,
            outer_key,
            inner_container,
            inner_key,
            op,
            val,
            env,
            ctx
          )
      end
    else
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  defp do_nested_aug_inner(
         container,
         container_expr,
         outer_key,
         inner_container,
         inner_key,
         op,
         val,
         env,
         ctx
       ) do
    inner_container = Ctx.deref(ctx, inner_container)

    case get_subscript_value(inner_container, inner_key) do
      {:exception, msg} ->
        {{:exception, msg}, env, ctx}

      old_val ->
        case Interpreter.safe_binop(op, old_val, val) do
          {:exception, msg} ->
            {{:exception, msg}, env, ctx}

          new_val ->
            updated_inner = set_subscript_value(inner_container, inner_key, new_val)
            updated_outer = set_subscript_value(container, outer_key, updated_inner)
            write_back_subscript(container_expr, updated_outer, env, ctx)
        end
    end
  end

  @doc """
  Evaluates attribute-backed augmented subscript assignment.
  """
  @spec eval_attr_aug_subscript_assign(
          Parser.ast_node(),
          Parser.ast_node(),
          atom(),
          Parser.ast_node(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  def eval_attr_aug_subscript_assign(target_expr, key_expr, op, val_expr, env, ctx) do
    with {raw_container, env, ctx} when not is_py_exception(raw_container) <-
           Interpreter.eval(target_expr, env, ctx),
         {key, env, ctx} when not is_py_exception(key) <- Interpreter.eval(key_expr, env, ctx),
         {val, env, ctx} when not is_py_exception(val) <- Interpreter.eval(val_expr, env, ctx) do
      container = Ctx.deref(ctx, raw_container)

      case container do
        {:py_dict, _, _} = dict ->
          old_val = PyDict.get(dict, key, 0)
          new_val = Interpreter.safe_binop(op, old_val, val)
          setattr_nested(target_expr, PyDict.put(dict, key, new_val), env, ctx)

        %{} = map ->
          old_val = Map.get(map, key, 0)
          new_val = Interpreter.safe_binop(op, old_val, val)
          setattr_nested(target_expr, Map.put(map, key, new_val), env, ctx)

        {:py_list, reversed, len} when is_integer(key) ->
          idx = if key < 0, do: len + key, else: key

          if idx < 0 or idx >= len do
            {{:exception, "IndexError: list index out of range"}, env, ctx}
          else
            old_val = Enum.at(reversed, len - 1 - idx)

            case Interpreter.safe_binop(op, old_val, val) do
              {:exception, msg} ->
                {{:exception, msg}, env, ctx}

              new_val ->
                updated = {:py_list, List.replace_at(reversed, len - 1 - idx, new_val), len}
                setattr_nested(target_expr, updated, env, ctx)
            end
          end

        list when is_list(list) and is_integer(key) ->
          idx = if key < 0, do: length(list) + key, else: key

          if idx < 0 or idx >= length(list) do
            {{:exception, "IndexError: list index out of range"}, env, ctx}
          else
            old_val = Enum.at(list, idx)

            case Interpreter.safe_binop(op, old_val, val) do
              {:exception, msg} ->
                {{:exception, msg}, env, ctx}

              new_val ->
                setattr_nested(target_expr, List.replace_at(list, idx, new_val), env, ctx)
            end
          end

        _ ->
          {{:exception, "TypeError: object does not support item assignment"}, env, ctx}
      end
    else
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  @doc """
  Evaluates name-backed augmented subscript assignment.
  """
  @spec eval_name_aug_subscript_assign(
          String.t(),
          Parser.ast_node(),
          atom(),
          Parser.ast_node(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  def eval_name_aug_subscript_assign(var_name, key_expr, op, val_expr, env, ctx) do
    case Env.get(env, var_name) do
      {:ok, raw_obj} ->
        obj = Ctx.deref(ctx, raw_obj)

        with {key, env, ctx} when not is_py_exception(key) <- Interpreter.eval(key_expr, env, ctx),
             {val, env, ctx} when not is_py_exception(val) <- Interpreter.eval(val_expr, env, ctx) do
          case get_subscript_value(obj, key) do
            {:exception, msg} ->
              {{:exception, msg}, env, ctx}

            {:defaultdict_call_needed, factory} ->
              case Interpreter.call_function(factory, [], %{}, env, ctx) do
                {{:exception, _} = signal, env, ctx} ->
                  {signal, env, ctx}

                {default_val, env, ctx, _updated_func} ->
                  do_aug_subscript(obj, key, op, val, default_val, var_name, env, ctx)

                {default_val, env, ctx} ->
                  do_aug_subscript(obj, key, op, val, default_val, var_name, env, ctx)
              end

            current_val ->
              case Interpreter.safe_binop(op, current_val, val) do
                {:exception, msg} ->
                  {{:exception, msg}, env, ctx}

                new_val ->
                  new_obj = set_subscript_value(obj, key, new_val)
                  {new_val, Env.put_at_source(env, var_name, new_obj), ctx}
              end
          end
        else
          {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
        end

      :undefined ->
        {{:exception, "NameError: name '#{var_name}' is not defined"}, env, ctx}
    end
  end

  defp do_aug_subscript(obj, key, op, val, default_val, var_name, env, ctx) do
    # Insert default into dict first (auto-insert), then apply aug op
    obj = set_subscript_value(obj, key, default_val)

    case Interpreter.safe_binop(op, default_val, val) do
      {:exception, msg} ->
        {{:exception, msg}, env, ctx}

      new_val ->
        new_obj = set_subscript_value(obj, key, new_val)
        {new_val, Env.put_at_source(env, var_name, new_obj), ctx}
    end
  end

  @doc false
  @spec setattr(Parser.ast_node(), Interpreter.pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  def setattr({:getattr, _, [{:var, _, [var_name]}, attr]}, value, env, ctx) do
    case Env.get(env, var_name) do
      {:ok, raw} ->
        case Ctx.deref(ctx, raw) do
          {:instance, class, _attrs} = inst ->
            # Check if the class has a property descriptor with a setter for this attr
            case ClassLookup.resolve_class_attr_with_owner(class, attr) do
              {:ok, {:property, _fget, fset, _fdel}, _owner} when fset != nil ->
                # Pass the ref (not the derefed instance) so __setattr__ writes back correctly
                self_arg = if match?({:ref, _}, raw), do: raw, else: inst

                case Interpreter.call_function(fset, [self_arg, value], %{}, env, ctx) do
                  {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
                  {_, env, ctx, _} -> {nil, env, ctx}
                  {_, env, ctx} -> {nil, env, ctx}
                end

              {:ok, {:property, _fget, nil, _fdel}, _owner} ->
                {{:exception,
                  "AttributeError: can't set attribute '#{attr}' — no setter defined"}, env, ctx}

              _ ->
                # Regular instance attribute assignment
                updated = put_elem(inst, 2, Map.put(elem(inst, 2), attr, value))

                case raw do
                  {:ref, id} -> {nil, env, Ctx.heap_put(ctx, id, updated)}
                  _ -> {nil, Env.put_at_source(env, var_name, updated), ctx}
                end
            end

          {:class, name, bases, class_attrs} ->
            updated = {:class, name, bases, Map.put(class_attrs, attr, value)}
            {nil, Env.put_at_source(env, var_name, updated), ctx}

          {:py_dict, _, _} = dict ->
            {nil, Env.put_at_source(env, var_name, PyDict.put(dict, attr, value)), ctx}

          other when is_map(other) ->
            {nil, Env.put_at_source(env, var_name, Map.put(other, attr, value)), ctx}

          {:function, _, _, _, _} = func ->
            wrapped = {:func_with_attrs, func, %{attr => value}}
            {nil, Env.put_at_source(env, var_name, wrapped), ctx}

          {:func_with_attrs, func, attrs} ->
            wrapped = {:func_with_attrs, func, Map.put(attrs, attr, value)}
            {nil, Env.put_at_source(env, var_name, wrapped), ctx}

          _ ->
            {{:exception, "AttributeError: cannot set attribute '#{attr}'"}, env, ctx}
        end

      _ ->
        {{:exception, "AttributeError: cannot set attribute '#{attr}'"}, env, ctx}
    end
  end

  def setattr({:getattr, _, [inner_target, attr]}, value, env, ctx) do
    case Interpreter.eval(inner_target, env, ctx) do
      {{:exception, _} = signal, env, ctx} ->
        {signal, env, ctx}

      {raw, env, ctx} ->
        case Ctx.deref(ctx, raw) do
          {:instance, class, attrs} ->
            updated = {:instance, class, Map.put(attrs, attr, value)}

            case raw do
              {:ref, id} -> {nil, env, Ctx.heap_put(ctx, id, updated)}
              _ -> write_back_target(inner_target, updated, env, ctx)
            end

          _ ->
            {{:exception, "AttributeError: cannot set attribute '#{attr}'"}, env, ctx}
        end
    end
  end

  def setattr(_target, _value, env, ctx) do
    {{:exception, "SyntaxError: cannot assign to attribute"}, env, ctx}
  end

  @doc false
  @spec setattr_nested(Parser.ast_node(), Interpreter.pyvalue(), Env.t(), Ctx.t()) ::
          eval_result()
  def setattr_nested({:getattr, meta, [obj_expr, attr]}, value, env, ctx) do
    setattr({:getattr, meta, [obj_expr, attr]}, value, env, ctx)
  end

  @doc false
  @spec get_subscript_value(Interpreter.pyvalue(), Interpreter.pyvalue()) ::
          Interpreter.pyvalue() | {:exception, String.t()}
  def get_subscript_value({:py_dict, _, _} = dict, key) do
    case PyDict.fetch(dict, key) do
      {:ok, val} ->
        val

      :error ->
        case PyDict.fetch(dict, "__defaultdict_factory__") do
          {:ok, {:builtin_type, _, func}} -> func.([])
          {:ok, {:builtin, func}} -> func.([])
          {:ok, {:function, _, _, _, _} = func} -> {:defaultdict_call_needed, func}
          _ -> {:exception, "KeyError: #{inspect(key)}"}
        end
    end
  end

  def get_subscript_value(obj, key) when is_map(obj) do
    case Map.fetch(obj, key) do
      {:ok, val} ->
        val

      :error ->
        case Map.fetch(obj, "__defaultdict_factory__") do
          {:ok, {:builtin_type, _, func}} -> func.([])
          {:ok, {:builtin, func}} -> func.([])
          {:ok, {:function, _, _, _, _} = func} -> {:defaultdict_call_needed, func}
          _ -> {:exception, "KeyError: #{inspect(key)}"}
        end
    end
  end

  def get_subscript_value({:py_list, reversed, len}, key) when is_integer(key) do
    idx = if key < 0, do: len + key, else: key

    if idx < 0 or idx >= len do
      {:exception, "IndexError: list index out of range"}
    else
      Enum.at(reversed, len - 1 - idx)
    end
  end

  def get_subscript_value(obj, key) when is_list(obj) and is_integer(key) do
    len = length(obj)
    idx = if key < 0, do: len + key, else: key

    if idx < 0 or idx >= len do
      {:exception, "IndexError: list index out of range"}
    else
      Enum.at(obj, idx)
    end
  end

  def get_subscript_value(_, _), do: {:exception, "TypeError: object is not subscriptable"}

  @doc false
  @spec set_subscript_value(Interpreter.pyvalue(), Interpreter.pyvalue(), Interpreter.pyvalue()) ::
          Interpreter.pyvalue()
  def set_subscript_value({:py_dict, _, _} = dict, key, val), do: PyDict.put(dict, key, val)
  def set_subscript_value(obj, key, val) when is_map(obj), do: Map.put(obj, key, val)

  def set_subscript_value({:py_list, reversed, len}, key, val) when is_integer(key) do
    idx = if key < 0, do: len + key, else: key
    {:py_list, List.replace_at(reversed, len - 1 - idx, val), len}
  end

  def set_subscript_value(obj, key, val) when is_list(obj) and is_integer(key) do
    List.replace_at(obj, key, val)
  end

  @doc false
  @spec delete_subscript_value(Interpreter.pyvalue(), Interpreter.pyvalue()) ::
          Interpreter.pyvalue() | {:exception, String.t()}
  def delete_subscript_value({:py_dict, _, _} = dict, key), do: PyDict.delete(dict, key)
  def delete_subscript_value(obj, key) when is_map(obj), do: Map.delete(obj, key)

  def delete_subscript_value({:py_list, reversed, len}, key) when is_integer(key) do
    idx = if key < 0, do: len + key, else: key

    if idx < 0 or idx >= len do
      {:exception, "IndexError: list index out of range"}
    else
      {:py_list, List.delete_at(reversed, len - 1 - idx), len - 1}
    end
  end

  def delete_subscript_value(obj, key) when is_list(obj) and is_integer(key) do
    len = length(obj)
    idx = if key < 0, do: len + key, else: key

    if idx < 0 or idx >= len do
      {:exception, "IndexError: list index out of range"}
    else
      List.delete_at(obj, idx)
    end
  end

  def delete_subscript_value(_, _),
    do: {:exception, "TypeError: object does not support item deletion"}

  @spec write_back_target(Parser.ast_node(), Interpreter.pyvalue(), Env.t(), Ctx.t()) ::
          eval_result()
  defp write_back_target({:var, _, [name]}, updated, env, ctx) do
    {updated, Env.put_at_source(env, name, updated), ctx}
  end

  defp write_back_target({:getattr, _, _} = target, updated, env, ctx) do
    setattr_nested(target, updated, env, ctx)
  end

  defp write_back_target(_, updated, env, ctx) do
    {updated, env, ctx}
  end

  @doc false
  @spec write_back_subscript(Parser.ast_node(), Interpreter.pyvalue(), Env.t(), Ctx.t()) ::
          eval_result()
  def write_back_subscript({:var, _, [name]}, updated, env, ctx) do
    case Env.get(env, name) do
      {:ok, {:ref, id}} -> {updated, env, Ctx.heap_put(ctx, id, updated)}
      _ -> {updated, Env.put_at_source(env, name, updated), ctx}
    end
  end

  def write_back_subscript({:subscript, _, [parent_expr, key_expr]}, updated, env, ctx) do
    {raw_parent, env, ctx} = Interpreter.eval(parent_expr, env, ctx)
    parent = Ctx.deref(ctx, raw_parent)
    {key, env, ctx} = Interpreter.eval(key_expr, env, ctx)
    updated_parent = set_subscript_value(parent, key, updated)
    write_back_subscript(parent_expr, updated_parent, env, ctx)
  end

  def write_back_subscript({:getattr, _, _} = target, updated, env, ctx) do
    setattr_nested(target, updated, env, ctx)
  end

  def write_back_subscript(_, updated, env, ctx) do
    {updated, env, ctx}
  end

  @spec ref_write_back(Interpreter.pyvalue(), term(), String.t(), Env.t(), Ctx.t()) ::
          {Env.t(), Ctx.t()}
  defp ref_write_back({:ref, id}, updated, _name, env, ctx) do
    {env, Ctx.heap_put(ctx, id, updated)}
  end

  defp ref_write_back(_raw, updated, name, env, ctx) do
    {Env.put_at_source(env, name, updated), ctx}
  end

  @spec ref_or_setattr(Interpreter.pyvalue(), term(), Parser.ast_node(), Env.t(), Ctx.t()) ::
          {Env.t(), Ctx.t()}
  defp ref_or_setattr({:ref, id}, updated, _target_expr, env, ctx) do
    {env, Ctx.heap_put(ctx, id, updated)}
  end

  defp ref_or_setattr(_raw, updated, target_expr, env, ctx) do
    {_, env, ctx} = setattr_nested(target_expr, updated, env, ctx)
    {env, ctx}
  end
end
