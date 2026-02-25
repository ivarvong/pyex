#!/usr/bin/env elixir

# Quick micro-benchmark to compare performance before/after removing event logging
alias Pyex.{Ctx, Interpreter}

code = """
total = 0
for i in range(1000):
    total = total + i
total
"""

# Parse once
{:ok, tokens} = Pyex.Lexer.tokenize(code)
{:ok, ast} = Pyex.Parser.parse(tokens)

IO.puts("Running 1000 iterations of loop-intensive code...")

{time_micro, _} =
  :timer.tc(fn ->
    for _ <- 1..100 do
      Interpreter.run(ast)
    end
  end)

avg_time = time_micro / 100

IO.puts("Average time per run: #{Float.round(avg_time, 2)} µs")
IO.puts("Throughput: #{Float.round(1_000_000 / avg_time, 2)} runs/sec")
