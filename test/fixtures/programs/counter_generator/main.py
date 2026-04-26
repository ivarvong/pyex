"""
Counter constructed from a generator expression or iterable.
Exercises: collections.Counter, generator expressions, missing-key default,
augmented assignment from empty counter, Counter.update, Counter arithmetic.
"""
from collections import Counter

# Counter from a generator expression
c1 = Counter(x for x in "abracadabra")
print(c1["a"])
print(c1["b"])
print(c1["r"])
print(c1["z"])  # missing key: should return 0

# Counter augmented assignment starting from empty
c2 = Counter()
c2["x"] += 1
c2["x"] += 1
c2["y"] += 1
print(c2["x"])
print(c2["y"])
print(c2["missing"])  # missing key: should return 0

# Counter from a list via generator
words = ["apple", "banana", "apple", "cherry", "banana", "apple"]
c3 = Counter(w for w in words)
print(c3["apple"])
print(c3["banana"])
print(c3["cherry"])
print(c3["grape"])  # missing key: should return 0

# Counter.update with a generator
c4 = Counter(["a", "b", "a"])
c4.update(x for x in "aab")
print(c4["a"])
print(c4["b"])

# Counter arithmetic
c5 = Counter(a=3, b=1)
c6 = Counter(a=1, b=2)
c7 = c5 + c6
print(c7["a"])
print(c7["b"])

# Counter.most_common
c8 = Counter("aabbccc")
top = c8.most_common(2)
print(top[0][0], top[0][1])
print(top[1][0], top[1][1])
