"""Statement-level sweep: function-call binding semantics.

Run with `python3 test/fixtures/sweeps/calls_gen.py`. Each cell is a full
program executed by CPython with stdout captured; the Elixir side
(`Pyex.Test.Sweep.check!("calls")`) runs the same program through pyex
and asserts the printed output (or the raised exception) matches.

This exercises argument binding — the rules that map call-site arguments
onto a function's parameters — which the expression sweeps never touch:
defaults, *args/**kwargs, keyword-only, positional-only, call-site
unpacking, default-value mutation, and the full family of binding errors.
"""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path

PROGRAMS = [
    # --- positional + defaults ---
    "def f(a, b): return a - b\nprint(f(5, 2))",
    "def f(a, b=10): return a - b\nprint(f(5))",
    "def f(a, b=10): return a - b\nprint(f(5, 2))",
    "def f(a, b=2, c=3): return (a, b, c)\nprint(f(1))",
    "def f(a, b=2, c=3): return (a, b, c)\nprint(f(1, c=9))",
    # --- keyword arguments ---
    "def f(a, b, c): return (a, b, c)\nprint(f(c=3, a=1, b=2))",
    "def f(a, b): return (a, b)\nprint(f(b=2, a=1))",
    "def f(a, b): return (a, b)\nprint(f(1, b=2))",
    # --- *args ---
    "def f(*args): return args\nprint(f())",
    "def f(*args): return args\nprint(f(1, 2, 3))",
    "def f(a, *args): return (a, args)\nprint(f(1, 2, 3))",
    "def f(a, b=5, *args): return (a, b, args)\nprint(f(1, 2, 3, 4))",
    # --- **kwargs ---
    "def f(**kw): return sorted(kw.items())\nprint(f(x=1, y=2))",
    "def f(a, **kw): return (a, sorted(kw.items()))\nprint(f(1, x=2, y=3))",
    "def f(**kw): return sorted(kw.items())\nprint(f())",
    # --- *args + **kwargs together ---
    "def f(a, *args, **kw): return (a, args, sorted(kw.items()))\nprint(f(1, 2, 3, x=4))",
    "def f(*args, **kw): return (args, sorted(kw.items()))\nprint(f(1, 2, k=3))",
    # --- keyword-only (after *) ---
    "def f(a, *, b): return (a, b)\nprint(f(1, b=2))",
    "def f(a, *, b=9): return (a, b)\nprint(f(1))",
    "def f(*args, key): return (args, key)\nprint(f(1, 2, key=3))",
    "def f(a, *, b): return (a, b)\nprint(f(1, 2))",  # TypeError: b is keyword-only
    "def f(a, *, b): return (a, b)\nprint(f(1))",  # TypeError: missing b
    # --- positional-only (before /) ---
    "def f(a, b, /): return (a, b)\nprint(f(1, 2))",
    "def f(a, b, /): return (a, b)\nprint(f(1, b=2))",  # TypeError: b is positional-only
    "def f(a, /, b): return (a, b)\nprint(f(1, b=2))",
    "def f(a, /, b): return (a, b)\nprint(f(1, 2))",
    # --- call-site unpacking ---
    "def f(a, b, c): return (a, b, c)\nargs = [1, 2, 3]\nprint(f(*args))",
    "def f(a, b, c): return (a, b, c)\nprint(f(1, *[2, 3]))",
    "def f(a, b, c): return (a, b, c)\nd = {'a': 1, 'b': 2, 'c': 3}\nprint(f(**d))",
    "def f(a, b, c): return (a, b, c)\nprint(f(1, **{'b': 2, 'c': 3}))",
    "def f(*args, **kw): return (args, sorted(kw.items()))\nprint(f(*[1, 2], **{'x': 3}))",
    # --- binding errors ---
    "def f(a, b): return a\nprint(f(1))",  # TypeError: missing b
    "def f(a, b): return a\nprint(f(1, 2, 3))",  # TypeError: too many positional
    "def f(a): return a\nprint(f(1, a=2))",  # TypeError: duplicate value for a
    "def f(a): return a\nprint(f(1, x=2))",  # TypeError: unexpected kwarg x
    "def f(): return 1\nprint(f(1))",  # TypeError: takes 0 positional
    # --- default-value mutation (shared mutable default) ---
    "def f(x=[]):\n    x.append(1)\n    return x\nprint(f())\nprint(f())",
    "def f(acc={}):\n    acc[len(acc)] = len(acc)\n    return sorted(acc.items())\nprint(f())\nprint(f())",
    # --- defaults evaluated once, at def time ---
    "n = 5\ndef f(x=n): return x\nn = 99\nprint(f())",
    # --- lambda binding ---
    "g = lambda a, b=3: a * b\nprint(g(4))\nprint(g(4, 2))",
    "g = lambda *a, **k: (a, sorted(k.items()))\nprint(g(1, 2, x=3))",
    # --- nested / passthrough ---
    "def f(a, b, c): return a + b + c\ndef g(*args): return f(*args)\nprint(g(1, 2, 3))",
    "def f(**kw): return sorted(kw.items())\ndef g(**kw): return f(**kw)\nprint(g(p=1, q=2))",
    # --- builtins honor keyword binding ---
    "print(sorted([3, 1, 2], reverse=True))",
    "print(sorted(['bb', 'a', 'ccc'], key=len))",
    "print(dict(a=1, b=2))",
    "print(max([1, 2], key=lambda x: -x))",
    "print(int('11', base=2))",
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
    out = Path(__file__).with_name("calls.json")
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
