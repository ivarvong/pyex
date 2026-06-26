"""Product-space sweep generator: the numeric tower.

Run with `python3 test/fixtures/sweeps/numeric_gen.py` to regenerate
`numeric.json`. Two kinds of cell:

  - expression cells (`code` -> CPython `repr`/exception) over the
    builtin numeric types (int, float, bool, complex) — floor division
    and modulo sign rules, power edge cases, round()'s banker's
    rounding, float repr precision, cross-type coercion/comparison, the
    float specials (inf/nan), bit operations, and big-int arithmetic.
  - program cells (`program` -> stdout/exception) for Decimal and
    Fraction, which need an import.

The Elixir side (`Pyex.Test.Sweep.check!("numeric")`) replays each cell
through pyex and asserts the value (or accept/reject) matches CPython.

Transcendental results that differ only in the last ULP between libm
implementations are deliberately avoided; every float result here is
exact or comes straight from IEEE-754 arithmetic both sides share.
"""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path

EXPRESSIONS = [
    # --- floor division & modulo: Python floors toward -inf ---
    "7 // 2", "7 // -2", "-7 // 2", "-7 // -2",
    "7 % 3", "-7 % 3", "7 % -3", "-7 % -3",
    "7.5 // 2", "-7.5 // 2", "7.5 % 2", "-7.5 % 2",
    "divmod(7, 3)", "divmod(-7, 3)", "divmod(7, -3)", "divmod(-7, -3)",
    "divmod(7.5, 2)", "divmod(-7.5, 2)",
    "5 // 2 * 2 + 5 % 2",
    # --- power ---
    "2 ** 10", "2 ** 0", "0 ** 0", "2 ** -1", "2 ** -2",
    "4 ** 0.5", "9 ** 0.5", "2 ** 100", "10 ** 50",
    "pow(2, 10)", "pow(2, 10, 100)", "pow(2, -1)", "pow(3, -1, 7)",
    "(2 ** 64) * (2 ** 64)", "10 ** 100 // 7", "10 ** 100 % 7",
    # --- round: banker's rounding + ndigits ---
    "round(0.5)", "round(1.5)", "round(2.5)", "round(-0.5)", "round(-1.5)",
    "round(2.675, 2)", "round(0.125, 2)", "round(1234.5678, -2)",
    "round(2.5, 0)", "round(3)", "round(3.14159, 2)", "round(-2.5)",
    # --- float repr precision ---
    "1 / 3", "0.1 + 0.2", "0.1 + 0.2 == 0.3", "1e16", "1e17", "1e-5",
    "1234567890123456.0", "0.1", "1 / 10", "100.0", "1_000_000.0",
    "6 / 2", "7 / 7", "10.0 / 3", "1e100", "1e-100", "0.0001",
    "2.0", "3.14", "-0.0", "0.0 == -0.0",
    # --- bool as int ---
    "True + 1", "True + True", "sum([True, True, False])", "True * 5",
    "int(True)", "True == 1", "False == 0", "1 + False",
    # --- complex ---
    "3 + 2j", "(1+2j) + (3-1j)", "(1+2j) * (3-1j)", "(1+2j) / (1-1j)",
    "abs(3+4j)", "(3+4j).real", "(3+4j).imag", "(1+2j).conjugate()",
    "(2j) ** 2", "complex(1, 2)", "(1+2j) == (1+2j)", "1j * 1j",
    "(2+0j) == 2", "complex('1+2j')",
    # --- cross-type comparison ---
    "1 == 1.0", "1 == True", "1.0 == 1", "0 == False", "1 < 1.5",
    "2 < 1.5", "10 ** 100 > 1e300", "2 ** 0.5 == 2 ** 0.5",
    # --- float specials ---
    "float('inf')", "float('-inf')", "float('nan')", "float('inf') + 1",
    "float('inf') - float('inf')", "float('nan') == float('nan')",
    "float('nan') != float('nan')", "float('inf') > 1e308",
    "1e308 * 10", "-1e308 * 10", "float('inf') == float('inf')",
    # --- division by zero ---
    "1 / 0", "1 // 0", "1 % 0", "1.0 / 0", "1.0 // 0.0", "divmod(1, 0)",
    "0 ** -1",
    # --- abs / unary ---
    "abs(-5)", "abs(-5.5)", "abs(-3-4j)", "abs(True)", "-(-5)", "+5",
    # --- int / float conversions ---
    "int(3.9)", "int(-3.9)", "int('  42  ')", "int('0x1f', 16)",
    "int('11', 2)", "int('z', 36)", "float('  3.14 ')", "float('1e3')",
    "int('1_000')", "float('inf')", "int(2.0)",
    # --- bit operations ---
    "5 & 3", "5 | 2", "5 ^ 1", "~5", "1 << 4", "256 >> 2", "-1 >> 1",
    "~0", "5 & 3 | 2", "1 << 100",
]

