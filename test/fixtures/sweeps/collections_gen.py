"""Statement-level sweep: the collections module (Counter, defaultdict,
OrderedDict).

Run with `python3 test/fixtures/sweeps/collections_gen.py`. Each cell is a
full program whose stdout (or raised exception) is compared to CPython by
`Pyex.Test.Sweep.check!("collections")`.

Driven by a bug report: Counter.most_common() returned [] after
incremental `c[k] += 1`, and defaultdict didn't honor __missing__ on a
chained read. This sweeps the surrounding surface to catch related
divergences — Counter construction vs incremental, arithmetic, elements,
and defaultdict factories, chained access, and ordering.
"""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path

PROGRAMS = [
    # ── Counter: construction vs incremental ──────────────────────────────
    "from collections import Counter\nprint(Counter(['a', 'a', 'b']).most_common())",
    "from collections import Counter\nc = Counter()\nc['a'] += 1\nc['a'] += 1\nc['b'] += 1\nprint(c.most_common())",
    "from collections import Counter\nc = Counter(['a'])\nc['a'] += 1\nprint(c.most_common())",
    "from collections import Counter\nc = Counter('mississippi')\nprint(c.most_common(2))",
    "from collections import Counter\nc = Counter()\nfor ch in 'banana':\n    c[ch] += 1\nprint(c.most_common())",
    "from collections import Counter\nc = Counter()\nc['x'] += 5\nprint(dict(c))",
    "from collections import Counter\nc = Counter(a=3, b=1)\nprint(c.most_common())",
    "from collections import Counter\nc = Counter({'a': 2, 'b': 5})\nprint(c.most_common())",
    # ── Counter: most_common ties keep first-seen order ───────────────────
    "from collections import Counter\nc = Counter()\nfor k in ['b', 'a', 'b', 'a', 'c']:\n    c[k] += 1\nprint(c.most_common())",
    # ── Counter: missing key reads as 0 (no insert) ───────────────────────
    "from collections import Counter\nc = Counter(['a'])\nprint(c['z'])\nprint('z' in c)",
    # ── Counter: elements ─────────────────────────────────────────────────
    "from collections import Counter\nc = Counter()\nc['a'] += 2\nc['b'] += 1\nprint(sorted(c.elements()))",
    "from collections import Counter\nprint(sorted(Counter('aabbc').elements()))",
    # ── Counter: update / arithmetic ──────────────────────────────────────
    "from collections import Counter\nc = Counter(['a', 'b'])\nc.update(['a', 'c'])\nprint(c.most_common())",
    "from collections import Counter\nprint((Counter(['a', 'a', 'b']) + Counter(['a', 'c'])).most_common())",
    "from collections import Counter\nprint((Counter(['a', 'a', 'b']) - Counter(['a', 'b', 'b'])).most_common())",
    "from collections import Counter\nc = Counter(['a', 'a', 'b'])\nc['a'] -= 5\nprint(dict(c))",
    "from collections import Counter\nc = Counter('aaabb')\nprint(c.total() if hasattr(c, 'total') else sum(c.values()))",
    # ── defaultdict: factories ────────────────────────────────────────────
    "from collections import defaultdict\nd = defaultdict(int)\nfor w in 'abracadabra':\n    d[w] += 1\nprint(sorted(d.items()))",
    "from collections import defaultdict\nd = defaultdict(list)\nd['a'].append(1)\nd['a'].append(2)\nprint(dict(d))",
    "from collections import defaultdict\nd = defaultdict(set)\nd['x'].add(1)\nd['x'].add(1)\nprint(dict(d))",
    "from collections import defaultdict\nd = defaultdict(int)\nprint(d['missing'])\nprint(dict(d))",
    # ── defaultdict: lambda factory + chained access ──────────────────────
    "from collections import defaultdict\nb = defaultdict(lambda: {'s': set(), 'n': 0})\nb['x']['s'].add('m1')\nprint(b['x']['n'])",
    "from collections import defaultdict\nb = defaultdict(lambda: {'s': [], 'n': 0})\nb['x']['s'].append('m')\nb['x']['n'] += 1\nprint(dict(b))",
    "from collections import defaultdict\nb = defaultdict(lambda: 7)\nprint(b['k'])\nprint(dict(b))",
    "from collections import defaultdict\nd = defaultdict(list)\nd['a']\nprint(dict(d))",  # bare read inserts []
    # ── defaultdict: nested defaultdict ───────────────────────────────────
    "from collections import defaultdict\ntree = defaultdict(lambda: defaultdict(int))\ntree['a']['b'] += 1\ntree['a']['c'] += 2\nprint({k: dict(v) for k, v in tree.items()})",
    # ── defaultdict: behaves like a dict otherwise ────────────────────────
    "from collections import defaultdict\nd = defaultdict(int, {'a': 1})\nd['b'] += 2\nprint(sorted(d.items()))",
    "from collections import defaultdict\nd = defaultdict(int)\nd['a'] += 1\nprint(len(d), 'a' in d, d.get('z', -1))",
    # ── OrderedDict ───────────────────────────────────────────────────────
    "from collections import OrderedDict\nd = OrderedDict()\nd['a'] = 1\nd['b'] = 2\nd['c'] = 3\nprint(list(d.keys()))",
    "from collections import OrderedDict\nd = OrderedDict([('a', 1), ('b', 2)])\nd.move_to_end('a')\nprint(list(d.keys()))",
    "from collections import OrderedDict\nd = OrderedDict([('a', 1), ('b', 2), ('c', 3)])\nd.popitem()\nprint(list(d.items()))",
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
    out = Path(__file__).with_name("collections.json")
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
