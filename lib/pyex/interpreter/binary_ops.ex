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

  defp dispatch(:in, l, {:tuple, items}), do: l in items
  defp dispatch(:in, l, {:py_list, reversed, _}), do: l in reversed
  defp dispatch(:in, l, r) when is_list(r), do: l in r

  defp dispatch(:in, l, r) when is_binary(l) and is_binary(r),
    do: String.contains?(r, l)

  defp dispatch(:in, l, {:py_dict, _, _} = dict),
    do: PyDict.has_key?(Pyex.Builtins.visible_dict(dict), l)

  defp dispatch(:in, l, r) when is_map(r),
    do: Map.has_key?(Pyex.Builtins.visible_dict(r), l)

  defp dispatch(:in, l, {:set, s}), do: MapSet.member?(s, l)
  defp dispatch(:in, l, {:frozenset, s}), do: MapSet.member?(s, l)

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
      {{:error, _}, _} -> type_error(op_str(op), l, r)
      {_, {:error, _}} -> type_error(op_str(op), l, r)
      {dl, dr} -> decimal_op(op, dl, dr, l, r)
    end
  end

  defp decimal_op(:plus, dl, dr, _l, _r), do: {:pyex_decimal, Decimal.add(dl, dr)}
  defp decimal_op(:minus, dl, dr, _l, _r), do: {:pyex_decimal, Decimal.sub(dl, dr)}
  defp decimal_op(:star, dl, dr, _l, _r), do: {:pyex_decimal, Decimal.mult(dl, dr)}

  defp decimal_op(:slash, dl, dr, _l, _r) do
    if Decimal.equal?(dr, Decimal.new(0)) do
      {:exception, "ZeroDivisionError: division by zero"}
    else
      {:pyex_decimal, Decimal.div(dl, dr)}
    end
  end

  defp decimal_op(:eq, dl, dr, _l, _r), do: Decimal.equal?(dl, dr)
  defp decimal_op(:neq, dl, dr, _l, _r), do: not Decimal.equal?(dl, dr)
  defp decimal_op(:lt, dl, dr, _l, _r), do: Decimal.lt?(dl, dr)
  defp decimal_op(:gt, dl, dr, _l, _r), do: Decimal.gt?(dl, dr)
  defp decimal_op(:lte, dl, dr, _l, _r), do: not Decimal.gt?(dl, dr)
  defp decimal_op(:gte, dl, dr, _l, _r), do: not Decimal.lt?(dl, dr)
  defp decimal_op(op, _dl, _dr, l, r), do: type_error(op_str(op), l, r)

  defp to_decimal({:pyex_decimal, d}), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(_), do: {:error, :not_decimal}

  defp op_str(:plus), do: "+"
  defp op_str(:minus), do: "-"
  defp op_str(:star), do: "*"
  defp op_str(:slash), do: "/"
  defp op_str(:eq), do: "=="
  defp op_str(:neq), do: "!="
  defp op_str(:lt), do: "<"
  defp op_str(:gt), do: ">"
  defp op_str(:lte), do: "<="
  defp op_str(:gte), do: ">="
  defp op_str(_), do: "?"
end
