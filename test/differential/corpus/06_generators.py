def evens(n):
    for i in range(n):
        if i % 2 == 0:
            yield i
def squares(it):
    for x in it:
        yield x*x
print(list(squares(evens(10))))
