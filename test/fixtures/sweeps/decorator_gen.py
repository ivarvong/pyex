"""Statement-level sweep: decorators.

Run with `python3 test/fixtures/sweeps/decorator_gen.py`. Each cell is a
full program whose stdout (or raised exception) is compared to CPython by
`Pyex.Test.Sweep.check!("decorator")`.

Covers user-defined decorators (simple, stacked, factories with args),
the metadata-preserving `functools.wraps`, class decorators, the built-in
method decorators (`@property` get/set/delete, `@classmethod`,
`@staticmethod`), `functools.lru_cache`, and the degenerate cases
(decorator that mutates or replaces its target).
"""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path

PROGRAMS = [
    # --- user-defined: simple ---
    "def deco(f):\n    def w(*a, **k):\n        return f(*a, **k) + 1\n    return w\n@deco\ndef add(a, b):\n    return a + b\nprint(add(2, 3))",
    # --- stacked (application order is bottom-up) ---
    "def d1(f):\n    def w():\n        return f() + 'A'\n    return w\ndef d2(f):\n    def w():\n        return f() + 'B'\n    return w\n@d1\n@d2\ndef g():\n    return 'x'\nprint(g())",
    # --- factory (decorator with arguments) ---
    "def repeat(n):\n    def deco(f):\n        def w(*a):\n            return [f(*a) for _ in range(n)]\n        return w\n    return deco\n@repeat(3)\ndef hi():\n    return 'hi'\nprint(hi())",
    "def prefix(p):\n    def deco(f):\n        def w(s):\n            return p + f(s)\n        return w\n    return deco\n@prefix('>> ')\ndef shout(s):\n    return s.upper()\nprint(shout('go'))",
    # --- functools.wraps preserves metadata ---
    "import functools\ndef deco(f):\n    @functools.wraps(f)\n    def w(*a, **k):\n        return f(*a, **k)\n    return w\n@deco\ndef foo():\n    'docstring'\n    return 1\nprint(foo.__name__, foo.__doc__)",
    "import functools\ndef deco(f):\n    @functools.wraps(f)\n    def w(*a, **k):\n        return f(*a, **k)\n    return w\n@deco\ndef foo():\n    return 1\nprint(foo.__wrapped__.__name__)",
    "import functools\ndef deco(f):\n    @functools.wraps(f)\n    def w(*a, **k):\n        return f(*a, **k)\n    return w\n@deco\ndef foo():\n    return 1\nprint(foo())",
    # --- decorator that mutates the function (attaches an attribute) ---
    "def tag(f):\n    f.registered = True\n    return f\n@tag\ndef foo():\n    return 1\nprint(foo.registered, foo())",
    # --- decorator that replaces the target entirely ---
    "def const(f):\n    return 42\n@const\ndef foo():\n    return 1\nprint(foo)",
    # --- class decorator ---
    "def addattr(cls):\n    cls.tag = 'tagged'\n    return cls\n@addattr\nclass C:\n    pass\nprint(C.tag)",
    "def singleton(cls):\n    inst = cls()\n    return inst\n@singleton\nclass Config:\n    value = 7\nprint(Config.value)",
    # --- @property: getter, setter, deleter ---
    "class C:\n    def __init__(self):\n        self._x = 0\n    @property\n    def x(self):\n        return self._x\n    @x.setter\n    def x(self, v):\n        self._x = v * 2\nc = C()\nc.x = 5\nprint(c.x)",
    "class C:\n    def __init__(self):\n        self._x = 1\n    @property\n    def x(self):\n        return self._x\n    @x.deleter\n    def x(self):\n        self._x = None\nc = C()\ndel c.x\nprint(c.x)",
    "class Circle:\n    def __init__(self, r):\n        self.r = r\n    @property\n    def area(self):\n        return 3 * self.r * self.r\nprint(Circle(2).area)",
    "class C:\n    @property\n    def x(self):\n        return 1\nc = C()\ntry:\n    c.x = 5\nexcept AttributeError:\n    print('no setter')",
    # --- @classmethod (cls binding through inheritance) ---
    "class A:\n    name = 'A'\n    @classmethod\n    def who(cls):\n        return cls.name\nclass B(A):\n    name = 'B'\nprint(A.who(), B.who())",
    "class C:\n    @classmethod\n    def make(cls):\n        return cls()\n    def __init__(self):\n        self.v = 9\nprint(C.make().v)",
    # --- @staticmethod ---
    "class C:\n    @staticmethod\n    def add(a, b):\n        return a + b\nprint(C.add(2, 3))",
    "class C:\n    @staticmethod\n    def add(a, b):\n        return a + b\nprint(C().add(4, 5))",
    # --- functools.lru_cache ---
    "import functools\n@functools.lru_cache(maxsize=None)\ndef fib(n):\n    return n if n < 2 else fib(n - 1) + fib(n - 2)\nprint(fib(15))",
    "import functools\n@functools.lru_cache\ndef sq(n):\n    return n * n\nprint(sq(6), sq(6))",
    # --- factory + stacking combined ---
    "def tag(label):\n    def deco(f):\n        def w(*a):\n            return label + ':' + f(*a)\n        return w\n    return deco\n@tag('outer')\n@tag('inner')\ndef g():\n    return 'v'\nprint(g())",
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
    out = Path(__file__).with_name("decorator.json")
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
