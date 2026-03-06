defmodule Pyex.Interpreter.BinaryOps do
  @moduledoc """
  Pure binary-operation evaluation for `Pyex.Interpreter`.

  Every function here is side-effect-free: no `Env` or `Ctx` threading.
  The main interpreter calls into this module after evaluating operands
  and resolving dunder methods, so all values arriving here are plain
  Pyex values.
  """

  import Bitwise, only: [band: 2, bor: 2, bxor: 2, bsl: 2, bsr: 2]

  alias Pyex.Interpreter.{Format, Helpers}
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

  defp dispatch(:plus, %{"__counter__" => true} = l, %{"__counter__" => true} = r) do
    Collections.counter_add(l, r)
  end

  defp dispatch(:plus, l, r) when is_number(l) and is_number(r), do: l + r

  defp dispatch(:plus, l, r),
    do: type_error("+", l, r)

  # -- minus ----------------------------------------------------------

  defp dispatch(:minus, l, r) when is_number(l) and is_number(r), do: l - r

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

  defp dispatch(:star, l, r),
    do: type_error("*", l, r)

  # -- slash ----------------------------------------------------------

  defp dispatch(:slash, _l, r) when r == 0 or r == 0.0,
    do: {:exception, "ZeroDivisionError: division by zero"}

  defp dispatch(:slash, l, r) when is_number(l) and is_number(r), do: l / r

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

  defp dispatch(:percent, l, r) when is_binary(l), do: Format.string_format(l, r)

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

  defp dispatch(:eq, {:py_list, lr, _}, {:py_list, rr, _}),
    do: Enum.reverse(lr) == Enum.reverse(rr)

  defp dispatch(:eq, {:py_list, reversed, _}, r) when is_list(r),
    do: Enum.reverse(reversed) == r

  defp dispatch(:eq, l, {:py_list, reversed, _}) when is_list(l),
    do: l == Enum.reverse(reversed)

  defp dispatch(:eq, l, r), do: l == r

  defp dispatch(:neq, {:py_list, lr, _}, {:py_list, rr, _}),
    do: Enum.reverse(lr) != Enum.reverse(rr)

  defp dispatch(:neq, {:py_list, reversed, _}, r) when is_list(r),
    do: Enum.reverse(reversed) != r

  defp dispatch(:neq, l, {:py_list, reversed, _}) when is_list(l),
    do: l != Enum.reverse(reversed)

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

  defp dispatch(:is, l, r), do: l === r
  defp dispatch(:is_not, l, r), do: l !== r

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
end
