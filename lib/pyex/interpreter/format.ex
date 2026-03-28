defmodule Pyex.Interpreter.Format do
  @moduledoc """
  Python `%`-style string formatting.

  Handles format specifiers like `%s`, `%d`, `%f`, `%x`, `%o`,
  `%e`, `%E`, `%g`, `%G`, and `%r` with flags, width, and
  precision support.
  """

  alias Pyex.{Ctx, Env, Interpreter}
  alias Pyex.Interpreter.{Helpers, Protocols}

  @typep format_spec :: %{
           flags: String.t(),
           width: non_neg_integer() | :star | nil,
           precision: non_neg_integer() | :star | nil
         }

  @doc """
  Formats a string using Python `%` operator semantics with dunder dispatch.

  Uses `eval_py_str` for `%s` so that `__str__` is honoured on instances
  (e.g. `"%s" % some_exception` returns the exception message, not
  `"<SomeError instance>"`).

  Returns `{result, env, ctx}` where result is the formatted string or
  `{:exception, message}`.
  """
  @spec string_format(
          String.t(),
          Interpreter.pyvalue(),
          Env.t(),
          Ctx.t()
        ) ::
          {String.t() | {:exception, String.t()}, Env.t(), Ctx.t()}
  def string_format(template, args, env, ctx) do
    arg_list =
      case args do
        {:tuple, items} -> items
        other -> [other]
      end

    string_format_loop(template, arg_list, <<>>, env, ctx)
  end

  @doc """
  Pure `%`-formatting without dunder dispatch.

  Used as a fallback when env/ctx are not available. `%s` uses
  `Helpers.py_str/1` directly, so `__str__` on instances is not called.
  Prefer `string_format/4` when env/ctx are in scope.
  """
  @spec string_format_pure(String.t(), Interpreter.pyvalue()) ::
          String.t() | {:exception, String.t()}
  def string_format_pure(template, args) do
    arg_list =
      case args do
        {:tuple, items} -> items
        other -> [other]
      end

    string_format_pure_loop(template, arg_list, <<>>)
  end

  @spec string_format_loop(String.t(), [Interpreter.pyvalue()], binary(), Env.t(), Ctx.t()) ::
          {String.t() | {:exception, String.t()}, Env.t(), Ctx.t()}
  defp string_format_loop(<<>>, _args, acc, env, ctx), do: {acc, env, ctx}

  defp string_format_loop(<<?%, ?%, rest::binary>>, args, acc, env, ctx) do
    string_format_loop(rest, args, <<acc::binary, ?%>>, env, ctx)
  end

  defp string_format_loop(<<?%, rest::binary>>, args, acc, env, ctx) do
    case parse_named_key(rest) do
      {:ok, key, rest} ->
        case parse_format_spec(rest) do
          {:ok, spec, code, rest} ->
            val = lookup_named_key(args, key)

            case val do
              {:exception, _} = exc ->
                {exc, env, ctx}

              _ ->
                {result, env, ctx} = apply_format_spec_ctx(spec, code, val, env, ctx)

                case result do
                  {:exception, _} = exc ->
                    {exc, env, ctx}

                  formatted ->
                    string_format_loop(rest, args, <<acc::binary, formatted::binary>>, env, ctx)
                end
            end

          {:error, msg} ->
            {{:exception, msg}, env, ctx}
        end

      :not_named ->
        case parse_format_spec(rest) do
          {:ok, spec, code, rest} ->
            {spec, args} =
              case resolve_star_args(spec, args) do
                {:ok, spec, args} -> {spec, args}
                :not_enough -> {spec, []}
              end

            case args do
              [val | remaining] ->
                {result, env, ctx} = apply_format_spec_ctx(spec, code, val, env, ctx)

                case result do
                  {:exception, _} = exc ->
                    {exc, env, ctx}

                  formatted ->
                    string_format_loop(
                      rest,
                      remaining,
                      <<acc::binary, formatted::binary>>,
                      env,
                      ctx
                    )
                end

              [] ->
                {{:exception, "TypeError: not enough arguments for format string"}, env, ctx}
            end

          {:error, msg} ->
            {{:exception, msg}, env, ctx}
        end
    end
  end

  defp string_format_loop(<<ch::utf8, rest::binary>>, args, acc, env, ctx) do
    string_format_loop(rest, args, <<acc::binary, ch::utf8>>, env, ctx)
  end

  @spec lookup_named_key(Interpreter.pyvalue(), String.t()) :: Interpreter.pyvalue()
  defp lookup_named_key({:py_dict, _, _} = dict, key) do
    case Pyex.PyDict.fetch(dict, key) do
      {:ok, val} -> val
      :error -> {:exception, "KeyError: '#{key}'"}
    end
  end

  defp lookup_named_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> {:exception, "KeyError: '#{key}'"}
    end
  end

  defp lookup_named_key([dict], key), do: lookup_named_key(dict, key)

  defp lookup_named_key(_, key), do: {:exception, "KeyError: '#{key}'"}

  @spec string_format_pure_loop(String.t(), [Interpreter.pyvalue()], binary()) ::
          String.t() | {:exception, String.t()}
  defp string_format_pure_loop(<<>>, _args, acc), do: acc

  defp string_format_pure_loop(<<?%, ?%, rest::binary>>, args, acc) do
    string_format_pure_loop(rest, args, <<acc::binary, ?%>>)
  end

  defp string_format_pure_loop(<<?%, rest::binary>>, args, acc) do
    case parse_format_spec(rest) do
      {:ok, raw_spec, code, rest} ->
        {spec, args} =
          case resolve_star_args(raw_spec, args) do
            {:ok, spec, args} -> {spec, args}
            :not_enough -> {raw_spec, []}
          end

        case args do
          [val | remaining] ->
            case apply_format_spec(spec, code, val) do
              {:exception, _} = exc ->
                exc

              formatted ->
                string_format_pure_loop(rest, remaining, <<acc::binary, formatted::binary>>)
            end

          [] ->
            {:exception, "TypeError: not enough arguments for format string"}
        end

      {:error, msg} ->
        {:exception, msg}
    end
  end

  defp string_format_pure_loop(<<ch::utf8, rest::binary>>, args, acc) do
    string_format_pure_loop(rest, args, <<acc::binary, ch::utf8>>)
  end

  @typep star_result :: {:ok, format_spec(), [Interpreter.pyvalue()]} | :not_enough

  @spec resolve_star_args(format_spec(), [Interpreter.pyvalue()]) :: star_result()
  defp resolve_star_args(%{width: :star, precision: :star} = spec, [w, p | rest])
       when is_integer(w) and is_integer(p) do
    {:ok, %{spec | width: abs(w), precision: p, flags: star_flags(spec.flags, w)}, rest}
  end

  defp resolve_star_args(%{width: :star} = spec, [w | rest]) when is_integer(w) do
    {:ok, %{spec | width: abs(w), flags: star_flags(spec.flags, w)}, rest}
  end

  defp resolve_star_args(%{precision: :star} = spec, [p | rest]) when is_integer(p) do
    {:ok, %{spec | precision: p}, rest}
  end

  defp resolve_star_args(%{width: :star}, _), do: :not_enough
  defp resolve_star_args(spec, args), do: {:ok, spec, args}

  @spec star_flags(String.t(), integer()) :: String.t()
  defp star_flags(flags, w) when w < 0,
    do: if(String.contains?(flags, "-"), do: flags, else: flags <> "-")

  defp star_flags(flags, _w), do: flags

  # Named key extraction for %(name)s syntax
  @spec parse_named_key(String.t()) :: {:ok, String.t(), String.t()} | :not_named
  defp parse_named_key(<<?(, rest::binary>>) do
    collect_named_key(rest, <<>>)
  end

  defp parse_named_key(_), do: :not_named

  @spec collect_named_key(String.t(), binary()) :: {:ok, String.t(), String.t()} | :not_named
  defp collect_named_key(<<?), rest::binary>>, name), do: {:ok, name, rest}

  defp collect_named_key(<<ch::utf8, rest::binary>>, name),
    do: collect_named_key(rest, <<name::binary, ch::utf8>>)

  defp collect_named_key(<<>>, _name), do: :not_named

  @spec apply_format_spec_ctx(format_spec(), char(), Interpreter.pyvalue(), Env.t(), Ctx.t()) ::
          {String.t() | {:exception, String.t()}, Env.t(), Ctx.t()}
  defp apply_format_spec_ctx(spec, ?s, val, env, ctx) do
    {str, env, ctx} = Protocols.eval_py_str(val, env, ctx)

    str =
      case spec.precision do
        nil -> str
        p -> String.slice(str, 0, p)
      end

    {pad_string(str, spec), env, ctx}
  end

  defp apply_format_spec_ctx(spec, code, val, env, ctx) do
    {apply_format_spec(spec, code, val), env, ctx}
  end

  @spec parse_format_spec(String.t()) ::
          {:ok, format_spec(), char(), String.t()} | {:error, String.t()}
  defp parse_format_spec(input) do
    {flags, input} = consume_flags(input, <<>>)
    {width, input} = consume_width(input)
    {precision, input} = consume_precision(input)

    case input do
      <<code, rest::binary>> when code in ~c[sdfrxoieEgG] ->
        {:ok, %{flags: flags, width: width, precision: precision}, code, rest}

      _ ->
        {:error, "ValueError: incomplete format"}
    end
  end

  @spec consume_width(String.t()) :: {non_neg_integer() | :star | nil, String.t()}
  defp consume_width(<<?*, rest::binary>>), do: {:star, rest}
  defp consume_width(input), do: consume_digits(input)

  @spec consume_flags(String.t(), binary()) :: {String.t(), String.t()}
  defp consume_flags(<<ch, rest::binary>>, acc) when ch in ~c[-+0 #] do
    consume_flags(rest, <<acc::binary, ch>>)
  end

  defp consume_flags(rest, acc), do: {acc, rest}

  @spec consume_digits(String.t()) :: {non_neg_integer() | nil, String.t()}
  defp consume_digits(input), do: consume_digits(input, <<>>)

  @spec consume_digits(String.t(), binary()) :: {non_neg_integer() | nil, String.t()}
  defp consume_digits(<<d, rest::binary>>, acc) when d in ?0..?9 do
    consume_digits(rest, <<acc::binary, d>>)
  end

  defp consume_digits(rest, <<>>), do: {nil, rest}

  defp consume_digits(rest, acc) do
    {String.to_integer(acc), rest}
  end

  @spec consume_precision(String.t()) :: {non_neg_integer() | :star | nil, String.t()}
  defp consume_precision(<<?., ?*, rest::binary>>), do: {:star, rest}

  defp consume_precision(<<?., rest::binary>>) do
    {digits, rest} = consume_digits(rest)
    {digits || 6, rest}
  end

  defp consume_precision(rest), do: {nil, rest}

  @spec apply_format_spec(format_spec(), char(), Interpreter.pyvalue()) ::
          String.t() | {:exception, String.t()}
  defp apply_format_spec(spec, ?s, val) do
    str = Helpers.py_str(val)

    str =
      case spec.precision do
        nil -> str
        p -> String.slice(str, 0, p)
      end

    pad_string(str, spec)
  end

  defp apply_format_spec(spec, ?r, val) do
    pad_string(Helpers.py_repr_fmt(val), spec)
  end

  defp apply_format_spec(spec, code, val) when code in ~c[di] and is_integer(val) do
    pad_string(Integer.to_string(val), spec)
  end

  defp apply_format_spec(spec, code, val) when code in ~c[di] and is_float(val) do
    pad_string(Integer.to_string(trunc(val)), spec)
  end

  defp apply_format_spec(spec, code, val) when code in ~c[di] and is_boolean(val) do
    pad_string(Integer.to_string(if(val, do: 1, else: 0)), spec)
  end

  defp apply_format_spec(spec, ?f, val) when is_number(val) do
    precision = spec.precision || 6
    formatted = format_float_bankers(val / 1, precision)
    pad_string(formatted, spec)
  end

  defp apply_format_spec(spec, code, val) when code in ~c[eE] and is_number(val) do
    precision = spec.precision || 6
    formatted = format_scientific_py(val / 1, precision)

    formatted =
      if code == ?E, do: String.upcase(formatted), else: formatted

    pad_string(formatted, spec)
  end

  defp apply_format_spec(spec, code, val) when code in ~c[gG] and is_number(val) do
    precision = max(spec.precision || 6, 1)
    float_val = val / 1
    formatted = format_g_py(float_val, precision)

    formatted =
      if code == ?G, do: String.upcase(formatted), else: formatted

    pad_string(formatted, spec)
  end

  defp apply_format_spec(spec, ?x, val) when is_integer(val) do
    formatted =
      if val < 0,
        do: ("-" <> Integer.to_string(-val, 16)) |> String.downcase(),
        else: Integer.to_string(val, 16) |> String.downcase()

    pad_string(formatted, spec)
  end

  defp apply_format_spec(spec, ?o, val) when is_integer(val) do
    formatted =
      if val < 0,
        do: "-" <> Integer.to_string(-val, 8),
        else: Integer.to_string(val, 8)

    pad_string(formatted, spec)
  end

  defp apply_format_spec(_spec, code, val) do
    {:exception,
     "TypeError: %#{<<code>>} format: a number is required, not #{Helpers.py_type(val)}"}
  end

  @spec format_float_bankers(float(), non_neg_integer()) :: String.t()
  defp format_float_bankers(float_val, precision) do
    case Decimal.parse(:erlang.float_to_binary(float_val, [])) do
      {d, ""} ->
        d
        |> Decimal.round(precision, :half_even)
        |> Decimal.to_string(:normal)
        |> ensure_decimal_places_fmt(precision)

      _ ->
        :erlang.float_to_binary(float_val, decimals: precision)
    end
  end

  @spec format_scientific_py(float(), non_neg_integer()) :: String.t()
  defp format_scientific_py(float_val, precision) do
    # Use Decimal banker's rounding for mantissa, matching CPython behaviour.
    exp =
      if float_val == 0.0 do
        0
      else
        float_val |> abs() |> :math.log10() |> Float.floor() |> trunc()
      end

    mantissa = float_val / :math.pow(10, exp)

    rounded_mantissa =
      case Decimal.parse(:erlang.float_to_binary(mantissa, [])) do
        {d, ""} ->
          d
          |> Decimal.round(precision, :half_even)
          |> Decimal.to_string(:normal)
          |> ensure_decimal_places_fmt(precision)

        _ ->
          :erlang.float_to_binary(mantissa, decimals: precision)
      end

    # If rounding pushed mantissa to 10.x, renormalise
    {rounded_mantissa, exp} =
      if String.starts_with?(rounded_mantissa, "10") or
           String.starts_with?(rounded_mantissa, "-10") do
        m2 = Decimal.parse(rounded_mantissa) |> elem(0)
        m2 = Decimal.div(m2, Decimal.new(10)) |> Decimal.round(precision, :half_even)
        s = m2 |> Decimal.to_string(:normal) |> ensure_decimal_places_fmt(precision)
        {s, exp + 1}
      else
        {rounded_mantissa, exp}
      end

    exp_sign = if exp >= 0, do: "+", else: "-"
    exp_str = abs(exp) |> Integer.to_string() |> String.pad_leading(2, "0")
    rounded_mantissa <> "e" <> exp_sign <> exp_str
  end

  @spec ensure_decimal_places_fmt(String.t(), non_neg_integer()) :: String.t()
  defp ensure_decimal_places_fmt(s, 0), do: s

  defp ensure_decimal_places_fmt(s, precision) do
    case String.split(s, ".") do
      [int_part, dec_part] ->
        pad = max(precision - byte_size(dec_part), 0)
        int_part <> "." <> dec_part <> String.duplicate("0", pad)

      [int_part] ->
        int_part <> "." <> String.duplicate("0", precision)
    end
  end

  @spec format_g_py(float(), pos_integer()) :: String.t()
  defp format_g_py(float_val, precision) do
    # Python %g rule: round to 'precision' significant figures first,
    # then if -4 <= exponent < precision use fixed, else scientific.
    # Strip trailing zeros in both cases.
    if float_val == 0.0 do
      "0"
    else
      # Round to 'precision' sig figs to determine the actual exponent after rounding
      exp_before = float_val |> abs() |> :math.log10() |> Float.floor() |> trunc()
      dec_places_for_round = max(precision - 1 - exp_before, 0)

      rounded =
        case Decimal.parse(:erlang.float_to_binary(float_val, [])) do
          {d, ""} ->
            d
            |> Decimal.round(dec_places_for_round, :half_even)
            |> Decimal.to_float()

          _ ->
            float_val
        end

      # Recompute exponent after rounding (rounding can change magnitude)
      exp =
        if rounded == 0.0 do
          0
        else
          rounded |> abs() |> :math.log10() |> Float.floor() |> trunc()
        end

      if exp >= -4 and exp < precision do
        dec_places = max(precision - 1 - exp, 0)
        raw = format_float_bankers(rounded, dec_places)
        strip_trailing_zeros(raw)
      else
        raw = format_scientific_py(rounded, precision - 1)
        [mantissa, exp_part] = String.split(raw, "e", parts: 2)
        mantissa = strip_trailing_zeros(mantissa)
        mantissa <> "e" <> exp_part
      end
    end
  end

  @spec strip_trailing_zeros(String.t()) :: String.t()
  defp strip_trailing_zeros(s) do
    if String.contains?(s, ".") do
      s
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")
    else
      s
    end
  end

  @spec pad_string(String.t(), format_spec()) :: String.t()
  defp pad_string(str, %{width: nil}), do: str

  defp pad_string(str, %{width: width, flags: _flags}) when byte_size(str) >= width, do: str

  defp pad_string(str, %{width: width, flags: flags}) do
    padding = width - byte_size(str)
    pad_char = if String.contains?(flags, "0"), do: "0", else: " "

    if String.contains?(flags, "-") do
      str <> String.duplicate(pad_char, padding)
    else
      String.duplicate(pad_char, padding) <> str
    end
  end
end
