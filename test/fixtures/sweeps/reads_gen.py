"""Statement-level sweep: comprehensions and read-side slicing.

Run with `python3 test/fixtures/sweeps/reads_gen.py`. Each cell is a full
program executed by CPython with stdout captured; the Elixir side
(`Pyex.Test.Sweep.check!("reads")`) runs the same program through pyex
and asserts the printed output (or the raised exception) matches.

Two domains the value/binop sweeps don't reach:
  - comprehensions: list/set/dict/generator, multiple `for` clauses,
    `if` filters, nesting, and scope-leak semantics.
  - slice *reads* (`x[a:b:c]`) across every sliceable type, with negative
    indices, omitted bounds, negative steps, and out-of-range clamping.
"""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path

PROGRAMS = [
    # --- list comprehensions ---
    "print([x * x for x in range(5)])",
    "print([x for x in range(10) if x % 2 == 0])",
    "print([x for x in range(20) if x % 2 == 0 if x % 3 == 0])",
    "print([(x, y) for x in range(2) for y in range(2)])",
    "print([x for row in [[1, 2], [3, 4]] for x in row])",  # flatten
    "print([[y for y in range(x)] for x in range(4)])",  # nested
    "print([x if x % 2 == 0 else -x for x in range(5)])",  # ternary in body
    # --- set / dict / generator comprehensions ---
    "print(sorted({x % 3 for x in range(10)}))",
    "print(sorted({x: x * x for x in range(4)}.items()))",
    "print(sum(x * x for x in range(5)))",  # generator expression
    "print(list(x for x in range(3)))",
    "print({k: v for k, v in [('a', 1), ('b', 2)]})",
    # --- comprehension scope ---
    "x = 99\n[x for x in range(3)]\nprint(x)",  # loop var does NOT leak
    "vals = [1, 2, 3]\nprint([v * 2 for v in vals])\nprint(vals)",
    "print([i for i in range(3)] + [i + 10 for i in range(3)])",
    # --- comprehension over strings / dicts ---
    "print([c.upper() for c in 'abc'])",
    "d = {'a': 1, 'b': 2}\nprint(sorted(k for k in d))",
    "d = {'a': 1, 'b': 2}\nprint(sorted(d.values()))",
    # --- walrus in comprehension ---
    "print([y for x in range(5) if (y := x * 2) > 4])",
    # --- slice reads: list ---
    "print([0, 1, 2, 3, 4][1:3])",
    "print([0, 1, 2, 3, 4][:2])",
    "print([0, 1, 2, 3, 4][2:])",
    "print([0, 1, 2, 3, 4][:])",
    "print([0, 1, 2, 3, 4][-2:])",
    "print([0, 1, 2, 3, 4][:-1])",
    "print([0, 1, 2, 3, 4][::2])",
    "print([0, 1, 2, 3, 4][::-1])",
    "print([0, 1, 2, 3, 4][4:1:-1])",
    "print([0, 1, 2, 3, 4][1:100])",  # over-range clamps
    "print([0, 1, 2, 3, 4][3:1])",  # empty
    "print([0, 1, 2, 3, 4][-100:100])",
    "print([0, 1, 2, 3, 4][1:4:2])",
    # --- slice reads: str ---
    "print('abcdef'[1:4])",
    "print('abcdef'[::-1])",
    "print('abcdef'[-3:])",
    "print('abcdef'[::2])",
    "print('abcdef'[10:])",  # empty
    # --- slice reads: tuple ---
    "print((0, 1, 2, 3, 4)[1:3])",
    "print((0, 1, 2, 3, 4)[::-1])",
    # --- slice reads: bytes / bytearray ---
    "print(b'abcdef'[1:4])",
    "print(b'abcdef'[::-1])",
    "print(bytearray(b'abcdef')[2:])",
    # --- slice reads: range ---
    "print(list(range(10)[2:8:2]))",
    "print(list(range(10)[::-1]))",
    # --- index reads with negatives / errors ---
    "print([10, 20, 30][-1])",
    "print('hello'[-2])",
    "print((1, 2, 3)[-3])",
    "print([1, 2, 3][5])",  # IndexError
    "print('ab'[9])",  # IndexError
    # --- slice with explicit slice() object ---
    "print([0, 1, 2, 3, 4][slice(1, 4)])",
    "print([0, 1, 2, 3, 4][slice(None, None, 2)])",
]


def run(prog: str) -> dict:
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            exec(prog, {})  # noqa: S102 - generator only, trusted snippets
        return {"program": prog, "stdout": buf.getvalue()}
    except Exception as exc:  # noqa: BLE001
        return {"program": prog, "error": type(exc).__name__}


def main() -> None:
    cells = [run(p) for p in PROGRAMS]
    out = Path(__file__).with_name("reads.json")
    out.write_text(
        json.dumps(
            {
                "python_version": ".".join(str(n) for n in __import__("sys").version_info[:3]),
                "cells": cells,
            },
            indent=2,
        )
        + "\n"
    )
    ok = sum(1 for c in cells if "stdout" in c)
    print(f"wrote {out}: {len(cells)} cells ({ok} produce output in CPython)")


if __name__ == "__main__":
    main()
