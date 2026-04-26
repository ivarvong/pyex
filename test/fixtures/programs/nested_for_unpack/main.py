"""
Nested tuple unpacking in for-loop targets and comprehensions.
Exercises: for (a, b) in ..., for i, (a, b) in ..., deep nesting.
"""

# Basic nested unpacking
for a, b in [(1, 2), (3, 4)]:
    print(a, b)

# Nested as first target: (a, b) in ...
for (x, y) in [(10, 20), (30, 40)]:
    print(x, y)

# Mixed: index + nested
pairs = [("alice", (90, "A")), ("bob", (75, "B")), ("carol", (85, "A"))]
for name, (score, grade) in pairs:
    print(name, score, grade)

# With enumerate
items = [(1, 2), (3, 4), (5, 6)]
for i, (a, b) in enumerate(items):
    print(i, a + b)

# List comprehension with nested unpacking
totals = [a + b for a, (b, c) in [(1, (2, 3)), (4, (5, 6))]]
print(totals)

# Generator expression with nested unpacking
gen_result = list(a * b for (a, b) in [(2, 3), (4, 5)])
print(gen_result)

# Deep nesting: i, (a, (b, c))
nested = list(enumerate([(1, (2, 3)), (4, (5, 6))]))
for i, (a, (b, c)) in nested:
    print(i, a, b, c)
