"""Differential test-vector generator for pyex's string-prefix lexing.

Run with `python3 test/fixtures/string_prefix_diff_gen.py` to regenerate
`test/fixtures/string_prefix_diff.json`. The output is deterministic (a
fixed cross-product, no RNG), so a regenerated file is byte-identical to
the committed one unless the generator code itself changed.

Each vector is one CPython-evaluated reference: a string/bytes *literal*
(prefix + quote-style + body) and the `repr()` of its value. The Elixir
test side evaluates the same literal in pyex and asserts `repr()` matches
CPython byte-for-byte. `repr` is used as a single uniform comparator that
works for both `str` and `bytes` results.

The generator enumerates the full Python string/bytes prefix matrix:

  * prefixes : '' r R f F u U  +  rf fr (all case/order variants)
               +  b B  +  rb br (all case/order variants)
  * quotes   : "  '  \"\"\"  '''
  * bodies   : plain / escapes (\\n \\t \\d \\\\ \\u00e9 \\xff) / braces
               ({x} {{x}}) / embedded quotes / real newlines

CPython is the legality oracle: any (prefix, quote, body) triple that is
not valid Python raises SyntaxError at compile time and is skipped, so we
never have to hand-encode Python's prefix-combination rules. Every emitted
vector is, by construction, valid Python that CPython actually evaluated.

The f-string / raw-f-string bodies reference `x`, which is bound to 5 in
the evaluation namespace so interpolation is exercised (`f"{x}"` -> "5"
while `"{x}"` -> "{x}").
"""

from __future__ import annotations

import json
import warnings

# Invalid escape sequences (e.g. "\d") are a SyntaxWarning in modern
# CPython but still evaluate; silence them so the generator output stays
# clean. They do not raise, so legality detection is unaffected.
warnings.simplefilter("ignore", SyntaxWarning)
warnings.simplefilter("ignore", DeprecationWarning)

# Every prefix we care about, including the empty (no-prefix) case. We list
# case/order variants explicitly rather than generating them so the fixture
# documents exactly what is covered: str prefixes (r/f/u and the rf/fr
# combos) and bytes prefixes (b and the rb/br combos), each case-insensitive.
PREFIXES = [
    "",
    "r", "R",
    "f", "F",
    "u", "U",
    "rf", "fr", "Rf", "rF", "Fr", "fR", "RF", "FR",
    "b", "B",
    "rb", "br", "Rb", "rB", "bR", "Br", "RB", "BR",
]

# (open, close) quote delimiters.
QUOTES = [
    ('"', '"'),
    ("'", "'"),
    ('"""', '"""'),
    ("'''", "'''"),
]

# Bodies chosen to exercise distinct lexing behaviours. Each is inserted
# verbatim between the quotes; CPython filters out illegal placements.
BODIES = [
    "",
    "ab",
    "a\\nb",        # backslash-n: raw keeps "\n", non-raw -> newline
    "a\\tb",        # backslash-t
    "\\d+",         # invalid escape: kept verbatim everywhere
    "a\\\\b",       # escaped backslash: raw -> "\\", non-raw -> "\"
    "{x}",          # f/rf -> interpolated 5; others -> literal "{x}"
    "{{x}}",        # f/rf -> literal "{x}"; others -> literal "{{x}}"
    "say 'hi'",     # embedded single quotes
    'say "hi"',     # embedded double quotes
    "line1\nline2",  # real newline: only valid inside triple quotes
    "tab\there",     # real tab
    "unicode \\u00e9",  # unicode escape: non-raw -> é, raw -> literal
    "hex \\xff",        # hex escape
]


def main() -> None:
    vectors = []
    namespace = {"x": 5}

    for prefix in PREFIXES:
        for open_q, close_q in QUOTES:
            for body in BODIES:
                src = f"{prefix}{open_q}{body}{close_q}"

                try:
                    value = eval(src, {}, namespace)  # noqa: S307 - trusted, fixed inputs
                except SyntaxError:
                    # Not valid Python (e.g. unescaped same-quote in a
                    # single-quoted string, real newline outside triples,
                    # an illegal prefix combination). pyex is not required
                    # to accept it, so it is not a differential vector.
                    continue
                except ValueError:
                    # e.g. a bad \x escape with too few digits.
                    continue

                if not isinstance(value, (str, bytes)):
                    continue

                vectors.append(
                    {
                        "id": f"{len(vectors):04d}",
                        "prefix": prefix,
                        "quote": open_q,
                        "src": src,
                        "kind": "bytes" if isinstance(value, bytes) else "str",
                        "expected": repr(value),
                    }
                )

    print(f"Generated {len(vectors)} vectors")
    with open("test/fixtures/string_prefix_diff.json", "w") as f:
        json.dump(vectors, f, indent=0)


if __name__ == "__main__":
    main()
