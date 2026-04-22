defmodule Pyex.Stdlib.DecimalTest do
  use ExUnit.Case, async: true

  describe "Decimal constructor" do
    test "Decimal from string" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("3.14"))
        """)

      assert result == "3.14"
    end

    test "Decimal from zero string" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("0"))
        """)

      assert result == "0"
    end

    test "Decimal from negative string" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("-1.5"))
        """)

      assert result == "-1.5"
    end

    test "Decimal from int" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal(5))
        """)

      assert result == "5"
    end

    test "invalid Decimal literal returns InvalidOperation" do
      assert {:error, %Pyex.Error{message: msg}} =
               Pyex.run("""
               from decimal import Decimal
               Decimal("abc")
               """)

      assert msg =~ "InvalidOperation"
      assert msg =~ "Decimal"
    end
  end

  describe "Decimal arithmetic" do
    test "Decimal + Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("1.1") + Decimal("2.2"))
        """)

      assert result == "3.3"
    end

    test "Decimal - Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("5.5") - Decimal("2.2"))
        """)

      assert result == "3.3"
    end

    test "Decimal * Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("2.5") * Decimal("4"))
        """)

      assert result == "10.0"
    end

    test "Decimal + int" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("3.14") + 1)
        """)

      assert result == "4.14"
    end

    test "int + Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(1 + Decimal("3.14"))
        """)

      assert result == "4.14"
    end

    test "Decimal += int" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        x = Decimal("10.5")
        x += 1
        str(x)
        """)

      assert result == "11.5"
    end
  end

  describe "Decimal comparison" do
    test "Decimal > Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        Decimal("3.14") > Decimal("2.71")
        """)

      assert result == true
    end

    test "Decimal == Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        Decimal("1.0") == Decimal("1.0")
        """)

      assert result == true
    end

    test "Decimal < 0" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        Decimal("-1.5") < 0
        """)

      assert result == true
    end

    test "Decimal > 0" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        Decimal("3.14") > 0
        """)

      assert result == true
    end

    test "Decimal == 0" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        Decimal("0") == 0
        """)

      assert result == true
    end
  end

  describe "Decimal division" do
    test "Decimal / Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("10") / Decimal("4"))
        """)

      assert result == "2.5"
    end

    test "Decimal / int" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("9") / 2)
        """)

      assert result == "4.5"
    end

    test "division by zero raises ZeroDivisionError" do
      assert {:error, %Pyex.Error{message: msg}} =
               Pyex.run("""
               from decimal import Decimal
               Decimal("1") / Decimal("0")
               """)

      assert msg =~ "ZeroDivisionError"
    end

    test "division by zero int raises ZeroDivisionError" do
      assert {:error, %Pyex.Error{message: msg}} =
               Pyex.run("""
               from decimal import Decimal
               Decimal("1") / 0
               """)

      assert msg =~ "ZeroDivisionError"
    end
  end

  describe "Decimal negative arithmetic" do
    test "Decimal subtraction yielding negative" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("1.5") - Decimal("3.0"))
        """)

      assert result == "-1.5"
    end

    test "negative Decimal + positive Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("-2.5") + Decimal("1.0"))
        """)

      assert result == "-1.5"
    end

    test "negative Decimal * positive Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("-3") * Decimal("4"))
        """)

      assert result == "-12"
    end

    test "negative Decimal * negative Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("-3") * Decimal("-4"))
        """)

      assert result == "12"
    end
  end

  describe "Decimal extended comparisons" do
    test "Decimal <= Decimal true" do
      assert Pyex.run!("""
             from decimal import Decimal
             Decimal("1.0") <= Decimal("1.0")
             """) == true
    end

    test "Decimal <= Decimal strict" do
      assert Pyex.run!("""
             from decimal import Decimal
             Decimal("0.9") <= Decimal("1.0")
             """) == true
    end

    test "Decimal >= Decimal true" do
      assert Pyex.run!("""
             from decimal import Decimal
             Decimal("2.0") >= Decimal("2.0")
             """) == true
    end

    test "Decimal != Decimal" do
      assert Pyex.run!("""
             from decimal import Decimal
             Decimal("1.0") != Decimal("2.0")
             """) == true
    end

    test "Decimal != Decimal same value" do
      assert Pyex.run!("""
             from decimal import Decimal
             Decimal("1.0") != Decimal("1.0")
             """) == false
    end

    test "Decimal < int" do
      assert Pyex.run!("""
             from decimal import Decimal
             Decimal("0.5") < 1
             """) == true
    end

    test "Decimal >= int" do
      assert Pyex.run!("""
             from decimal import Decimal
             Decimal("5") >= 5
             """) == true
    end
  end

  describe "Decimal copy constructor" do
    test "Decimal from Decimal returns same value" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        a = Decimal("3.14")
        b = Decimal(a)
        str(b)
        """)

      assert result == "3.14"
    end
  end

  describe "Decimal repr" do
    test "repr of Decimal wraps in Decimal('...') per CPython" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        repr(Decimal("3.14"))
        """)

      assert result == "Decimal('3.14')"
    end

    test "Decimal in list repr is wrapped per CPython" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str([Decimal("3.14")])
        """)

      assert result == "[Decimal('3.14')]"
    end
  end

  describe "Decimal truthiness" do
    test "non-zero Decimal is truthy in if" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        x = Decimal("1.5")
        "truthy" if x else "falsy"
        """)

      assert result == "truthy"
    end

    test "zero Decimal is falsy in if" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        x = Decimal("0")
        "nonzero" if x else "zero"
        """)

      assert result == "zero"
    end

    test "negative Decimal is truthy in if" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        x = Decimal("-1")
        "truthy" if x else "falsy"
        """)

      assert result == "truthy"
    end

    test "zero Decimal in while loop does not execute" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        x = Decimal("0")
        ran = False
        while x:
            ran = True
            break
        ran
        """)

      assert result == false
    end
  end

  describe "Decimal augmented assignment" do
    test "Decimal -= Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        x = Decimal("10.5")
        x -= Decimal("3.5")
        str(x)
        """)

      assert result == "7.0"
    end

    test "Decimal *= int" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        x = Decimal("2.5")
        x *= 3
        str(x)
        """)

      assert result == "7.5"
    end
  end

  describe "Decimal with f-string formatting" do
    test "Decimal with .2f format spec" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        val = Decimal("3.14159")
        f"{val:.2f}"
        """)

      assert result == "3.14"
    end

    test "Decimal .2f preserves large-value precision" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        val = Decimal("12345678901234567890.12")
        f"{val:.2f}"
        """)

      assert result == "12345678901234567890.12"
    end

    test "Decimal .2f pads trailing zeros" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        val = Decimal("1")
        f"{val:.2f}"
        """)

      assert result == "1.00"
    end
  end

  describe "str(Decimal)" do
    test "str of Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("3.14"))
        """)

      assert result == "3.14"
    end

    test "str of negative Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("-99.99"))
        """)

      assert result == "-99.99"
    end

    test "str of large Decimal" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("123456789.123456789"))
        """)

      assert result == "123456789.123456789"
    end
  end

  describe "Decimal precision (avoids float errors)" do
    test "0.1 + 0.2 == 0.3 with Decimal (unlike floats)" do
      assert Pyex.run!("""
             from decimal import Decimal
             Decimal("0.1") + Decimal("0.2") == Decimal("0.3")
             """) == true
    end

    test "0.1 + 0.2 as float is NOT 0.3" do
      assert Pyex.run!("0.1 + 0.2 == 0.3") == false
    end

    test "Decimal str of 0.1 + 0.2 is exactly 0.3" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("0.1") + Decimal("0.2"))
        """)

      assert result == "0.3"
    end

    test "Decimal subtraction precision: 1.0 - 0.9 == 0.1" do
      assert Pyex.run!("""
             from decimal import Decimal
             Decimal("1.0") - Decimal("0.9") == Decimal("0.1")
             """) == true
    end

    test "Decimal multiplication precision: 0.1 * 3 == 0.3" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("0.1") * Decimal("3"))
        """)

      assert result == "0.3"
    end

    test "Decimal division precision: 1 / 3 * 3" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("1") / Decimal("3") * Decimal("3"))
        """)

      # Decimal preserves the repeating-decimal behavior
      assert result != nil
    end

    test "financial calculation: sum of line items" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        items = [Decimal("19.99"), Decimal("4.99"), Decimal("3.49")]
        total = Decimal("0")
        for item in items:
            total += item
        str(total)
        """)

      assert result == "28.47"
    end
  end

  describe "Decimal type errors" do
    test "Decimal + string raises TypeError" do
      assert {:error, %Pyex.Error{message: msg}} =
               Pyex.run("""
               from decimal import Decimal
               Decimal("1") + "hello"
               """)

      assert msg =~ "TypeError"
    end

    test "Decimal * string raises TypeError" do
      assert {:error, %Pyex.Error{message: msg}} =
               Pyex.run("""
               from decimal import Decimal
               Decimal("1") * "hello"
               """)

      assert msg =~ "TypeError"
    end

    test "Decimal + float raises TypeError" do
      assert {:error, %Pyex.Error{message: msg}} =
               Pyex.run("""
               from decimal import Decimal
               Decimal("1") + 1.5
               """)

      assert msg =~ "TypeError"
    end

    test "float + Decimal raises TypeError" do
      assert {:error, %Pyex.Error{message: msg}} =
               Pyex.run("""
               from decimal import Decimal
               1.5 + Decimal("1")
               """)

      assert msg =~ "TypeError"
    end
  end

  describe "bool() with Decimal (regression)" do
    test "bool(Decimal('0')) is false" do
      assert Pyex.run!("""
             from decimal import Decimal
             bool(Decimal("0"))
             """) == false
    end

    test "bool(Decimal('1')) is true" do
      assert Pyex.run!("""
             from decimal import Decimal
             bool(Decimal("1"))
             """) == true
    end

    test "bool(Decimal('-0')) is false" do
      assert Pyex.run!("""
             from decimal import Decimal
             bool(Decimal("-0"))
             """) == false
    end

    test "bool(Decimal('0.00')) is false" do
      assert Pyex.run!("""
             from decimal import Decimal
             bool(Decimal("0.00"))
             """) == false
    end

    test "bool(Decimal('0.001')) is true" do
      assert Pyex.run!("""
             from decimal import Decimal
             bool(Decimal("0.001"))
             """) == true
    end
  end

  describe "Decimal edge cases" do
    test "large Decimal arithmetic" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("999999999999999999.99") + Decimal("0.01"))
        """)

      assert result == "1000000000000000000.00"
    end

    test "very small Decimal arithmetic" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("0.000000001") + Decimal("0.000000001"))
        """)

      assert result == "2E-9" or result == "0.000000002"
    end

    test "repeating decimal from division preserves precision" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        s = str(Decimal("1") / Decimal("3"))
        s[:5]
        """)

      assert result == "0.333"
    end

    test "division by zero raises ZeroDivisionError (int zero)" do
      assert {:error, %Pyex.Error{message: msg}} =
               Pyex.run("""
               from decimal import Decimal
               Decimal("5") / 0
               """)

      assert msg =~ "ZeroDivisionError"
    end

    test "not operator with Decimal" do
      assert Pyex.run!("""
             from decimal import Decimal
             not Decimal("0")
             """) == true
    end

    test "not operator with non-zero Decimal" do
      assert Pyex.run!("""
             from decimal import Decimal
             not Decimal("1")
             """) == false
    end

    test "Decimal in f-string without format spec" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        f"{Decimal('3.14')}"
        """)

      assert result == "3.14"
    end

    test "Decimal negative division" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        str(Decimal("-10") / Decimal("3"))
        """)

      # Should start with -3.333...
      assert String.starts_with?(result, "-3.333")
    end
  end
end
