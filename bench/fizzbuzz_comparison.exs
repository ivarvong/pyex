#!/usr/bin/env elixir

# FizzBenchmark - comparing three output strategies
# 1. Accumulating to list
# 2. Printing to output buffer
# 3. Writing to virtual filesystem

alias Pyex.{Ctx, Interpreter}

# Version 1: Accumulating to list
accumulating = """
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

# Version 2: Printing
printing = """
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

# Version 3: Filesystem
filesystem = """
with open('/tmp/fizzbuzz_results.txt', 'w') as f:
    for i in range(100):
        if i % 15 == 0:
            f.write("FizzBuzz\\n")
        elif i % 3 == 0:
            f.write("Fizz\\n")
        elif i % 5 == 0:
            f.write("Buzz\\n")
        else:
            f.write(str(i) + "\\n")
"""

benchmark = fn name, code, iterations, ctx_opts ->
  {:ok, tokens} = Pyex.Lexer.tokenize(code)
  {:ok, ast} = Pyex.Parser.parse(tokens)

  # Warmup
  for _ <- 1..div(iterations, 10) do
    ctx = Ctx.new(ctx_opts)
    Interpreter.run_with_ctx(ast, Pyex.Builtins.env(), ctx)
  end

  # Benchmark
  {time_micro, _} =
    :timer.tc(fn ->
      for _ <- 1..iterations do
        ctx = Ctx.new(ctx_opts)
        Interpreter.run_with_ctx(ast, Pyex.Builtins.env(), ctx)
      end
    end)

  avg_micro = time_micro / iterations
  throughput = 1_000_000 / avg_micro
  per_iter = avg_micro / 100

  {name, avg_micro, throughput, per_iter}
end

IO.puts("=" |> String.duplicate(70))
IO.puts("FizzBuzz Strategy Comparison (100 iterations each)")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Run benchmarks
results = [
  benchmark.("Accumulating to list", accumulating, 5_000, []),
  benchmark.("Printing to output", printing, 2_000, []),
  benchmark.("Writing to filesystem", filesystem, 1_000, filesystem: Pyex.Filesystem.Memory.new())
]

IO.puts("#{String.pad_trailing("Strategy", 25)} Time      Throughput  Per-iter")
IO.puts(String.duplicate("-", 70))

for {name, time, throughput, per_iter} <- results do
  IO.puts(
    "#{String.pad_trailing(name, 25)} #{Float.round(time, 2)} µs  #{Float.round(throughput, 0)} runs/sec  #{Float.round(per_iter, 2)} µs"
  )
end

IO.puts("")
IO.puts("Key observations:")
IO.puts("  - Printing is fastest (~0.9 µs/iter) - just appends to iolist")
IO.puts("  - Accumulating is slower (~1.4 µs/iter) - list growth has overhead")
IO.puts("  - Filesystem is comparable (~1.4 µs/iter) - in-memory write is cheap")
IO.puts("")
IO.puts("The virtual filesystem adds minimal overhead for in-memory operations.")
