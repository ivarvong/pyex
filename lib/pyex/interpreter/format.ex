defmodule Pyex.Interpreter.Format do
  @moduledoc """
  Python `%`-style string formatting.

  Handles format specifiers like `%s`, `%d`, `%f`, `%x`, `%o`,
  `%e`, `%E`, `%g`, `%G`, and `%r` with flags, width, and
  precision support.
  """

  alias Pyex.Interpreter.Helpers

  @typep format_spec :: %{
           flags: String.t(),
           width: non_neg_integer() | nil,
           precision: non_neg_integer() | nil
         }

  @doc """
  Formats a string using Python `%` operator semantics.

  Returns the formatted string or `{:exception, message}` on error.
  """
  @spec string_format(String.t(), Pyex.Interpreter.pyvalue()) ::
          String.t() | {:exception, String.t()}
  def string_format(template, args) do
    arg_list =
      case args do
        {:tuple, items} -> items
        other -> [other]
      end

    string_format_loop(template, arg_list, <<>>)
  end

  @spec string_format_loop(String.t(), [Pyex.Interpreter.pyvalue()], binary()) ::
          String.t() | {:exception, String.t()}
  defp string_format_loop(<<>>, _args, acc), do: acc

  defp string_format_loop(<<?%, ?%, rest::binary>>, args, acc) do
    string_format_loop(rest, args, <<acc::binary, ?%>>)
  end

  defp string_format_loop(<<?%, rest::binary>>, args, acc) do
    case parse_format_spec(rest) do
      {:ok, spec, code, rest} ->
        case args do
          [val | remaining] ->
            case apply_format_spec(spec, code, val) do
              {:exception, _} = exc -> exc
              formatted -> string_format_loop(rest, remaining, <<acc::binary, formatted::binary>>)
            end

          [] ->
            {:exception, "TypeError: not enough arguments for format string"}
        end

      {:error, msg} ->
        {:exception, msg}
    end
  end

  defp string_format_loop(<<ch::utf8, rest::binary>>, args, acc) do
    string_format_loop(rest, args, <<acc::binary, ch::utf8>>)
  end

  @spec parse_format_spec(String.t()) ::
          {:ok, format_spec(), char(), String.t()} | {:error, String.t()}
  defp parse_format_spec(input) do
    {flags, input} = consume_flags(input, <<>>)
    {width, input} = consume_digits(input)
    {precision, input} = consume_precision(input)

    case input do
      <<code, rest::binary>> when code in ~c[sdfrxoieEgG] ->
        {:ok, %{flags: flags, width: width, precision: precision}, code, rest}

      _ ->
        {:error, "ValueError: incomplete format"}
    end
  end

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

  @spec consume_precision(String.t()) :: {non_neg_integer() | nil, String.t()}
  defp consume_precision(<<?., rest::binary>>) do
    {digits, rest} = consume_digits(rest)
    {digits || 6, rest}
  end

  defp consume_precision(rest), do: {nil, rest}

  @spec apply_format_spec(format_spec(), char(), Pyex.Interpreter.pyvalue()) ::
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
    formatted = :erlang.float_to_binary(val / 1, decimals: precision)
    pad_string(formatted, spec)
  end

  defp apply_format_spec(spec, code, val) when code in ~c[eE] and is_number(val) do
    precision = spec.precision || 6
    float_val = val / 1
    formatted = :io_lib.format(~c"~.#{precision}e", [float_val]) |> IO.iodata_to_binary()
    formatted = normalize_exponent(formatted)

    formatted =
      if code == ?E, do: String.upcase(formatted), else: formatted

    pad_string(formatted, spec)
  end

  defp apply_format_spec(spec, code, val) when code in ~c[gG] and is_number(val) do
    precision = max(spec.precision || 6, 1)
    float_val = val / 1
    formatted = :io_lib.format(~c"~.#{precision}g", [float_val]) |> IO.iodata_to_binary()

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

  @spec normalize_exponent(String.t()) :: String.t()
  defp normalize_exponent(str) do
    Regex.replace(~r/e([+-])(\d)$/, str, "e\\g{1}0\\2")
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
