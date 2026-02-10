alias Pyex.Ctx

ctx = %{
  Ctx.new(timeout_ms: 200)
  | compute_ns: 0,
    compute_started_at: System.monotonic_time(:nanosecond)
}

programs = %{
  "gen_range(5)" => """
  def gen_range(n):
      i = 0
      while i < n:
          yield i
          i += 1
  list(gen_range(5))
  """,
  "gen_range(10)" => """
  def gen_range(n):
      i = 0
      while i < n:
          yield i
          i += 1
  list(gen_range(10))
  """,
  "squares(5)" => """
  def squares(n):
      for i in range(n):
          yield i * i
  list(squares(5))
  """,
  "squares(8)" => """
  def squares(n):
      for i in range(n):
          yield i * i
  list(squares(8))
  """,
  "fibonacci(10)" => """
  def fibonacci(n):
      a, b = 0, 1
      for _ in range(n):
          yield a
          a, b = b, a + b
  list(fibonacci(10))
  """,
  "chain(3)" => """
  def chain(*iterables):
      for it in iterables:
          yield from it
  list(chain(range(3), range(3)))
  """,
  "chain(5)" => """
  def chain(*iterables):
      for it in iterables:
          yield from it
  list(chain(range(5), range(5)))
  """,
  "filtered(5)" => """
  def filtered(n):
      for x in range(n):
          if x % 2 == 0:
              yield x
  list(filtered(5))
  """,
  "filtered(10)" => """
  def filtered(n):
      for x in range(n):
          if x > 3:
              yield x
  list(filtered(10))
  """
}

IO.puts("=== Individual program benchmarks ===\n")

for {name, code} <- Enum.sort(programs) do
  times =
    for _ <- 1..100 do
      fresh = %{ctx | compute_ns: 0, compute_started_at: System.monotonic_time(:nanosecond)}
      t0 = System.monotonic_time(:microsecond)
      Pyex.run(code, fresh)
      System.monotonic_time(:microsecond) - t0
    end

  avg = Enum.sum(times) / length(times)
  p50 = Enum.sort(times) |> Enum.at(49)
  p95 = Enum.sort(times) |> Enum.at(94)
  p99 = Enum.sort(times) |> Enum.at(98)
  max = Enum.max(times)

  IO.puts(
    "#{String.pad_trailing(name, 18)} avg=#{Float.round(avg / 1000, 2)}ms  " <>
      "p50=#{Float.round(p50 / 1000, 2)}ms  p95=#{Float.round(p95 / 1000, 2)}ms  " <>
      "p99=#{Float.round(p99 / 1000, 2)}ms  max=#{Float.round(max / 1000, 2)}ms"
  )
end

IO.puts("\n=== Breakdown: compile vs interpret ===\n")

for {name, code} <- [
      {"fibonacci(10)", programs["fibonacci(10)"]},
      {"squares(8)", programs["squares(8)"]}
    ] do
  compile_times =
    for _ <- 1..100 do
      t0 = System.monotonic_time(:microsecond)
      {:ok, _ast} = Pyex.compile(code)
      System.monotonic_time(:microsecond) - t0
    end

  {:ok, ast} = Pyex.compile(code)

  interpret_times =
    for _ <- 1..100 do
      fresh = %{ctx | compute_ns: 0, compute_started_at: System.monotonic_time(:nanosecond)}
      t0 = System.monotonic_time(:microsecond)
      Pyex.run(ast, fresh)
      System.monotonic_time(:microsecond) - t0
    end

  c_avg = Enum.sum(compile_times) / length(compile_times)
  i_avg = Enum.sum(interpret_times) / length(interpret_times)

  IO.puts(
    "#{String.pad_trailing(name, 18)} compile=#{Float.round(c_avg / 1000, 2)}ms  " <>
      "interpret=#{Float.round(i_avg / 1000, 2)}ms  " <>
      "total=#{Float.round((c_avg + i_avg) / 1000, 2)}ms"
  )
end

IO.puts("\n=== 500 runs simulating property test ===\n")

all_programs = Map.values(programs)

t0 = System.monotonic_time(:millisecond)

for _ <- 1..500 do
  code = Enum.random(all_programs)
  fresh = %{ctx | compute_ns: 0, compute_started_at: System.monotonic_time(:nanosecond)}
  Pyex.run(code, fresh)
end

elapsed = System.monotonic_time(:millisecond) - t0
IO.puts("500 random runs: #{elapsed}ms (avg #{Float.round(elapsed / 500, 2)}ms/run)")
