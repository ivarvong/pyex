"""
Scope resolution through global, nonlocal, comprehensions, and loop leakage.

The fixture combines writes through different scope declarations with Python's
ordinary closure lookup and the fact that loop variables remain bound after a
loop completes.
"""


status = "initial"


def orchestrate(values):
    global status
    status = "running"
    total = 0
    audit = []

    def record(label, amount):
        nonlocal total
        total += amount
        audit.append((label, total))
        return total

    def nested():
        local_values = []
        for value in values:
            local_values.append(record("v" + str(value), value))
        return local_values, value

    nested_values, leaked = nested()
    squares = [value * value for value in values]
    try:
        value_after_comp = value
    except NameError:
        value_after_comp = "missing"

    status = "done"
    return total, audit, nested_values, leaked, squares, value_after_comp


result = orchestrate([2, 3, 5])
assert result == (
    10,
    [("v2", 2), ("v3", 5), ("v5", 10)],
    [2, 5, 10],
    5,
    [4, 9, 25],
    "missing",
)
assert status == "done"

print("result", result)
print("status", status)
