cache = {}
def fib(n):
    if n < 2:
        return n
    if n not in cache:
        cache[n] = fib(n-1) + fib(n-2)
    return cache[n]
print([fib(i) for i in range(15)])
