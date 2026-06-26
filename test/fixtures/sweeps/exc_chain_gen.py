"""Statement-level sweep: exception chaining (PEP 3134).

Run with `python3 test/fixtures/sweeps/exc_chain_gen.py`. Each cell is a
full program whose stdout (or raised exception) is compared to CPython by
`Pyex.Test.Sweep.check!("exc_chain")`.

Covers what the raise×except matrix sweep doesn't: `raise ... from`
(explicit `__cause__`), implicit `__context__` when an exception is raised
while handling another, `raise ... from None` suppression
(`__suppress_context__`), the default values of all three dunders, and
`.args`.
"""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path

PROGRAMS = [
    # --- explicit cause: raise ... from ---
    "try:\n    raise ValueError('v') from KeyError('k')\nexcept ValueError as e:\n    print(type(e.__cause__).__name__, e.__cause__)",
    "try:\n    raise RuntimeError('r') from TypeError('t')\nexcept RuntimeError as e:\n    print(repr(e.__cause__))",
    "k = KeyError('boom')\ntry:\n    raise ValueError('v') from k\nexcept ValueError as e:\n    print(e.__cause__ is k)",
    # --- raise ... from sets __suppress_context__ ---
    "try:\n    try:\n        raise KeyError('k')\n    except KeyError:\n        raise ValueError('v') from TypeError('t')\nexcept ValueError as e:\n    print(e.__suppress_context__, type(e.__cause__).__name__)",
    # --- raise ... from None ---
    "try:\n    try:\n        raise KeyError('k')\n    except KeyError:\n        raise ValueError('v') from None\nexcept ValueError as e:\n    print(e.__cause__, e.__suppress_context__)",
    # --- implicit context (exception raised while handling another) ---
    "try:\n    try:\n        raise KeyError('k')\n    except KeyError:\n        raise ValueError('v')\nexcept ValueError as e:\n    print(type(e.__context__).__name__)",
    "try:\n    try:\n        raise KeyError('k')\n    except KeyError:\n        raise ValueError('v')\nexcept ValueError as e:\n    print(str(e.__context__))",
    "try:\n    try:\n        1 / 0\n    except ZeroDivisionError:\n        raise RuntimeError('wrapped')\nexcept RuntimeError as e:\n    print(type(e.__context__).__name__)",
    # --- context still set even with explicit cause ---
    "try:\n    try:\n        raise KeyError('k')\n    except KeyError:\n        raise ValueError('v') from IndexError('i')\nexcept ValueError as e:\n    print(type(e.__context__).__name__, type(e.__cause__).__name__)",
    # --- nested context chain ---
    "try:\n    try:\n        try:\n            raise KeyError('a')\n        except KeyError:\n            raise ValueError('b')\n    except ValueError:\n        raise RuntimeError('c')\nexcept RuntimeError as e:\n    print(type(e.__context__).__name__, type(e.__context__.__context__).__name__)",
    # --- defaults ---
    "try:\n    raise ValueError('v')\nexcept ValueError as e:\n    print(e.__cause__)",
    "try:\n    raise ValueError('v')\nexcept ValueError as e:\n    print(e.__context__)",
    "try:\n    raise ValueError('v')\nexcept ValueError as e:\n    print(e.__suppress_context__)",
    # --- .args ---
    "try:\n    raise ValueError('a', 'b')\nexcept ValueError as e:\n    print(e.args)",
    "try:\n    raise ValueError('solo')\nexcept ValueError as e:\n    print(e.args)",
    "try:\n    raise ValueError()\nexcept ValueError as e:\n    print(e.args)",
    "try:\n    raise KeyError('k')\nexcept KeyError as e:\n    print(e.args)",
    # --- bare re-raise keeps identity, doesn't self-chain ---
    "try:\n    try:\n        raise ValueError('v')\n    except ValueError:\n        raise\nexcept ValueError as e:\n    print(e.__context__, type(e).__name__)",
    # --- cause/context are the actual handled instances ---
    "captured = None\ntry:\n    try:\n        raise KeyError('orig')\n    except KeyError as k:\n        captured = k\n        raise ValueError('new')\nexcept ValueError as e:\n    print(e.__context__ is captured)",
    # --- raise inside finally chains the in-flight exception ---
    "try:\n    try:\n        raise KeyError('k')\n    finally:\n        raise ValueError('from finally')\nexcept ValueError as e:\n    print(type(e.__context__).__name__)",
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
    out = Path(__file__).with_name("exc_chain.json")
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
