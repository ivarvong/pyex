source = File.read!("scripts/encode.py")
{:ok, ast} = Pyex.compile(source)

n = 500

run_us = elem(:timer.tc(fn -> for _ <- 1..n, do: Pyex.run!(source) end), 0) |> div(n)
eval_us = elem(:timer.tc(fn -> for _ <- 1..n, do: Pyex.run!(ast) end), 0) |> div(n)
compile_us = elem(:timer.tc(fn -> for _ <- 1..n, do: Pyex.compile(source) end), 0) |> div(n)

IO.puts("encode.py (avg of #{n} runs):")
IO.puts("  Pyex.run!(source):  #{run_us}μs")
IO.puts("  Pyex.compile(src):  #{compile_us}μs")
IO.puts("  Pyex.run!(ast):     #{eval_us}μs")
IO.puts("  compile+eval:       #{compile_us + eval_us}μs")

IO.puts(
  "  savings:            #{run_us - eval_us}μs (#{round((run_us - eval_us) / run_us * 100)}%)"
)
