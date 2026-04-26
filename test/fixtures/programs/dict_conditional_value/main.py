"""
Conditional (ternary) expressions as dict values AND keys, and as set elements.
Exercises: dict literals, set literals, set comprehensions with ternary expressions.
"""

x = None
d1 = {"a": 1 if x is not None else None}
print(d1)

y = 42
d2 = {"value": y * 2 if y > 0 else -1, "flag": True if y > 10 else False}
print(d2["value"])
print(d2["flag"])

# Ternary as dict KEY
active = True
d3 = {"on" if active else "off": 1}
print(d3)

# Multiple entries with ternary keys and values
a, b = 10, 20
d4 = {"big" if a > b else "small": a if a > b else b, "same": a == b}
print(d4["small"])
print(d4["same"])

# Set literal with conditional element
s1 = {1 if active else 2, 3}
print(sorted(list(s1)))

# Set comprehension with conditional element
s2 = {i if i % 2 == 0 else -i for i in range(5)}
print(sorted(list(s2)))

items = [1, 2, 3]
d5 = {
    "has_items": True if items else False,
    "first": items[0] if items else None,
    "count": len(items) if items else 0,
}
print(d5["has_items"])
print(d5["first"])
print(d5["count"])
