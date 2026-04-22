defmodule Pyex.Interpreter.BinaryOps do
  @moduledoc """
  Binary-operation evaluation for `Pyex.Interpreter`.

  Most functions here are side-effect-free. The exception is
  `binop_result/3` which heap-allocates mutable results (lists,
  dicts, sets) so they participate in the reference system.
  """

  alias Pyex.Ctx

  import Bitwise, only: [band: 2, bor: 2, bxor: 2, bsl: 2, bsr: 2]

  alias Pyex.Interpreter.{Format, Helpers}
  alias Pyex.{PyDict}
  alias Pyex.Stdlib.Collections

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc false
  @spec safe_binop(atom(), term(), term()) :: term()
  def safe_binop(op, l, r) when is_boolean(l) or is_boolean(r) do
    case op do
      op
      when op in [
             :plus,
             :minus,
             :star,
             :slash,
             :floor_div,
             :percent,
             :double_star,
             :amp,
             :pipe,
             :caret,
             :lshift,
             :rshift,
             :eq,
             :neq,
             :lt,
             :gt,
             :lte,
             :gte
           ] ->
        safe_binop(op, Helpers.bool_to_int(l), Helpers.bool_to_int(r))

      _ ->
        dispatch(op, l, r)
    end
  end

  # Membership (`in` / `not in`) on a Decimal LHS must dispatch on the
  # container, not the Decimal — fall through to the generic dispatch so
  # `Decimal('1') in {1}` works (set/list/dict membership uses hash equality
  # and our Decimal hash matches int hash for integer-valued Decimals).
  def safe_binop(op, {:pyex_decimal, _} = l, r) when op in [:in, :not_in],
    do: dispatch(op, l, r)

  def safe_binop(op, {:pyex_decimal, _} = l, r), do: decimal_dispatch(op, l, r)
  def safe_binop(op, l, {:pyex_decimal, _} = r), do: decimal_dispatch(op, l, r)
  def safe_binop(op, l, r), do: dispatch(op, l, r)

  @doc false
  @spec dunder_for_op(atom()) :: String.t() | nil
  def dunder_for_op(:plus), do: "__add__"
  def dunder_for_op(:minus), do: "__sub__"
  def dunder_for_op(:star), do: "__mul__"
  def dunder_for_op(:slash), do: "__truediv__"
  def dunder_for_op(:floor_div), do: "__floordiv__"
  def dunder_for_op(:percent), do: "__mod__"
  def dunder_for_op(:double_star), do: "__pow__"
  def dunder_for_op(:eq), do: "__eq__"
  def dunder_for_op(:neq), do: "__ne__"
  def dunder_for_op(:lt), do: "__lt__"
  def dunder_for_op(:gt), do: "__gt__"
  def dunder_for_op(:lte), do: "__le__"
  def dunder_for_op(:gte), do: "__ge__"
  def dunder_for_op(:amp), do: "__and__"
  def dunder_for_op(:pipe), do: "__or__"
  def dunder_for_op(:caret), do: "__xor__"
  def dunder_for_op(:lshift), do: "__lshift__"
  def dunder_for_op(:rshift), do: "__rshift__"
  def dunder_for_op(:in), do: nil
  def dunder_for_op(:not_in), do: nil
  def dunder_for_op(:is), do: nil
  def dunder_for_op(:is_not), do: nil
  def dunder_for_op(:and), do: nil
  def dunder_for_op(:or), do: nil
  def dunder_for_op(_), do: nil

  @doc false
  @spec rdunder_for_op(atom()) :: String.t() | nil
  def rdunder_for_op(:plus), do: "__radd__"
  def rdunder_for_op(:minus), do: "__rsub__"
  def rdunder_for_op(:star), do: "__rmul__"
  def rdunder_for_op(:slash), do: "__rtruediv__"
  def rdunder_for_op(:floor_div), do: "__rfloordiv__"
  def rdunder_for_op(:percent), do: "__rmod__"
  def rdunder_for_op(:double_star), do: "__rpow__"
  def rdunder_for_op(:eq), do: "__eq__"
  def rdunder_for_op(:neq), do: "__ne__"
  def rdunder_for_op(:lt), do: "__gt__"
  def rdunder_for_op(:gt), do: "__lt__"
  def rdunder_for_op(:lte), do: "__ge__"
  def rdunder_for_op(:gte), do: "__le__"
  def rdunder_for_op(_), do: nil

  @doc false
  @spec ordering_compare(atom(), term(), term()) :: boolean() | {:exception, String.t()}

  # NaN comparisons always return False (except !=)
  def ordering_compare(_op, :nan, _), do: false
  def ordering_compare(_op, _, :nan), do: false

  # Infinity ordering: +inf > everything, -inf < everything
  def ordering_compare(op, :infinity, :infinity), do: op in [:lte, :gte]
  def ordering_compare(op, :neg_infinity, :neg_infinity), do: op in [:lte, :gte]
  def ordering_compare(op, :infinity, :neg_infinity), do: op in [:gt, :gte]
  def ordering_compare(op, :neg_infinity, :infinity), do: op in [:lt, :lte]
  def ordering_compare(op, :infinity, r) when is_number(r), do: op in [:gt, :gte]
  def ordering_compare(op, :neg_infinity, r) when is_number(r), do: op in [:lt, :lte]
  def ordering_compare(op, l, :infinity) when is_number(l), do: op in [:lt, :lte]
  def ordering_compare(op, l, :neg_infinity) when is_number(l), do: op in [:gt, :gte]

  def ordering_compare(op, l, r) when is_number(l) and is_number(r), do: ord_cmp(op, l, r)
  def ordering_compare(op, l, r) when is_binary(l) and is_binary(r), do: ord_cmp(op, l, r)
  def ordering_compare(op, l, r) when is_list(l) and is_list(r), do: ord_cmp(op, l, r)

  def ordering_compare(op, {:py_list, lr, _}, {:py_list, rr, _}),
    do: ord_cmp(op, Enum.reverse(lr), Enum.reverse(rr))

  def ordering_compare(op, {:py_list, lr, _}, r) when is_list(r),
    do: ord_cmp(op, Enum.reverse(lr), r)

  def ordering_compare(op, l, {:py_list, rr, _}) when is_list(l),
    do: ord_cmp(op, l, Enum.reverse(rr))

  def ordering_compare(op, {:tuple, a}, {:tuple, b}), do: ord_cmp(op, a, b)

  def ordering_compare(op, l, r) when is_boolean(l) and is_number(r),
    do: ordering_compare(op, bool_to_int(l), r)

  def ordering_compare(op, l, r) when is_number(l) and is_boolean(r),
    do: ordering_compare(op, l, bool_to_int(r))

  def ordering_compare(_op, l, r) do
    {:exception,
     "TypeError: '<' not supported between instances of '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}
  end

  @doc false
  @spec binop_result(term(), term(), term()) :: {term(), term(), term()}
  def binop_result({:exception, msg}, env, ctx), do: {{:exception, msg}, env, ctx}

  def binop_result({:py_list, _, _} = list, env, ctx) do
    {ref, ctx} = Ctx.heap_alloc(ctx, list)
    {ref, env, ctx}
  end

  def binop_result({:py_dict, _, _} = dict, env, ctx) do
    {ref, ctx} = Ctx.heap_alloc(ctx, dict)
    {ref, env, ctx}
  end

  def binop_result({:set, _} = set, env, ctx) do
    {ref, ctx} = Ctx.heap_alloc(ctx, set)
    {ref, env, ctx}
  end

  def binop_result(value, env, ctx) when is_binary(value) do
    {value, env, Ctx.track_memory(ctx, byte_size(value))}
  end

  def binop_result(value, env, ctx), do: {value, env, ctx}

  @doc false
  @spec series_binop(atom(), term(), term()) :: term()
  def series_binop(op, l, r) do
    ls = series_unwrap(l)
    rs = series_unwrap(r)

    result =
      case op do
        :plus -> Explorer.Series.add(ls, rs)
        :minus -> Explorer.Series.subtract(ls, rs)
        :star -> Explorer.Series.multiply(ls, rs)
        :slash -> Explorer.Series.divide(ls, rs)
        :gt -> Explorer.Series.greater(ls, rs)
        :gte -> Explorer.Series.greater_equal(ls, rs)
        :lt -> Explorer.Series.less(ls, rs)
        :lte -> Explorer.Series.less_equal(ls, rs)
        :eq -> Explorer.Series.equal(ls, rs)
        :neq -> Explorer.Series.not_equal(ls, rs)
        :amp -> series_bool_and(ls, rs)
        :pipe -> series_bool_or(ls, rs)
        _ -> {:exception, "TypeError: unsupported operand for Series"}
      end

    case result do
      {:exception, _} = err -> err
      %Explorer.Series{} = s -> {:pandas_series, s}
    end
  end

  # -------------------------------------------------------------------
  # Dispatch (all private)
  # -------------------------------------------------------------------

  # -- plus -----------------------------------------------------------

  defp dispatch(:plus, l, r) when is_binary(l) and is_binary(r), do: l <> r

  defp dispatch(:plus, {:py_list, lr, ll}, {:py_list, rr, rl}) do
    items = Enum.reverse(lr) ++ Enum.reverse(rr)
    {:py_list, Enum.reverse(items), ll + rl}
  end

  defp dispatch(:plus, {:py_list, lr, ll}, r) when is_list(r) do
    items = Enum.reverse(lr) ++ r
    {:py_list, Enum.reverse(items), ll + length(r)}
  end

  defp dispatch(:plus, l, {:py_list, rr, rl}) when is_list(l) do
    items = l ++ Enum.reverse(rr)
    {:py_list, Enum.reverse(items), length(l) + rl}
  end

  defp dispatch(:plus, l, r) when is_list(l) and is_list(r), do: l ++ r
  defp dispatch(:plus, {:tuple, l}, {:tuple, r}), do: {:tuple, l ++ r}

  defp dispatch(
         :plus,
         {:py_dict, %{"__counter__" => true}, _} = l,
         {:py_dict, %{"__counter__" => true}, _} = r
       ) do
    Collections.counter_add(l, r)
  end

  defp dispatch(:plus, %{"__counter__" => true} = l, %{"__counter__" => true} = r) do
    Collections.counter_add(l, r)
  end

  defp dispatch(:plus, :infinity, r) when is_number(r) or r == :neg_infinity,
    do: if(r == :neg_infinity, do: :nan, else: :infinity)

  defp dispatch(:plus, :neg_infinity, r) when is_number(r) or r == :infinity,
    do: if(r == :infinity, do: :nan, else: :neg_infinity)

  defp dispatch(:plus, l, :infinity) when is_number(l), do: :infinity
  defp dispatch(:plus, l, :neg_infinity) when is_number(l), do: :neg_infinity
  defp dispatch(:plus, :infinity, :infinity), do: :infinity
  defp dispatch(:plus, :neg_infinity, :neg_infinity), do: :neg_infinity
  defp dispatch(:plus, l, r) when is_number(l) and is_number(r), do: l + r

  defp dispatch(:plus, {:bytes, a}, {:bytes, b}), do: {:bytes, a <> b}
  defp dispatch(:plus, {:bytearray, a}, {:bytes, b}), do: {:bytearray, a <> b}
  defp dispatch(:plus, {:bytes, a}, {:bytearray, b}), do: {:bytearray, a <> b}
  defp dispatch(:plus, {:bytearray, a}, {:bytearray, b}), do: {:bytearray, a <> b}

  defp dispatch(:plus, {:complex, r1, i1}, {:complex, r2, i2}), do: {:complex, r1 + r2, i1 + i2}
  defp dispatch(:plus, {:complex, r, i}, n) when is_number(n), do: {:complex, r + n, i}
  defp dispatch(:plus, n, {:complex, r, i}) when is_number(n), do: {:complex, n + r, i}

  defp dispatch(:plus, l, r),
    do: type_error("+", l, r)

  # -- minus ----------------------------------------------------------

  defp dispatch(:minus, l, r) when is_number(l) and is_number(r), do: l - r
  defp dispatch(:minus, {:complex, r1, i1}, {:complex, r2, i2}), do: {:complex, r1 - r2, i1 - i2}
  defp dispatch(:minus, {:complex, r, i}, n) when is_number(n), do: {:complex, r - n, i}
  defp dispatch(:minus, n, {:complex, r, i}) when is_number(n), do: {:complex, n - r, -i}

  defp dispatch(:star, {:complex, a, b}, {:complex, c, d}),
    do: {:complex, a * c - b * d, a * d + b * c}

  defp dispatch(:star, {:complex, a, b}, n) when is_number(n),
    do: {:complex, a * n, b * n}

  defp dispatch(:star, n, {:complex, a, b}) when is_number(n),
    do: {:complex, n * a, n * b}

  defp dispatch(:slash, {:complex, a, b}, {:complex, c, d}) do
    denom = c * c + d * d
    {:complex, (a * c + b * d) / denom, (b * c - a * d) / denom}
  end

  defp dispatch(:slash, {:complex, a, b}, n) when is_number(n),
    do: {:complex, a / n, b / n}

  defp dispatch(:minus, {:set, a}, {:set, b}),
    do: {:set, MapSet.difference(a, b)}

  defp dispatch(:minus, {:frozenset, a}, {:set, b}),
    do: {:frozenset, MapSet.difference(a, b)}

  defp dispatch(:minus, {:frozenset, a}, {:frozenset, b}),
    do: {:frozenset, MapSet.difference(a, b)}

  defp dispatch(:minus, {:set, a}, {:frozenset, b}),
    do: {:set, MapSet.difference(a, b)}

  defp dispatch(:minus, l, r),
    do: type_error("-", l, r)

  # -- star -----------------------------------------------------------

  defp dispatch(:star, l, r) when is_binary(l) and is_integer(r) do
    len = String.length(l) * max(r, 0)

    if len > 10_000_000 do
      {:exception, "MemoryError: string repetition would create #{len} characters (max 10000000)"}
    else
      String.duplicate(l, max(r, 0))
    end
  end

  defp dispatch(:star, l, r) when is_integer(l) and is_binary(r),
    do: dispatch(:star, r, l)

  defp dispatch(:star, l, r) when is_integer(l) and is_list(r),
    do: Helpers.repeat_list(r, l)

  defp dispatch(:star, l, r) when is_list(l) and is_integer(r),
    do: Helpers.repeat_list(l, r)

  defp dispatch(:star, {:py_list, reversed, len}, r) when is_integer(r) do
    case Helpers.repeat_list(Enum.reverse(reversed), r) do
      {:exception, _} = err -> err
      items -> {:py_list, Enum.reverse(items), len * max(r, 0)}
    end
  end

  defp dispatch(:star, l, {:py_list, reversed, len}) when is_integer(l) do
    case Helpers.repeat_list(Enum.reverse(reversed), l) do
      {:exception, _} = err -> err
      items -> {:py_list, Enum.reverse(items), len * max(l, 0)}
    end
  end

  defp dispatch(:star, {:tuple, items}, r) when is_integer(r) do
    case Helpers.repeat_list(items, r) do
      {:exception, _} = err -> err
      list -> {:tuple, list}
    end
  end

  defp dispatch(:star, l, {:tuple, items}) when is_integer(l) do
    case Helpers.repeat_list(items, l) do
      {:exception, _} = err -> err
      list -> {:tuple, list}
    end
  end

  defp dispatch(:star, l, r) when is_number(l) and is_number(r), do: l * r

  # IEEE-754 special-value multiplication.
  defp dispatch(:star, :infinity, 0), do: :nan
  defp dispatch(:star, :infinity, +0.0), do: :nan
  defp dispatch(:star, :infinity, -0.0), do: :nan
  defp dispatch(:star, 0, :infinity), do: :nan
  defp dispatch(:star, +0.0, :infinity), do: :nan
  defp dispatch(:star, -0.0, :infinity), do: :nan
  defp dispatch(:star, :neg_infinity, 0), do: :nan
  defp dispatch(:star, :neg_infinity, +0.0), do: :nan
  defp dispatch(:star, :neg_infinity, -0.0), do: :nan
  defp dispatch(:star, 0, :neg_infinity), do: :nan
  defp dispatch(:star, +0.0, :neg_infinity), do: :nan
  defp dispatch(:star, -0.0, :neg_infinity), do: :nan
  defp dispatch(:star, :infinity, r) when is_number(r) and r > 0, do: :infinity
  defp dispatch(:star, :infinity, r) when is_number(r) and r < 0, do: :neg_infinity
  defp dispatch(:star, :neg_infinity, r) when is_number(r) and r > 0, do: :neg_infinity
  defp dispatch(:star, :neg_infinity, r) when is_number(r) and r < 0, do: :infinity
  defp dispatch(:star, l, :infinity) when is_number(l) and l > 0, do: :infinity
  defp dispatch(:star, l, :infinity) when is_number(l) and l < 0, do: :neg_infinity
  defp dispatch(:star, l, :neg_infinity) when is_number(l) and l > 0, do: :neg_infinity
  defp dispatch(:star, l, :neg_infinity) when is_number(l) and l < 0, do: :infinity
  defp dispatch(:star, :infinity, :infinity), do: :infinity
  defp dispatch(:star, :neg_infinity, :neg_infinity), do: :infinity
  defp dispatch(:star, :infinity, :neg_infinity), do: :neg_infinity
  defp dispatch(:star, :neg_infinity, :infinity), do: :neg_infinity
  defp dispatch(:star, :nan, _), do: :nan
  defp dispatch(:star, _, :nan), do: :nan

  defp dispatch(:star, l, r),
    do: type_error("*", l, r)

  # -- slash ----------------------------------------------------------

  defp dispatch(:slash, _l, r) when r == 0 or r == 0.0,
    do: {:exception, "ZeroDivisionError: division by zero"}

  defp dispatch(:slash, l, r) when is_number(l) and is_number(r), do: l / r

  # IEEE-754 special-value division: finite / inf -> 0.0, inf / finite -> inf, etc.
  defp dispatch(:slash, l, :infinity) when is_number(l), do: 0.0
  defp dispatch(:slash, l, :neg_infinity) when is_number(l), do: -0.0
  defp dispatch(:slash, :infinity, r) when is_number(r) and r > 0, do: :infinity
  defp dispatch(:slash, :infinity, r) when is_number(r) and r < 0, do: :neg_infinity
  defp dispatch(:slash, :neg_infinity, r) when is_number(r) and r > 0, do: :neg_infinity
  defp dispatch(:slash, :neg_infinity, r) when is_number(r) and r < 0, do: :infinity
  defp dispatch(:slash, :infinity, :infinity), do: :nan
  defp dispatch(:slash, :neg_infinity, :neg_infinity), do: :nan
  defp dispatch(:slash, :infinity, :neg_infinity), do: :nan
  defp dispatch(:slash, :neg_infinity, :infinity), do: :nan
  defp dispatch(:slash, :nan, _), do: :nan
  defp dispatch(:slash, _, :nan), do: :nan

  defp dispatch(:slash, l, r),
    do: type_error("/", l, r)

  # -- floor_div ------------------------------------------------------

  defp dispatch(:floor_div, _l, r) when r == 0 or r == 0.0,
    do: {:exception, "ZeroDivisionError: integer division or modulo by zero"}

  defp dispatch(:floor_div, l, r) when is_integer(l) and is_integer(r),
    do: Integer.floor_div(l, r)

  defp dispatch(:floor_div, l, r) when is_number(l) and is_number(r),
    do: Float.floor(l / r)

  defp dispatch(:floor_div, l, r),
    do: type_error("//", l, r)

  # -- percent --------------------------------------------------------
  # String % formatting is intercepted in do_eval_binop (interpreter.ex) so
  # that eval_py_str dunder dispatch is available for %s arguments.  This
  # clause is kept as a pure fallback (no dunder dispatch) for callers that
  # do not have env/ctx available.

  defp dispatch(:percent, l, r) when is_binary(l), do: Format.string_format_pure(l, r)

  defp dispatch(:percent, _l, r) when r == 0 or r == 0.0,
    do: {:exception, "ZeroDivisionError: integer division or modulo by zero"}

  defp dispatch(:percent, l, r) when is_integer(l) and is_integer(r),
    do: Integer.mod(l, r)

  defp dispatch(:percent, l, r) when is_number(l) and is_number(r),
    do: l - Float.floor(l / r) * r

  defp dispatch(:percent, l, r),
    do: type_error("%", l, r)

  # -- double_star ----------------------------------------------------

  defp dispatch(:double_star, l, r) when is_number(l) and is_number(r) do
    cond do
      l == 0 and r < 0 ->
        {:exception, "ZeroDivisionError: 0 cannot be raised to a negative power"}

      is_integer(l) and is_integer(r) and r >= 0 ->
        Helpers.int_pow(l, r)

      is_float(l) or is_float(r) ->
        try do
          :math.pow(l, r)
        rescue
          ArithmeticError ->
            {:exception, "ValueError: math domain error"}
        end

      true ->
        try do
          :math.pow(l, r) |> Helpers.maybe_intify()
        rescue
          ArithmeticError ->
            {:exception, "ValueError: math domain error"}
        end
    end
  end

  defp dispatch(:double_star, l, r),
    do: type_error("**", l, r)

  # -- equality -------------------------------------------------------

  defp dispatch(:eq, {:py_dict, lm, _}, {:py_dict, rm, _}), do: lm == rm
  defp dispatch(:eq, {:py_dict, lm, _}, rm) when is_map(rm), do: lm == rm
  defp dispatch(:eq, lm, {:py_dict, rm, _}) when is_map(lm), do: lm == rm

  defp dispatch(:eq, {:py_list, lr, _}, {:py_list, rr, _}),
    do: Enum.reverse(lr) == Enum.reverse(rr)

  defp dispatch(:eq, {:py_list, reversed, _}, r) when is_list(r),
    do: Enum.reverse(reversed) == r

  defp dispatch(:eq, l, {:py_list, reversed, _}) when is_list(l),
    do: l == Enum.reverse(reversed)

  # Synthetic classes returned by `type(x)` compare equal to their
  # corresponding `{:builtin_type, _, _}` singleton.
  defp dispatch(:eq, {:class, name, _, _}, {:builtin_type, name, _}), do: true
  defp dispatch(:eq, {:builtin_type, name, _}, {:class, name, _, _}), do: true
  defp dispatch(:eq, {:class, name, _, _}, {:exception_class, name}), do: true
  defp dispatch(:eq, {:exception_class, name}, {:class, name, _, _}), do: true

  defp dispatch(:eq, {:instance, {:class, "type", _, _}, attrs}, {:builtin_type, name, _}),
    do: builtin_type_instance_name(attrs) == name

  defp dispatch(:eq, {:builtin_type, name, _}, {:instance, {:class, "type", _, _}, attrs}),
    do: name == builtin_type_instance_name(attrs)

  defp dispatch(:eq, {:instance, {:class, "type", _, _}, attrs}, {:class, class_name, _, _}),
    do: builtin_type_instance_name(attrs) == class_name

  defp dispatch(:eq, {:class, class_name, _, _}, {:instance, {:class, "type", _, _}, attrs}),
    do: class_name == builtin_type_instance_name(attrs)

  defp dispatch(:eq, :nan, _), do: false
  defp dispatch(:eq, _, :nan), do: false
  defp dispatch(:eq, :infinity, r) when is_number(r), do: false
  defp dispatch(:eq, :neg_infinity, r) when is_number(r), do: false
  defp dispatch(:eq, r, :infinity) when is_number(r), do: false
  defp dispatch(:eq, r, :neg_infinity) when is_number(r), do: false
  defp dispatch(:eq, l, r), do: l == r

  defp dispatch(:neq, {:py_dict, lm, _}, {:py_dict, rm, _}), do: lm != rm
  defp dispatch(:neq, {:py_dict, lm, _}, rm) when is_map(rm), do: lm != rm
  defp dispatch(:neq, lm, {:py_dict, rm, _}) when is_map(lm), do: lm != rm

  defp dispatch(:neq, {:py_list, lr, _}, {:py_list, rr, _}),
    do: Enum.reverse(lr) != Enum.reverse(rr)

  defp dispatch(:neq, {:py_list, reversed, _}, r) when is_list(r),
    do: Enum.reverse(reversed) != r

  defp dispatch(:neq, l, {:py_list, reversed, _}) when is_list(l),
    do: l != Enum.reverse(reversed)

  defp dispatch(:neq, {:class, name, _, _}, {:builtin_type, name, _}), do: false
  defp dispatch(:neq, {:builtin_type, name, _}, {:class, name, _, _}), do: false
  defp dispatch(:neq, {:class, name, _, _}, {:exception_class, name}), do: false
  defp dispatch(:neq, {:exception_class, name}, {:class, name, _, _}), do: false

  defp dispatch(:neq, {:instance, {:class, "type", _, _}, attrs}, {:builtin_type, name, _}),
    do: builtin_type_instance_name(attrs) != name

  defp dispatch(:neq, {:builtin_type, name, _}, {:instance, {:class, "type", _, _}, attrs}),
    do: name != builtin_type_instance_name(attrs)

  defp dispatch(:neq, {:instance, {:class, "type", _, _}, attrs}, {:class, class_name, _, _}),
    do: builtin_type_instance_name(attrs) != class_name

  defp dispatch(:neq, {:class, class_name, _, _}, {:instance, {:class, "type", _, _}, attrs}),
    do: class_name != builtin_type_instance_name(attrs)

  defp dispatch(:neq, :nan, _), do: true
  defp dispatch(:neq, _, :nan), do: true
  defp dispatch(:neq, l, r), do: l != r

  # -- ordering -------------------------------------------------------

  defp dispatch(:lt, l, r), do: ordering_compare(:lt, l, r)
  defp dispatch(:gt, l, r), do: ordering_compare(:gt, l, r)
  defp dispatch(:lte, l, r), do: ordering_compare(:lte, l, r)
  defp dispatch(:gte, l, r), do: ordering_compare(:gte, l, r)

  # -- membership -----------------------------------------------------

  defp dispatch(:in, l, {:tuple, items}), do: py_member?(l, items)
  defp dispatch(:in, l, {:py_list, reversed, _}), do: py_member?(l, reversed)
  defp dispatch(:in, l, r) when is_list(r), do: py_member?(l, r)

  defp dispatch(:in, l, r) when is_binary(l) and is_binary(r),
    do: String.contains?(r, l)

  defp dispatch(:in, l, {:py_dict, _, _} = dict),
    do: PyDict.has_key?(Pyex.Builtins.visible_dict(dict), l)

  defp dispatch(:in, l, r) when is_map(r),
    do: Map.has_key?(Pyex.Builtins.visible_dict(r), PyDict.canonical_key(l))

  defp dispatch(:in, l, {:set, s}), do: MapSet.member?(s, PyDict.canonical_key(l))
  defp dispatch(:in, l, {:frozenset, s}), do: MapSet.member?(s, PyDict.canonical_key(l))

  defp dispatch(:in, l, {:range, start, stop, step}) when is_integer(l) do
    cond do
      step > 0 and l >= start and l < stop -> rem(l - start, step) == 0
      step < 0 and l <= start and l > stop -> rem(start - l, -step) == 0
      true -> false
    end
  end

  defp dispatch(:in, _l, {:range, _, _, _}), do: false

  defp dispatch(:in, _l, r),
    do: {:exception, "TypeError: argument of type '#{Helpers.py_type(r)}' is not iterable"}

  # -- identity -------------------------------------------------------

  # Synthetic classes returned by `type(x)` for primitives compare
  # identity-equal to the corresponding `{:builtin_type, name, _}`
  # singleton (`int`, `str`, etc.).  Matches CPython's `type(42) is int`.
  defp dispatch(:is, {:class, name, _, _}, {:builtin_type, name, _}), do: true
  defp dispatch(:is, {:builtin_type, name, _}, {:class, name, _, _}), do: true

  defp dispatch(:is, {:class, name, _, _}, {:exception_class, name}), do: true
  defp dispatch(:is, {:exception_class, name}, {:class, name, _, _}), do: true

  # Legacy clauses for any remaining `{:instance, {:class, "type", ...}, ...}`
  # pyvalues (now rare — builtin_type_of returns real classes).
  defp dispatch(:is, {:instance, {:class, "type", _, _}, attrs}, {:builtin_type, name, _}),
    do: builtin_type_instance_name(attrs) == name

  defp dispatch(:is, {:builtin_type, name, _}, {:instance, {:class, "type", _, _}, attrs}),
    do: name == builtin_type_instance_name(attrs)

  defp dispatch(:is, {:instance, {:class, "type", _, _}, attrs}, {:class, class_name, _, _}),
    do: builtin_type_instance_name(attrs) == class_name

  defp dispatch(:is, {:class, class_name, _, _}, {:instance, {:class, "type", _, _}, attrs}),
    do: class_name == builtin_type_instance_name(attrs)

  defp dispatch(:is, l, r), do: l === r

  defp dispatch(:is_not, l, r) do
    not dispatch(:is, l, r)
  end

  # -- not_in ---------------------------------------------------------

  defp dispatch(:not_in, l, r) do
    case safe_binop(:in, l, r) do
      {:exception, _} = exc -> exc
      val -> not val
    end
  end

  # -- bitwise --------------------------------------------------------

  defp dispatch(:amp, {:set, a}, {:set, b}), do: {:set, MapSet.intersection(a, b)}

  defp dispatch(:amp, {:frozenset, a}, {:set, b}),
    do: {:frozenset, MapSet.intersection(a, b)}

  defp dispatch(:amp, {:frozenset, a}, {:frozenset, b}),
    do: {:frozenset, MapSet.intersection(a, b)}

  defp dispatch(:amp, {:set, a}, {:frozenset, b}),
    do: {:set, MapSet.intersection(a, b)}

  defp dispatch(:amp, l, r) when is_integer(l) and is_integer(r), do: band(l, r)

  defp dispatch(:amp, l, r),
    do: type_error("&", l, r)

  defp dispatch(:pipe, {:set, a}, {:set, b}), do: {:set, MapSet.union(a, b)}

  defp dispatch(:pipe, {:frozenset, a}, {:set, b}),
    do: {:frozenset, MapSet.union(a, b)}

  defp dispatch(:pipe, {:frozenset, a}, {:frozenset, b}),
    do: {:frozenset, MapSet.union(a, b)}

  defp dispatch(:pipe, {:set, a}, {:frozenset, b}), do: {:set, MapSet.union(a, b)}

  defp dispatch(:pipe, {:py_dict, _, _} = l, {:py_dict, _, _} = r), do: PyDict.merge(l, r)
  defp dispatch(:pipe, {:py_dict, _, _} = l, r) when is_map(r), do: PyDict.merge_map(l, r)

  defp dispatch(:pipe, l, {:py_dict, _, _} = r) when is_map(l),
    do: PyDict.merge(PyDict.from_map(l), r)

  defp dispatch(:pipe, l, r) when is_map(l) and is_map(r), do: Map.merge(l, r)

  defp dispatch(:pipe, l, r) when is_integer(l) and is_integer(r), do: bor(l, r)

  defp dispatch(:pipe, l, r),
    do: type_error("|", l, r)

  defp dispatch(:caret, {:set, a}, {:set, b}),
    do: {:set, MapSet.symmetric_difference(a, b)}

  defp dispatch(:caret, {:frozenset, a}, {:set, b}),
    do: {:frozenset, MapSet.symmetric_difference(a, b)}

  defp dispatch(:caret, {:frozenset, a}, {:frozenset, b}),
    do: {:frozenset, MapSet.symmetric_difference(a, b)}

  defp dispatch(:caret, {:set, a}, {:frozenset, b}),
    do: {:set, MapSet.symmetric_difference(a, b)}

  defp dispatch(:caret, l, r) when is_integer(l) and is_integer(r), do: bxor(l, r)

  defp dispatch(:caret, l, r),
    do: type_error("^", l, r)

  # -- shifts ---------------------------------------------------------

  defp dispatch(:lshift, l, r) when is_integer(l) and is_integer(r) do
    if r > 100_000 do
      {:exception, "OverflowError: left shift by #{r} exceeds maximum allowed (100000)"}
    else
      bsl(l, r)
    end
  end

  defp dispatch(:lshift, l, r),
    do: type_error("<<", l, r)

  defp dispatch(:rshift, l, r) when is_integer(l) and is_integer(r), do: bsr(l, r)

  defp dispatch(:rshift, l, r),
    do: type_error(">>", l, r)

  @spec builtin_type_instance_name(map()) :: String.t() | nil
  defp builtin_type_instance_name(%{"__name__" => name}) when is_binary(name), do: name
  defp builtin_type_instance_name(_), do: nil

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp type_error(op_str, l, r) do
    {:exception,
     "TypeError: unsupported operand type(s) for #{op_str}: '#{Helpers.py_type(l)}' and '#{Helpers.py_type(r)}'"}
  end

  # Python `in` for ordered containers (list/tuple) compares element-wise
  # with `==`, which means `1 in [True]`, `1 in [1.0]`, and
  # `Decimal('1') in [1]` all hold. We canonicalize numeric values so the
  # structural comparison matches.
  defp py_member?(needle, haystack) do
    if needle in haystack do
      true
    else
      canon = PyDict.canonical_key(needle)
      Enum.any?(haystack, fn item -> PyDict.canonical_key(item) == canon end)
    end
  end

  defp ord_cmp(:lt, l, r), do: l < r
  defp ord_cmp(:gt, l, r), do: l > r
  defp ord_cmp(:lte, l, r), do: l <= r
  defp ord_cmp(:gte, l, r), do: l >= r

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  defp series_unwrap({:pandas_series, s}), do: s
  defp series_unwrap(v) when is_number(v), do: v
  defp series_unwrap(true), do: 1
  defp series_unwrap(false), do: 0

  defp series_bool_and(%Explorer.Series{} = l, %Explorer.Series{} = r) do
    Explorer.Series.and(l, r)
  end

  defp series_bool_or(%Explorer.Series{} = l, %Explorer.Series{} = r) do
    Explorer.Series.or(l, r)
  end

  # -------------------------------------------------------------------
  # Decimal dispatch
  # -------------------------------------------------------------------

  @spec decimal_dispatch(atom(), term(), term()) :: term()
  defp decimal_dispatch(op, l, r) do
    dl = to_decimal(l)
    dr = to_decimal(r)

    case {dl, dr} do
      # Equality across incompatible types must return false / true (CPython
      # never raises from `==` between Decimal and float). Ordering still
      # raises (you cannot meaningfully compare a Decimal to a float).
      {{:error, _}, _} when op == :eq -> false
      {{:error, _}, _} when op == :neq -> true
      {_, {:error, _}} when op == :eq -> false
      {_, {:error, _}} when op == :neq -> true
      {{:error, _}, _} -> type_error(op_str(op), l, r)
      {_, {:error, _}} -> type_error(op_str(op), l, r)
      {dl, dr} -> safe_decimal_op(op, dl, dr, l, r)
    end
  end

  # Wraps decimal_op so that the Elixir Decimal library's traps (e.g.
  # InvalidOperation on Inf*0, Inf-Inf, Inf/Inf) become Python-style
  # exceptions instead of Erlang errors that would crash the interpreter.
  defp safe_decimal_op(op, dl, dr, l, r) do
    decimal_op(op, dl, dr, l, r)
  rescue
    Decimal.Error ->
      {:exception, "InvalidOperation: invalid operation in Decimal arithmetic"}
  end

  defp decimal_op(:plus, dl, dr, _l, _r) do
    case nan_passthrough(dl, dr) do
      nil -> {:pyex_decimal, Decimal.add(dl, dr) |> clip_coef_to_precision()}
      nan -> {:pyex_decimal, nan}
    end
  end

  defp decimal_op(:minus, dl, dr, _l, _r) do
    case nan_passthrough(dl, dr) do
      nil -> {:pyex_decimal, Decimal.sub(dl, dr) |> clip_coef_to_precision()}
      nan -> {:pyex_decimal, nan}
    end
  end

  defp decimal_op(:star, dl, dr, _l, _r) do
    case nan_passthrough(dl, dr) do
      nil -> {:pyex_decimal, Decimal.mult(dl, dr) |> clip_coef_to_precision()}
      nan -> {:pyex_decimal, nan}
    end
  end

  defp decimal_op(:slash, dl, dr, _l, _r) do
    case nan_passthrough(dl, dr) do
      nan when not is_nil(nan) ->
        {:pyex_decimal, nan}

      _ ->
        cond do
          # Inf/Inf is undefined (InvalidOperation).
          Decimal.inf?(dl) and Decimal.inf?(dr) ->
            {:exception, "InvalidOperation: Infinity / Infinity is undefined"}

          # Inf / finite = signed Infinity (does NOT raise even if divisor is 0).
          Decimal.inf?(dl) ->
            sign = if dl.sign == dr.sign, do: 1, else: -1
            {:pyex_decimal, %Decimal{sign: sign, coef: :inf, exp: 0}}

          # finite / Inf = signed zero.
          Decimal.inf?(dr) ->
            sign = if dl.sign == dr.sign, do: 1, else: -1
            {:pyex_decimal, %Decimal{sign: sign, coef: 0, exp: 0}}

          Decimal.equal?(dl, Decimal.new(0)) and Decimal.equal?(dr, Decimal.new(0)) ->
            {:exception, "InvalidOperation: 0/0 is undefined"}

          Decimal.equal?(dr, Decimal.new(0)) ->
            {:exception, "ZeroDivisionError: division by zero"}

          true ->
            {:pyex_decimal, decimal_div_correctly_rounded(dl, dr) |> clip_coef_to_precision()}
        end
    end
  end

  defp decimal_op(:floor_div, dl, dr, _l, _r) do
    case nan_passthrough(dl, dr) do
      nan when not is_nil(nan) ->
        {:pyex_decimal, nan}

      _ ->
        cond do
          # Inf // Inf is undefined; Inf // finite is signed Infinity;
          # finite // Inf is zero with sign determined by both operands.
          Decimal.inf?(dl) and Decimal.inf?(dr) ->
            {:exception, "InvalidOperation: Infinity // Infinity is undefined"}

          Decimal.inf?(dl) ->
            sign = if dl.sign == dr.sign, do: 1, else: -1
            {:pyex_decimal, %Decimal{sign: sign, coef: :inf, exp: 0}}

          Decimal.inf?(dr) ->
            sign = if dl.sign == dr.sign, do: 1, else: -1
            {:pyex_decimal, %Decimal{sign: sign, coef: 0, exp: 0}}

          Decimal.equal?(dl, Decimal.new(0)) and Decimal.equal?(dr, Decimal.new(0)) ->
            {:exception, "InvalidOperation: 0//0 is undefined"}

          Decimal.equal?(dr, Decimal.new(0)) ->
            {:exception, "ZeroDivisionError: division by zero"}

          true ->
            decimal_floor_div(dl, dr)
        end
    end
  end

  defp decimal_op(:percent, dl, dr, _l, _r) do
    case nan_passthrough(dl, dr) do
      nan when not is_nil(nan) ->
        {:pyex_decimal, nan}

      _ ->
        cond do
          # Inf as dividend: undefined per IEEE, signal InvalidOperation.
          Decimal.inf?(dl) ->
            {:exception, "InvalidOperation: Infinity remainder is undefined"}

          # finite % Infinity returns the dividend unchanged (the only
          # integer multiple of Inf that fits inside |finite| is zero).
          Decimal.inf?(dr) ->
            {:pyex_decimal, dl}

          Decimal.equal?(dr, Decimal.new(0)) ->
            # CPython-specific: `Decimal % 0` is ALWAYS InvalidOperation,
            # never DivisionByZero (unlike `/` and `//`). See
            # `IBM decimal-arithmetic spec -> remainder: divisor is zero`.
            {:exception, "InvalidOperation: modulo undefined for zero divisor"}

          true ->
            decimal_percent(dl, dr)
        end
    end
  end

  defp decimal_op(:double_star, dl, dr, _l, _r) do
    case nan_passthrough(dl, dr) do
      nan when not is_nil(nan) -> {:pyex_decimal, nan}
      _ -> decimal_pow(dl, dr)
    end
  end

  defp decimal_op(:eq, dl, dr, _l, _r), do: Decimal.equal?(dl, dr)
  defp decimal_op(:neq, dl, dr, _l, _r), do: not Decimal.equal?(dl, dr)
  defp decimal_op(:lt, dl, dr, _l, _r), do: Decimal.lt?(dl, dr)
  defp decimal_op(:gt, dl, dr, _l, _r), do: Decimal.gt?(dl, dr)
  defp decimal_op(:lte, dl, dr, _l, _r), do: not Decimal.gt?(dl, dr)
  defp decimal_op(:gte, dl, dr, _l, _r), do: not Decimal.lt?(dl, dr)
  defp decimal_op(op, _dl, _dr, l, r), do: type_error(op_str(op), l, r)

  # Decimal exponentiation. Supports integer exponents directly via repeated
  # multiplication (preserves exactness); falls back to ln/exp via floats for
  # fractional or negative non-integer exponents.
  defp decimal_pow(dl, dr) do
    cond do
      Decimal.integer?(dr) ->
        exp = Decimal.to_integer(dr)

        cond do
          exp == 0 ->
            # CPython signals InvalidOperation for `0 ** 0` on Decimal
            # (unlike int's `0 ** 0 == 1`). Non-zero base to the zeroth
            # power is always 1.
            if Decimal.equal?(dl, Decimal.new(0)) do
              {:exception, "InvalidOperation: 0 ** 0 is undefined"}
            else
              {:pyex_decimal, Decimal.new(1)}
            end

          exp > 0 ->
            if Decimal.equal?(dl, Decimal.new(0)) do
              # CPython normalises zero**n to exp 0 with sign derived from
              # the base's sign and the exponent's parity. E.g.
              # `-0.00 ** 7 = -0`, `-0.00 ** 10 = 0`.
              sign = if dl.sign == -1 and rem(exp, 2) == 1, do: -1, else: 1
              {:pyex_decimal, %Decimal{sign: sign, coef: 0, exp: 0}}
            else
              # Compute under elevated precision so the chain of multiplies
              # doesn't accumulate half-even rounding errors, then round once
              # under the user context. This matches CPython's result to the
              # last digit for typical 28-digit precision.
              {:pyex_decimal, integer_pow_decimal_rounded(dl, exp)}
            end

          # Negative integer exponent: 1 / (base ** |exp|)
          exp < 0 ->
            cond do
              Decimal.equal?(dl, Decimal.new(0)) ->
                # CPython returns +/- Infinity (not ZeroDivisionError) for
                # `0 ** negative`. Sign follows the base when the exponent
                # is odd; flips to positive when it is even.
                sign = if dl.sign == -1 and rem(-exp, 2) == 1, do: -1, else: 1
                {:pyex_decimal, %Decimal{sign: sign, coef: :inf, exp: 0}}

              true ->
                # Exact power at elevated precision, then correctly-rounded division.
                ctx = Decimal.Context.get()
                high_prec = %{ctx | precision: ctx.precision * 2 + 5}

                full_power =
                  Decimal.Context.with(high_prec, fn ->
                    integer_pow_decimal(dl, -exp)
                  end)

                full =
                  Decimal.Context.with(high_prec, fn ->
                    Decimal.div(Decimal.new(1), full_power)
                  end)

                {:pyex_decimal, Decimal.apply_context(full)}
            end
        end

      true ->
        # Non-integer exponent: use float math, preserve as Decimal.
        try do
          base = Decimal.to_float(dl)
          exp = Decimal.to_float(dr)
          result = :math.pow(base, exp)
          {:pyex_decimal, Decimal.from_float(result)}
        rescue
          ArithmeticError -> {:exception, "ValueError: math domain error"}
        end
    end
  end

  defp integer_pow_decimal(_base, 0), do: Decimal.new(1)
  defp integer_pow_decimal(base, 1), do: base

  defp integer_pow_decimal(base, n) when n > 1 do
    half = integer_pow_decimal(base, div(n, 2))
    sq = Decimal.mult(half, half)
    if rem(n, 2) == 0, do: sq, else: Decimal.mult(sq, base)
  end

  # Positive integer power, correctly rounded under the user context:
  # compute the exact (or near-exact) product at elevated precision, then
  # round once. A single deferred rounding step is what CPython does for
  # `Decimal ** positive_int`.
  defp integer_pow_decimal_rounded(base, n) do
    ctx = Decimal.Context.get()
    high_prec = %{ctx | precision: ctx.precision * 2 + 5}

    full =
      Decimal.Context.with(high_prec, fn ->
        integer_pow_decimal(base, n)
      end)

    Decimal.apply_context(full)
  end

  defp to_decimal({:pyex_decimal, d}), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(true), do: Decimal.new(1)
  defp to_decimal(false), do: Decimal.new(0)
  defp to_decimal(_), do: {:error, :not_decimal}

  # Elixir's `Decimal.div` keeps only the first N digits of the quotient
  # plus one extra rounding digit, then signals `:rounded`. That works for
  # `:half_up` / `:half_down` (which only need the next digit) but
  # produces an off-by-one error under `:half_even` (CPython's default)
  # when the next digit is exactly `5` and any of the *further* discarded
  # digits are non-zero -- the half-even tie-break depends on knowing the
  # sticky bit, but the Elixir lib has already dropped it.
  #
  # CPython's mpdec preserves a sticky indicator. We approximate the same
  # behaviour by computing the quotient at much higher precision, then
  # letting `apply_context` round under the user's actual context. The
  # extra precision gives `precision/3` enough surviving digits to make
  # the correct half-even decision.
  defp decimal_div_correctly_rounded(dl, dr) do
    ctx = Decimal.Context.get()
    high_prec = %{ctx | precision: ctx.precision * 2 + 5}
    full = Decimal.Context.with(high_prec, fn -> Decimal.div(dl, dr) end)
    Decimal.apply_context(full)
  end

  # Elixir's Decimal sometimes leaves a coefficient with (precision + 1)
  # digits after a rounding carry (e.g. `70 - 10000e+9` at prec=9 yields a
  # 10-digit `1000000000` coef). CPython / IEEE require the coefficient
  # to contain exactly `precision` digits; when a carry pushes us to
  # `precision + 1` the trailing zero is dropped and the exponent bumped.
  defp clip_coef_to_precision(%Decimal{coef: :NaN} = d), do: d
  defp clip_coef_to_precision(%Decimal{coef: :inf} = d), do: d
  defp clip_coef_to_precision(%Decimal{coef: 0} = d), do: d

  defp clip_coef_to_precision(%Decimal{coef: coef, exp: exp} = d) do
    prec = Decimal.Context.get().precision
    digit_count = length(Integer.digits(coef))

    if digit_count > prec and rem(coef, 10) == 0 do
      clip_coef_to_precision(%{d | coef: div(coef, 10), exp: exp + 1})
    else
      d
    end
  end

  # CPython's Decimal arithmetic on NaN returns the NaN operand unchanged
  # (with its original sign). Elixir's Decimal.sub/mul/etc. sometimes flip
  # the NaN's sign when the NaN is the right-hand operand of a
  # sign-flipping op -- so we intercept before that happens.
  defp nan_passthrough(%Decimal{coef: :NaN} = dl, _dr), do: dl
  defp nan_passthrough(_dl, %Decimal{coef: :NaN} = dr), do: dr
  defp nan_passthrough(_, _), do: nil

  # CPython's Decimal remainder is always exact (never rounds), but
  # Elixir's Decimal.rem computes `a - (trunc(a/b) * b)` under the active
  # context's precision -- which rounds the `q * b` step when the divisor
  # has more decimal digits than the precision permits. Run the whole
  # computation under a context tall enough to cover the sum of both
  # operand widths so the subtraction is exact.
  defp decimal_rem_exact(dl, dr) do
    digits_l = integer_digit_count(dl.coef) + max(-dl.exp, 0)
    digits_r = integer_digit_count(dr.coef) + max(-dr.exp, 0)
    needed = digits_l + digits_r + 10
    ctx = Decimal.Context.get()
    high_prec = %{ctx | precision: max(ctx.precision, needed)}
    Decimal.Context.with(high_prec, fn -> Decimal.rem(dl, dr) end)
  end

  # CPython's rule: the integer part of a // or % quotient must fit in
  # the current precision, otherwise signal `DivisionImpossible` (a
  # subclass of InvalidOperation). Elixir's Decimal.div_int enforces this
  # at the active precision and raises `Decimal.Error` when the quotient
  # overflows -- so we first probe at user precision to catch the error,
  # then compute the real result at elevated precision (for the `%` path)
  # or at user precision (for `//`, which is bounded).
  defp decimal_floor_div(dl, dr) do
    try do
      q = Decimal.div_int(dl, dr) |> rescale_exponent(0)

      if quotient_fits_precision?(q) do
        {:pyex_decimal, q}
      else
        {:exception, "InvalidOperation: quotient too large for current precision"}
      end
    rescue
      Decimal.Error ->
        {:exception, "InvalidOperation: quotient too large for current precision"}
    end
  end

  defp decimal_percent(dl, dr) do
    try do
      q_check = Decimal.div_int(dl, dr) |> rescale_exponent(0)

      unless quotient_fits_precision?(q_check) do
        throw({:division_impossible})
      end

      target_exp = min(dl.exp, dr.exp)

      r =
        decimal_rem_exact(dl, dr)
        |> rescale_exponent(target_exp)
        # CPython rounds the remainder to fit the user's current precision
        # (the IBM `Rounded` / `Inexact` flags surface here). Apply the
        # active context so our result matches.
        |> Decimal.apply_context()
        |> clip_coef_to_precision()

      # CPython preserves the sign of the dividend even when the
      # remainder is zero, so `-1 % 1` yields `-0`. Elixir's Decimal.rem
      # returns positive zero for exactly-divisible cases; we restore the
      # dividend's sign on a zero result.
      r = if r.coef == 0, do: %{r | sign: dl.sign}, else: r

      {:pyex_decimal, r}
    rescue
      Decimal.Error ->
        {:exception, "InvalidOperation: quotient too large for current precision"}
    catch
      {:division_impossible} ->
        {:exception, "InvalidOperation: quotient too large for current precision"}
    end
  end

  # CPython's `//` and `%` require the integer quotient to fit in the
  # current precision. Elixir's `Decimal.div_int` silently returns more
  # digits than the context allows, so we enforce the bound ourselves.
  defp quotient_fits_precision?(%Decimal{coef: :NaN}), do: true
  defp quotient_fits_precision?(%Decimal{coef: :inf}), do: true
  defp quotient_fits_precision?(%Decimal{coef: 0}), do: true

  defp quotient_fits_precision?(%Decimal{coef: coef}) do
    length(Integer.digits(abs(coef))) <= Decimal.Context.get().precision
  end

  defp integer_digit_count(:NaN), do: 0
  defp integer_digit_count(:inf), do: 0
  defp integer_digit_count(0), do: 1
  defp integer_digit_count(n) when is_integer(n), do: length(Integer.digits(abs(n)))

  # Scale a Decimal to a target exponent without changing its value.
  # Only safe when the current exponent is >= target (we shift the
  # coefficient left). For finite Decimals only; NaN / Inf pass through.
  defp rescale_exponent(%Decimal{coef: :NaN} = d, _), do: d
  defp rescale_exponent(%Decimal{coef: :inf} = d, _), do: d
  defp rescale_exponent(%Decimal{exp: e} = d, target) when e == target, do: d

  defp rescale_exponent(%Decimal{sign: s, coef: 0}, target),
    do: %Decimal{sign: s, coef: 0, exp: target}

  defp rescale_exponent(%Decimal{sign: s, coef: coef, exp: e}, target) when e > target do
    diff = e - target
    %Decimal{sign: s, coef: coef * pow10_int(diff), exp: target}
  end

  defp rescale_exponent(d, _target), do: d

  defp pow10_int(0), do: 1
  defp pow10_int(n) when n > 0, do: 10 * pow10_int(n - 1)

  defp op_str(:plus), do: "+"
  defp op_str(:minus), do: "-"
  defp op_str(:star), do: "*"
  defp op_str(:slash), do: "/"
  defp op_str(:floor_div), do: "//"
  defp op_str(:percent), do: "%"
  defp op_str(:double_star), do: "**"
  defp op_str(:eq), do: "=="
  defp op_str(:neq), do: "!="
  defp op_str(:lt), do: "<"
  defp op_str(:gt), do: ">"
  defp op_str(:lte), do: "<="
  defp op_str(:gte), do: ">="
  defp op_str(_), do: "?"
end
