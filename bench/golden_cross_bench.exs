# Golden cross detection benchmark: naive Python vs pandas (Explorer/Polars).
#
# Prices are injected via a custom `platform` module, just like production:
#
#     import platform
#     prices = platform.get_prices("AAPL")
#
# Usage:
#   mix run bench/golden_cross_bench.exs
#
# Compares three approaches at 300 and 1000 price points:
# - Naive: O(n*w) nested loop SMA on a plain Python list
# - Prefix sum: O(n) prefix-sum SMA on a plain Python list
# - Pandas: Explorer/Polars rolling window (Rust NIF) on a Series

defmodule GoldenCrossBench do
  def naive_code do
    """
    import platform
    prices = platform.get_prices("AAPL").tolist()

    def sma(data, window):
        result = []
        for i in range(len(data)):
            if i < window - 1:
                result.append(None)
            else:
                total = 0
                for j in range(window):
                    total += data[i - j]
                result.append(total / window)
        return result

    sma50 = sma(prices, 50)
    sma200 = sma(prices, 200)

    signals = []
    for i in range(1, len(prices)):
        if sma50[i] is not None and sma200[i] is not None:
            if sma50[i - 1] is not None and sma200[i - 1] is not None:
                if sma50[i] > sma200[i] and sma50[i - 1] <= sma200[i - 1]:
                    signals.append(i)
    signals
    """
  end

  def prefix_code do
    """
    import platform
    prices = platform.get_prices("AAPL").tolist()

    def sma_prefix(data, window):
        n = len(data)
        prefix = [0.0] * (n + 1)
        for i in range(n):
            prefix[i + 1] = prefix[i] + data[i]
        result = []
        for i in range(n):
            if i < window - 1:
                result.append(None)
            else:
                result.append((prefix[i + 1] - prefix[i + 1 - window]) / window)
        return result

    sma50 = sma_prefix(prices, 50)
    sma200 = sma_prefix(prices, 200)

    signals = []
    for i in range(1, len(prices)):
        if sma50[i] is not None and sma200[i] is not None:
            if sma50[i - 1] is not None and sma200[i - 1] is not None:
                if sma50[i] > sma200[i] and sma50[i - 1] <= sma200[i - 1]:
                    signals.append(i)
    signals
    """
  end

  def pandas_code do
    """
    import pandas as pd
    import platform

    prices = platform.get_prices("AAPL")
    sma50 = prices.rolling(50).mean()
    sma200 = prices.rolling(200).mean()
    diff = sma50 - sma200
    diff_list = diff.tolist()

    signals = []
    for i in range(1, len(diff_list)):
        if diff_list[i] is not None and diff_list[i - 1] is not None:
            if diff_list[i] > 0 and diff_list[i - 1] <= 0:
                signals.append(i)
    signals
    """
  end

  def generate_prices(n) do
    :rand.seed(:exsss, {42, 42, 42})

    Enum.scan(1..n, 100.0, fn _, prev ->
      change = (:rand.uniform() - 0.48) * 4
      Float.round(max(prev + change, 1.0), 2)
    end)
  end

  def platform_module(prices) do
    series = {:pandas_series, Explorer.Series.from_list(prices)}
    %{"platform" => %{"get_prices" => {:builtin, fn [_symbol] -> series end}}}
  end

  def run_bench(label, code, opts, runs) do
    for _ <- 1..3, do: Pyex.run!(code, opts)

    times =
      for _ <- 1..runs do
        {us, _} = :timer.tc(fn -> Pyex.run!(code, opts) end)
        us
      end

    sorted = Enum.sort(times)
    n = length(sorted)
    p = fn pct -> Enum.at(sorted, min(round(n * pct / 100), n - 1)) end

    IO.puts("  #{label}:")

    IO.puts(
      "    min=#{fmt(hd(sorted))} p50=#{fmt(p.(50))} p95=#{fmt(p.(95))} max=#{fmt(List.last(sorted))}"
    )

    Enum.at(sorted, div(n, 2))
  end

  def fmt(us) when us < 1_000, do: "#{us}us"
  def fmt(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  def fmt(us), do: "#{Float.round(us / 1_000_000, 2)}s"
end

IO.puts("=== Golden Cross Benchmark ===\n")

for n <- [300, 1000] do
  prices = GoldenCrossBench.generate_prices(n)
  modules = GoldenCrossBench.platform_module(prices)
  opts = [timeout_ms: 30_000, modules: modules]
  runs = if n <= 300, do: 20, else: 10

  IO.puts("#{n} price points (#{runs} runs):")

  naive_p50 =
    GoldenCrossBench.run_bench("Naive (O(n*w) loop)", GoldenCrossBench.naive_code(), opts, runs)

  prefix_p50 =
    GoldenCrossBench.run_bench("Prefix sum (O(n))", GoldenCrossBench.prefix_code(), opts, runs)

  pandas_p50 =
    GoldenCrossBench.run_bench(
      "Pandas/Explorer (Rust)",
      GoldenCrossBench.pandas_code(),
      opts,
      runs
    )

  IO.puts(
    "  Speedup: naive/pandas=#{Float.round(naive_p50 / max(pandas_p50, 1), 1)}x  prefix/pandas=#{Float.round(prefix_p50 / max(pandas_p50, 1), 1)}x"
  )

  IO.puts("")
end
