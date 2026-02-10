# Benchmark: Parse time vs Execution time for Pyex
#
# Run with: mix run bench/timing_bench.exs

alias Pyex.{Lexer, Parser, Interpreter, Builtins}

# Non-trivial Python program: Sieve of Eratosthenes + prime factorization + statistics
python_source = """
# Sieve of Eratosthenes to find primes up to n
def sieve(n):
    is_prime = []
    for i in range(n + 1):
        is_prime.append(True)
    is_prime[0] = False
    is_prime[1] = False

    p = 2
    while p * p <= n:
        if is_prime[p]:
            multiple = p * p
            while multiple <= n:
                is_prime[multiple] = False
                multiple = multiple + p
        p = p + 1

    primes = []
    for i in range(n + 1):
        if is_prime[i]:
            primes.append(i)
    return primes

# Prime factorization
def factorize(n):
    factors = []
    d = 2
    while d * d <= n:
        while n % d == 0:
            factors.append(d)
            n = n // d
        d = d + 1
    if n > 1:
        factors.append(n)
    return factors

# Fibonacci with memoization
def make_fib():
    cache = {}
    def fib(n):
        if n in cache:
            return cache[n]
        if n <= 1:
            result = n
        else:
            result = fib(n - 1) + fib(n - 2)
        cache[n] = result
        return result
    return fib

# Statistics functions
def mean(nums):
    total = 0
    for x in nums:
        total = total + x
    return total / len(nums)

def variance(nums):
    m = mean(nums)
    total = 0
    for x in nums:
        diff = x - m
        total = total + diff * diff
    return total / len(nums)

# Merge sort implementation
def merge_sort(arr):
    if len(arr) <= 1:
        return arr
    mid = len(arr) // 2
    left = []
    right = []
    for i in range(mid):
        left.append(arr[i])
    for i in range(mid, len(arr)):
        right.append(arr[i])
    left = merge_sort(left)
    right = merge_sort(right)
    return merge(left, right)

def merge(left, right):
    result = []
    i = 0
    j = 0
    while i < len(left) and j < len(right):
        if left[i] <= right[j]:
            result.append(left[i])
            i = i + 1
        else:
            result.append(right[j])
            j = j + 1
    while i < len(left):
        result.append(left[i])
        i = i + 1
    while j < len(right):
        result.append(right[j])
        j = j + 1
    return result

# Run computations
primes = sieve(200)
print("Primes up to 200:", len(primes), "found")

factors_720 = factorize(720)
print("Prime factors of 720:", factors_720)

fib = make_fib()
fib_results = []
for i in range(20):
    fib_results.append(fib(i))
print("Fibonacci 0-19:", fib_results)

test_data = [64, 25, 12, 22, 11, 90, 45, 33, 78, 56]
sorted_data = merge_sort(test_data)
print("Sorted:", sorted_data)

m = mean(primes)
v = variance(primes)
print("Mean of primes:", m)
print("Variance of primes:", v)

# Nested comprehensions and dict operations
matrix = []
for i in range(5):
    row = []
    for j in range(5):
        row.append(i * j)
    matrix.append(row)

diag_sum = 0
for i in range(5):
    diag_sum = diag_sum + matrix[i][i]
print("Diagonal sum of 5x5 multiplication table:", diag_sum)

# String operations
words = ["hello", "world", "python", "elixir", "pyex"]
upper_words = []
for w in words:
    upper_words.append(w.upper())
joined = ", ".join(upper_words)
print("Upper words:", joined)

# Final result
result = len(primes) + fib(15) + diag_sum
print("Final result:", result)
"""

IO.puts("=" |> String.duplicate(60))
IO.puts("Pyex Timing Benchmark")
IO.puts("=" |> String.duplicate(60))
IO.puts("")
IO.puts("Source code: #{String.length(python_source)} characters, #{length(String.split(python_source, "\n"))} lines")
IO.puts("")

# Measure tokenization
{lex_time, {:ok, tokens}} = :timer.tc(fn -> Lexer.tokenize(python_source) end)
IO.puts("Tokenization: #{lex_time / 1000} ms (#{length(tokens)} tokens)")

# Measure parsing
{parse_time, {:ok, ast}} = :timer.tc(fn -> Parser.parse(tokens) end)
ast_size = :erts_debug.size(ast)
IO.puts("Parsing:      #{parse_time / 1000} ms (AST size: #{ast_size} words)")

# Combined parse time
total_parse_time = lex_time + parse_time
IO.puts("Total Parse:  #{total_parse_time / 1000} ms")
IO.puts("")

# Measure execution (capture output)
IO.puts("-" |> String.duplicate(60))
IO.puts("Program Output:")
IO.puts("-" |> String.duplicate(60))

{exec_time, result} = :timer.tc(fn ->
  Interpreter.run_with_ctx(ast, Builtins.env(), Pyex.Ctx.new())
end)

IO.puts("-" |> String.duplicate(60))
IO.puts("")

case result do
  {:ok, value, _env, _ctx} ->
    IO.puts("Execution:    #{exec_time / 1000} ms")
    IO.puts("Return value: #{inspect(value)}")
  {:error, reason} ->
    IO.puts("Execution failed: #{reason}")
end

IO.puts("")
IO.puts("=" |> String.duplicate(60))
IO.puts("Summary")
IO.puts("=" |> String.duplicate(60))
IO.puts("Parse time:     #{Float.round(total_parse_time / 1000, 2)} ms")
IO.puts("Execution time: #{Float.round(exec_time / 1000, 2)} ms")
IO.puts("Parse/Exec ratio: #{Float.round(total_parse_time / exec_time, 3)}")
IO.puts("")
