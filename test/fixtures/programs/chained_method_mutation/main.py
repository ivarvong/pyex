"""
Chained method calls where the receiver is a complex expression — mutations
must propagate back (e.g. d.setdefault("k", []).append(v)).
Exercises: setdefault+append, module attr mutation, subscript method chain.
"""

# dict.setdefault("k", []).append(v) — canonical groupby pattern
data = [
    {"group": "a", "val": 1},
    {"group": "b", "val": 2},
    {"group": "a", "val": 3},
    {"group": "b", "val": 4},
]
groups = {}
for row in data:
    groups.setdefault(row["group"], []).append(row["val"])

print(sorted(groups["a"]))
print(sorted(groups["b"]))

# Verify the dict itself is correct
print(len(groups))

# sys.path mutations via chained method
import sys

before = len(sys.path)
sys.path.append("/test/path")
print(sys.path[-1])
print(len(sys.path) - before)

# Subscript + method chain
nested = {"lists": []}
nested["lists"].append(42)
nested["lists"].append(99)
print(sorted(nested["lists"]))

# str chain (immutable — returns new value)
result = "  Hello World  ".strip().lower().replace(" ", "_")
print(result)
