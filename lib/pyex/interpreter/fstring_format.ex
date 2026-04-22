defmodule Pyex.Interpreter.FstringFormat do
  @moduledoc """
  Python format mini-language implementation for f-string format specs.

  Parses and applies format specs like `:.2f`, `:>10`, `:<14`, `:*^10`,
  `:>18,.2f`, `:05d`, etc.

  Format spec grammar: `[[fill]align][sign][#][0][width][grouping][.precision][type]`
  """

  alias Pyex.Interpreter.Helpers

  @doc """
  Applies a Python format spec string to a value.

  Returns the formatted string or `{:exception, message}`.
  """
  @spec apply_format_spec(Pyex.Interpreter.pyvalue(), String.t()) ::
          String.t() | {:exception, String.t()}
  def apply_format_spec(val, spec_str) do
    {:ok, spec} = parse_spec(spec_str)
    format_value(val, spec)
  end

  # Internal spec struct
  defp parse_spec(str) do
    {fill, align, str} = parse_fill_align(str)
    {sign, str} = parse_sign(str)
    {alt, str} = parse_alt(str)
    {zero_pad, str} = parse_zero_pad(str)
    {width, str} = parse_width(str)
    {grouping, str} = parse_grouping(str)
    {precision, str} = parse_precision(str)
    type = str

    # If zero-pad is set and no fill/align, use 0-fill right-aligned
    {fill, align} =
      if zero_pad and fill == nil and align == nil do
        {"0", ">"}
      else
        {fill || " ", align}
      end

    {:ok,
     %{
       fill: fill,
       align: align,
       sign: sign,
       alt: alt,
       width: width,
       grouping: grouping,
       precision: precision,
       type: type
     }}
  end

  # Parse optional [fill]align
  defp parse_fill_align(str) do
    case str do
      # Two-char fill+align: e.g., "*^", "0>"
      <<fill::utf8, align, rest::binary>> when align in [?<, ?>, ?^, ?=] ->
        {<<fill::utf8>>, <<align>>, rest}

      # One-char align only
      <<align, rest::binary>> when align in [?<, ?>, ?^, ?=] ->
        {nil, <<align>>, rest}

      _ ->
        {nil, nil, str}
    end
  end

  defp parse_sign(<<"+", rest::binary>>), do: {"+", rest}
  defp parse_sign(<<"-", rest::binary>>), do: {"-", rest}
  defp parse_sign(<<" ", rest::binary>>), do: {" ", rest}
  defp parse_sign(str), do: {nil, str}

  defp parse_alt(<<"#", rest::binary>>), do: {true, rest}
  defp parse_alt(str), do: {false, str}

  defp parse_zero_pad(<<"0", rest::binary>>), do: {true, rest}
  defp parse_zero_pad(str), do: {false, str}

  defp parse_width(str), do: consume_digits(str)

  defp parse_grouping(<<",", rest::binary>>), do: {",", rest}
  defp parse_grouping(<<"_", rest::binary>>), do: {"_", rest}
  defp parse_grouping(str), do: {nil, str}

  defp parse_precision(<<".", rest::binary>>) do
    {digits, rest} = consume_digits(rest)
    {digits || 0, rest}
  end

  defp parse_precision(str), do: {nil, str}

  defp consume_digits(str), do: consume_digits(str, <<>>)

  defp consume_digits(<<d, rest::binary>>, acc) when d in ?0..?9 do
    consume_digits(rest, <<acc::binary, d>>)
  end

  defp consume_digits(rest, <<>>), do: {nil, rest}
  defp consume_digits(rest, acc), do: {String.to_integer(acc), rest}

  # Format a value with parsed spec
  defp format_value(val, spec) do
    case spec.type do
      "f" -> format_float(val, spec)
      "d" -> format_int(val, spec)
      "s" -> format_string(val, spec)
      "e" -> format_scientific(val, spec, "e")
      "E" -> format_scientific(val, spec, "E")
      "g" -> format_general(val, spec, "e")
      "G" -> format_general(val, spec, "E")
      "x" -> format_base(val, spec, 16, false)
      "X" -> format_base(val, spec, 16, true)
      "o" -> format_base(val, spec, 8, false)
      "b" -> format_base(val, spec, 2, false)
      "%" -> format_percentage(val, spec)
      "" -> format_default(val, spec)
      _ -> {:exception, "ValueError: Unknown format code '#{spec.type}'"}
    end
  end

  defp format_float(val, spec) when is_number(val) do
    precision = spec.precision || 6
    float_val = val / 1
    formatted = format_float_rounded(float_val, precision)
    formatted = maybe_group(formatted, spec.grouping)
    formatted = apply_sign(formatted, spec.sign, val)
    apply_alignment(formatted, spec, val)
  end

  defp format_float({:pyex_decimal, d}, spec) do
    precision = spec.precision || 6
    formatted = format_decimal_fixed(d, precision)
    formatted = maybe_group(formatted, spec.grouping)
    apply_alignment(formatted, spec, {:pyex_decimal, d})
  end

  defp format_float(val, _spec) do
    {:exception,
     "ValueError: Unknown format code 'f' for object of type '#{Helpers.py_type(val)}'"}
  end

  defp format_int(val, spec) when is_integer(val) do
    formatted = Integer.to_string(val)
    formatted = maybe_group(formatted, spec.grouping)
    formatted = apply_sign(formatted, spec.sign, val)
    apply_alignment(formatted, spec, val)
  end

  defp format_int(val, spec) when is_float(val) do
    format_int(trunc(val), spec)
  end

  defp format_int(val, _spec) do
    {:exception,
     "ValueError: Unknown format code 'd' for object of type '#{Helpers.py_type(val)}'"}
  end

  defp format_string(val, spec) when is_binary(val) do
    formatted =
      case spec.precision do
        nil -> val
        p -> String.slice(val, 0, p)
      end

    apply_alignment(formatted, spec, val)
  end

  defp format_string(val, spec) do
    format_string(Helpers.py_str(val), spec)
  end

  defp format_scientific(val, spec, e_char) when is_number(val) do
    precision = spec.precision || 6
    formatted = format_scientific_bankers(val / 1, precision)

    formatted =
      if e_char == "E", do: String.upcase(formatted), else: formatted

    formatted = apply_sign(formatted, spec.sign, val)
    apply_alignment(formatted, spec, val)
  end

  defp format_scientific(val, _spec, _e_char) do
    {:exception,
     "ValueError: Unknown format code 'e' for object of type '#{Helpers.py_type(val)}'"}
  end

  # Python's "g" format:
  #   - precision P defaults to 6; P == 0 means P == 1
  #   - compute the exponent of the value (call it X)
  #   - if -4 <= X < P: use fixed notation with precision P-1-X
  #   - otherwise: use scientific notation with precision P-1
  #   - strip trailing zeros (and the decimal point if that's all that's left)
  @spec format_general(term(), map(), String.t()) :: String.t() | {:exception, String.t()}
  defp format_general(val, spec, e_char) when is_number(val) do
    precision = spec.precision || 6
    precision = if precision == 0, do: 1, else: precision
    float_val = val / 1

    exp =
      if float_val == 0.0 do
        0
      else
        float_val |> abs() |> :math.log10() |> Float.floor() |> trunc()
      end

    formatted =
      if exp >= -4 and exp < precision do
        # Fixed notation
        fixed_spec = %{spec | precision: max(precision - 1 - exp, 0), type: "f"}
        trim_trailing_zeros(format_float(val, fixed_spec))
      else
        sci_spec = %{spec | precision: max(precision - 1, 0), type: e_char}

        case format_scientific(val, sci_spec, e_char) do
          {:exception, _} = e -> e
          s -> trim_scientific_trailing_zeros(s)
        end
      end

    case formatted do
      {:exception, _} = e -> e
      s -> apply_alignment(s, spec, val)
    end
  end

  defp format_general(val, _spec, _e) do
    {:exception,
     "ValueError: Unknown format code 'g' for object of type '#{Helpers.py_type(val)}'"}
  end

  @spec trim_trailing_zeros(String.t()) :: String.t()
  defp trim_trailing_zeros(s) do
    if String.contains?(s, ".") do
      stripped = String.trim_trailing(s, "0")
      # Don't leave a bare decimal point.
      String.trim_trailing(stripped, ".")
    else
      s
    end
  end

  @spec trim_scientific_trailing_zeros(String.t()) :: String.t()
  defp trim_scientific_trailing_zeros(s) do
    case Regex.run(~r/^(-?\d+)\.(\d*?)(0*)([eE][+-]?\d+)$/, s) do
      [_, int_part, frac, _zeros, exp] ->
        if frac == "" do
          int_part <> exp
        else
          int_part <> "." <> frac <> exp
        end

      _ ->
        s
    end
  end

  @spec format_scientific_bankers(float(), non_neg_integer()) :: String.t()
  defp format_scientific_bankers(float_val, precision) do
    # Compute exponent
    exp =
      if float_val == 0.0 do
        0
      else
        float_val |> abs() |> :math.log10() |> Float.floor() |> trunc()
      end

    # Normalise mantissa and round using banker's rounding
    mantissa = float_val / :math.pow(10, exp)

    rounded_mantissa =
      case Decimal.parse(:erlang.float_to_binary(mantissa, [])) do
        {d, ""} ->
          d
          |> Decimal.round(precision, :half_even)
          |> Decimal.to_string(:normal)
          |> ensure_decimal_places(precision)

        _ ->
          :erlang.float_to_binary(mantissa, decimals: precision)
      end

    # Check if rounding pushed mantissa to 10.0
    {rounded_mantissa, exp} =
      if String.starts_with?(rounded_mantissa, "10") or
           String.starts_with?(rounded_mantissa, "-10") do
        m2 = Decimal.parse(rounded_mantissa) |> elem(0)
        m2 = Decimal.div(m2, Decimal.new(10)) |> Decimal.round(precision, :half_even)
        s = m2 |> Decimal.to_string(:normal) |> ensure_decimal_places(precision)
        {s, exp + 1}
      else
        {rounded_mantissa, exp}
      end

    exp_sign = if exp >= 0, do: "+", else: "-"
    exp_str = abs(exp) |> Integer.to_string() |> String.pad_leading(2, "0")
    rounded_mantissa <> "e" <> exp_sign <> exp_str
  end

  @spec ensure_decimal_places(String.t(), non_neg_integer()) :: String.t()
  defp ensure_decimal_places(s, 0), do: s

  defp ensure_decimal_places(s, precision) do
    case String.split(s, ".") do
      [int_part, dec_part] ->
        pad = max(precision - byte_size(dec_part), 0)
        int_part <> "." <> dec_part <> String.duplicate("0", pad)

      [int_part] ->
        int_part <> "." <> String.duplicate("0", precision)
    end
  end

  defp format_base(val, spec, base, upcase) when is_integer(val) do
    formatted =
      if val < 0 do
        "-" <> Integer.to_string(-val, base)
      else
        Integer.to_string(val, base)
      end

    formatted = if upcase, do: String.upcase(formatted), else: String.downcase(formatted)

    formatted =
      if spec.alt do
        prefix =
          case base do
            16 -> if(upcase, do: "0X", else: "0x")
            8 -> "0o"
            2 -> "0b"
          end

        if val < 0,
          do: "-" <> prefix <> String.trim_leading(formatted, "-"),
          else: prefix <> formatted
      else
        formatted
      end

    apply_alignment(formatted, spec, val)
  end

  defp format_base(val, _spec, _base, _upcase) do
    {:exception, "ValueError: Unknown format code for object of type '#{Helpers.py_type(val)}'"}
  end

  defp format_percentage(val, spec) when is_number(val) do
    precision = spec.precision || 6
    float_val = val * 100.0
    formatted = format_float_rounded(float_val, precision) <> "%"
    apply_alignment(formatted, spec, val)
  end

  defp format_percentage(val, _spec) do
    {:exception,
     "ValueError: Unknown format code '%' for object of type '#{Helpers.py_type(val)}'"}
  end

  defp format_default(val, spec) when is_integer(val) do
    formatted = Integer.to_string(val)
    formatted = maybe_group(formatted, spec.grouping)
    formatted = apply_sign(formatted, spec.sign, val)
    apply_alignment(formatted, spec, val)
  end

  defp format_default(val, spec) when is_float(val) do
    formatted = format_default_float(val)
    formatted = maybe_group(formatted, spec.grouping)
    formatted = apply_sign(formatted, spec.sign, val)
    apply_alignment(formatted, spec, val)
  end

  defp format_default(val, spec) when is_binary(val) do
    format_string(val, spec)
  end

  defp format_default(val, spec) do
    format_string(Helpers.py_str(val), spec)
  end

  defp format_default_float(f) do
    # Match CPython: Python uses `repr(float)` which is decimal for
    # magnitudes in [1e-4, 1e16) and scientific otherwise.
    Helpers.py_float_str(f)
  end

  # Apply comma/underscore grouping to the integer part of a number string
  defp maybe_group(str, nil), do: str

  defp maybe_group(str, sep) do
    {neg, str} =
      case str do
        "-" <> rest -> {"-", rest}
        _ -> {"", str}
      end

    case String.split(str, ".") do
      [int_part] ->
        neg <> group_digits(int_part, sep)

      [int_part, dec_part] ->
        neg <> group_digits(int_part, sep) <> "." <> dec_part
    end
  end

  defp group_digits(str, sep) do
    str
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.map(&List.to_string/1)
    |> Enum.join(sep)
    |> String.reverse()
  end

  # Apply alignment and width
  defp apply_alignment(str, %{width: nil}, _val), do: str

  @max_format_width 10_000_000

  defp apply_alignment(str, %{width: width} = spec, val) when width > @max_format_width do
    apply_alignment(str, %{spec | width: @max_format_width}, val)
  end

  defp apply_alignment(str, spec, val) do
    width = spec.width
    len = String.length(str)

    if len >= width do
      str
    else
      padding = width - len
      fill = spec.fill || " "

      case spec.align || default_align(val) do
        "<" ->
          str <> String.duplicate(fill, padding)

        ">" ->
          String.duplicate(fill, padding) <> str

        "^" ->
          left = div(padding, 2)
          right = padding - left
          String.duplicate(fill, left) <> str <> String.duplicate(fill, right)

        "=" ->
          # Pad after sign
          case str do
            <<sign, rest::binary>> when sign in [?+, ?-, ?\s] ->
              <<sign>> <> String.duplicate(fill, padding) <> rest

            _ ->
              String.duplicate(fill, padding) <> str
          end
      end
    end
  end

  @spec format_decimal_fixed(Decimal.t(), non_neg_integer()) :: String.t()
  defp format_decimal_fixed(d, precision) do
    d
    |> Decimal.round(precision, :half_even)
    |> Decimal.to_string(:normal)
    |> ensure_decimal_places(precision)
  end

  @spec format_float_rounded(float(), non_neg_integer()) :: String.t()
  defp format_float_rounded(float_val, precision) do
    # Use Decimal for banker's rounding (round-half-to-even), which matches
    # Python's behaviour.  Fall back to Erlang for values Decimal can't handle.
    case Decimal.parse(:erlang.float_to_binary(float_val, [])) do
      {d, ""} ->
        d
        |> Decimal.round(precision, :half_even)
        |> Decimal.to_string(:normal)
        |> ensure_decimal_places(precision)

      _ ->
        :erlang.float_to_binary(float_val, decimals: precision)
    end
  end

  @spec apply_sign(String.t(), String.t() | nil, number()) :: String.t()
  defp apply_sign(formatted, nil, _val), do: formatted
  defp apply_sign(formatted, "-", _val), do: formatted

  defp apply_sign(formatted, "+", val) when val >= 0 do
    if String.starts_with?(formatted, "-"), do: formatted, else: "+" <> formatted
  end

  defp apply_sign(formatted, " ", val) when val >= 0 do
    if String.starts_with?(formatted, "-"), do: formatted, else: " " <> formatted
  end

  defp apply_sign(formatted, _sign, _val), do: formatted

  # Python defaults: numbers right-align, strings left-align.
  defp default_align(val) when is_integer(val) or is_float(val), do: ">"
  defp default_align({:pyex_decimal, _}), do: ">"
  defp default_align(_), do: "<"
end
