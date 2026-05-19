"""
Mutation guards for dictionary and set iteration.

CPython raises RuntimeError when dictionary or set size changes during active
iteration, but permits value replacement that leaves dictionary size stable.
"""


def mutate_dict_size():
    data = {"a": 1, "b": 2}
    seen = []
    try:
        for key in data:
            seen.append(key)
            data["c"] = 3
    except RuntimeError as exc:
        return seen, "runtime", "dictionary" in str(exc)
    return seen, "ok", False


def mutate_dict_value():
    data = {"a": 1, "b": 2}
    seen = []
    for key in data:
        seen.append((key, data[key]))
        data[key] = data[key] * 10
    return seen, sorted(data.items())


def mutate_set_size():
    values = {1, 2, 3}
    seen = []
    try:
        for value in values:
            seen.append(value)
            values.add(4)
    except RuntimeError as exc:
        return sorted(seen), "runtime", "set" in str(exc)
    return sorted(seen), "ok", False


dict_size = mutate_dict_size()
dict_value = mutate_dict_value()
set_size = mutate_set_size()

assert dict_size[1:] == ("runtime", True)
assert dict_value == ([("a", 1), ("b", 2)], [("a", 10), ("b", 20)])
assert set_size[1:] == ("runtime", True)

print("dict_size", dict_size)
print("dict_value", dict_value)
print("set_size", set_size)
