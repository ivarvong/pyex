#!/usr/bin/env elixir

# Real FizzBuzz benchmark - the classic interview question
# Tests: conditionals, modulo operations, string operations, list append/print

alias Pyex.Interpreter

# Classic FizzBuzz accumulating to list (interview style)
accumulating_fizzbuzz = """
results = []
for i in range(100):
    if i % 15 == 0:
        results.append("FizzBuzz")
    elif i % 3 == 0:
        results.append("Fizz")
    elif i % 5 == 0:
        results.append("Buzz")
    else:
        results.append(str(i))
"""

# FizzBuzz with printing (100 print statements)
printing_fizzbuzz = """
for i in range(100):
    if i % 15 == 0:
        print("FizzBuzz")
    elif i % 3 == 0:
        print("Fizz")
    elif i % 5 == 0:
        print("Buzz")
    else:
        print(i)
"""

benchmark = fn name, code, iterations ->
  {:ok, tokens} = Pyex.Lexer.tokenize(code)
  {:ok, ast} = Pyex.Parser.parse(tokens)

  {time_micro, _} =
    :timer.tc(fn ->
      for _ <- 1..iterations do
        Interpreter.run(ast)
      end
    end)

  avg_micro = time_micro / iterations
  throughput = 1_000_000 / avg_micro
  per_iter = avg_micro / 100

  IO.puts(
    "#{String.pad_trailing(name, 30)} #{Float.round(avg_micro, 2)} µs  #{Float.round(throughput, 0)} runs/sec  #{Float.round(per_iter, 2)} µs/iter"
  )
end

IO.puts("=" |> String.duplicate(70))
IO.puts("Real FizzBuzz Benchmark (100 iterations each)")
IO.puts("=" |> String.duplicate(70))
IO.puts("")
IO.puts("#{String.pad_trailing("Workload", 30)} Time      Throughput  Per-iter")
IO.puts(String.duplicate("-", 70))

benchmark.("FizzBuzz (accumulating)", accumulating_fizzbuzz, 5_000)
benchmark.("FizzBuzz (printing)", printing_fizzbuzz, 1_000)

IO.puts("")
IO.puts("Note: Printing version includes 100 print() calls per run")
IO.puts("      Accumulating version includes 100 list.append() calls per run")
