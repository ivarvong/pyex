"""
Ordering stability across sorted records and dictionary mutations.

This fixture checks stable sorting with repeated keys, dictionary insertion
order after update/delete/reinsert, and nested tuple/list equality at the
boundaries used by result normalization code.
"""


records = [
    {"id": "a", "tier": 2, "score": 10},
    {"id": "b", "tier": 1, "score": 20},
    {"id": "c", "tier": 2, "score": 30},
    {"id": "d", "tier": 1, "score": 40},
    {"id": "e", "tier": 2, "score": 50},
]

by_tier = sorted(records, key=lambda row: row["tier"])
by_score_bucket = sorted(records, key=lambda row: row["score"] // 20)

assert [row["id"] for row in by_tier] == ["b", "d", "a", "c", "e"]
assert [row["id"] for row in by_score_bucket] == ["a", "b", "c", "d", "e"]

ledger = {}
for row in records:
    ledger[row["id"]] = row["score"]
ledger["b"] = 21
removed = ledger.pop("c")
ledger["c"] = removed
ledger["f"] = 60

assert list(ledger.items()) == [("a", 10), ("b", 21), ("d", 40), ("e", 50), ("c", 30), ("f", 60)]

nested_left = [("a", [1, 2]), ("b", []), ("c", [(1, "x")])]
nested_right = [("a", [1, 2]), ("b", []), ("c", [(1, "x")])]
nested_other = [("a", [1, 2]), ("b", []), ("c", [(1, "y")])]

assert nested_left == nested_right
assert nested_left != nested_other

print("tier", [row["id"] for row in by_tier])
print("bucket", [row["id"] for row in by_score_bucket])
print("ledger", list(ledger.items()))
print("nested", nested_left == nested_right, nested_left != nested_other)
