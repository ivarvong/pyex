"""Statement-level sweep: item/slice assignment, del, augmented
assignment, and unpacking × container types.

Run with `python3 test/fixtures/sweeps/mutate_gen.py`. Each cell is a full
program executed by CPython with stdout captured; the Elixir side
(`Pyex.Test.Sweep.check!("mutate")`) runs the same program through pyex
and asserts the printed output (or the raised exception) matches.

These are statements, not expressions, so they exercise the half of
Python the expression sweeps can't reach.
"""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path

PROGRAMS = [
    # --- item assignment ---
    "x = [10, 20, 30]\nx[0] = 99\nprint(x)",
    "x = [10, 20, 30]\nx[-1] = 99\nprint(x)",
    "x = [10, 20, 30]\nx[5] = 99\nprint(x)",  # IndexError
    "d = {'a': 1}\nd['b'] = 2\nprint(sorted(d.items()))",
    "d = {'a': 1}\nd['a'] = 9\nprint(d)",
    "b = bytearray(b'abc')\nb[0] = 120\nprint(b)",
    "b = bytearray(b'abc')\nb[0] = 300\nprint(b)",  # ValueError
    "s = 'ab'\ns[0] = 'x'\nprint(s)",  # TypeError (str immutable)
    "t = (1, 2)\nt[0] = 9\nprint(t)",  # TypeError (tuple immutable)
    # --- slice assignment ---
    "x = [1, 2, 3, 4]\nx[1:3] = [8, 9]\nprint(x)",
    "x = [1, 2, 3, 4]\nx[1:3] = [8, 9, 10]\nprint(x)",  # grow
    "x = [1, 2, 3, 4]\nx[1:3] = []\nprint(x)",  # shrink
    "x = [1, 2, 3, 4]\nx[:] = [7]\nprint(x)",  # replace all
    "x = [1, 2, 3, 4]\nx[::2] = [7, 8]\nprint(x)",  # extended slice
    "x = [1, 2, 3, 4]\nx[::2] = [7]\nprint(x)",  # ValueError (size mismatch)
    "b = bytearray(b'abcd')\nb[1:3] = b'XY'\nprint(b)",
    # --- del ---
    "x = [1, 2, 3]\ndel x[1]\nprint(x)",
    "x = [1, 2, 3]\ndel x[-1]\nprint(x)",
    "x = [1, 2, 3, 4]\ndel x[1:3]\nprint(x)",
    "d = {'a': 1, 'b': 2}\ndel d['a']\nprint(sorted(d.items()))",
    "d = {'a': 1}\ndel d['z']\nprint(d)",  # KeyError
    "b = bytearray(b'abc')\ndel b[0]\nprint(b)",
    # --- nested mutation (shared-reference semantics) ---
    "x = [[1, 2]]\nx[0][1] = 99\nprint(x)",
    "t = ([1, 2],)\nt[0][1] = 99\nprint(t)",  # mutates the inner list
    "d = {'k': [1, 2]}\nd['k'][0] = 9\nprint(d)",
    "x = [[1, 2], [3, 4]]\nx[0].append(9)\nprint(x)",
    # --- augmented item assignment ---
    "x = [1, 2]\nx[0] += 10\nprint(x)",
    "x = [2, 3]\nx[1] *= 4\nprint(x)",
    "d = {'a': 1}\nd['a'] += 5\nprint(d)",
    "x = [[1], [2]]\nx[0] += [9]\nprint(x)",
    # --- unpacking ---
    "a, b = [1, 2]\nprint(a, b)",
    "a, b = (1, 2)\nprint(a, b)",
    "a, b, c = 'xyz'\nprint(a, b, c)",
    "a, *b = [1, 2, 3, 4]\nprint(a, b)",
    "*a, b = [1, 2, 3, 4]\nprint(a, b)",
    "a, *b, c = [1, 2, 3, 4]\nprint(a, b, c)",
    "(a, b), c = [(1, 2), 3]\nprint(a, b, c)",
    "a, b = [1, 2, 3]\nprint(a)",  # ValueError (too many)
    "a, b, c = [1, 2]\nprint(a)",  # ValueError (too few)
    "a, b = 5\nprint(a)",  # TypeError (not iterable)
    "x = [1, 2, 3]\nx[0], x[2] = x[2], x[0]\nprint(x)",  # swap via subscript targets
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
    out = Path(__file__).with_name("mutate.json")
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
