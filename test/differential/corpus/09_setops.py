a = set(range(10))
b = {2,4,6,8,10,12}
print(sorted(a & b), sorted(a | b), sorted(a - b), sorted(a ^ b))