PROGRAMS = [
    # --- Decimal ---
    "from decimal import Decimal\nprint(Decimal('0.1') + Decimal('0.2'))",
    "from decimal import Decimal\nprint(Decimal(1) / Decimal(3))",
    "from decimal import Decimal\nprint(Decimal('1') + 2)",
    "from decimal import Decimal\nprint(Decimal('2.5').quantize(Decimal('1')))",
    "from decimal import Decimal\ntry:\n    Decimal('1') + 0.1\nexcept TypeError:\n    print('TypeError')",
    "from decimal import Decimal\nprint(Decimal('10') % Decimal('3'))",
    # --- Fraction ---
    "from fractions import Fraction\nprint(Fraction(1, 3) + Fraction(1, 6))",
    "from fractions import Fraction\nprint(Fraction(6, 4))",
    "from fractions import Fraction\nprint(Fraction(1, 3) + 1)",
    "from fractions import Fraction\nprint(float(Fraction(1, 4)))",
    "from fractions import Fraction\nprint(Fraction(3, 4) * Fraction(2, 3))",
    "from fractions import Fraction\nprint(repr(Fraction(6, 4)))",
    "from fractions import Fraction\nprint(Fraction(1, 2) - Fraction(1, 3))",
    "from fractions import Fraction\nprint(-Fraction(1, 2))",
    "from fractions import Fraction\nprint(Fraction(2, 3) ** 2)",
    "from fractions import Fraction\nprint(Fraction(1, 4).numerator, Fraction(1, 4).denominator)",
    "from fractions import Fraction\nprint(int(Fraction(7, 2)))",
    "from fractions import Fraction\nprint(Fraction(1, 2) < Fraction(2, 3))",
    "from fractions import Fraction\nprint(Fraction(2, 1) == 2)",
    "from fractions import Fraction\nprint(Fraction(1, 2) + 0.5)",
    "from fractions import Fraction\ntry:\n    Fraction(1, 0)\nexcept ZeroDivisionError:\n    print('ZeroDivisionError')",
]


def evaluate(code: str) -> dict:
    try:
        return {"code": code, "result": repr(eval(code))}  # noqa: S307 - generator only
    except Exception as exc:  # noqa: BLE001
        return {"code": code, "error": type(exc).__name__}


def run_program(prog: str) -> dict:
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            exec(prog, {})  # noqa: S102 - generator only, trusted snippets
        return {"program": prog, "stdout": buf.getvalue()}
    except Exception as exc:  # noqa: BLE001
        return {"program": prog, "error": type(exc).__name__}


def main() -> None:
    cells = [evaluate(c) for c in EXPRESSIONS] + [run_program(p) for p in PROGRAMS]
    manifest = {
        "python_version": ".".join(str(n) for n in __import__("sys").version_info[:3]),
        "cells": cells,
    }
    out = Path(__file__).with_name("numeric.json")
    out.write_text(json.dumps(manifest, indent=2) + "\n")
    ok = sum(1 for c in cells if "result" in c or "stdout" in c)
    print(f"wrote {out}: {len(cells)} cells ({ok} produce a value/output in CPython)")


if __name__ == "__main__":
    main()
