"""Statement-level sweep: class / OOP semantics.

Run with `python3 test/fixtures/sweeps/oop_gen.py`. Each cell is a full
program executed by CPython with stdout captured; the Elixir side
(`Pyex.Test.Sweep.check!("oop")`) runs the same program through pyex
and asserts the printed output (or the raised exception) matches.

This exercises the object model: __init__/__new__, inheritance and
method resolution (including diamond MRO and super()), classmethod /
staticmethod / property, class-vs-instance attributes, the comparison /
hash / call dunders, and name mangling.
"""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path

PROGRAMS = [
    # --- basics ---
    "class A:\n    def __init__(self, x):\n        self.x = x\n    def double(self):\n        return self.x * 2\nprint(A(5).double())",
    "class A:\n    pass\na = A()\na.x = 1\na.y = 2\nprint(a.x + a.y)",
    # --- class vs instance attributes ---
    "class A:\n    count = 0\na = A()\nb = A()\nA.count = 9\nprint(a.count, b.count)",
    "class A:\n    items = []\na = A()\nb = A()\na.items.append(1)\nprint(b.items)",  # shared class attr
    "class A:\n    x = 1\na = A()\na.x = 99\nprint(a.x, A.x)",  # shadowing
    # --- class identity: mutation visible to existing instances ---
    "class A:\n    count = 0\na = A()\nA.count = 9\nprint(a.count)",  # post-construction class-attr mutation
    "class A:\n    def __init__(self): self.v = 1\na = A()\nA.bonus = lambda self: self.v + 10\nprint(a.bonus())",  # monkeypatch method
    "class A:\n    tag = 'a'\nclass B(A):\n    pass\nb = B()\nA.tag = 'z'\nprint(b.tag)",  # parent mutation seen via subclass instance
    # --- inheritance + override ---
    "class A:\n    def f(self): return 'A'\nclass B(A):\n    def f(self): return 'B'\nprint(B().f(), A().f())",
    "class A:\n    def f(self): return 'A'\nclass B(A):\n    pass\nprint(B().f())",  # inherited
    "class A:\n    def __init__(self):\n        self.x = 1\nclass B(A):\n    def __init__(self):\n        super().__init__()\n        self.y = 2\nb = B()\nprint(b.x, b.y)",
    "class A:\n    def f(self): return 1\nclass B(A):\n    def f(self): return super().f() + 10\nprint(B().f())",
    # --- diamond / MRO ---
    "class A:\n    def f(self): return 'A'\nclass B(A):\n    def f(self): return 'B' + super().f()\nclass C(A):\n    def f(self): return 'C' + super().f()\nclass D(B, C):\n    def f(self): return 'D' + super().f()\nprint(D().f())",
    "class A: pass\nclass B(A): pass\nclass C(A): pass\nclass D(B, C): pass\nprint([c.__name__ for c in D.__mro__])",
    # --- classmethod / staticmethod ---
    "class A:\n    @staticmethod\n    def add(a, b): return a + b\nprint(A.add(2, 3))",
    "class A:\n    name = 'A'\n    @classmethod\n    def who(cls): return cls.name\nclass B(A):\n    name = 'B'\nprint(A.who(), B.who())",
    "class A:\n    @classmethod\n    def make(cls): return cls()\n    def __init__(self): self.v = 7\nprint(A.make().v)",
    # --- property ---
    "class A:\n    def __init__(self, r): self._r = r\n    @property\n    def area(self): return self._r * self._r\nprint(A(4).area)",
    "class A:\n    def __init__(self): self._x = 0\n    @property\n    def x(self): return self._x\n    @x.setter\n    def x(self, v): self._x = v * 2\na = A()\na.x = 5\nprint(a.x)",
    # --- __new__ ---
    "class A:\n    def __new__(cls):\n        obj = super().__new__(cls)\n        obj.tag = 'new'\n        return obj\nprint(A().tag)",
    # --- isinstance / issubclass ---
    "class A: pass\nclass B(A): pass\nprint(isinstance(B(), A), isinstance(A(), B))",
    "class A: pass\nclass B(A): pass\nprint(issubclass(B, A), issubclass(A, B))",
    "class A: pass\nprint(isinstance(A(), object))",
    # --- comparison / hash / equality dunders ---
    "class P:\n    def __init__(self, v): self.v = v\n    def __eq__(self, o): return self.v == o.v\nprint(P(1) == P(1), P(1) == P(2))",
    "class P:\n    def __init__(self, v): self.v = v\n    def __lt__(self, o): return self.v < o.v\nprint([p.v for p in sorted([P(3), P(1), P(2)])])",
    "class P:\n    def __init__(self, v): self.v = v\n    def __hash__(self): return self.v % 2\n    def __eq__(self, o): return self.v == o.v\nprint(len({P(1), P(1), P(2)}))",
    # --- __repr__ / __str__ ---
    "class A:\n    def __repr__(self): return 'A!'\nprint(repr(A()), str(A()))",
    "class A:\n    def __str__(self): return 'as-str'\nprint(str(A()))",
    "class A:\n    def __repr__(self): return 'rep'\nprint([A(), A()])",  # list uses repr
    # --- __call__ ---
    "class Adder:\n    def __init__(self, n): self.n = n\n    def __call__(self, x): return x + self.n\nadd5 = Adder(5)\nprint(add5(10))",
    # --- __len__ / __getitem__ / __contains__ ---
    "class Box:\n    def __init__(self, items): self.items = items\n    def __len__(self): return len(self.items)\n    def __getitem__(self, i): return self.items[i]\nb = Box([10, 20, 30])\nprint(len(b), b[1])",
    "class Box:\n    def __contains__(self, x): return x == 42\nprint(42 in Box(), 1 in Box())",
    # --- name mangling ---
    "class A:\n    def __init__(self): self.__secret = 7\n    def get(self): return self.__secret\nprint(A().get())",
    # --- AttributeError ---
    "class A: pass\nprint(A().missing)",  # AttributeError
    # --- bound vs unbound method dispatch ---
    "class A:\n    def f(self, x): return x + 1\na = A()\ng = a.f\nprint(g(10))",
    "class A:\n    def f(self, x): return x + 1\nprint(A.f(A(), 10))",
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
    out = Path(__file__).with_name("oop.json")
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
