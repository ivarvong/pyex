"""
Walrus operator (:=) in various positions.
Exercises: assignment expressions in conditions, call args, comprehensions.
"""

# In if condition
data = [1, 2, 3]
if n := len(data):
    print("length:", n)

# In call argument
result = sorted(items := [3, 1, 2])
print("items:", items)
print("sorted:", result)

# In while condition (reading from a list)
values = [10, 20, 0, 30]
idx = 0
total = 0
while (idx < len(values)) and (v := values[idx]) != 0:
    total += v
    idx += 1
print("total:", total)

# In list comprehension filter
numbers = range(10)
evens_doubled = [y for x in numbers if (y := x * 2) < 10]
print("evens_doubled:", evens_doubled)

# Nested: len(data := expr)
count = len(words := "hello world".split())
print("count:", count)
print("words:", words)

# In function call argument
import math
side = math.sqrt(area := 25)
print("area:", area)
print("side:", side)
