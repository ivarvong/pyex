defmodule Pyex.MathOracleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pyex.Filesystem.Memory

  @moduledoc """
  Cross-checks LLM-style Python math code against an Elixir oracle.

  The Python program:
  - generates a list of dict rows with consistent keys
  - generates random integers (seeded) per cell
  - writes the rows to CSV in the in-memory filesystem
  - reads the CSV back and computes stats using basic Python

  The Elixir side reads the exact CSV content and computes the same
  stats as the oracle, then compares within float tolerance.
  """

  @runs 200
  @timeout_ms 500

  property "stats computed in Python match the Elixir oracle" do
    check all(
            seed <- integer(0..1_000_000_000),
            row_count <- integer(1..60),
            col_count <- integer(1..8),
            max_runs: @runs
          ) do
      source = python_source(seed, row_count, col_count)

      opts = [filesystem: Memory.new(), fs_module: Memory, timeout_ms: @timeout_ms]

      {:ok, py_stats, ctx} = run_pyex_isolated(source, opts)
      {:ok, csv} = Memory.read(ctx.filesystem, "data.csv")

      oracle_stats = oracle_stats_from_csv(csv)
      assert_stats_close(py_stats, oracle_stats)
    end
  end

  defp run_pyex_isolated(source, opts) do
    Task.async(fn -> Pyex.run(source, opts) end)
    |> Task.await(@timeout_ms * 5)
  end

  defp python_source(seed, row_count, col_count) do
    """
    import csv
    import random

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

    def median_reverse(xs):
        ys = sorted(xs, reverse=True)
        n = len(ys)
        mid = n // 2
        if n % 2 == 1:
            return ys[n - 1 - mid]
        a = ys[n - 1 - (mid - 1)]
        b = ys[n - 1 - mid]
        return (a + b) / 2

    def variance_two_pass(xs):
        m = mean_loop(xs)
        squares = map(lambda x: (x - m) * (x - m), xs)
        return sum(squares) / len(xs)

    def variance_reduce(xs):
        m = mean_reduce(xs)
        acc = reduce(lambda a, x: a + (x - m) * (x - m), xs, 0.0)
        return acc / len(xs)

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

    def stddev_pop(xs):
        return variance_two_pass(xs) ** 0.5

    def stats_for(xs):
        if len(xs) == 0:
            return {
                "count": 0,
                "sum": 0,
                "min": None,
                "max": None,
                "mean": None,
                "median": None,
                "variance_pop": None,
                "stddev_pop": None,
                "sorted": [],
                "sorted_reverse": [],
                "sorted_abs": [],
            }

        sum_builtin = sum(xs)
        min_builtin = min(xs)
        max_builtin = max(xs)

        mean_a = mean_loop(xs)
        med_a = median_sorted(xs)
        var_a = variance_two_pass(xs)
        std_a = var_a ** 0.5

        return {
            "count": len(xs),
            "sum": sum_builtin,
            "min": min_builtin,
            "max": max_builtin,
            "mean": mean_a,
            "median": med_a,
            "variance_pop": var_a,
            "stddev_pop": std_a,
            "sorted": sorted(xs),
            "sorted_reverse": sorted(xs, reverse=True),
            "sorted_abs": sorted(xs, key=abs),
        }

    random.seed(#{seed})
    fieldnames = ["c" + str(i) for i in range(#{col_count})]

    rows = []
    for _ in range(#{row_count}):
        values = [random.randint(-1000, 1000) for _ in fieldnames]
        row = dict(zip(fieldnames, values))
        rows.append(row)

    assert all([len(r) == len(fieldnames) and all([name in r for name in fieldnames]) for r in rows])

    f = open("data.csv", "w")
    w = csv.DictWriter(f, fieldnames)
    w.writeheader()
    w.writerows(rows)
    f.close()

    f = open("data.csv")
    parsed = list(csv.DictReader(f))
    f.close()

    cols = {name: [] for name in fieldnames}
    for _, row in enumerate(parsed):
        for name in fieldnames:
            cols[name].append(int(row.get(name)))

    stats = {}
    for name in fieldnames:
        xs = cols[name]

        sum_builtin = sum(xs)
        sum_a = sum_loop(xs)
        sum_b = sum_reduce(xs)

        min_builtin = min(xs)
        min_a = min_loop(xs)
        min_b = min_reduce(xs)

        max_builtin = max(xs)
        max_a = max_loop(xs)
        max_b = max_reduce(xs)

        mean_a = mean_loop(xs)
        mean_b = mean_reduce(xs)
        mean_c = sum_builtin / len(xs)

        med_a = median_sorted(xs)
        med_b = median_reverse(xs)
        med_c = median_sorted(sorted(xs, key=lambda x: x))

        var_a = variance_two_pass(xs)
        var_b = variance_reduce(xs)
        var_c = variance_welford(xs)

        std_a = var_a ** 0.5
        std_b = stddev_pop(xs)

        neg = list(filter(lambda x: x < 0, xs))
        squares = list(map(lambda x: x * x, xs))

        stats[name] = {
            "count": len(xs),
            "sum": sum_builtin,
            "min": min_builtin,
            "max": max_builtin,
            "mean": mean_a,
            "median": med_a,
            "variance_pop": var_a,
            "stddev_pop": std_a,
            "sorted": sorted(xs),
            "sorted_reverse": sorted(xs, reverse=True),
            "sorted_abs": sorted(xs, key=abs),
            "subsets": {
                "neg": stats_for(list(filter(lambda x: x < 0, xs))),
                "even": stats_for(list(filter(lambda x: x % 2 == 0, xs))),
                "smallabs": stats_for([x for x in xs if abs(x) <= 10]),
            },
            "variants": {
                "sum_loop": sum_a,
                "sum_reduce": sum_b,
                "min_loop": min_a,
                "min_reduce": min_b,
                "max_loop": max_a,
                "max_reduce": max_b,
                "mean_reduce": mean_b,
                "mean_sum_div": mean_c,
                "median_reverse": med_b,
                "median_key_sorted": med_c,
                "variance_reduce": var_b,
                "variance_welford": var_c,
                "stddev_via_two_pass": std_b,
                "neg_count": len(neg),
                "squares_sum": sum(squares),
                "sorted": sorted(xs),
                "sorted_reverse": sorted(xs, reverse=True),
                "sorted_key": sorted(xs, key=lambda x: x),
                "sorted_abs": sorted(xs, key=abs),
            },
        }

    stats
    """
  end

  defp oracle_stats_from_csv(csv) when is_binary(csv) do
    lines =
      csv
      |> String.split(~r/\r\n|\n|\r/)
      |> Enum.reject(&(&1 == ""))

    [header | data_lines] = lines
    fieldnames = String.split(header, ",")

    values_by_field =
      Enum.reduce(fieldnames, %{}, fn name, acc -> Map.put(acc, name, []) end)

    values_by_field =
      Enum.reduce(data_lines, values_by_field, fn line, acc ->
        fields = String.split(line, ",")

        Enum.zip(fieldnames, fields)
        |> Enum.reduce(acc, fn {name, value}, acc2 ->
          n = String.to_integer(value)
          Map.update!(acc2, name, fn xs -> [n | xs] end)
        end)
      end)

    values_by_field
    |> Enum.map(fn {name, xs_rev} ->
      xs = Enum.reverse(xs_rev)

      stats = %{
        "count" => length(xs),
        "sum" => Enum.sum(xs),
        "min" => Enum.min(xs),
        "max" => Enum.max(xs),
        "mean" => mean(xs),
        "median" => median(xs),
        "variance_pop" => variance_pop(xs),
        "stddev_pop" => :math.sqrt(variance_pop(xs)),
        "sorted" => Enum.sort(xs),
        "sorted_reverse" => Enum.sort(xs, :desc),
        "sorted_abs" => Enum.sort_by(xs, &abs/1),
        "subsets" => %{
          "neg" => oracle_subset_stats(xs, fn x -> x < 0 end),
          "even" => oracle_subset_stats(xs, fn x -> rem(x, 2) == 0 end),
          "smallabs" => oracle_subset_stats(xs, fn x -> abs(x) <= 10 end)
        }
      }

      {name, stats}
    end)
    |> Map.new()
  end

  defp oracle_subset_stats(xs, pred) when is_list(xs) and is_function(pred, 1) do
    subset = Enum.filter(xs, pred)

    if subset == [] do
      %{
        "count" => 0,
        "sum" => 0,
        "min" => nil,
        "max" => nil,
        "mean" => nil,
        "median" => nil,
        "variance_pop" => nil,
        "stddev_pop" => nil,
        "sorted" => [],
        "sorted_reverse" => [],
        "sorted_abs" => []
      }
    else
      var = variance_pop(subset)

      %{
        "count" => length(subset),
        "sum" => Enum.sum(subset),
        "min" => Enum.min(subset),
        "max" => Enum.max(subset),
        "mean" => mean(subset),
        "median" => median(subset),
        "variance_pop" => var,
        "stddev_pop" => :math.sqrt(var),
        "sorted" => Enum.sort(subset),
        "sorted_reverse" => Enum.sort(subset, :desc),
        "sorted_abs" => Enum.sort_by(subset, &abs/1)
      }
    end
  end

  defp mean(xs) when is_list(xs) and xs != [] do
    Enum.sum(xs) / length(xs)
  end

  defp median(xs) when is_list(xs) and xs != [] do
    ys = Enum.sort(xs)
    n = length(ys)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(ys, mid)
    else
      (Enum.at(ys, mid - 1) + Enum.at(ys, mid)) / 2
    end
  end

  defp variance_pop(xs) when is_list(xs) and xs != [] do
    m = mean(xs)

    Enum.reduce(xs, 0.0, fn x, acc ->
      d = x - m
      acc + d * d
    end) / length(xs)
  end

  defp assert_stats_close(py_stats, oracle_stats)
       when is_map(py_stats) and is_map(oracle_stats) do
    assert Map.keys(py_stats) |> Enum.sort() == Map.keys(oracle_stats) |> Enum.sort()

    Enum.each(oracle_stats, fn {name, oracle} ->
      py = Map.fetch!(py_stats, name)
      variants = Map.fetch!(py, "variants")
      py_subsets = Map.fetch!(py, "subsets")
      oracle_subsets = Map.fetch!(oracle, "subsets")

      assert py["count"] == oracle["count"]
      assert py["sum"] == oracle["sum"]
      assert py["min"] == oracle["min"]
      assert py["max"] == oracle["max"]

      assert_close(py["mean"], oracle["mean"])
      assert_close(py["median"], oracle["median"])
      assert_close(py["variance_pop"], oracle["variance_pop"])
      assert_close(py["stddev_pop"], oracle["stddev_pop"])

      assert py["sorted"] == oracle["sorted"]
      assert py["sorted_reverse"] == oracle["sorted_reverse"]
      assert py["sorted_abs"] == oracle["sorted_abs"]

      assert variants["sum_loop"] == oracle["sum"]
      assert variants["sum_reduce"] == oracle["sum"]
      assert variants["min_loop"] == oracle["min"]
      assert variants["min_reduce"] == oracle["min"]
      assert variants["max_loop"] == oracle["max"]
      assert variants["max_reduce"] == oracle["max"]

      assert_close(variants["mean_reduce"], oracle["mean"])
      assert_close(variants["mean_sum_div"], oracle["mean"])
      assert_close(variants["median_reverse"], oracle["median"])
      assert_close(variants["median_key_sorted"], oracle["median"])
      assert_close(variants["variance_reduce"], oracle["variance_pop"])
      assert_close(variants["variance_welford"], oracle["variance_pop"])
      assert_close(variants["stddev_via_two_pass"], oracle["stddev_pop"])

      assert variants["sorted"] == oracle["sorted"]
      assert variants["sorted_reverse"] == oracle["sorted_reverse"]
      assert variants["sorted_key"] == oracle["sorted"]
      assert variants["sorted_abs"] == oracle["sorted_abs"]

      assert is_integer(variants["neg_count"])
      assert variants["neg_count"] >= 0
      assert variants["neg_count"] <= oracle["count"]
      assert is_integer(variants["squares_sum"])

      assert_subset_stats_close(Map.fetch!(py_subsets, "neg"), Map.fetch!(oracle_subsets, "neg"))

      assert_subset_stats_close(
        Map.fetch!(py_subsets, "even"),
        Map.fetch!(oracle_subsets, "even")
      )

      assert_subset_stats_close(
        Map.fetch!(py_subsets, "smallabs"),
        Map.fetch!(oracle_subsets, "smallabs")
      )
    end)
  end

  defp assert_subset_stats_close(py, oracle) when is_map(py) and is_map(oracle) do
    assert py["count"] == oracle["count"]
    assert py["sum"] == oracle["sum"]
    assert py["min"] == oracle["min"]
    assert py["max"] == oracle["max"]

    assert_close_or_nil(py["mean"], oracle["mean"])
    assert_close_or_nil(py["median"], oracle["median"])
    assert_close_or_nil(py["variance_pop"], oracle["variance_pop"])
    assert_close_or_nil(py["stddev_pop"], oracle["stddev_pop"])

    assert py["sorted"] == oracle["sorted"]
    assert py["sorted_reverse"] == oracle["sorted_reverse"]
    assert py["sorted_abs"] == oracle["sorted_abs"]
  end

  defp assert_close_or_nil(nil, nil), do: :ok
  defp assert_close_or_nil(a, b), do: assert_close(a, b)

  defp assert_close(a, b) when is_integer(a) and is_integer(b), do: assert(a == b)

  defp assert_close(a, b) when is_number(a) and is_number(b) do
    a = a * 1.0
    b = b * 1.0
    diff = abs(a - b)
    scale = max(abs(a), abs(b))
    tol = max(1.0e-9, scale * 1.0e-9)
    assert diff <= tol
  end
end
