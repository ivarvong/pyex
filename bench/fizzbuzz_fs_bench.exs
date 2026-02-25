#!/usr/bin/env elixir

# FizzBuzz benchmark using virtual filesystem
# Writes results to in-memory filesystem, then reads them back

alias Pyex.{Ctx, Interpreter}

# FizzBuzz writing to filesystem
fs_fizzbuzz = """
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

{:ok, tokens} = Pyex.Lexer.tokenize(fs_fizzbuzz)
{:ok, ast} = Pyex.Parser.parse(tokens)

IO.puts("=" |> String.duplicate(70))
IO.puts("FizzBuzz via Virtual Filesystem Benchmark")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Warmup
for _ <- 1..100 do
  ctx = Ctx.new(filesystem: Pyex.Filesystem.Memory.new())
  Interpreter.run_with_ctx(ast, Pyex.Builtins.env(), ctx)
end

# Benchmark
iterations = 1_000

{time_micro, _} =
  :timer.tc(fn ->
    for _ <- 1..iterations do
      ctx = Ctx.new(filesystem: Pyex.Filesystem.Memory.new())
      Interpreter.run_with_ctx(ast, Pyex.Builtins.env(), ctx)
    end
  end)

avg_micro = time_micro / iterations
throughput = 1_000_000 / avg_micro
per_iter = avg_micro / 100

IO.puts("Iterations: #{iterations}")
IO.puts("Total time: #{Float.round(time_micro / 1000, 2)} ms")
IO.puts("Average per run: #{Float.round(avg_micro, 2)} µs")
IO.puts("Throughput: #{Float.round(throughput, 0)} runs/sec")
IO.puts("Per-loop iteration: #{Float.round(per_iter, 2)} µs")

# Now let's verify it actually works and show what we read
IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("Verification - reading results from filesystem")
IO.puts("=" |> String.duplicate(70))

ctx = Ctx.new(filesystem: Pyex.Filesystem.Memory.new())
{:ok, _, _, final_ctx} = Interpreter.run_with_ctx(ast, Pyex.Builtins.env(), ctx)

# Read back from filesystem
{:ok, content} = Pyex.Filesystem.Memory.read(final_ctx.filesystem, "/tmp/fizzbuzz_results.txt")
lines = String.split(content, "\n", trim: true)

IO.puts("Wrote #{length(lines)} lines to filesystem")
IO.puts("")
IO.puts("First 10 lines:")
Enum.take(lines, 10) |> Enum.each(&IO.puts("  #{&1}"))
IO.puts("  ...")
IO.puts("Last 5 lines:")
Enum.drop(lines, 95) |> Enum.each(&IO.puts("  #{&1}"))
