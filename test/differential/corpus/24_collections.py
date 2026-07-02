from collections import defaultdict, Counter
dd = defaultdict(list)
for i in range(6):
    dd[i % 3].append(i)
print(dict(sorted(dd.items())))
print(Counter("mississippi").most_common(2))
