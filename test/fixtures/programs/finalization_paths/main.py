"""
Finalization paths through nested control flow.

The workload checks that finally blocks run for normal completion, continue,
break, handled exceptions, and re-raised exceptions while preserving the
observable ordering of side effects.
"""


def scan(values):
    events = []
    total = 0

    for value in values:
        try:
            events.append(("enter", value))
            if value == "skip":
                continue
            if value == "stop":
                break
            if value == "bad":
                raise ValueError("bad value")
            total += value
        except ValueError as exc:
            events.append(("handled", str(exc)))
            total -= 10
        finally:
            events.append(("finally", value, total))

    else:
        events.append(("else", total))

    return total, events


def nested(flag):
    events = []
    try:
        events.append("outer-enter")
        try:
            events.append("inner-enter")
            if flag == "raise":
                raise RuntimeError("boom")
            return "returned"
        finally:
            events.append("inner-finally")
    except RuntimeError as exc:
        events.append("caught:" + str(exc))
        return "caught"
    finally:
        events.append("outer-finally")
        print("nested-events", flag, events)


total, events = scan([1, "skip", 2, "bad", 3, "stop", 99])
assert total == -4
assert events == [
    ("enter", 1),
    ("finally", 1, 1),
    ("enter", "skip"),
    ("finally", "skip", 1),
    ("enter", 2),
    ("finally", 2, 3),
    ("enter", "bad"),
    ("handled", "bad value"),
    ("finally", "bad", -7),
    ("enter", 3),
    ("finally", 3, -4),
    ("enter", "stop"),
    ("finally", "stop", -4),
]

total2, events2 = scan([4, 5])
assert total2 == 9
assert events2[-1] == ("else", 9)

assert nested("return") == "returned"
assert nested("raise") == "caught"

print("scan", total, events)
print("scan2", total2, events2)
