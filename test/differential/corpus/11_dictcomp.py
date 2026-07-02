keys, vals = ["a","b","c"], [1,2,3]
d = {k: v*v for k, v in zip(keys, vals)}
print(d)
print({v: k for k, v in d.items()})
