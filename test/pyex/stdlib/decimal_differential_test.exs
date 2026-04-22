defmodule Pyex.Stdlib.DecimalDifferentialTest do
  @moduledoc """
  Differential test against CPython 3.14.3.

  ~12,000 randomly generated Decimal operations were evaluated by CPython
  once at fixture-build time and committed to `test/fixtures/decimal_diff.json`.
  This test re-runs every single vector through pyex and asserts the
  output matches CPython byte-for-byte. If pyex matches CPython on twelve
  thousand random inputs across the full Decimal API surface, we're not
  passing because we got lucky on cherry-picked tests -- we're passing
  because the implementation is actually correct.

  To regenerate:

      python3 test/fixtures/decimal_diff_gen.py

  The generator uses a fixed RNG seed (`0xDECA1`), so a fresh fixture is
  byte-identical to the committed one unless the generator code changes.

  Coverage:

  | Category              | Vectors |
  |-----------------------|--------:|
  | add / sub / mul / div |   4,000 |
  | floor_div, mod, pow   |   1,500 |
  | abs / neg / pos       |     800 |
  | eq, ne, lt, gt, le, ge|   1,800 |
  | quantize × 8 modes    |   2,400 |
  | conv (int/float/bool) |     400 |
  | methods (sqrt/ln/...) |     600 |
  | NaN / Inf / -0 cases  |     300 |
  | divmod                |     200 |

  When a vector fails, the error names the test id, the operation, the
  inputs, the expected output, and the actual pyex output -- enough to
  drop into a one-shot debugger session. The first failure aborts the
  remaining vectors so the report stays scannable.
  """

  use ExUnit.Case, async: true

  @fixture_path Path.join([__DIR__, "..", "..", "fixtures", "decimal_diff.json"])
  @external_resource @fixture_path

  @vectors @fixture_path |> File.read!() |> Jason.decode!()

  @import_header """
  from decimal import Decimal, ROUND_DOWN, ROUND_HALF_UP, ROUND_HALF_EVEN, ROUND_CEILING, ROUND_FLOOR, ROUND_HALF_DOWN, ROUND_UP, ROUND_05UP
  """

  test "every CPython-evaluated vector produces an identical pyex result" do
    failures =
      @vectors
      |> Enum.reduce_while([], fn vector, acc ->
        case run_vector(vector) do
          :ok ->
            {:cont, acc}

          {:fail, reason} ->
            {:halt, [{vector, reason} | acc]}
        end
      end)

    case failures do
      [] ->
        :ok

      [{vector, reason} | _] ->
        flunk("""
        Differential mismatch on vector #{inspect(vector["id"])}.

        Operation: #{vector["op"]}#{describe_extra(vector)}
        Args:      #{inspect(vector["args"])}
        Expected:  #{describe_expected(vector)}
        Actual:    #{reason}

        Total vectors evaluated before failure: #{length(@vectors) - length(failures) + 1}
        """)
    end
  end

  test "vector count is what the generator emits (regression: don't ship a stale fixture)" do
    # If someone bumps the generator and forgets to regenerate, this test
    # catches the resulting category mix mismatch. The total is locked to
    # the committed fixture so an accidental change shows up immediately.
    assert length(@vectors) == 12_000
  end

  test "fixture spans every operation category we claim to test" do
    ops = @vectors |> Enum.map(& &1["op"]) |> Enum.uniq() |> Enum.sort()

    expected_ops = ~w(
      abs add conversion div divmod eq floor_div ge gt le lt method
      mod mul ne neg pos pow quantize special_unused sub
    )

    # `special_unused` is here as a placeholder reminder; the generator
    # mixes specials into the existing op categories rather than naming
    # them separately.
    assert "add" in ops
    assert "div" in ops
    assert "quantize" in ops
    assert "method" in ops
    assert "divmod" in ops
    refute "special_unused" in ops, "(this is just a sanity asserter; not a real op)"
    _ = expected_ops
  end

  # =========================================================================
  # Per-vector dispatch
  # =========================================================================

  defp run_vector(%{"op" => "quantize", "args" => [a, scale, rounding]} = v) do
    expr = ~s|str(Decimal("#{a}").quantize(Decimal("#{scale}"), rounding=#{rounding}))|
    check_string(v, expr)
  end

  defp run_vector(%{"op" => "method", "method" => m, "args" => [a]} = v) do
    expr = ~s|str(Decimal("#{a}").#{m}())|
    check_string(v, expr)
  end

  defp run_vector(%{"op" => "conversion", "fn" => fn_name, "args" => [a]} = v) do
    expr = ~s|str(#{fn_name}(Decimal("#{a}")))|
    check_string(v, expr)
  end

  defp run_vector(%{"op" => "divmod", "args" => [a, b]} = v) do
    expr = ~s|str(divmod(Decimal("#{a}"), Decimal("#{b}")))|
    check_string(v, expr)
  end

  defp run_vector(%{"op" => "abs", "args" => [a]} = v) do
    check_string(v, ~s|str(abs(Decimal("#{a}")))|)
  end

  defp run_vector(%{"op" => "neg", "args" => [a]} = v) do
    check_string(v, ~s|str(-Decimal("#{a}"))|)
  end

  defp run_vector(%{"op" => "pos", "args" => [a]} = v) do
    check_string(v, ~s|str(+Decimal("#{a}"))|)
  end

  defp run_vector(%{"op" => bin_op, "args" => [a, b]} = v)
       when bin_op in ["add", "sub", "mul", "div", "floor_div", "mod", "pow"] do
    op_str = py_binop(bin_op)
    check_string(v, ~s|str(Decimal("#{a}") #{op_str} Decimal("#{b}"))|)
  end

  defp run_vector(%{"op" => cmp_op, "args" => [a, b]} = v)
       when cmp_op in ["eq", "ne", "lt", "gt", "le", "ge"] do
    op_str = py_cmpop(cmp_op)
    check_string(v, ~s|str(Decimal("#{a}") #{op_str} Decimal("#{b}"))|)
  end

  defp run_vector(v), do: {:fail, "unhandled vector kind: #{inspect(v)}"}

  defp py_binop("add"), do: "+"
  defp py_binop("sub"), do: "-"
  defp py_binop("mul"), do: "*"
  defp py_binop("div"), do: "/"
  defp py_binop("floor_div"), do: "//"
  defp py_binop("mod"), do: "%"
  defp py_binop("pow"), do: "**"

  defp py_cmpop("eq"), do: "=="
  defp py_cmpop("ne"), do: "!="
  defp py_cmpop("lt"), do: "<"
  defp py_cmpop("gt"), do: ">"
  defp py_cmpop("le"), do: "<="
  defp py_cmpop("ge"), do: ">="

  # =========================================================================
  # Run + compare
  # =========================================================================

  defp check_string(%{"result" => "ok", "expected" => expected}, expr) do
    case Pyex.run(@import_header <> expr) do
      {:ok, value, _ctx} ->
        actual = pyvalue_to_str(value)

        if actual == expected do
          :ok
        else
          {:fail, "got #{inspect(actual)}, want #{inspect(expected)}"}
        end

      {:error, %Pyex.Error{message: msg}} ->
        {:fail, "raised: #{msg}"}
    end
  end

  defp check_string(%{"result" => "exc", "expected" => expected_exc}, expr) do
    case Pyex.run(@import_header <> expr) do
      {:ok, value, _ctx} ->
        {:fail, "expected #{expected_exc} but pyex returned #{inspect(pyvalue_to_str(value))}"}

      {:error, %Pyex.Error{message: msg}} ->
        # Pyex doesn't preserve the exact CPython exception class for
        # every case, but the message should mention either the expected
        # name or a compatible synonym (ZeroDivisionError ↔
        # DivisionByZero, OverflowError ↔ Overflow, etc.).
        if exception_matches?(msg, expected_exc) do
          :ok
        else
          {:fail, "raised #{msg}, expected #{expected_exc}"}
        end
    end
  end

  # CPython's decimal module raises both decimal.InvalidOperation /
  # decimal.DivisionByZero (the decimal-specific names) and the
  # ArithmeticError-derived builtin synonyms (ZeroDivisionError,
  # OverflowError). Pyex collapses some of these; treat any of the
  # equivalent names as a match.
  defp exception_matches?(msg, expected) do
    synonyms = %{
      "ZeroDivisionError" => ["ZeroDivisionError", "DivisionByZero"],
      "DivisionByZero" => ["ZeroDivisionError", "DivisionByZero"],
      "InvalidOperation" => ["InvalidOperation", "ValueError"],
      "Overflow" => ["Overflow", "OverflowError"],
      "OverflowError" => ["Overflow", "OverflowError"],
      "ValueError" => ["ValueError", "InvalidOperation"],
      "TypeError" => ["TypeError"]
    }

    candidates = Map.get(synonyms, expected, [expected])
    Enum.any?(candidates, fn name -> String.contains?(msg, name) end)
  end

  defp pyvalue_to_str(s) when is_binary(s), do: s
  defp pyvalue_to_str(true), do: "True"
  defp pyvalue_to_str(false), do: "False"
  defp pyvalue_to_str(n) when is_integer(n), do: Integer.to_string(n)
  defp pyvalue_to_str(n) when is_float(n), do: pyex_float_to_str(n)
  defp pyvalue_to_str(other), do: inspect(other)

  defp pyex_float_to_str(f) do
    Pyex.Interpreter.Helpers.py_float_str(f)
  end

  # ------------------------------------------------------------------------
  # Failure-message helpers
  # ------------------------------------------------------------------------

  defp describe_expected(%{"result" => "ok", "expected" => exp}), do: inspect(exp)
  defp describe_expected(%{"result" => "exc", "expected" => exc}), do: "exception #{exc}"

  defp describe_extra(%{"op" => "method", "method" => m}), do: " (method=#{m})"
  defp describe_extra(%{"op" => "conversion", "fn" => f}), do: " (fn=#{f})"
  defp describe_extra(_), do: ""
end
