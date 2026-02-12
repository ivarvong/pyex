# Benchmarks the math oracle workload (same Python programs as the property tests).
#
# Usage:
#   mix run bench/math_oracle_bench.exs
#
# Runs the full integer stats program at several data sizes and reports
# p50/p95/p99/min/max timing.

alias Pyex.Filesystem.Memory

defmodule MathOracleBench do
  def python_source(_row_count) do
    """
    import csv

    def reduce(fn, xs, init):
        acc = init
        for x in xs:
            acc = fn(acc, x)
        return acc

    def sum_loop(xs):
        total = 0
        for x in xs:
            total += x
        return total

    def sum_reduce(xs):
        return reduce(lambda acc, x: acc + x, xs, 0)

    def min_loop(xs):
        m = xs[0]
        for x in xs:
            if x < m:
                m = x
        return m

    def max_loop(xs):
        m = xs[0]
        for x in xs:
            if x > m:
                m = x
        return m

    def min_reduce(xs):
        return reduce(lambda m, x: x if x < m else m, xs[1:], xs[0])

    def max_reduce(xs):
        return reduce(lambda m, x: x if x > m else m, xs[1:], xs[0])

    def mean_loop(xs):
        return sum_loop(xs) / len(xs)

    def mean_reduce(xs):
        return sum_reduce(xs) / len(xs)

    def median_sorted(xs):
        ys = sorted(xs)
        n = len(ys)
        mid = n // 2
        if n % 2 == 1:
            return ys[mid]
        return (ys[mid - 1] + ys[mid]) / 2

    def variance_two_pass(xs):
        m = mean_loop(xs)
        squares = list(map(lambda x: (x - m) * (x - m), xs))
        return sum(squares) / len(xs)

    def variance_welford(xs):
        n = 0
        mean = 0.0
        m2 = 0.0
        for x in xs:
            n += 1
            dx = x - mean
            mean += dx / n
            m2 += dx * (x - mean)
        return m2 / n

    f = open("data.csv")
    parsed = list(csv.DictReader(f))
    f.close()
    xs = [int(row["x"]) for row in parsed]

    {
        "sum": sum(xs),
        "sum_loop": sum_loop(xs),
        "sum_reduce": sum_reduce(xs),
        "min": min(xs),
        "min_loop": min_loop(xs),
        "min_reduce": min_reduce(xs),
        "max": max(xs),
        "max_loop": max_loop(xs),
        "max_reduce": max_reduce(xs),
        "mean": mean_loop(xs),
        "mean_reduce": mean_reduce(xs),
        "median": median_sorted(xs),
        "var_two_pass": variance_two_pass(xs),
        "var_welford": variance_welford(xs),
        "sorted": sorted(xs),
        "sorted_rev": sorted(xs, reverse=True),
        "sorted_abs": sorted(xs, key=abs),
        "neg": sorted(list(filter(lambda x: x < 0, xs))),
        "even": sorted(list(filter(lambda x: x % 2 == 0, xs))),
    }
    """
  end

  def build_csv(row_count) do
    header = "x"
    rows = for _ <- 1..row_count, do: Integer.to_string(Enum.random(-1000..1000))
    Enum.join([header | rows], "\r\n") <> "\r\n"
  end

  def run_bench(label, row_count, runs) do
    csv = build_csv(row_count)
    fs = Memory.new()
    {:ok, fs} = Memory.write(fs, "data.csv", csv, :write)
    opts = [filesystem: fs, timeout_ms: 5000]
    source = python_source(row_count)

    # warm up
    for _ <- 1..3, do: Pyex.run!(source, opts)

    times =
      for _ <- 1..runs do
        {us, _} = :timer.tc(fn -> Pyex.run!(source, opts) end)
        us
      end

    sorted = Enum.sort(times)
    n = length(sorted)
    p = fn pct -> Enum.at(sorted, min(round(n * pct / 100), n - 1)) end

    IO.puts("#{label} (#{runs} runs, #{row_count} rows):")

    IO.puts(
      "  min=#{fmt(hd(sorted))} p50=#{fmt(p.(50))} p95=#{fmt(p.(95))} p99=#{fmt(p.(99))} max=#{fmt(List.last(sorted))}"
    )
  end

  def fmt(us) when us < 1_000, do: "#{us}us"
  def fmt(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  def fmt(us), do: "#{Float.round(us / 1_000_000, 2)}s"
end

IO.puts("=== Math Oracle Benchmark ===\n")
MathOracleBench.run_bench("  10 rows", 10, 100)
MathOracleBench.run_bench("  30 rows", 30, 100)
MathOracleBench.run_bench("  60 rows", 60, 50)
