"""Product-space sweep generator: binary operators x operand-type pairs.

Run with `python3 test/fixtures/sweeps/binop_gen.py` to regenerate
`binop.json`. Crosses every binary operator with every ordered pair of
operand types and records what CPython does for each cell (the repr of
the value, or the exception class). The Elixir side
(`Pyex.Test.Sweep.check!("binop")`) replays each cell through pyex and
asserts it matches — both when CPython produces a value and when it
raises.

`%` (string/bytes formatting) and `@` (matmul) are intentionally left to
their own sweeps: they are mini-languages, not arithmetic on a value.
"""

from __future__ import annotations

import json
from pathlib import Path

OPERATORS = [
    "+", "-", "*", "/", "//", "**",
    "==", "!=", "<", "<=", ">", ">=",
    "&", "|", "^", "<<", ">>",
    "in",
]

# label => a literal of that type
OPERANDS = {
    "int": "3",
    "float": "2.5",
    "bool": "True",
    "str": "'ab'",
    "list": "[1, 2]",
    "tuple": "(1, 2)",
    "set": "{1, 2}",
    "frozenset": "frozenset({1, 2})",
    "dict": "{1: 2}",
    "bytes": "b'ab'",
    "none": "None",
}


def evaluate(code: str) -> dict:
    try:
        return {"code": code, "result": repr(eval(code))}  # noqa: S307 - generator only
    except Exception as exc:  # noqa: BLE001
        return {"code": code, "error": type(exc).__name__}


def main() -> None:
    cells = [
        evaluate(f"({lhs}) {op} ({rhs})")
        for op in OPERATORS
        for lhs in OPERANDS.values()
        for rhs in OPERANDS.values()
    ]
    manifest = {
        "python_version": ".".join(str(n) for n in __import__("sys").version_info[:3]),
        "cells": cells,
    }
    out = Path(__file__).with_name("binop.json")
    out.write_text(json.dumps(manifest, indent=2) + "\n")
    ok = sum(1 for c in cells if "result" in c)
    print(f"wrote {out}: {len(cells)} cells ({ok} produce a value in CPython)")


if __name__ == "__main__":
    main()
