"""
Closure capture, default argument snapshots, and late binding.

The program combines mutable cell state, default-argument snapshots used to
avoid late binding, and the ordinary late-binding behavior closures otherwise
observe after the loop variable changes.
"""


def make_accumulators(names):
    funcs = []
    shared = {"count": 0, "history": []}

    for name in names:
        def add(amount, label=name, state=shared):
            state["count"] += amount
            state["history"].append((label, state["count"]))
            return label, state["count"]

        funcs.append(add)

    return funcs, shared


def late_bound():
    funcs = []
    for i in range(4):
        funcs.append(lambda: i)
    return [fn() for fn in funcs]


def snapshot_bound():
    funcs = []
    for i in range(4):
        funcs.append(lambda i=i: i)
    return [fn() for fn in funcs]


funcs, shared = make_accumulators(["alpha", "beta", "gamma"])
results = [funcs[0](3), funcs[1](5), funcs[2](-2), funcs[0](4)]

assert results == [("alpha", 3), ("beta", 8), ("gamma", 6), ("alpha", 10)]
assert shared == {
    "count": 10,
    "history": [("alpha", 3), ("beta", 8), ("gamma", 6), ("alpha", 10)],
}
assert late_bound() == [3, 3, 3, 3]
assert snapshot_bound() == [0, 1, 2, 3]

print("results", results)
print("shared", shared)
print("late", late_bound())
print("snapshot", snapshot_bound())
