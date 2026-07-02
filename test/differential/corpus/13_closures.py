def counter(start=0):
    n = start
    def inc(step=1):
        nonlocal n
        n += step
        return n
    return inc
c = counter(10)
print(c(), c(2), c(3))
