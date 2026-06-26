"""Statement sweep: control flow — loop/else, break/continue,
comprehension scoping, with, ternary/short-circuit."""
import contextlib, io, json
from pathlib import Path
PROGS = [
    # for/while else
    "for i in range(3):\n    pass\nelse:\n    print('else')",
    "for i in range(3):\n    if i == 1:\n        break\nelse:\n    print('else')",
    "n = 0\nwhile n < 3:\n    n += 1\nelse:\n    print('while-else', n)",
    "n = 0\nwhile n < 3:\n    n += 1\n    if n == 2:\n        break\nelse:\n    print('no')",
    # break/continue
    "out = []\nfor i in range(5):\n    if i == 3:\n        break\n    out.append(i)\nprint(out)",
    "out = []\nfor i in range(5):\n    if i % 2 == 0:\n        continue\n    out.append(i)\nprint(out)",
    # nested loops + break only inner
    "out = []\nfor i in range(3):\n    for j in range(3):\n        if j == 1:\n            break\n        out.append((i, j))\nprint(out)",
    # loop variable leaks (for) but not comprehension
    "for i in range(3):\n    pass\nprint(i)",
    "x = [i for i in range(3)]\ntry:\n    print(i)\nexcept NameError:\n    print('no leak')",
    # comprehension forms
    "print([x*x for x in range(4)])",
    "print([x for x in range(6) if x % 2 == 0])",
    "print({k: v for k, v in [('a', 1), ('b', 2)]})",
    "print({x % 3 for x in range(7)})",
    "print(sorted(x + y for x in [1, 2] for y in [10, 20]))",
    "print([[r * c for c in range(3)] for r in range(3)])",
    # nested comprehension scoping
    "print([y for y in [x for x in range(3)]])",
    # with (contextlib.suppress)
    "import contextlib\nwith contextlib.suppress(ValueError):\n    raise ValueError\nprint('after')",
    "from contextlib import suppress\ntotal = 0\nwith suppress(ZeroDivisionError):\n    total = 1 / 0\nprint(total)",
    # ternary / short-circuit
    "print('yes' if 5 > 3 else 'no')",
    "print(0 or 'x', 1 and 'y', None or [])",
    "print([] and 1, [1] or 2)",
    # for-else with continue (else still runs)
    "for i in range(3):\n    if i == 5:\n        break\n    continue\nelse:\n    print('ran')",
    # while with break/else
    "i = 0\nwhile True:\n    i += 1\n    if i >= 3:\n        break\nprint(i)",
    # enumerate / zip in loops
    "for idx, ch in enumerate('ab'):\n    print(idx, ch)",
    "for a, b in zip([1, 2], ['x', 'y']):\n    print(a, b)",
    # pass / multiple targets
    "a = b = c = 5\nprint(a, b, c)",
    "x, y = 1, 2\nx, y = y, x\nprint(x, y)",
]
def run(prog):
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            exec(prog, {})
        return {"program": prog, "stdout": buf.getvalue()}
    except Exception as e:
        return {"program": prog, "error": type(e).__name__}
cells = [run(p) for p in PROGS]
Path(__file__).with_name("control.json").write_text(
    json.dumps({"python_version": ".".join(map(str,__import__("sys").version_info[:3])), "cells": cells}, indent=2)+"\n")
print(f"control: {len(cells)} cells")
