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
  Evaluates subscript assignment on an arbitrary expression target.

  Handles cases like `f()[k] = v` or `obj.method()[k] = v` where the
  subscript container is the result of evaluating an expression. Writes
  through heap refs; non-ref temporaries are updated and discarded (matches
  CPython behavior — no error, but the mutation has no lasting effect).
  """
  @spec eval_expr_subscript_assign(
          Parser.ast_node(),
          Parser.ast_node(),
          Parser.ast_node() | {:__evaluated__, Interpreter.pyvalue()},
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  def eval_expr_subscript_assign(target_expr, key_expr, val_expr, env, ctx) do
    with {raw_container, env, ctx} when not is_py_exception(raw_container) <-
           Interpreter.eval(target_expr, env, ctx),
         {key, env, ctx} when not is_py_exception(key) <- Interpreter.eval(key_expr, env, ctx),
         {val, env, ctx} when not is_py_exception(val) <- Interpreter.eval(val_expr, env, ctx) do
      container = Ctx.deref(ctx, raw_container)

      case container do
        {:py_dict, _, _} = dict ->
          updated = PyDict.put(dict, key, val)
          ctx = maybe_heap_put(ctx, raw_container, updated)
          {val, env, ctx}

        %{} = map ->
          updated = Map.put(map, key, val)
          ctx = maybe_heap_put(ctx, raw_container, updated)
          {val, env, ctx}

        {:py_list, reversed, _len} when is_integer(key) ->
          python_list = Enum.reverse(reversed)
          real_idx = if key < 0, do: length(python_list) + key, else: key
          updated_python = List.replace_at(python_list, real_idx, val)
          updated = {:py_list, Enum.reverse(updated_python), length(updated_python)}
          ctx = maybe_heap_put(ctx, raw_container, updated)
          {val, env, ctx}

        {:instance, _, _} = inst ->
          case Dunder.call_dunder_mut(inst, "__setitem__", [key, val], env, ctx) do
            {:ok, updated_inst, _return_val, env, ctx} ->
              ctx = maybe_heap_put(ctx, raw_container, updated_inst)
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

  @spec maybe_heap_put(Ctx.t(), Interpreter.pyvalue(), Interpreter.pyvalue()) :: Ctx.t()
  defp maybe_heap_put(ctx, {:ref, id}, updated), do: Ctx.heap_put(ctx, id, updated)
  defp maybe_heap_put(ctx, _raw, _updated), do: ctx

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
          case splice_list(Enum.reverse(reversed), start, stop, step, replacement) do
            {:exception, _} = e ->
              {e, env, ctx}

            updated_python ->
              updated = {:py_list, Enum.reverse(updated_python), length(updated_python)}
              {env, ctx} = ref_write_back(raw_container, updated, name, env, ctx)
              {nil, env, ctx}
          end

        {:bytearray, bin} ->
          with bytes <- :binary.bin_to_list(bin),
               repl when is_list(repl) <- bytearray_bytes(Ctx.deref(ctx, val)),
               result when is_list(result) <- splice_list(bytes, start, stop, step, repl) do
            updated = {:bytearray, :binary.list_to_bin(result)}
            {env, ctx} = ref_write_back(raw_container, updated, name, env, ctx)
            {nil, env, ctx}
          else
            {:exception, _} = e -> {e, env, ctx}
          end

        _ ->
          {{:exception, "TypeError: object does not support slice assignment"}, env, ctx}
      end
    else
      {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
    end
  end

  # Slice assignment on a list: contiguous (step 1, may grow/shrink) or
  # extended (step != 1, element-wise, replacement length must match).
  @spec splice_list([term()], integer() | nil, integer() | nil, integer() | nil, [term()]) ::
          [term()] | {:exception, String.t()}
  defp splice_list(list, start, stop, step, replacement) do
    n = length(list)

    if step in [nil, 1] do
      lo = normalize_slice_bound(start, n, 0)
      hi = normalize_slice_bound(stop, n, n)
      {before, rest} = Enum.split(list, lo)
      {_removed, tail} = Enum.split(rest, max(hi - lo, 0))
      before ++ replacement ++ tail
    else
      indices = slice_indices(start, stop, step, n)

      if length(indices) != length(replacement) do
        {:exception,
         "ValueError: attempt to assign sequence of size #{length(replacement)} " <>
           "to extended slice of size #{length(indices)}"}
      else
        repl = Map.new(Enum.zip(indices, replacement))
        Enum.map(0..(n - 1)//1, fn i -> Map.get(repl, i, Enum.at(list, i)) end)
      end
    end
  end

  # The concrete indices a slice selects (CPython's slice.indices), used
  # for extended-step assignment and deletion.
  @spec slice_indices(integer() | nil, integer() | nil, integer() | nil, non_neg_integer()) ::
          [non_neg_integer()]
  def slice_indices(start, stop, step, n) do
    step = step || 1

    {lo, hi} =
      if step > 0 do
        {clamp_index(start, n, 0, 0, n), clamp_index(stop, n, n, 0, n)}
      else
        {clamp_index(start, n, n - 1, -1, n - 1), clamp_index(stop, n, -1, -1, n - 1)}
      end

    Stream.iterate(lo, &(&1 + step))
    |> Enum.take_while(fn i -> if step > 0, do: i < hi, else: i > hi end)
  end

  # Resolve a slice bound to a concrete index: nil -> `default`, negative
  # wraps, then clamp into [lo, hi].
  defp clamp_index(nil, _n, default, _lo, _hi), do: default

  defp clamp_index(i, n, _default, lo, hi) do
    i = if i < 0, do: i + n, else: i
    i |> max(lo) |> min(hi)
  end

  @spec bytearray_bytes(term()) :: [byte()] | {:exception, String.t()}
  defp bytearray_bytes({:bytes, bin}), do: :binary.bin_to_list(bin)
  defp bytearray_bytes({:bytearray, bin}), do: :binary.bin_to_list(bin)
  defp bytearray_bytes(list) when is_list(list), do: list
  defp bytearray_bytes(_), do: {:exception, "TypeError: can assign only bytes to bytearray slice"}

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

        {:py_list, reversed, len} when is_integer(key) ->
          if key < -len or key >= len do
            {{:exception, "IndexError: list assignment index out of range"}, env, ctx}
          else
            python_list = Enum.reverse(reversed)
            real_idx = if key < 0, do: len + key, else: key
            updated_python = List.replace_at(python_list, real_idx, val)
            updated = {:py_list, Enum.reverse(updated_python), length(updated_python)}
            {env, ctx} = ref_write_back(raw_container, updated, name, env, ctx)
            {val, env, ctx}
          end

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

        {:bytearray, bin} when is_integer(key) ->
          bytes = :binary.bin_to_list(bin)
          len = length(bytes)

          cond do
            key < -len or key >= len ->
              {{:exception, "IndexError: bytearray index out of range"}, env, ctx}

            not is_integer(val) or val < 0 or val > 255 ->
              {{:exception, "ValueError: byte must be in range(0, 256)"}, env, ctx}

            true ->
              idx = if key < 0, do: len + key, else: key
              updated = {:bytearray, :binary.list_to_bin(List.replace_at(bytes, idx, val))}
              {env, ctx} = ref_write_back(raw_container, updated, name, env, ctx)
              {val, env, ctx}
          end

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
                  do_aug_subscript(raw_obj, obj, key, op, val, default_val, var_name, env, ctx)

                {default_val, env, ctx} ->
                  do_aug_subscript(raw_obj, obj, key, op, val, default_val, var_name, env, ctx)
              end

            current_val ->
              # Deref both operands: a subscript value may be a heap ref
              # (`x[0]` when x's elements are mutable), which the raw binop
              # dispatch can't add directly.
              case Interpreter.safe_binop(op, Ctx.deref(ctx, current_val), Ctx.deref(ctx, val)) do
                {:exception, msg} ->
                  {{:exception, msg}, env, ctx}

                new_val ->
                  new_obj = set_subscript_value(obj, key, new_val)
                  {env, ctx} = ref_write_back(raw_obj, new_obj, var_name, env, ctx)
                  {new_val, env, ctx}
              end
          end
        else
          {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
        end

      :undefined ->
        {{:exception, "NameError: name '#{var_name}' is not defined"}, env, ctx}
    end
  end

  defp do_aug_subscript(raw_obj, obj, key, op, val, default_val, var_name, env, ctx) do
    # Insert default into dict first (auto-insert), then apply aug op
    obj = set_subscript_value(obj, key, default_val)

    case Interpreter.safe_binop(op, default_val, val) do
      {:exception, msg} ->
        {{:exception, msg}, env, ctx}

      new_val ->
        new_obj = set_subscript_value(obj, key, new_val)
        {env, ctx} = ref_write_back(raw_obj, new_obj, var_name, env, ctx)
        {new_val, env, ctx}
    end
  end

  @doc false
  @spec setattr(Parser.ast_node(), Interpreter.pyvalue(), Env.t(), Ctx.t()) :: eval_result()
  @spec fallback_instance_attr_assign(
          Interpreter.pyvalue(),
          Interpreter.pyvalue(),
          String.t(),
          String.t(),
          Interpreter.pyvalue(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp fallback_instance_attr_assign(inst, raw, var_name, attr, value, env, ctx) do
    updated = put_elem(inst, 2, Map.put(elem(inst, 2), attr, value))

    case raw do
      {:ref, id} -> {nil, env, Ctx.heap_put(ctx, id, updated)}
      _ -> {nil, Env.put_at_source(env, var_name, updated), ctx}
    end
  end

  @spec check_slots_and_assign(
          Interpreter.pyvalue(),
          Interpreter.pyvalue(),
          String.t(),
          String.t(),
          Interpreter.pyvalue(),
          Env.t(),
          Ctx.t()
        ) :: eval_result()
  defp check_slots_and_assign({:instance, class, _} = inst, raw, var_name, attr, value, env, ctx) do
    case slot_names(class) do
      {:ok, slots} ->
        if attr in slots do
          fallback_instance_attr_assign(inst, raw, var_name, attr, value, env, ctx)
        else
          {:class, class_name, _, _} = class

          {{:exception, "AttributeError: '#{class_name}' object has no attribute '#{attr}'"}, env,
           ctx}
        end

      :no_slots ->
        fallback_instance_attr_assign(inst, raw, var_name, attr, value, env, ctx)
    end
  end

  @spec slot_names(Interpreter.pyvalue()) :: {:ok, [String.t()]} | :no_slots
  defp slot_names({:class, _, bases, class_attrs}) do
    case Map.fetch(class_attrs, "__slots__") do
      {:ok, slots_val} ->
        {:ok, slots_to_names(slots_val) ++ inherited_slots(bases)}

      :error ->
        # __slots__ enforcement only kicks in when *some* class in the MRO
        # defines it AND every class in the MRO either defines __slots__ or
        # is a known-safe base (`object`).  If any class lacks __slots__ and
        # isn't `object`, the instance has a __dict__ and accepts any attr.
        if bases == [] do
          :no_slots
        else
          case inherited_slots_all(bases) do
            :partial -> :no_slots
            :unrestricted -> :no_slots
            names -> if names == [], do: :no_slots, else: {:ok, names}
          end
        end
    end
  end

  defp slot_names(_), do: :no_slots

  @spec slots_to_names(Interpreter.pyvalue()) :: [String.t()]
  defp slots_to_names({:tuple, items}), do: Enum.filter(items, &is_binary/1)

  defp slots_to_names({:py_list, reversed, _}),
    do: reversed |> Enum.reverse() |> Enum.filter(&is_binary/1)

  defp slots_to_names(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp slots_to_names(s) when is_binary(s), do: [s]
  defp slots_to_names(_), do: []

  @spec inherited_slots([Interpreter.pyvalue()]) :: [String.t()]
  defp inherited_slots(bases) do
    Enum.flat_map(bases, fn base ->
      case slot_names(base) do
        {:ok, names} -> names
        :no_slots -> []
      end
    end)
  end

  @spec inherited_slots_all([Interpreter.pyvalue()]) :: [String.t()] | :partial | :unrestricted
  defp inherited_slots_all([]), do: :unrestricted

  defp inherited_slots_all(bases) do
    Enum.reduce_while(bases, [], fn base, acc ->
      case slot_names(base) do
        {:ok, names} -> {:cont, acc ++ names}
        :no_slots -> {:halt, :partial}
      end
    end)
  end

  def setattr({:getattr, _, [{:var, _, [var_name]}, attr]}, value, env, ctx) do
    case Env.get(env, var_name) do
      {:ok, raw} ->
        case Ctx.deref(ctx, raw) do
          {:instance, class, _attrs} = inst when not is_nil(class) ->
            if dataclass_frozen?(class) do
              {frozen_assign_error(attr), env, ctx}
            else
              setattr_to_instance(inst, raw, class, var_name, attr, value, env, ctx)
            end

          {:class, name, bases, class_attrs} ->
            updated = {:class, name, bases, Map.put(class_attrs, attr, value)}
            ctx = Ctx.register_class(ctx, updated)
            {nil, Env.put_at_source(env, var_name, updated), ctx}

          {:py_dict, _, _} = dict ->
            {nil, Env.put_at_source(env, var_name, PyDict.put(dict, attr, value)), ctx}

          {:module, mod_name, attrs} ->
            updated = {:module, mod_name, Map.put(attrs, attr, value)}
            {nil, Env.put_at_source(env, var_name, updated), ctx}

          other when is_map(other) ->
            {nil, Env.put_at_source(env, var_name, Map.put(other, attr, value)), ctx}

          {:function, _, _, _, _, _, _} = func ->
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
            if dataclass_frozen?(class) do
              {frozen_assign_error(attr), env, ctx}
            else
              updated = {:instance, class, Map.put(attrs, attr, value)}

              case raw do
                {:ref, id} -> {nil, env, Ctx.heap_put(ctx, id, updated)}
                _ -> write_back_target(inner_target, updated, env, ctx)
              end
            end

          _ ->
            {{:exception, "AttributeError: cannot set attribute '#{attr}'"}, env, ctx}
        end
    end
  end

  def setattr(_target, _value, env, ctx) do
    {{:exception, "SyntaxError: cannot assign to attribute"}, env, ctx}
  end

  # Instance attribute assignment, after the frozen-dataclass check. Honors
  # property setters and data descriptors before falling back to a plain store.
  defp setattr_to_instance(inst, raw, class, var_name, attr, value, env, ctx) do
    self_arg = if match?({:ref, _}, raw), do: raw, else: inst

    # Check if the class has a property descriptor with a setter for this attr
    case ClassLookup.resolve_class_attr_with_owner(class, attr) do
      {:ok, {:property, _fget, fset, _fdel}, _owner} when fset != nil ->
        case Interpreter.call_function(fset, [self_arg, value], %{}, env, ctx) do
          {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
          # call_function may return a 4-tuple with updated_func
          # when the setter is a regular Python function.
          {{:exception, _} = signal, env, ctx, _} -> {signal, env, ctx}
          {_, env, ctx, _} -> {nil, env, ctx}
          {_, env, ctx} -> {nil, env, ctx}
        end

      {:ok, {:property, _fget, nil, _fdel}, _owner} ->
        {{:exception, "AttributeError: can't set attribute '#{attr}' — no setter defined"}, env,
         ctx}

      {:ok, {:instance, _, _} = descriptor, _owner} ->
        # Generic data descriptor with __set__.
        case Interpreter.invoke_descriptor_set(descriptor, self_arg, value, env, ctx) do
          {:ok, env, ctx} ->
            {nil, env, ctx}

          :no_descriptor ->
            check_slots_and_assign(inst, raw, var_name, attr, value, env, ctx)
        end

      _ ->
        check_slots_and_assign(inst, raw, var_name, attr, value, env, ctx)
    end
  end

  # True when an instance's class (or an ancestor) was made a frozen dataclass.
  @spec dataclass_frozen?(Interpreter.pyvalue()) :: boolean()
  defp dataclass_frozen?({:class, _, _, _} = class) do
    case ClassLookup.class_attribute(class, "__dataclass_frozen__") do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp dataclass_frozen?(_), do: false

  @spec frozen_assign_error(String.t()) :: {:exception, String.t()}
  defp frozen_assign_error(attr),
    do: {:exception, "FrozenInstanceError: cannot assign to field '#{attr}'"}

  @doc false
  @spec setattr_nested(Parser.ast_node(), Interpreter.pyvalue(), Env.t(), Ctx.t()) ::
          eval_result()
  def setattr_nested({:getattr, meta, [obj_expr, attr]}, value, env, ctx) do
    setattr({:getattr, meta, [obj_expr, attr]}, value, env, ctx)
  end

  @doc false
  @spec get_subscript_value(Interpreter.pyvalue(), Interpreter.pyvalue()) ::
          Interpreter.pyvalue() | {:exception, String.t()}
  def get_subscript_value({:py_dict, %{"__counter__" => true}, _} = dict, key) do
    case PyDict.fetch(dict, key) do
      {:ok, val} when is_integer(val) -> val
      _ -> 0
    end
  end

  def get_subscript_value({:py_dict, _, _} = dict, key) do
    case PyDict.fetch(dict, key) do
      {:ok, val} ->
        val

      :error ->
        case PyDict.fetch(dict, "__defaultdict_factory__") do
          {:ok, {:builtin_type, _, func}} -> func.([])
          {:ok, {:builtin, func}} -> func.([])
          {:ok, {:function, _, _, _, _, _, _} = func} -> {:defaultdict_call_needed, func}
          _ -> {:exception, "KeyError: #{Pyex.Builtins.py_repr_quoted(key)}"}
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
          {:ok, {:function, _, _, _, _, _, _} = func} -> {:defaultdict_call_needed, func}
          _ -> {:exception, "KeyError: #{Pyex.Builtins.py_repr_quoted(key)}"}
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

  def get_subscript_value({:tuple, items}, key) when is_integer(key) do
    len = length(items)
    idx = if key < 0, do: len + key, else: key

    if idx < 0 or idx >= len do
      {:exception, "IndexError: tuple index out of range"}
    else
      Enum.at(items, idx)
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

  # Only reached on the nested-mutation path (`t[0][1] = v`): the inner
  # object is mutated and written back into the tuple's slot. CPython
  # allows this — the tuple still holds the same (now-mutated) element.
  # Direct `t[0] = v` is rejected earlier in eval_index_assign.
  def set_subscript_value({:tuple, items}, key, val) when is_integer(key) do
    idx = if key < 0, do: length(items) + key, else: key
    {:tuple, List.replace_at(items, idx, val)}
  end

  @doc false
  @spec delete_subscript_value(Interpreter.pyvalue(), Interpreter.pyvalue()) ::
          Interpreter.pyvalue() | {:exception, String.t()}
  def delete_subscript_value({:py_dict, _, _} = dict, key) do
    if PyDict.has_key?(dict, key) do
      PyDict.delete(dict, key)
    else
      {:exception, "KeyError: #{Pyex.Builtins.py_repr_quoted(key)}"}
    end
  end

  def delete_subscript_value(obj, key) when is_map(obj), do: Map.delete(obj, key)

  def delete_subscript_value({:bytearray, bin}, key) when is_integer(key) do
    bytes = :binary.bin_to_list(bin)
    len = length(bytes)
    idx = if key < 0, do: len + key, else: key

    if idx < 0 or idx >= len do
      {:exception, "IndexError: bytearray index out of range"}
    else
      {:bytearray, :binary.list_to_bin(List.delete_at(bytes, idx))}
    end
  end

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
