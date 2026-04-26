"""
generator.send(value) — coroutine-style generators using yield as expression.
Exercises: v = yield expr syntax, .send(), .close(), yield None.
"""


def accumulator():
    total = 0
    while True:
        value = yield total
        if value is None:
            break
        total += value


g = accumulator()
print(next(g))      # prime: 0
print(g.send(10))   # 10
print(g.send(5))    # 15
print(g.send(3))    # 18


def echo():
    while True:
        received = yield
        print("echo:", received)


e = echo()
next(e)
e.send("hello")
e.send("world")
e.close()


def two_yields():
    x = yield 1
    y = yield x + 10
    yield y + 100


t = two_yields()
print(next(t))
print(t.send(5))   # x=5, yields 15
print(t.send(20))  # y=20, yields 120
try:
    next(t)
except StopIteration:
    print("done")
