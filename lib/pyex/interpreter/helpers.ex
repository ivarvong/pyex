defmodule Pyex.Interpreter.Helpers do
  @moduledoc """
  Pure utility functions for the Pyex interpreter.

  Contains Python value representation (`py_type/1`, `py_str/1`),
  truthiness checks (`truthy?/1`), error formatting, and small
  arithmetic helpers. All functions are side-effect-free and do
  not depend on the interpreter's evaluation loop.
  """

  alias Pyex.{Builtins, Ctx, Env, Parser, PyDict}

  @doc """
  Returns the Python type name for a runtime value.
  """
  @dialyzer {:nowarn_function, py_type: 1}
  @spec py_type(term()) :: String.t()
  def py_type(val) when is_integer(val), do: "int"
  def py_type(:infinity), do: "float"
  def py_type(:neg_infinity), do: "float"
  def py_type(:nan), do: "float"
  def py_type(:ellipsis), do: "ellipsis"
  def py_type(val) when is_float(val), do: "float"
  def py_type(val) when is_binary(val), do: "str"
  def py_type(val) when is_boolean(val), do: "bool"
  def py_type(nil), do: "NoneType"
  def py_type({:py_list, _, _}), do: "list"
  def py_type(val) when is_list(val), do: "list"
  def py_type({:py_dict, _, _}), do: "dict"
  def py_type(val) when is_map(val), do: "dict"
  def py_type({:tuple, _}), do: "tuple"
  def py_type({:set, _}), do: "set"
  def py_type({:frozenset, _}), do: "frozenset"
  def py_type({:function, _, _, _, _}), do: "function"
  def py_type({:builtin, _}), do: "builtin_function_or_method"
  def py_type({:builtin_type, name, _}), do: "<class '#{name}'>"
  def py_type({:builtin_kw, _}), do: "builtin_function_or_method"
  def py_type({:class, name, _, _}), do: "<class '#{name}'>"
  def py_type({:instance, {:class, name, _, _}, _}), do: name
  def py_type({:generator, _}), do: "generator"
  def py_type({:generator_error, _, _}), do: "generator"
  def py_type({:iterator, _}), do: "iterator"
  def py_type({:bound_method, _, _}), do: "method"
  def py_type({:bound_method, _, _, _}), do: "method"
  def py_type({:range, _, _, _}), do: "range"
  def py_type({:super_proxy, _, _}), do: "super"
  def py_type({:pandas_series, _}), do: "Series"
  def py_type({:pandas_rolling, _, _}), do: "Rolling"
  def py_type({:pandas_dataframe, _}), do: "DataFrame"
  def py_type({:pyex_decimal, _}), do: "Decimal"
  def py_type({:deque, _, _}), do: "deque"
  def py_type({:stringio, _}), do: "StringIO"
  def py_type({:property, _, _, _}), do: "property"
  def py_type({:staticmethod, _}), do: "staticmethod"
  def py_type({:classmethod, _}), do: "classmethod"
  def py_type({:partial, _, _, _}), do: "partial"
  def py_type({:lru_cached_function, _, _}), do: "function"
  def py_type({:ref, _}), do: "ref"
  def py_type(_), do: "object"

  @doc """
  Converts a Python value to its `str()` representation.
  """
  @spec py_str(Pyex.Interpreter.pyvalue()) :: String.t()
  def py_str(nil), do: "None"
  def py_str(true), do: "True"
  def py_str(false), do: "False"
  def py_str(val) when is_binary(val), do: val
  def py_str(val) when is_integer(val), do: Integer.to_string(val)
  def py_str(:infinity), do: "inf"
  def py_str(:neg_infinity), do: "-inf"
  def py_str(:nan), do: "nan"
  def py_str(:ellipsis), do: "Ellipsis"
  def py_str(val) when is_float(val), do: py_float_str(val)

  def py_str({:py_list, reversed, _len}) do
    "[" <> (reversed |> Enum.reverse() |> Enum.map_join(", ", &py_repr_fmt/1)) <> "]"
  end

  def py_str(val) when is_list(val), do: "[" <> Enum.map_join(val, ", ", &py_repr_fmt/1) <> "]"

  def py_str({:py_dict, _, _} = dict) do
    visible = Builtins.visible_dict(dict)

    inner =
      Enum.map_join(PyDict.items(visible), ", ", fn {k, v} ->
        py_repr_fmt(k) <> ": " <> py_repr_fmt(v)
      end)

    "{" <> inner <> "}"
  end

  def py_str(val) when is_map(val) do
    visible = Builtins.visible_dict(val)

    inner =
      Enum.map_join(visible, ", ", fn {k, v} ->
        py_repr_fmt(k) <> ": " <> py_repr_fmt(v)
      end)

    "{" <> inner <> "}"
  end

  def py_str({:stringio, buf}), do: "<StringIO object at 0x0, buf=#{inspect(buf)}>"

  def py_str({:deque, items, nil}),
    do: "deque([" <> Enum.map_join(items, ", ", &py_repr_fmt/1) <> "])"

  def py_str({:deque, items, maxlen}),
    do: "deque([" <> Enum.map_join(items, ", ", &py_repr_fmt/1) <> "], maxlen=#{maxlen})"

  def py_str({:tuple, items}), do: "(" <> Enum.map_join(items, ", ", &py_repr_fmt/1) <> ")"
  def py_str({:set, s}), do: "{" <> Enum.map_join(MapSet.to_list(s), ", ", &py_repr_fmt/1) <> "}"

  def py_str({:frozenset, s}) do
    if MapSet.size(s) == 0 do
      "frozenset()"
    else
      "frozenset({" <> Enum.map_join(MapSet.to_list(s), ", ", &py_repr_fmt/1) <> "})"
    end
  end

  def py_str({:class, name, _, _}), do: "<class '#{name}'>"
  def py_str({:builtin_type, name, _}), do: "<class '#{name}'>"

  def py_str({:instance, {:class, "type", _, _}, %{"__name__" => type_name}}) do
    "<class '#{type_name}'>"
  end

  def py_str({:instance, {:class, name, _, _}, fields}) do
    case fields do
      %{"args" => {:tuple, [arg]}} -> py_str(arg)
      %{"args" => {:tuple, []}} -> ""
      %{"args" => {:tuple, args}} -> "(" <> Enum.map_join(args, ", ", &py_str/1) <> ")"
      _ -> "<#{name} instance>"
    end
  end

  def py_str({:super_proxy, _, _}), do: "<super>"

  def py_str({:range, s, e, st}),
    do: if(st == 1, do: "range(#{s}, #{e})", else: "range(#{s}, #{e}, #{st})")

  def py_str({:pyex_decimal, d}), do: Decimal.to_string(d)
  def py_str({:generator, _}), do: "<generator object>"
  def py_str({:generator_error, _, _}), do: "<generator object>"
  def py_str({:iterator, _}), do: "<iterator object>"
  def py_str({:ref, _}), do: "<ref>"
  def py_str(_), do: "<object>"

  @doc """
  Formats a value for `repr()` — strings are single-quoted,
  everything else delegates to `py_str/1`.
  """
  @spec py_repr_fmt(Pyex.Interpreter.pyvalue()) :: String.t()
  def py_repr_fmt(val) when is_binary(val), do: repr_string(val)
  def py_repr_fmt({:pyex_decimal, d}), do: "Decimal('#{Decimal.to_string(d)}')"
  def py_repr_fmt(val), do: py_str(val)

  @doc """
  Produces a Python repr for a string value.

  Uses double quotes if the string contains single quotes but no double
  quotes (matching CPython's repr behaviour).
  """
  @spec repr_string(String.t()) :: String.t()
  def repr_string(s) do
    has_single = String.contains?(s, "'")
    has_double = String.contains?(s, "\"")

    if has_single and not has_double do
      "\"" <> escape_repr_double(s) <> "\""
    else
      "'" <> escape_repr(s) <> "'"
    end
  end

  @doc """
  Escapes special characters in a string for repr output (single-quoted).
  """
  @spec escape_repr(String.t()) :: String.t()
  def escape_repr(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
    |> String.replace("\0", "\\x00")
  end

  @spec escape_repr_double(String.t()) :: String.t()
  defp escape_repr_double(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
    |> String.replace("\0", "\\x00")
  end

  @doc """
  Returns whether a Python value is truthy (pure version).

  Does not handle `__bool__` dunder dispatch — use
  `eval_truthy/3` in the interpreter for instance truthiness.
  """
  @spec truthy?(Pyex.Interpreter.pyvalue()) :: boolean()
  def truthy?(false), do: false
  def truthy?(nil), do: false
  def truthy?(0), do: false
  def truthy?(+0.0), do: false
  def truthy?(""), do: false
  def truthy?([]), do: false
  def truthy?({:py_list, _, 0}), do: false
  def truthy?({:py_dict, map, _}) when map == %{}, do: false
  def truthy?({:py_dict, _, _}), do: true
  def truthy?(map) when map == %{}, do: false
  def truthy?({:tuple, []}), do: false
  def truthy?({:set, s}), do: MapSet.size(s) > 0

  def truthy?({:pyex_decimal, d}), do: not Decimal.equal?(d, Decimal.new(0))

  def truthy?({:range, start, stop, step}),
    do: Builtins.range_length({:range, start, stop, step}) > 0

  def truthy?({:ref, _}), do: true
  def truthy?(_), do: true

  @doc """
  Appends a line number to an error message when available.
  """
  @spec format_error(String.t(), Ctx.t()) :: String.t()
  def format_error(msg, %Ctx{current_line: nil}), do: msg
  def format_error(msg, %Ctx{current_line: line}), do: msg <> " (line #{line})"

  @doc false
  @spec unwrap(Pyex.Interpreter.pyvalue() | {atom(), term()}) :: Pyex.Interpreter.pyvalue()
  def unwrap({:returned, value}), do: to_python_view(value)
  def unwrap({:exception, _} = signal), do: signal
  def unwrap(value), do: to_python_view(value)

  @doc false
  @spec unwrap_function_result(Pyex.Interpreter.pyvalue() | {atom(), term()}) ::
          Pyex.Interpreter.pyvalue()
  def unwrap_function_result({:returned, value}), do: to_python_view(value)
  def unwrap_function_result({:exception, _} = signal), do: signal
  def unwrap_function_result(_value), do: nil

  @doc false
  @spec unwrap_def(Parser.ast_node()) :: Parser.ast_node()
  def unwrap_def({:decorated_def, _, [_dec, inner]}), do: unwrap_def(inner)
  def unwrap_def({:def, _, _} = node), do: node
  def unwrap_def({:class, _, _} = node), do: node

  @doc false
  @spec root_var_name(Parser.ast_node()) :: {:ok, String.t()} | :error
  def root_var_name({:var, _, [name]}), do: {:ok, name}
  def root_var_name({:getattr, _, [expr, _]}), do: root_var_name(expr)
  def root_var_name({:call, _, [expr, _]}), do: root_var_name(expr)
  def root_var_name(_), do: :error

  @doc """
  Converts internal representation to user-visible Python value.
  Transforms reverse-storage lists back to regular lists.
  """
  @spec to_python_view(term()) :: term()
  def to_python_view({:py_list, reversed, _len}),
    do: reversed |> Enum.reverse() |> Enum.map(&to_python_view/1)

  def to_python_view({:tuple, items}), do: {:tuple, Enum.map(items, &to_python_view/1)}
  def to_python_view({:set, s}), do: {:set, s}
  def to_python_view({:frozenset, s}), do: {:frozenset, s}
  def to_python_view({:dict, d}), do: {:dict, d}
  def to_python_view({:range, start, stop, step}), do: {:range, start, stop, step}
  def to_python_view({:generator, items}), do: {:generator, Enum.map(items, &to_python_view/1)}
  def to_python_view({:instance, class, fields}), do: {:instance, class, fields}
  def to_python_view({:iterator, _} = it), do: it
  def to_python_view(list) when is_list(list), do: Enum.map(list, &to_python_view/1)

  def to_python_view({:py_dict, _, _} = dict) do
    Map.new(PyDict.items(dict), fn {k, v} -> {to_python_view(k), to_python_view(v)} end)
  end

  def to_python_view(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, to_python_view(v)} end)

  def to_python_view({:pyex_decimal, _} = d), do: d
  def to_python_view(val), do: val

  @doc false
  @spec bool_to_int(boolean() | number()) :: number()
  def bool_to_int(true), do: 1
  def bool_to_int(false), do: 0
  def bool_to_int(other), do: other

  @max_exp 100_000

  @doc false
  @spec int_pow(integer(), non_neg_integer()) :: integer() | {:exception, String.t()}
  def int_pow(_base, 0), do: 1
  def int_pow(base, 1), do: base

  def int_pow(_base, exp) when exp > @max_exp do
    {:exception, "OverflowError: exponent #{exp} exceeds maximum allowed (#{@max_exp})"}
  end

  def int_pow(base, exp) when rem(exp, 2) == 0 do
    half = int_pow(base, div(exp, 2))

    case half do
      {:exception, _} -> half
      _ -> half * half
    end
  end

  def int_pow(base, exp) do
    rest = int_pow(base, exp - 1)

    case rest do
      {:exception, _} -> rest
      _ -> base * rest
    end
  end

  @doc false
  @spec maybe_intify(float()) :: integer() | float()
  def maybe_intify(f) when is_float(f) do
    rounded = round(f)
    if rounded == f, do: rounded, else: f
  end

  @max_repeat_len 10_000_000

  @doc false
  @spec repeat_list(list(), integer()) :: list() | {:exception, String.t()}
  def repeat_list(_list, n) when n <= 0, do: []

  def repeat_list(list, n) do
    result_len = length(list) * n

    if result_len > @max_repeat_len do
      {:exception,
       "MemoryError: list repetition would create #{result_len} elements (max #{@max_repeat_len})"}
    else
      list |> List.duplicate(n) |> List.flatten()
    end
  end

  @doc false
  @spec has_scope_declarations?(Env.t()) :: boolean()
  def has_scope_declarations?(%Env{scopes: [top | _]}) do
    Enum.any?(top, fn
      {{:__global__, _}, _} -> true
      {{:__nonlocal__, _}, _} -> true
      _ -> false
    end)
  end

  @doc false
  @spec refresh_closure(Pyex.Interpreter.pyvalue(), Env.t()) :: Pyex.Interpreter.pyvalue()
  def refresh_closure({:function, name, params, body, _old_env}, post_call_env) do
    new_closure_env = Env.drop_top_scope(post_call_env)
    {:function, name, params, body, new_closure_env}
  end

  def refresh_closure(value, _post_call_env), do: value

  @doc false
  @dialyzer {:nowarn_function, update_closure_env: 2}
  @spec update_closure_env(Pyex.Interpreter.pyvalue(), Env.t()) :: Pyex.Interpreter.pyvalue()
  def update_closure_env({:function, name, params, body, old_env}, post_call_env) do
    new_closure_env = Env.merge_closure_scopes(old_env, post_call_env)
    {:function, name, params, body, new_closure_env}
  end

  def update_closure_env(value, _post_call_env), do: value

  @doc false
  @spec rebind_var(Env.t(), Parser.ast_node(), Pyex.Interpreter.pyvalue()) :: Env.t()
  def rebind_var(env, {:var, _, [var_name]}, updated_func) do
    Env.put_at_source(env, var_name, updated_func)
  end

  def rebind_var(env, _expr, _updated_func), do: env

  @doc """
  Formats a float the way Python does: decimal notation for magnitudes
  in roughly [1e-4, 1e16), scientific notation outside that range.
  `NaN`/`±inf` are handled by dedicated `py_str` clauses.

  Matches CPython's `repr(float)` (which `str(float)` delegates to
  since 3.2).  Uses Erlang's `:short` float formatting so the shortest
  string that round-trips to the same IEEE-754 double is produced.
  """
  @spec py_float_str(float()) :: String.t()
  def py_float_str(val) when is_float(val) do
    short = :erlang.float_to_binary(val, [:short])

    cond do
      val == 0.0 ->
        short

      String.contains?(short, "e") ->
        py_float_reformat_scientific(val, short)

      true ->
        abs_val = abs(val)

        if abs_val >= 1.0e16 or abs_val < 1.0e-4 do
          val |> :erlang.float_to_binary([:short]) |> normalize_scientific()
        else
          short
        end
    end
  end

  @spec py_float_reformat_scientific(float(), binary()) :: binary()
  defp py_float_reformat_scientific(val, short) do
    abs_val = abs(val)

    if abs_val >= 1.0e-4 and abs_val < 1.0e16 do
      expand_scientific(short)
    else
      normalize_scientific(short)
    end
  end

  @spec expand_scientific(binary()) :: binary()
  defp expand_scientific(short) do
    [mantissa_str, exp_str] = String.split(short, "e")
    exp = String.to_integer(exp_str)
    expand_mantissa(mantissa_str, exp)
  end

  @spec expand_mantissa(binary(), integer()) :: binary()
  defp expand_mantissa(mantissa_str, exp) do
    {sign, rest} =
      case mantissa_str do
        "-" <> r -> {"-", r}
        r -> {"", r}
      end

    {int_part, frac_part} =
      case String.split(rest, ".") do
        [i, f] -> {i, f}
        [i] -> {i, ""}
      end

    digits = int_part <> frac_part
    point_pos = String.length(int_part) + exp
    total = String.length(digits)

    cond do
      point_pos <= 0 ->
        sign <> "0." <> String.duplicate("0", -point_pos) <> digits

      point_pos >= total ->
        sign <> digits <> String.duplicate("0", point_pos - total) <> ".0"

      true ->
        {l, r} = String.split_at(digits, point_pos)
        sign <> l <> "." <> r
    end
  end

  @spec normalize_scientific(binary()) :: binary()
  defp normalize_scientific(s) do
    case Regex.run(~r/^(-?\d+(?:\.\d+)?)[eE]([+-]?\d+)$/, s) do
      [_, mantissa, exp] ->
        exp_int = String.to_integer(exp)
        sign = if exp_int < 0, do: "-", else: "+"
        exp_abs = abs(exp_int) |> Integer.to_string() |> String.pad_leading(2, "0")
        trim_trailing_dot_zero(mantissa) <> "e" <> sign <> exp_abs

      _ ->
        s
    end
  end

  @spec trim_trailing_dot_zero(binary()) :: binary()
  defp trim_trailing_dot_zero(mantissa) do
    case Regex.run(~r/^(-?\d+)\.0+$/, mantissa) do
      [_, int_part] -> int_part
      _ -> mantissa
    end
  end
end
