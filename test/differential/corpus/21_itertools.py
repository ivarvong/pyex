import itertools
print(list(itertools.chain([1,2],[3,4])))
print(list(itertools.islice(itertools.count(10), 3)))
print([list(g) for k, g in itertools.groupby([1,1,2,3,3,3])])
