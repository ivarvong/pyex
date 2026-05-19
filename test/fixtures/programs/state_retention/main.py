"""
State retention and aliasing across ordinary helper functions.

The program leans on Python's live references: mutable default arguments keep
state between calls, setdefault returns the stored object, and closures observe
the same underlying containers after mutation.
"""


def remember(value, bucket=[]):
    bucket.append(value)
    return list(bucket)


def group(rows):
    grouped = {}
    aliases = []
    for key, value in rows:
        slot = grouped.setdefault(key, [])
        slot.append(value)
        aliases.append(slot)
    return grouped, aliases


def make_counter(start=0):
    total = {"value": start, "history": []}

    def add(amount):
        total["value"] += amount
        total["history"].append(total["value"])
        return total["value"]

    def snapshot():
        return total["value"], list(total["history"])

    return add, snapshot


first = remember("alpha")
second = remember("beta")
third = remember("gamma")
assert first == ["alpha"]
assert second == ["alpha", "beta"]
assert third == ["alpha", "beta", "gamma"]

grouped, aliases = group([("a", 1), ("b", 2), ("a", 3), ("a", 4), ("b", 5)])
assert grouped == {"a": [1, 3, 4], "b": [2, 5]}
assert aliases[0] is aliases[2]
assert aliases[1] is aliases[4]
aliases[0].append(99)
assert grouped["a"] == [1, 3, 4, 99]

add, snapshot = make_counter(10)
assert [add(5), add(-3), add(8)] == [15, 12, 20]
assert snapshot() == (20, [15, 12, 20])

print("remember", first, second, third)
print("grouped", sorted(grouped.items()))
print("alias", aliases[0] is grouped["a"], aliases[1] is grouped["b"])
print("counter", snapshot())
