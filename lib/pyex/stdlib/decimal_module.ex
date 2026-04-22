defmodule Pyex.Stdlib.DecimalModule do
  @moduledoc """
  Python `decimal` module: arbitrary-precision decimal arithmetic with
  configurable precision and rounding.

  Wraps the Elixir `Decimal` library; values are tagged
  `{:pyex_decimal, %Decimal{}}`. The default context matches CPython
  (precision 28, `ROUND_HALF_EVEN`) and is installed for every
  `Pyex.run/2` invocation.

  ## What is supported

    * Constructors: `Decimal(int)`, `Decimal(str)`, `Decimal(Decimal)`,
      `Decimal(float)` (exact float repr per CPython), `Decimal(tuple)`
      (sign, digits, exponent).
    * All arithmetic operators: `+`, `-`, `*`, `/`, `//`, `%`, `**`,
      unary `+`, unary `-`, `abs()`.
    * All comparison operators against `Decimal`, `int`, `bool`.
    * Methods: `quantize`, `as_tuple`, `is_finite`, `is_zero`,
      `is_signed`, `is_nan`, `is_infinite`, `is_qnan`, `is_snan`,
      `is_normal`, `is_subnormal`, `copy_abs`, `copy_negate`,
      `copy_sign`, `sqrt`, `ln`, `log10`, `exp`, `to_integral_value`,
      `to_integral_exact`, `normalize`, `adjusted`, `compare`, `max`,
      `min`, `same_quantum`, `number_class`, `conjugate`,
      `__abs__`, `__neg__`, `__pos__`.
    * Functions: `getcontext`, `setcontext`, `localcontext`.
    * Constants: `MAX_PREC`, `MAX_EMAX`, `MIN_EMIN`, `MIN_ETINY`,
      `HAVE_THREADS`, `HAVE_CONTEXTVAR`.
    * Rounding constants: `ROUND_DOWN`, `ROUND_HALF_UP`,
      `ROUND_HALF_EVEN`, `ROUND_CEILING`, `ROUND_FLOOR`,
      `ROUND_HALF_DOWN`, `ROUND_UP`, `ROUND_05UP`.
    * Exception classes: `DecimalException`, `Clamped`,
      `InvalidOperation`, `ConversionSyntax`, `DivisionByZero`,
      `DivisionImpossible`, `DivisionUndefined`, `Inexact`,
      `InvalidContext`, `Rounded`, `Subnormal`, `Overflow`,
      `Underflow`, `FloatOperation`.

  ## Context limitations

  Mutating attributes on the object returned by `getcontext()` does not
  retroactively affect already-computed values. To change the active
  context you must call `setcontext(ctx)` after mutation, or use
  `localcontext()` as a `with` block. This matches CPython's API for
  `setcontext`/`localcontext` but differs slightly from CPython's
  `getcontext().prec = N` style: in pyex you must follow the assignment
  with `setcontext(ctx)`.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Interpreter

  @rounding_to_atom %{
    "ROUND_DOWN" => :down,
    "ROUND_HALF_UP" => :half_up,
    "ROUND_HALF_EVEN" => :half_even,
    "ROUND_CEILING" => :ceiling,
    "ROUND_FLOOR" => :floor,
    "ROUND_HALF_DOWN" => :half_down,
    "ROUND_UP" => :up,
    # Elixir Decimal does not natively support ROUND_05UP ("round zero or
    # five away from zero"), so we pass a sentinel atom that quantize/
    # round call sites recognise and implement in user code.
    "ROUND_05UP" => :round_05up
  }

  @rounding_atom_to_string %{
    :down => "ROUND_DOWN",
    :half_up => "ROUND_HALF_UP",
    :half_even => "ROUND_HALF_EVEN",
    :ceiling => "ROUND_CEILING",
    :floor => "ROUND_FLOOR",
    :half_down => "ROUND_HALF_DOWN",
    :up => "ROUND_UP"
  }

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "Decimal" => {:builtin, &decimal_new/1},
      "getcontext" => {:builtin, &getcontext/1},
      "setcontext" => {:builtin, &setcontext/1},
      "localcontext" => {:builtin_kw, &localcontext/2},
      "Context" => context_class(),
      "BasicContext" => basic_context_instance(),
      "ExtendedContext" => extended_context_instance(),
      "DefaultContext" => default_context_instance(),
      "ROUND_DOWN" => "ROUND_DOWN",
      "ROUND_HALF_UP" => "ROUND_HALF_UP",
      "ROUND_HALF_EVEN" => "ROUND_HALF_EVEN",
      "ROUND_CEILING" => "ROUND_CEILING",
      "ROUND_FLOOR" => "ROUND_FLOOR",
      "ROUND_HALF_DOWN" => "ROUND_HALF_DOWN",
      "ROUND_UP" => "ROUND_UP",
      "ROUND_05UP" => "ROUND_05UP",
      "MAX_PREC" => 999_999_999_999_999_999,
      "MAX_EMAX" => 999_999_999_999_999_999,
      "MIN_EMIN" => -999_999_999_999_999_999,
      "MIN_ETINY" => -1_999_999_999_999_999_998,
      "HAVE_THREADS" => true,
      "HAVE_CONTEXTVAR" => true,
      "DecimalException" => {:exception_class, "DecimalException"},
      "Clamped" => {:exception_class, "Clamped"},
      "InvalidOperation" => {:exception_class, "InvalidOperation"},
      "ConversionSyntax" => {:exception_class, "ConversionSyntax"},
      "DivisionByZero" => {:exception_class, "DivisionByZero"},
      "DivisionImpossible" => {:exception_class, "DivisionImpossible"},
      "DivisionUndefined" => {:exception_class, "DivisionUndefined"},
      "Inexact" => {:exception_class, "Inexact"},
      "InvalidContext" => {:exception_class, "InvalidContext"},
      "Rounded" => {:exception_class, "Rounded"},
      "Subnormal" => {:exception_class, "Subnormal"},
      "Overflow" => {:exception_class, "Overflow"},
      "Underflow" => {:exception_class, "Underflow"},
      "FloatOperation" => {:exception_class, "FloatOperation"}
    }
  end

  # -------------------------------------------------------------------
  # Internal helpers used by binary_ops, methods, etc.
  # -------------------------------------------------------------------

  @doc """
  Maps a CPython rounding-mode string (`"ROUND_HALF_EVEN"`, etc.) to the
  Elixir `Decimal` rounding atom. Returns `nil` for unknown modes.
  """
  @spec rounding_to_atom(String.t()) :: Decimal.rounding() | nil
  def rounding_to_atom(name) when is_binary(name), do: Map.get(@rounding_to_atom, name)
  def rounding_to_atom(_), do: nil

  @doc """
  Inverse of `rounding_to_atom/1`: converts a `Decimal` rounding atom
  back to its CPython string form for display in `Context.rounding`.
  """
  @spec atom_to_rounding(Decimal.rounding()) :: String.t()
  def atom_to_rounding(atom), do: Map.get(@rounding_atom_to_string, atom, "ROUND_HALF_EVEN")

  # -------------------------------------------------------------------
  # Decimal constructor
  # -------------------------------------------------------------------

  @spec decimal_new([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp decimal_new([]), do: {:pyex_decimal, Decimal.new(0)}

  defp decimal_new([val]) when is_binary(val) do
    case parse_decimal_string(val) do
      {:ok, decimal} -> {:pyex_decimal, decimal}
      {:error, msg} -> {:exception, msg}
    end
  end

  defp decimal_new([val]) when is_integer(val), do: {:pyex_decimal, Decimal.new(val)}

  defp decimal_new([true]), do: {:pyex_decimal, Decimal.new(1)}
  defp decimal_new([false]), do: {:pyex_decimal, Decimal.new(0)}

  defp decimal_new([{:pyex_decimal, _} = d]), do: d

  defp decimal_new([val]) when is_float(val) do
    cond do
      val != val -> {:pyex_decimal, %Decimal{sign: 1, coef: :NaN, exp: 0}}
      true -> {:pyex_decimal, Decimal.from_float(val)}
    end
  end

  defp decimal_new([:infinity]), do: {:pyex_decimal, %Decimal{sign: 1, coef: :inf, exp: 0}}

  defp decimal_new([:neg_infinity]),
    do: {:pyex_decimal, %Decimal{sign: -1, coef: :inf, exp: 0}}

  defp decimal_new([:nan]), do: {:pyex_decimal, %Decimal{sign: 1, coef: :NaN, exp: 0}}

  # Decimal((sign, (digits...), exponent)) — CPython tuple form.
  defp decimal_new([{:tuple, [sign, {:tuple, digits}, exp]}])
       when sign in [0, 1] and is_integer(exp) and is_list(digits) do
    case build_from_tuple(sign, digits, exp) do
      {:ok, d} -> {:pyex_decimal, d}
      {:error, msg} -> {:exception, msg}
    end
  end

  defp decimal_new([{:tuple, [sign, {:py_list, reversed, _}, exp]}])
       when sign in [0, 1] and is_integer(exp) do
    decimal_new([{:tuple, [sign, {:tuple, Enum.reverse(reversed)}, exp]}])
  end

  defp decimal_new([val]) do
    {:exception,
     "TypeError: conversion from #{Pyex.Interpreter.Helpers.py_type(val)} to Decimal is not supported"}
  end

  defp decimal_new(args) when length(args) > 1 do
    {:exception, "TypeError: Decimal() takes at most 2 arguments (#{length(args)} given)"}
  end

  @spec parse_decimal_string(String.t()) :: {:ok, Decimal.t()} | {:error, String.t()}
  defp parse_decimal_string(val) do
    trimmed = String.trim(val)
    # CPython 3.6+ accepts digit-group underscores ("1_000_000") in numeric
    # literals. They must appear between digits, never adjacent to a sign,
    # decimal point, or exponent marker. We validate then strip.
    cond do
      trimmed == "" ->
        {:error, "InvalidOperation: invalid literal for Decimal: '#{val}'"}

      true ->
        # Strip a NaN diagnostic payload ("NaN42", "-sNaN001") -- pyex's
        # underlying Decimal lib does not retain the payload, but the
        # value "NaN" round-trips through arithmetic just like CPython's.
        normalised = strip_nan_payload(trimmed)

        case strip_digit_underscores(normalised) do
          {:ok, cleaned} ->
            try do
              {:ok, Decimal.new(cleaned)}
            rescue
              Decimal.Error ->
                {:error, "InvalidOperation: invalid literal for Decimal: '#{val}'"}
            end

          :error ->
            {:error, "InvalidOperation: invalid literal for Decimal: '#{val}'"}
        end
    end
  end

  defp strip_nan_payload(val) do
    case Regex.run(~r/^([+-]?)(s?nan)(\d+)$/i, val) do
      [_, sign, nan, _payload] -> sign <> nan
      _ -> val
    end
  end

  defp strip_digit_underscores(s) do
    if String.contains?(s, "_") do
      # An underscore is valid only when it sits between two digits.
      chars = String.graphemes(s)

      if valid_underscore_positions?(chars) do
        {:ok, chars |> Enum.reject(&(&1 == "_")) |> Enum.join()}
      else
        :error
      end
    else
      {:ok, s}
    end
  end

  defp valid_underscore_positions?(chars) do
    chars
    |> Enum.with_index()
    |> Enum.all?(fn
      {"_", 0} ->
        false

      {"_", i} ->
        i + 1 < length(chars) and digit?(Enum.at(chars, i - 1)) and digit?(Enum.at(chars, i + 1))

      _ ->
        true
    end)
  end

  defp digit?(c) when is_binary(c), do: c in ~w(0 1 2 3 4 5 6 7 8 9)
  defp digit?(_), do: false

  defp build_from_tuple(sign, digits, exp) do
    cond do
      not Enum.all?(digits, fn d -> is_integer(d) and d >= 0 and d <= 9 end) ->
        {:error, "ValueError: digits must be integers in 0..9"}

      digits == [] ->
        {:ok, %Decimal{sign: if(sign == 0, do: 1, else: -1), coef: 0, exp: exp}}

      true ->
        coef = Enum.reduce(digits, 0, fn d, acc -> acc * 10 + d end)
        {:ok, %Decimal{sign: if(sign == 0, do: 1, else: -1), coef: coef, exp: exp}}
    end
  end

  # -------------------------------------------------------------------
  # Context support
  # -------------------------------------------------------------------

  @context_class_attrs %{
    "__class_name__" => "Context"
  }

  defp context_class do
    {:class, "Context", [], @context_class_attrs}
  end

  @spec getcontext([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp getcontext([]) do
    snapshot_to_instance(Decimal.Context.get())
  end

  defp getcontext(args) do
    {:exception, "TypeError: getcontext() takes no arguments (#{length(args)} given)"}
  end

  @spec setcontext([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp setcontext([{:instance, {:class, "Context", _, _}, attrs}]) do
    case instance_to_decimal_context(attrs) do
      {:ok, ctx} ->
        Decimal.Context.set(ctx)
        nil

      {:error, msg} ->
        {:exception, msg}
    end
  end

  defp setcontext([_other]) do
    {:exception, "TypeError: setcontext() requires a Context instance"}
  end

  defp setcontext(args) do
    {:exception, "TypeError: setcontext() takes exactly 1 argument (#{length(args)} given)"}
  end

  @spec localcontext([Interpreter.pyvalue()], map()) :: Interpreter.pyvalue()
  defp localcontext(args, _kwargs) do
    base =
      case args do
        [] ->
          Decimal.Context.get()

        [{:instance, {:class, "Context", _, _}, attrs}] ->
          case instance_to_decimal_context(attrs) do
            {:ok, ctx} -> ctx
            {:error, _} -> Decimal.Context.get()
          end

        _ ->
          Decimal.Context.get()
      end

    saved = Decimal.Context.get()
    instance = snapshot_to_instance(base)

    {:instance, localcontext_class(),
     %{
       "__base__" => instance,
       "__saved__" => context_to_attrs(saved)
     }}
  end

  defp localcontext_class do
    methods = %{
      "__enter__" => {:builtin, &localcontext_enter/1},
      "__exit__" => {:builtin, &localcontext_exit/1}
    }

    {:class, "LocalContext", [], methods}
  end

  defp localcontext_enter([{:instance, _, %{"__base__" => base}}]) do
    {:instance, {:class, "Context", _, _}, attrs} = base

    case instance_to_decimal_context(attrs) do
      {:ok, ctx} -> Decimal.Context.set(ctx)
      _ -> :ok
    end

    base
  end

  defp localcontext_enter(_), do: nil

  defp localcontext_exit([{:instance, _, %{"__saved__" => saved_attrs}} | _rest]) do
    case attrs_to_decimal_context(saved_attrs) do
      {:ok, ctx} -> Decimal.Context.set(ctx)
      _ -> :ok
    end

    false
  end

  defp localcontext_exit(_), do: false

  defp snapshot_to_instance(%Decimal.Context{precision: prec, rounding: rounding}) do
    {:instance, context_class(),
     %{
       "prec" => prec,
       "rounding" => atom_to_rounding(rounding),
       "Emin" => -999_999,
       "Emax" => 999_999,
       "capitals" => 1,
       "clamp" => 0,
       "flags" => empty_signal_dict(),
       "traps" => default_traps()
     }}
  end

  defp empty_signal_dict do
    keys = [
      "Clamped",
      "InvalidOperation",
      "DivisionByZero",
      "Inexact",
      "Rounded",
      "Subnormal",
      "Overflow",
      "Underflow",
      "FloatOperation"
    ]

    map = keys |> Enum.into(%{}, fn k -> {k, false} end)
    {:py_dict, map, %{}}
  end

  defp default_traps do
    map = %{
      "Clamped" => false,
      "InvalidOperation" => true,
      "DivisionByZero" => true,
      "Inexact" => false,
      "Rounded" => false,
      "Subnormal" => false,
      "Overflow" => true,
      "Underflow" => false,
      "FloatOperation" => false
    }

    {:py_dict, map, %{}}
  end

  defp instance_to_decimal_context(attrs) do
    prec = Map.get(attrs, "prec", 28)
    rounding_str = Map.get(attrs, "rounding", "ROUND_HALF_EVEN")

    cond do
      not is_integer(prec) or prec < 1 ->
        {:error, "ValueError: prec must be a positive integer"}

      not is_binary(rounding_str) or rounding_to_atom(rounding_str) == nil ->
        {:error, "TypeError: invalid rounding mode '#{inspect(rounding_str)}'"}

      true ->
        {:ok,
         %Decimal.Context{
           precision: prec,
           rounding: rounding_to_atom(rounding_str)
         }}
    end
  end

  defp attrs_to_decimal_context(attrs) do
    instance_to_decimal_context(attrs)
  end

  defp context_to_attrs(%Decimal.Context{precision: prec, rounding: rounding}) do
    %{"prec" => prec, "rounding" => atom_to_rounding(rounding)}
  end

  defp basic_context_instance do
    {:instance, context_class(),
     %{
       "prec" => 9,
       "rounding" => "ROUND_HALF_UP",
       "Emin" => -999_999,
       "Emax" => 999_999,
       "capitals" => 1,
       "clamp" => 0,
       "flags" => empty_signal_dict(),
       "traps" => default_traps()
     }}
  end

  defp extended_context_instance do
    {:instance, context_class(),
     %{
       "prec" => 9,
       "rounding" => "ROUND_HALF_EVEN",
       "Emin" => -999_999,
       "Emax" => 999_999,
       "capitals" => 1,
       "clamp" => 0,
       "flags" => empty_signal_dict(),
       "traps" => empty_signal_dict()
     }}
  end

  defp default_context_instance do
    {:instance, context_class(),
     %{
       "prec" => 28,
       "rounding" => "ROUND_HALF_EVEN",
       "Emin" => -999_999,
       "Emax" => 999_999,
       "capitals" => 1,
       "clamp" => 0,
       "flags" => empty_signal_dict(),
       "traps" => default_traps()
     }}
  end
end
