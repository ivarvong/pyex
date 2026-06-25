"""Product-space sweep generator: type constructors x input values.

Run with `python3 test/fixtures/sweeps/ctor_gen.py` to regenerate
`ctor.json`. Crosses each builtin type constructor with a diverse set of
input values and records what CPython does (the repr, or the exception
class). `Pyex.Test.Sweep.check!("ctor")` replays each cell through pyex.

Constructors whose repr is order-defined (set/frozenset/dict) wrap their
result in `sorted(...)` so the comparison is implementation-stable;
inputs are kept ordered for the same reason. A handful of multi-argument
forms (`int(s, base)`, `bytes(s, enc)`, ...) are appended explicitly.
"""

from __future__ import annotations

import json
from pathlib import Path

# label => template producing a deterministic repr for ctor({arg}).
CONSTRUCTORS = {
    "int": "int({arg})",
    "float": "float({arg})",
    "str": "str({arg})",
    "bool": "bool({arg})",
    "bytes": "bytes({arg})",
    "list": "list({arg})",
    "tuple": "tuple({arg})",
    "complex": "complex({arg})",
    "set": "sorted(set({arg}))",
    "frozenset": "sorted(frozenset({arg}))",
    "dict": "sorted(dict({arg}).items())",
}

# Ordered / scalar inputs only (no multi-element set/dict literals, whose
# iteration order into list()/tuple() would be implementation-defined).
INPUTS = [
    "42", "-5", "0", "3.14", "1e3", "3.0", "True", "False", "None", "1j",
    "'42'", "'  10  '", "'0x1f'", "'1_000'", "'3.14'", "'abc'", "''", "'café'",
    "[1, 2, 3]", "[]", "['a', 'b']", "[(1, 2), (3, 4)]",
    "(1, 2)", "()", "b'ab'", "b''", "range(3)", "{1: 2}", "bytearray(b'xy')",
]

# Multi-argument / keyword forms worth pinning explicitly.
EXTRAS = [
    "int('1f', 16)",
    "int('101', 2)",
    "int('777', 8)",
    "int('42', 10)",
    "int('z', 36)",
    "int(3.99)",
    "int(-3.99)",
    "float('inf')",
    "float('-inf')",
    "float('nan')",
    "str(b'ab', 'utf-8')",
    "bytes('abc', 'utf-8')",
    "bytes(3)",
    "bool()",
    "int()",
    "str()",
    "list()",
    "dict()",
    "dict([('a', 1), ('b', 2)])",
    "complex('1+2j')",
    "complex(1, 2)",
]


def evaluate(code: str) -> dict:
    try:
        return {"code": code, "result": repr(eval(code))}  # noqa: S307 - generator only
    except Exception as exc:  # noqa: BLE001
        return {"code": code, "error": type(exc).__name__}


def main() -> None:
    cells = [
        evaluate(template.replace("{arg}", arg))
        for template in CONSTRUCTORS.values()
        for arg in INPUTS
    ]
    cells += [evaluate(code) for code in EXTRAS]

    manifest = {
        "python_version": ".".join(str(n) for n in __import__("sys").version_info[:3]),
        "cells": cells,
    }
    out = Path(__file__).with_name("ctor.json")
    out.write_text(json.dumps(manifest, indent=2) + "\n")
    ok = sum(1 for c in cells if "result" in c)
    print(f"wrote {out}: {len(cells)} cells ({ok} produce a value in CPython)")


if __name__ == "__main__":
    main()
