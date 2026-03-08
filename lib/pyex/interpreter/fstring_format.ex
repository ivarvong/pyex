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
    formatted = :erlang.float_to_binary(float_val, decimals: precision)
    formatted = maybe_group(formatted, spec.grouping)
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
    float_val = val / 1
    formatted = :io_lib.format(~c"~.#{precision}e", [float_val]) |> IO.iodata_to_binary()
    formatted = normalize_exponent(formatted)

    formatted =
      if e_char == "E", do: String.upcase(formatted), else: formatted

    apply_alignment(formatted, spec, val)
  end

  defp format_scientific(val, _spec, _e_char) do
    {:exception,
     "ValueError: Unknown format code 'e' for object of type '#{Helpers.py_type(val)}'"}
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
    formatted = :erlang.float_to_binary(float_val, decimals: precision) <> "%"
    apply_alignment(formatted, spec, val)
  end

  defp format_percentage(val, _spec) do
    {:exception,
     "ValueError: Unknown format code '%' for object of type '#{Helpers.py_type(val)}'"}
  end

  defp format_default(val, spec) when is_integer(val) do
    formatted = Integer.to_string(val)
    formatted = maybe_group(formatted, spec.grouping)
    apply_alignment(formatted, spec, val)
  end

  defp format_default(val, spec) when is_float(val) do
    # Python default float formatting
    formatted = format_default_float(val)
    formatted = maybe_group(formatted, spec.grouping)
    apply_alignment(formatted, spec, val)
  end

  defp format_default(val, spec) when is_binary(val) do
    format_string(val, spec)
  end

  defp format_default(val, spec) do
    format_string(Helpers.py_str(val), spec)
  end

  defp format_default_float(f) do
    # Python uses repr-style float formatting by default
    s = Float.to_string(f)
    # Erlang Float.to_string may add extra precision;
    # just use it as is since it generally matches Python well enough
    s
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
    |> Decimal.round(precision)
    |> Decimal.to_string()
  end

  # Python defaults: numbers right-align, strings left-align.
  defp default_align(val) when is_integer(val) or is_float(val), do: ">"
  defp default_align({:pyex_decimal, _}), do: ">"
  defp default_align(_), do: "<"

  defp normalize_exponent(str) do
    Regex.replace(~r/e([+-])(\d)$/, str, "e\\g{1}0\\2")
  end
end
