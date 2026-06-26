"""Statement sweep: exception raising/catching across the hierarchy,
plus the exception type each builtin operation raises."""
import contextlib, io, json
from pathlib import Path

RAISED = ["ValueError","TypeError","KeyError","IndexError","ZeroDivisionError",
          "AttributeError","RuntimeError","OverflowError","StopIteration","NameError"]
EXCEPT = ["ValueError","TypeError","LookupError","ArithmeticError","Exception",
          "BaseException","RuntimeError","KeyError"]

# raise R / except E (tests subclass catching across the hierarchy)
MATRIX = [f"try:\n    raise {r}('m')\nexcept {e}:\n    print('caught')"
          for r in RAISED for e in EXCEPT]

# operations that raise, caught with `as e`, printing type + message
BUILTIN = [
    "1 / 0", "1 // 0", "1 % 0", "[][0]", "(1, 2)[5]", "'ab'[9]", "{}['x']",
    "{'a':1}['z']", "int('x')", "int('1.5')", "float('x')", "[].pop()",
    "[1,2].index(9)", "'abc'.index('z')", "len(5)", "abs('x')", "next(iter([]))",
    "[1,2,3][1:2][5]", "{1,2} | [3]", "'a' + 1", "[] + ()", "10 ** -1 % 0",
    "min([])", "max([])", "sorted(5)", "'x'.encode().decode('utf-99')",
]
BUILTIN_PROGS = [f"try:\n    {op}\nexcept Exception as e:\n    print(type(e).__name__)"
                 for op in BUILTIN]

# flow: else / finally / multiple except / tuple except / re-raise / bare
FLOW = [
    "try:\n    x = 1\nexcept Exception:\n    print('e')\nelse:\n    print('else')",
    "try:\n    raise ValueError\nexcept Exception:\n    print('e')\nelse:\n    print('else')",
    "try:\n    x = 1\nfinally:\n    print('finally')",
    "try:\n    raise KeyError('k')\nexcept (TypeError, KeyError) as e:\n    print('tuple', type(e).__name__)",
    "try:\n    raise ValueError('v')\nexcept TypeError:\n    print('T')\nexcept ValueError:\n    print('V')",
    "try:\n    raise IndexError\nexcept LookupError:\n    print('lookup')\nfinally:\n    print('fin')",
    "try:\n    try:\n        raise ValueError('inner')\n    finally:\n        print('inner-fin')\nexcept ValueError as e:\n    print('outer', e)",
    "def f():\n    raise RuntimeError('boom')\ntry:\n    f()\nexcept RuntimeError as e:\n    print(e)",
    "try:\n    raise ValueError('msg')\nexcept ValueError as e:\n    print(str(e), repr(e))",
    "try:\n    raise Exception('a', 'b')\nexcept Exception as e:\n    print(e.args)",
    "for i in range(3):\n    try:\n        if i == 1:\n            raise ValueError\n    except ValueError:\n        print('caught', i)",
]

def run(prog):
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            exec(prog, {})
        return {"program": prog, "stdout": buf.getvalue()}
    except Exception as e:
        return {"program": prog, "error": type(e).__name__}

cells = [run(p) for p in MATRIX + BUILTIN_PROGS + FLOW]
Path(__file__).with_name("exc.json").write_text(
    json.dumps({"python_version": ".".join(map(str,__import__("sys").version_info[:3])), "cells": cells}, indent=2)+"\n")
print(f"exc: {len(cells)} cells")
