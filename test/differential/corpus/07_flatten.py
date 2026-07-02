def flatten(xs):
    out = []
    for x in xs:
        out.extend(flatten(x) if isinstance(x, list) else [x])
    return out
print(flatten([1,[2,[3,4],5],[6],7]))
