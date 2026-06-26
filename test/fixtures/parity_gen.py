"""CPython surface-parity reference generator for pyex.

Run with `python3 test/fixtures/parity_gen.py` to regenerate
`test/fixtures/parity.json`. The output is a snapshot of the *public*
attribute surface (everything `dir(x)` reports that does not start with
`_`) for a representative value of each Python type pyex models, plus the
builtin namespace partitioned into exceptions and everything else.

The Elixir side (`test/pyex/parity_test.exs`) compares pyex's own
`dir()` / builtin surface against this reference and asserts that every
CPython public name is either implemented by pyex or listed in an
explicit `@known_gaps` ledger with a reason. A regenerated file is
byte-identical to the committed one (sorted keys, sorted lists) unless
CPython's surface itself changed.

The point is to make *absence* loud: a method CPython exposes that pyex
neither implements nor has acknowledged becomes a failing test, not a
silent hole nobody notices until an agent's program hits it.
"""

from __future__ import annotations

import builtins
import datetime
import json
import os
from pathlib import Path


def public(obj) -> list[str]:
    """Public attribute names on `obj` (what `dir()` shows, sans dunders)."""
    return sorted(name for name in dir(obj) if not name.startswith("_"))


def type_surfaces() -> dict[str, list[str]]:
    """One representative value per builtin / stdlib type pyex models."""
    devnull = open(os.devnull, "w")
    try:
        values = {
            "str": "",
            "list": [],
            "tuple": (),
            "dict": {},
            "set": set(),
            "frozenset": frozenset(),
            "file": devnull,
            "date": datetime.date(2026, 1, 1),
            "datetime": datetime.datetime(2026, 1, 1, 12, 30),
        }
        return {name: public(value) for name, value in values.items()}
    finally:
        devnull.close()


def builtin_surface() -> dict[str, list[str]]:
    """The builtin namespace, split into exception classes and the rest.

    pyex tracks exception classes through a separate hierarchy, so the
    parity test compares the two partitions independently.
    """

    def is_exception(name: str) -> bool:
        obj = getattr(builtins, name)
        return isinstance(obj, type) and issubclass(obj, BaseException)

    names = [name for name in dir(builtins) if not name.startswith("_")]
    return {
        "exceptions": sorted(name for name in names if is_exception(name)),
        "functions": sorted(name for name in names if not is_exception(name)),
    }


def main() -> None:
    manifest = {
        "python_version": ".".join(str(n) for n in __import__("sys").version_info[:3]),
        "types": type_surfaces(),
        "builtins": builtin_surface(),
    }
    out = Path(__file__).with_name("parity.json")
    out.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"wrote {out} ({manifest['python_version']})")


if __name__ == "__main__":
    main()
