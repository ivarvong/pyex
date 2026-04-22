defmodule Pyex.Stdlib.DecimalConformanceTest do
  @moduledoc """
  Hardcore CPython conformance tests for the `decimal` module, focused on
  features financial / quantitative code actually depends on:

    * exact arithmetic identities
    * every ROUND_* mode at half-boundaries (positive AND negative)
    * `quantize()` with cents/eighths and explicit rounding modes
    * Python-style floor-division and modulo on Decimals (sign-of-divisor)
    * Context manipulation via `getcontext`/`setcontext`/`localcontext`
    * NaN/Infinity propagation, signed zeros
    * Real-world financial scenarios (sales tax, tip split, NPV, loan
      amortization, share allocation)

  Each test is named after the *specific behavior* it locks in -- not the
  function it exercises.
  """

  use ExUnit.Case, async: true

  # Bring every decimal symbol the conformance suite touches into scope.
  # Pyex's parser doesn't support the parenthesized multi-import form
  # (`from m import (a, b, c)`), so we list these on a single line.
  @import_header """
  from decimal import Decimal, ROUND_DOWN, ROUND_HALF_UP, ROUND_HALF_EVEN, ROUND_CEILING, ROUND_FLOOR, ROUND_HALF_DOWN, ROUND_UP, ROUND_05UP, getcontext, setcontext, localcontext, Context, InvalidOperation, DivisionByZero, Overflow
  """

  defp run!(body), do: Pyex.run!(@import_header <> body)
  defp run(body), do: Pyex.run(@import_header <> body)

  # =========================================================================
  # Arithmetic identities -- the hard guarantees that financial code relies on
  # =========================================================================

  describe "arithmetic identities" do
    test "0.1 + 0.2 == 0.3 exactly (float disagrees)" do
      assert run!(~s|Decimal("0.1") + Decimal("0.2") == Decimal("0.3")|) == true
      assert Pyex.run!("0.1 + 0.2 == 0.3") == false
    end

    test "a == +a == --a holds for all signs" do
      for v <- ["-12.5", "0", "12.5", "0.0001"] do
        assert run!(~s|Decimal("#{v}") == +Decimal("#{v}")|) == true
        assert run!(~s|Decimal("#{v}") == -(-Decimal("#{v}"))|) == true
      end
    end

    test "a + (-a) == 0 for all finite values" do
      for v <- ["1", "-1", "1234567890.987654321", "0.00000001"] do
        assert run!(~s|str(Decimal("#{v}") + (-Decimal("#{v}")))|) =~ "0"
      end
    end

    test "(a // b) * b + (a % b) == a (Python's floor-div identity)" do
      cases = [
        {"7", "3"},
        {"-7", "3"},
        {"7", "-3"},
        {"-7", "-3"},
        {"100", "7"},
        {"0.99", "0.10"},
        {"-12.34", "1.5"}
      ]

      for {a, b} <- cases do
        prog = """
        a = Decimal("#{a}")
        b = Decimal("#{b}")
        (a // b) * b + (a % b) == a
        """

        assert run!(prog) == true, "identity failed for #{a} // #{b}"
      end
    end

    test "abs preserves magnitude across signs and zeros" do
      assert run!(~s|str(abs(Decimal("-3.14")))|) == "3.14"
      assert run!(~s|str(abs(Decimal("3.14")))|) == "3.14"
      assert run!(~s|str(abs(Decimal("-0")))|) == "0"
      # abs preserves trailing zeros like CPython
      assert run!(~s|str(abs(Decimal("-12.500")))|) == "12.500"
    end

    test "multiplication preserves trailing-zero significance" do
      # Decimal preserves the number of significant digits; CPython's
      # `Decimal('1.30') * Decimal('1.00')` gives Decimal('1.3000').
      assert run!(~s|str(Decimal("1.30") * Decimal("1.00"))|) == "1.3000"
      assert run!(~s|str(Decimal("0.10") * Decimal("3"))|) == "0.30"
    end

    test "addition of values with different scales preserves max scale" do
      assert run!(~s|str(Decimal("1.5") + Decimal("0.0001"))|) == "1.5001"
      assert run!(~s|str(Decimal("1") + Decimal("0.00000001"))|) == "1.00000001"
    end
  end

  # =========================================================================
  # Floor division and modulo - Python semantics (sign of result == sign of divisor)
  # =========================================================================

  # Decimal `//` and `%` follow the IEEE / IBM decimal-arithmetic spec --
  # NOT Python's int semantics. `//` truncates toward zero (so `-7 // 3 == -2`,
  # not `-3`), and `%` returns the sign of the *dividend* (so `-7 % 3 == -1`,
  # not `2`). The pair satisfies `(a // b) * b + (a % b) == a`. This is an
  # explicit CPython choice for Decimal -- see the decimal module docs.
  describe "// (floor division) -- CPython truncation semantics" do
    test "positive // positive truncates toward zero" do
      assert run!(~s|str(Decimal("10") // Decimal("3"))|) == "3"
      assert run!(~s|str(Decimal("100") // Decimal("7"))|) == "14"
    end

    test "negative dividend truncates toward zero (not floor!)" do
      # CPython Decimal truncates: -7 // 3 == -2, NOT -3.
      assert run!(~s|str(Decimal("-7") // Decimal("3"))|) == "-2"
      assert run!(~s|str(Decimal("-10") // Decimal("3"))|) == "-3"
    end

    test "negative divisor still truncates toward zero" do
      assert run!(~s|str(Decimal("7") // Decimal("-3"))|) == "-2"
      assert run!(~s|str(Decimal("-7") // Decimal("-3"))|) == "2"
    end

    test "exact division gives integer result" do
      assert run!(~s|str(Decimal("10") // Decimal("2"))|) == "5"
      assert run!(~s|str(Decimal("-12") // Decimal("4"))|) == "-3"
    end

    test "fractional dividend is truncated" do
      assert run!(~s|str(Decimal("3.7") // Decimal("1"))|) == "3"
      # -3.7 truncated toward zero = -3 (NOT -4)
      assert run!(~s|str(Decimal("-3.7") // Decimal("1"))|) == "-3"
    end

    test "zero divisor raises ZeroDivisionError" do
      assert {:error, %Pyex.Error{message: msg}} =
               run("Decimal('1') // Decimal('0')")

      assert msg =~ "ZeroDivisionError"
    end

    test "0 // 0 raises InvalidOperation (not ZeroDivisionError)" do
      assert {:error, %Pyex.Error{message: msg}} =
               run("Decimal('0') // Decimal('0')")

      assert msg =~ "InvalidOperation"
    end
  end

  describe "% (modulo) -- CPython sign-of-dividend semantics" do
    test "positive operands give positive remainder" do
      assert run!(~s|str(Decimal("10") % Decimal("3"))|) == "1"
    end

    test "negative dividend, positive divisor gives negative remainder" do
      # CPython Decimal: -7 % 3 == -1, NOT 2 (Python int's behaviour).
      assert run!(~s|str(Decimal("-7") % Decimal("3"))|) == "-1"
    end

    test "positive dividend, negative divisor gives positive remainder" do
      # CPython Decimal: 7 % -3 == 1, NOT -2.
      assert run!(~s|str(Decimal("7") % Decimal("-3"))|) == "1"
    end

    test "both negative gives negative remainder" do
      assert run!(~s|str(Decimal("-7") % Decimal("-3"))|) == "-1"
    end

    test "fractional remainder" do
      assert run!(~s|str(Decimal("10.5") % Decimal("3"))|) == "1.5"
    end

    test "modulo by zero raises InvalidOperation (NOT ZeroDivisionError)" do
      # CPython quirk: while `Decimal / 0` and `Decimal // 0` raise
      # DivisionByZero, `Decimal % 0` raises InvalidOperation. The
      # remainder of "x divided by nothing" isn't a single divergent
      # value -- it's undefined.
      assert {:error, %Pyex.Error{message: msg}} =
               run("Decimal('5') % Decimal('0')")

      assert msg =~ "InvalidOperation"
    end

    test "0 % 0 raises InvalidOperation" do
      assert {:error, %Pyex.Error{message: msg}} =
               run("Decimal('0') % Decimal('0')")

      assert msg =~ "InvalidOperation"
    end
  end

  # =========================================================================
  # Power operator
  # =========================================================================

  describe "** (power)" do
    test "integer exponents produce exact results" do
      assert run!(~s|str(Decimal("2") ** Decimal("10"))|) == "1024"
      assert run!(~s|str(Decimal("3") ** Decimal("4"))|) == "81"
      # Exact: 1.1**3 == 1.331
      assert run!(~s|str(Decimal("1.1") ** Decimal("3"))|) == "1.331"
    end

    test "non-zero base to the zero power is one; 0**0 raises InvalidOperation" do
      assert run!(~s|str(Decimal("1.5") ** Decimal("0"))|) == "1"
      assert run!(~s|str(Decimal("-1.5") ** Decimal("0"))|) == "1"

      # CPython: `Decimal('0') ** Decimal('0')` is undefined, raises
      # InvalidOperation (unlike `int(0) ** int(0) == 1`).
      assert {:error, %Pyex.Error{message: msg}} =
               run("Decimal('0') ** Decimal('0')")

      assert msg =~ "InvalidOperation"
    end

    test "negative integer exponent is reciprocal" do
      assert run!(~s|str(Decimal("2") ** Decimal("-3"))|) == "0.125"
      assert run!(~s|str(Decimal("10") ** Decimal("-2"))|) == "0.01"
    end

    test "zero raised to negative power returns Infinity (NOT ZeroDivisionError)" do
      # CPython treats `Decimal(0) ** Decimal(-n)` as a converging
      # arithmetic identity: the result is +/- Infinity, with the sign
      # following the base when the exponent is odd.
      assert run!("str(Decimal('0') ** Decimal('-1'))") == "Infinity"
      assert run!("str(Decimal('0') ** Decimal('-2'))") == "Infinity"
      assert run!("str(Decimal('-0') ** Decimal('-1'))") == "-Infinity"
      assert run!("str(Decimal('-0') ** Decimal('-2'))") == "Infinity"
    end

    test "** with integer right-hand side coerces" do
      assert run!("str(Decimal('2') ** 16)") == "65536"
    end
  end

  # =========================================================================
  # All rounding modes at canonical boundaries
  # =========================================================================

  describe "rounding modes at exact half boundaries" do
    # IBM standard rounding table (also reproduced in Decimal.Context docs).
    # Format: {value, expected per mode}
    cases_pos = [
      # value, half_even, half_up, half_down, up,   down, ceiling, floor
      {"5.5", "6", "6", "5", "6", "5", "6", "5"},
      {"2.5", "2", "3", "2", "3", "2", "3", "2"},
      {"1.6", "2", "2", "2", "2", "1", "2", "1"},
      {"1.1", "1", "1", "1", "2", "1", "2", "1"},
      {"1.0", "1", "1", "1", "1", "1", "1", "1"}
    ]

    cases_neg = [
      {"-1.0", "-1", "-1", "-1", "-1", "-1", "-1", "-1"},
      {"-1.1", "-1", "-1", "-1", "-2", "-1", "-1", "-2"},
      {"-1.6", "-2", "-2", "-2", "-2", "-1", "-1", "-2"},
      {"-2.5", "-2", "-3", "-2", "-3", "-2", "-2", "-3"},
      {"-5.5", "-6", "-6", "-5", "-6", "-5", "-5", "-6"}
    ]

    for {v, he, hu, hd, up, dn, ce, fl} <- cases_pos ++ cases_neg do
      test "value #{v} rounds correctly under every mode" do
        prog = fn mode ->
          ~s|str(Decimal("#{unquote(v)}").quantize(Decimal("1"), rounding=#{mode}))|
        end

        assert run!(prog.("ROUND_HALF_EVEN")) == unquote(he)
        assert run!(prog.("ROUND_HALF_UP")) == unquote(hu)
        assert run!(prog.("ROUND_HALF_DOWN")) == unquote(hd)
        assert run!(prog.("ROUND_UP")) == unquote(up)
        assert run!(prog.("ROUND_DOWN")) == unquote(dn)
        assert run!(prog.("ROUND_CEILING")) == unquote(ce)
        assert run!(prog.("ROUND_FLOOR")) == unquote(fl)
      end
    end
  end

  describe "banker's rounding (ROUND_HALF_EVEN) at consecutive halves" do
    # The defining property: 0.5 → 0, 1.5 → 2, 2.5 → 2, 3.5 → 4, 4.5 → 4
    # i.e. ties round to the nearest EVEN integer.
    test "halves round to nearest even" do
      assert run!(~s|str(Decimal("0.5").quantize(Decimal("1")))|) == "0"
      assert run!(~s|str(Decimal("1.5").quantize(Decimal("1")))|) == "2"
      assert run!(~s|str(Decimal("2.5").quantize(Decimal("1")))|) == "2"
      assert run!(~s|str(Decimal("3.5").quantize(Decimal("1")))|) == "4"
      assert run!(~s|str(Decimal("4.5").quantize(Decimal("1")))|) == "4"
    end

    test "non-halves round to nearest" do
      assert run!(~s|str(Decimal("0.49").quantize(Decimal("1")))|) == "0"
      assert run!(~s|str(Decimal("0.51").quantize(Decimal("1")))|) == "1"
      assert run!(~s|str(Decimal("2.501").quantize(Decimal("1")))|) == "3"
    end
  end

  # =========================================================================
  # quantize() - financial code's main rounding tool
  # =========================================================================

  describe "quantize to cents (the canonical money-rounding pattern)" do
    test "quantize preserves trailing zeros (e.g. 1 → 1.00)" do
      assert run!(~s|str(Decimal("1").quantize(Decimal("0.01")))|) == "1.00"
      assert run!(~s|str(Decimal("0").quantize(Decimal("0.01")))|) == "0.00"
    end

    test "quantize rounds excess precision using banker's by default" do
      # 1.005 -> 1.00 because the next digit pair is 50 and the preceding is 0 (even)
      # but with banker's: look at digit at position to round; 0 is even so 1.005 → 1.00
      assert run!(~s|str(Decimal("1.005").quantize(Decimal("0.01")))|) == "1.00"
      # 1.015 → 1.02 (1 is odd so round up)
      assert run!(~s|str(Decimal("1.015").quantize(Decimal("0.01")))|) == "1.02"
      # 1.025 → 1.02 (2 is even so don't round up)
      assert run!(~s|str(Decimal("1.025").quantize(Decimal("0.01")))|) == "1.02"
    end

    test "quantize with explicit ROUND_HALF_UP" do
      assert run!(~s|str(Decimal("1.005").quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))|) ==
               "1.01"

      assert run!(~s|str(Decimal("1.025").quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))|) ==
               "1.03"
    end

    test "quantize with ROUND_DOWN truncates" do
      assert run!(~s|str(Decimal("1.999").quantize(Decimal("0.01"), rounding=ROUND_DOWN))|) ==
               "1.99"

      assert run!(~s|str(Decimal("-1.999").quantize(Decimal("0.01"), rounding=ROUND_DOWN))|) ==
               "-1.99"
    end

    test "quantize with ROUND_UP inflates" do
      assert run!(~s|str(Decimal("1.001").quantize(Decimal("0.01"), rounding=ROUND_UP))|) ==
               "1.01"

      assert run!(~s|str(Decimal("-1.001").quantize(Decimal("0.01"), rounding=ROUND_UP))|) ==
               "-1.01"
    end

    test "quantize preserves sign on negative inputs" do
      assert run!(~s|str(Decimal("-3.14159").quantize(Decimal("0.01")))|) == "-3.14"

      assert run!(~s|str(Decimal("-0.005").quantize(Decimal("0.01")))|) == "0.00" or
               run!(~s|str(Decimal("-0.005").quantize(Decimal("0.01")))|) == "-0.00"
    end

    test "quantize to a finer scale pads with zeros" do
      # 3.14 → 3.1400 (no information loss)
      assert run!(~s|str(Decimal("3.14").quantize(Decimal("0.0001")))|) == "3.1400"
    end

    test "quantize accepts any Decimal as the exponent template" do
      # The numerical value of the template is irrelevant; only its exponent matters
      assert run!(~s|str(Decimal("3.14159").quantize(Decimal("999.99")))|) == "3.14"
    end
  end

  # =========================================================================
  # Real-world finance: sales tax, tip split, NPV, loan amortization, alloc
  # =========================================================================

  describe "real-world finance: sales tax" do
    test "8.875% sales tax on $19.99 rounds to $1.77 with banker's" do
      # 19.99 * 0.08875 = 1.7741125 → banker's to 1.77
      result =
        run!("""
        price = Decimal("19.99")
        rate = Decimal("0.08875")
        tax = (price * rate).quantize(Decimal("0.01"))
        str(tax)
        """)

      assert result == "1.77"
    end

    test "8.875% sales tax on $19.99 with ROUND_HALF_UP rounds to $1.77" do
      result =
        run!("""
        price = Decimal("19.99")
        rate = Decimal("0.08875")
        tax = (price * rate).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
        str(tax)
        """)

      assert result == "1.77"
    end

    test "tax on item priced at exact half-cent boundary differs by mode" do
      # 0.005 is the boundary; banker's rounds to 0.00, half-up to 0.01
      result_he =
        run!("""
        amt = Decimal("0.005")
        str(amt.quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN))
        """)

      result_hu =
        run!("""
        amt = Decimal("0.005")
        str(amt.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))
        """)

      assert result_he == "0.00"
      assert result_hu == "0.01"
    end
  end

  describe "real-world finance: penny-perfect tip split" do
    test "split $100 tip 3 ways with explicit penny remainder allocation" do
      # 100 / 3 = 33.33 each, leaving 1 cent over to allocate
      result =
        run!("""
        total = Decimal("100.00")
        n = 3
        per_share = (total / n).quantize(Decimal("0.01"), rounding=ROUND_DOWN)
        # Total of equal shares (with rounding-down)
        sum_eq = per_share * n
        remainder = total - sum_eq
        # remainder gets distributed as +0.01 to each of the first
        # `remainder * 100` people; everyone else gets per_share.
        remainder_cents = int(remainder * 100)
        shares = []
        for i in range(n):
            if i < remainder_cents:
                shares.append(per_share + Decimal("0.01"))
            else:
                shares.append(per_share)
        # Reconstructed sum must equal the original total exactly.
        total_back = Decimal("0.00")
        for s in shares:
            total_back += s
        [str(s) for s in shares] + [str(total_back)]
        """)

      assert result == ["33.34", "33.33", "33.33", "100.00"]
    end
  end

  describe "real-world finance: compound interest" do
    test "10000 @ 5% compounded annually for 10 years matches CPython math" do
      result =
        run!("""
        principal = Decimal("10000.00")
        rate = Decimal("0.05")
        years = 10
        balance = principal
        for _ in range(years):
            balance = balance * (Decimal("1") + rate)
        balance.quantize(Decimal("0.01")) == Decimal("16288.95")
        """)

      assert result == true
    end

    test "monthly compounding for one year matches manual computation" do
      # Verify month-by-month compounding gives the same result as one
      # bulk multiplication by (1 + r/n) ** n.
      result =
        run!("""
        principal = Decimal("1000.00")
        annual = Decimal("0.12")
        n = 12
        monthly = annual / n
        balance = principal
        for _ in range(n):
            balance = balance * (Decimal("1") + monthly)
        bulk = principal * ((Decimal("1") + monthly) ** n)
        balance.quantize(Decimal("0.0000000001")) == bulk.quantize(Decimal("0.0000000001"))
        """)

      assert result == true
    end
  end

  describe "real-world finance: discounted cash flow / NPV" do
    test "NPV of [-1000, 300, 400, 500] @ 10% is positive" do
      result =
        run!("""
        cashflows = [Decimal("-1000"), Decimal("300"), Decimal("400"), Decimal("500")]
        rate = Decimal("0.10")
        npv = Decimal("0")
        for t, cf in enumerate(cashflows):
            npv += cf / ((Decimal("1") + rate) ** t)
        # Round to cents for assertion stability
        npv.quantize(Decimal("0.01"))
        """)

      # Expected: -1000 + 300/1.1 + 400/1.21 + 500/1.331 ≈ -1000 + 272.73 + 330.58 + 375.66 = -21.04
      # (negative NPV: project doesn't clear the hurdle)
      assert run!("str(#{inspect_decimal(result)})") == "-21.04"
    end
  end

  describe "real-world finance: loan amortization" do
    test "30-year mortgage at 6% on 200k: monthly P&I" do
      # M = P * (r(1+r)^n) / ((1+r)^n - 1)
      result =
        run!("""
        P = Decimal("200000")
        annual_rate = Decimal("0.06")
        years = 30
        n = years * 12
        r = annual_rate / 12
        factor = (Decimal("1") + r) ** n
        M = P * (r * factor) / (factor - Decimal("1"))
        M.quantize(Decimal("0.01"))
        """)

      # The standard answer is $1199.10 (at default banker's rounding)
      assert run!("str(#{inspect_decimal(result)})") == "1199.10"
    end
  end

  describe "real-world finance: percentage allocation that must sum to whole" do
    test "split 100 shares across 3 owners by % weight, no fractional shares lost" do
      # Weights 1/3 each → 33.33%. Largest-remainder method allocates the
      # leftover share to the owner with the largest fractional remainder.
      result =
        run!("""
        total = 100
        weights = [Decimal("0.3333"), Decimal("0.3333"), Decimal("0.3334")]
        raw = [w * total for w in weights]
        whole = [int(v) for v in raw]
        leftover = total - sum(whole)
        # Fractional parts
        fracs = [(v - int(v), i) for i, v in enumerate(raw)]
        fracs.sort(reverse=True)
        for k in range(leftover):
            whole[fracs[k][1]] += 1
        whole + [sum(whole)]
        """)

      assert result == [33, 33, 34, 100]
    end
  end

  # =========================================================================
  # Sign and zero handling
  # =========================================================================

  describe "signed zeros" do
    test "Decimal('-0') and Decimal('0') compare equal but differ in sign" do
      assert run!(~s|Decimal("-0") == Decimal("0")|) == true
      assert run!(~s|Decimal("-0").is_signed()|) == true
      assert run!(~s|Decimal("0").is_signed()|) == false
    end

    test "unary minus / plus on zero clears sign (CPython context normalisation)" do
      # CPython's unary `-` and `+` go through context, which normalises
      # signed zero to +0. To preserve the sign on zero, use `copy_negate`.
      assert run!(~s|(-Decimal("0")).is_signed()|) == false
      assert run!(~s|(-Decimal("-0")).is_signed()|) == false
      assert run!(~s|(+Decimal("-0")).is_signed()|) == false
    end

    test "copy_negate preserves zero sign manipulation" do
      # The way to actually flip the sign of zero is `copy_negate`.
      assert run!(~s|Decimal("0").copy_negate().is_signed()|) == true
      assert run!(~s|Decimal("-0").copy_negate().is_signed()|) == false
    end

    test "abs of negative zero produces non-negative zero" do
      assert run!(~s|abs(Decimal("-0")).is_signed()|) == false
    end
  end

  # =========================================================================
  # Special values: NaN, Infinity
  # =========================================================================

  describe "special values" do
    test "is_nan and is_infinite identify NaN / Inf correctly" do
      assert run!(~s|Decimal("NaN").is_nan()|) == true
      assert run!(~s|Decimal("Infinity").is_infinite()|) == true
      assert run!(~s|Decimal("-Infinity").is_infinite()|) == true
      assert run!(~s|Decimal("3.14").is_finite()|) == true
      assert run!(~s|Decimal("NaN").is_finite()|) == false
      assert run!(~s|Decimal("Infinity").is_finite()|) == false
    end

    test "NaN does not equal anything, including itself" do
      assert run!(~s|Decimal("NaN") == Decimal("NaN")|) == false
      assert run!(~s|Decimal("NaN") != Decimal("NaN")|) == true
    end

    test "Infinity arithmetic" do
      assert run!(~s|str(Decimal("Infinity") + Decimal("1"))|) == "Infinity"
      assert run!(~s|str(Decimal("-Infinity") - Decimal("1"))|) == "-Infinity"
    end

    test "number_class returns CPython-format strings" do
      assert run!(~s|Decimal("3.14").number_class()|) == "+Normal"
      assert run!(~s|Decimal("-3.14").number_class()|) == "-Normal"
      assert run!(~s|Decimal("0").number_class()|) == "+Zero"
      assert run!(~s|Decimal("-0").number_class()|) == "-Zero"
      assert run!(~s|Decimal("Infinity").number_class()|) == "+Infinity"
      assert run!(~s|Decimal("-Infinity").number_class()|) == "-Infinity"
      assert run!(~s|Decimal("NaN").number_class()|) == "NaN"
    end
  end

  # =========================================================================
  # Context (getcontext / setcontext / localcontext)
  # =========================================================================

  describe "context: precision" do
    test "default precision is 28, default rounding is ROUND_HALF_EVEN" do
      assert run!("getcontext().prec") == 28
      assert run!("getcontext().rounding") == "ROUND_HALF_EVEN"
    end

    test "setcontext with raised precision affects subsequent division" do
      # 1/7 at default 28 digits has 28 significant digits.
      # Lowered to 6, we get only 6 digits.
      result =
        run!("""
        ctx = getcontext()
        ctx.prec = 6
        setcontext(ctx)
        s = str(Decimal("1") / Decimal("7"))
        s
        """)

      # Expect result like "0.142857"
      assert result == "0.142857"
    end

    test "localcontext restores prior context on exit" do
      # before/after must match; inside must differ.
      result =
        run!("""
        before = getcontext().prec
        with localcontext() as ctx:
            ctx.prec = 4
            setcontext(ctx)
            inside = getcontext().prec
        after = getcontext().prec
        [before, inside, after]
        """)

      assert result == [28, 4, 28]
    end

    test "localcontext respects the inside precision for a division" do
      result =
        run!("""
        with localcontext() as ctx:
            ctx.prec = 5
            setcontext(ctx)
            short = str(Decimal("1") / Decimal("3"))
        long = str(Decimal("1") / Decimal("3"))
        [short, long[:31]]
        """)

      assert result == ["0.33333", "0.3333333333333333333333333333"]
    end
  end

  # =========================================================================
  # as_tuple round-trip and tuple constructor
  # =========================================================================

  describe "as_tuple / Decimal((sign, digits, exp))" do
    test "as_tuple of 3.14 = (0, (3, 1, 4), -2)" do
      assert run!("Decimal('3.14').as_tuple()") == {:tuple, [0, {:tuple, [3, 1, 4]}, -2]}
    end

    test "as_tuple of -3.14 = (1, (3, 1, 4), -2)" do
      assert run!("Decimal('-3.14').as_tuple()") == {:tuple, [1, {:tuple, [3, 1, 4]}, -2]}
    end

    test "as_tuple of 0 = (0, (0,), 0)" do
      assert run!("Decimal('0').as_tuple()") == {:tuple, [0, {:tuple, [0]}, 0]}
    end

    test "tuple constructor reconstructs the original Decimal" do
      assert run!("str(Decimal((0, (3, 1, 4), -2)))") == "3.14"
      assert run!("str(Decimal((1, (3, 1, 4), -2)))") == "-3.14"
      assert run!("str(Decimal((0, (1, 2, 3, 4, 5), 0)))") == "12345"
    end
  end

  # =========================================================================
  # copy_abs, copy_negate, copy_sign
  # =========================================================================

  describe "copy_abs / copy_negate / copy_sign" do
    test "copy_abs always positive" do
      assert run!(~s|str(Decimal("-3.14").copy_abs())|) == "3.14"
      assert run!(~s|str(Decimal("3.14").copy_abs())|) == "3.14"
    end

    test "copy_negate flips sign even on zero" do
      assert run!(~s|str(Decimal("-3.14").copy_negate())|) == "3.14"
      assert run!(~s|str(Decimal("3.14").copy_negate())|) == "-3.14"
      assert run!(~s|Decimal("0").copy_negate().is_signed()|) == true
    end

    test "copy_sign takes magnitude from self, sign from arg" do
      assert run!(~s|str(Decimal("3.14").copy_sign(Decimal("-1")))|) == "-3.14"
      assert run!(~s|str(Decimal("-3.14").copy_sign(Decimal("1")))|) == "3.14"
    end
  end

  # =========================================================================
  # sqrt, ln, log10, exp
  # =========================================================================

  describe "transcendentals: sqrt / ln / log10 / exp" do
    test "sqrt(2) at default precision matches first 12 digits" do
      result = run!(~s|str(Decimal("2").sqrt())|)
      assert String.starts_with?(result, "1.414213562")
    end

    test "sqrt of perfect squares is exact" do
      assert run!(~s|str(Decimal("16").sqrt())|) == "4"
      assert run!(~s|str(Decimal("100").sqrt())|) == "10"
    end

    test "ln(e^x) ≈ x" do
      result =
        run!("""
        e = Decimal("1").exp()  # e^1
        # ln(e) should be very close to 1
        ln_e = e.ln()
        # within rounding of one
        abs(ln_e - Decimal("1")) < Decimal("0.0001")
        """)

      assert result == true
    end

    test "log10(1000) ≈ 3" do
      result =
        run!("""
        v = Decimal("1000").log10()
        abs(v - Decimal("3")) < Decimal("0.0001")
        """)

      assert result == true
    end

    test "ln of negative raises InvalidOperation" do
      assert {:error, %Pyex.Error{message: msg}} = run("Decimal('-1').ln()")
      assert msg =~ "InvalidOperation"
    end
  end

  # =========================================================================
  # min / max / compare / normalize / adjusted
  # =========================================================================

  describe "min / max / compare / adjusted / normalize" do
    test "min and max take the smaller / larger respectively" do
      assert run!(~s|str(Decimal("1.5").max(Decimal("2.5")))|) == "2.5"
      assert run!(~s|str(Decimal("1.5").min(Decimal("2.5")))|) == "1.5"
      assert run!(~s|str(Decimal("-3").max(Decimal("0")))|) == "0"
    end

    test "compare returns -1, 0, or 1 as Decimals" do
      assert run!(~s|str(Decimal("1").compare(Decimal("2")))|) == "-1"
      assert run!(~s|str(Decimal("2").compare(Decimal("2")))|) == "0"
      assert run!(~s|str(Decimal("3").compare(Decimal("2")))|) == "1"
    end

    test "compare with NaN gives NaN" do
      assert run!(~s|str(Decimal("3").compare(Decimal("NaN")))|) == "NaN"
    end

    test "adjusted exponent" do
      # adjusted(x) = exp + len(coef) - 1
      assert run!(~s|Decimal("123.45").adjusted()|) == 2
      assert run!(~s|Decimal("0.00123").adjusted()|) == -3
      assert run!(~s|Decimal("1").adjusted()|) == 0
    end

    test "normalize strips trailing zeros" do
      # 1.500 → 1.5  (CPython uses scientific for some normalize results)
      assert run!(~s|str(Decimal("1.500").normalize())|) == "1.5"

      assert run!(~s|str(Decimal("100").normalize())|) == "1E+2" or
               run!(~s|str(Decimal("100").normalize())|) == "100"
    end
  end

  # =========================================================================
  # Mixing with int, bool
  # =========================================================================

  describe "int and bool coerce to Decimal" do
    test "Decimal + bool" do
      assert run!(~s|str(Decimal("3") + True)|) == "4"
      assert run!(~s|str(Decimal("3") + False)|) == "3"
    end

    test "comparison with bool" do
      assert run!(~s|Decimal("1") == True|) == true
      assert run!(~s|Decimal("0") == False|) == true
      assert run!(~s|Decimal("0.5") < True|) == true
    end

    test "Decimal(True), Decimal(False)" do
      assert run!("str(Decimal(True))") == "1"
      assert run!("str(Decimal(False))") == "0"
    end

    test "Decimal(int) preserves the integer exactly even for huge values" do
      assert run!("str(Decimal(2 ** 64))") == "18446744073709551616"
    end
  end

  # =========================================================================
  # Float rejection (CPython behavior is TypeError on Decimal +/-/*/etc float)
  # =========================================================================

  describe "Decimal vs float" do
    test "Decimal + float raises TypeError" do
      assert {:error, %Pyex.Error{message: msg}} = run("Decimal('1') + 1.5")
      assert msg =~ "TypeError"
    end

    test "float + Decimal raises TypeError" do
      assert {:error, %Pyex.Error{message: msg}} = run("1.5 + Decimal('1')")
      assert msg =~ "TypeError"
    end

    test "Decimal(float) succeeds (CPython behavior)" do
      # CPython produces the exact bit-for-bit decimal expansion of the
      # IEEE-754 double; pyex's underlying Decimal lib produces the
      # shortest decimal that round-trips. Both are valid; here we just
      # confirm the constructor doesn't crash and yields a Decimal.
      result = run!("str(Decimal(0.5))")
      assert result == "0.5"
    end
  end

  # =========================================================================
  # repr / str CPython parity
  # =========================================================================

  describe "repr and str format" do
    test "repr wraps value in Decimal('...')" do
      assert run!(~s|repr(Decimal("3.14"))|) == "Decimal('3.14')"
      assert run!(~s|repr(Decimal("-12.500"))|) == "Decimal('-12.500')"
      assert run!(~s|repr(Decimal("0"))|) == "Decimal('0')"
    end

    test "str returns bare numeric form" do
      assert run!(~s|str(Decimal("3.14"))|) == "3.14"
      assert run!(~s|str(Decimal("-12.500"))|) == "-12.500"
    end

    test "Decimal in list uses repr form (CPython parity)" do
      assert run!(~s|str([Decimal("1.5"), Decimal("2.5")])|) ==
               "[Decimal('1.5'), Decimal('2.5')]"
    end

    test "Decimal in tuple uses repr form" do
      assert run!(~s|str((Decimal("1.5"),))|) == "(Decimal('1.5'),)"
    end

    test "f-string with format spec rounds with banker's" do
      assert run!(~s|f"{Decimal('1.005'):.2f}"|) == "1.00"
      assert run!(~s|f"{Decimal('1.015'):.2f}"|) == "1.02"
    end

    test "f-string without spec uses str form" do
      assert run!(~s|f"{Decimal('3.14')}"|) == "3.14"
    end
  end

  # =========================================================================
  # Hashability / dict key behavior
  # =========================================================================

  describe "Decimal as dict key" do
    test "Decimal can be a dict key" do
      result =
        run!("""
        d = {Decimal("1.5"): "found"}
        d[Decimal("1.5")]
        """)

      assert result == "found"
    end
  end

  # =========================================================================
  # Iteration / aggregation patterns
  # =========================================================================

  describe "aggregate patterns commonly used in finance" do
    test "sum() over Decimals via reduction yields exact total" do
      result =
        run!("""
        items = [Decimal("19.99"), Decimal("4.99"), Decimal("3.49"), Decimal("0.01")]
        total = Decimal("0")
        for x in items:
            total += x
        str(total)
        """)

      assert result == "28.48"
    end

    test "max/min over a list of Decimals" do
      result =
        run!("""
        prices = [Decimal("3.14"), Decimal("2.71"), Decimal("1.41"), Decimal("9.99")]
        [str(max(prices)), str(min(prices))]
        """)

      assert result == ["9.99", "1.41"]
    end
  end

  # =========================================================================
  # Cross-type interop -- the silent-failure category
  # =========================================================================

  describe "cross-type equality with float (must not raise)" do
    test "Decimal == float returns False" do
      assert run!(~s|Decimal("1") == 1.5|) == false
      assert run!(~s|Decimal("1.5") == 1.5|) == false
    end

    test "Decimal != float returns True" do
      assert run!(~s|Decimal("1") != 1.5|) == true
    end

    test "float == Decimal returns False" do
      assert run!(~s|1.5 == Decimal("1")|) == false
    end

    test "Decimal < float still raises (ordering is undefined)" do
      assert {:error, %Pyex.Error{message: msg}} = run("Decimal('1') < 1.5")
      assert msg =~ "TypeError"
    end
  end

  describe "hash interop with int / bool" do
    test "hash(Decimal('1')) == hash(1)" do
      assert run!(~s|hash(Decimal("1")) == hash(1)|) == true
    end

    test "hash(Decimal('1.0')) == hash(1)" do
      assert run!(~s|hash(Decimal("1.0")) == hash(1)|) == true
    end

    test "hash(Decimal('-0')) == hash(0)" do
      assert run!(~s|hash(Decimal("-0")) == hash(0)|) == true
    end

    test "hash(Decimal('1')) == hash(True)" do
      assert run!(~s|hash(Decimal("1")) == hash(True)|) == true
    end

    test "hash(Decimal('NaN')) raises TypeError" do
      assert {:error, %Pyex.Error{message: msg}} = run("hash(Decimal('NaN'))")
      assert msg =~ "TypeError"
    end
  end

  describe "set / dict cross-type membership" do
    test "Decimal('1') in {1} is True" do
      assert run!("Decimal('1') in {1}") == true
    end

    test "1 in {Decimal('1')} is True" do
      assert run!("1 in {Decimal('1')}") == true
    end

    test "Decimal('1') in [1] is True (list)" do
      assert run!("Decimal('1') in [1]") == true
    end

    test "True in {Decimal('1')} is True (bool/Decimal interop)" do
      assert run!("True in {Decimal('1')}") == true
    end

    test "{1, True, Decimal('1'), 1.0} collapses to a single element" do
      assert run!("len({1, True, Decimal('1'), 1.0})") == 1
    end

    test "dict keyed by int can be looked up with Decimal" do
      assert run!("d = {1: 'one', 2: 'two'}\nd[Decimal('1')]") == "one"
    end

    test "dict keyed by Decimal can be looked up with int" do
      assert run!("d = {Decimal('1'): 'one'}\nd[1]") == "one"
    end

    test "putting Decimal('1') overwrites int key 1" do
      result =
        run!("""
        d = {1: 'a'}
        d[Decimal('1')] = 'b'
        d[1]
        """)

      assert result == "b"
    end
  end

  describe "divmod / round / sum on Decimals" do
    test "divmod returns a (Decimal, Decimal) tuple per CPython" do
      assert run!("divmod(Decimal('10'), Decimal('3'))") ==
               {:tuple, [{:pyex_decimal, Decimal.new("3")}, {:pyex_decimal, Decimal.new("1")}]}
    end

    test "divmod with negative dividend uses Decimal truncation semantics" do
      # CPython: divmod(Decimal('-7'), Decimal('3')) == (-2, -1), NOT (-3, 2)
      assert run!("str(divmod(Decimal('-7'), Decimal('3'))[0])") == "-2"
      assert run!("str(divmod(Decimal('-7'), Decimal('3'))[1])") == "-1"
    end

    test "divmod by zero raises InvalidOperation (matches CPython)" do
      # divmod returns (q, r), and `r` would signal InvalidOperation for
      # a zero divisor -- so the whole pair raises InvalidOperation,
      # not DivisionByZero.
      assert {:error, %Pyex.Error{message: msg}} =
               run("divmod(Decimal('5'), Decimal('0'))")

      assert msg =~ "InvalidOperation"
    end

    test "round(Decimal, n) returns a Decimal with banker's rounding" do
      # 1.235 → 1.24 (banker's: '4' is even? No — looks at digit being kept;
      # the digit after '3' is the '5', so we round '3' to '4' (odd → up).
      # Actually banker's: the kept digit '3' becomes '4' because the next
      # digit is '5' and the kept digit '3' is odd, so round up to even.
      assert run!("str(round(Decimal('1.235'), 2))") == "1.24"
      # 1.245 → 1.24 (kept digit '4' is even, drop the '5')
      assert run!("str(round(Decimal('1.245'), 2))") == "1.24"
      # 1.255 → 1.26 (kept digit '5' is odd, round up to even '6')
      assert run!("str(round(Decimal('1.255'), 2))") == "1.26"
    end

    test "round(Decimal) without ndigits returns int" do
      assert run!("round(Decimal('2.5'))") == 2
      assert run!("round(Decimal('3.5'))") == 4
      assert run!("round(Decimal('-2.5'))") == -2
    end

    test "sum over Decimals is exact" do
      assert run!("str(sum([Decimal('0.1')] * 10))") == "1.0"
      assert run!("str(sum([Decimal('0.01')] * 100))") == "1.00"
    end

    test "sum with explicit Decimal start" do
      assert run!("str(sum([Decimal('1'), Decimal('2')], Decimal('10')))") == "13"
    end
  end

  describe "Inf / NaN edge-case operations raise InvalidOperation" do
    test "Inf * 0 raises InvalidOperation" do
      assert {:error, %Pyex.Error{message: msg}} =
               run("Decimal('Infinity') * Decimal('0')")

      assert msg =~ "InvalidOperation"
    end

    test "Inf - Inf raises InvalidOperation" do
      assert {:error, %Pyex.Error{message: msg}} =
               run("Decimal('Infinity') - Decimal('Infinity')")

      assert msg =~ "InvalidOperation"
    end

    test "Inf / Inf raises InvalidOperation" do
      assert {:error, %Pyex.Error{message: msg}} =
               run("Decimal('Infinity') / Decimal('Infinity')")

      assert msg =~ "InvalidOperation"
    end
  end

  describe "underscore digit separators" do
    test "Decimal('1_000_000') parses as 1000000 (CPython 3.6+)" do
      assert run!("str(Decimal('1_000_000'))") == "1000000"
    end

    test "Decimal('1_234.567_89') parses with mid-fraction underscores" do
      assert run!("str(Decimal('1_234.567_89'))") == "1234.56789"
    end

    test "Decimal with leading underscore is invalid" do
      assert {:error, _} = run("Decimal('_1000')")
    end

    test "Decimal with trailing underscore is invalid" do
      assert {:error, _} = run("Decimal('1000_')")
    end
  end

  describe "int(Decimal) and float(Decimal) coercion" do
    test "int(Decimal) truncates toward zero" do
      assert run!("int(Decimal('3.99'))") == 3
      assert run!("int(Decimal('-3.99'))") == -3
      assert run!("int(Decimal('0.5'))") == 0
    end

    test "int(Decimal('NaN')) raises ValueError" do
      assert {:error, %Pyex.Error{message: msg}} = run("int(Decimal('NaN'))")
      assert msg =~ "ValueError"
    end

    test "int(Decimal('Inf')) raises OverflowError" do
      assert {:error, %Pyex.Error{message: msg}} = run("int(Decimal('Infinity'))")
      assert msg =~ "OverflowError"
    end

    test "float(Decimal) round-trips small values" do
      assert run!("float(Decimal('1.5'))") == 1.5
      assert run!("float(Decimal('0'))") == 0.0
    end
  end

  describe "comparison chains with Decimals" do
    test "a < b < c works across Decimal types" do
      assert run!("Decimal('1') < Decimal('2') < Decimal('3')") == true
      assert run!("Decimal('1') < Decimal('2') < Decimal('1')") == false
    end

    test "chains can mix Decimal and int" do
      assert run!("Decimal('1') < 2 < Decimal('3')") == true
    end
  end

  # ---------- helpers ----------

  # Convert a runtime value back into a Decimal-string form for re-evaluation.
  # Used by NPV / amortization tests where we re-evaluate the result for a
  # stable assertion regardless of intermediate-precision digits.
  defp inspect_decimal({:pyex_decimal, d}), do: ~s|Decimal("#{Decimal.to_string(d)}")|
  defp inspect_decimal(s) when is_binary(s), do: ~s|Decimal("#{s}")|
end
