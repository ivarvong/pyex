defmodule Pyex.MathOracleTest do
  @moduledoc """
  Cross-checks LLM-style Python math code against an Explorer (Polars/Rust) oracle.

  The Python program generates random datasets, writes them as CSV to the
  in-memory filesystem, reads them back, and computes statistics using
  multiple independent algorithm implementations (loops, reduce, map,
  filter, Welford, etc.). Every result is returned to the Elixir test.

  The Elixir side parses the same CSV with Explorer (backed by Polars,
  written in Rust) — a completely independent implementation in a
  different language — and asserts that every Python result matches
  the Polars-computed oracle.

  This makes it essentially impossible for a shared bug to pass:
  the Python interpreter, the Elixir test helpers, and the Polars
  engine would all need the same defect.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Explorer.Series
  alias Pyex.Filesystem.Memory

  @runs 200
  @timeout_ms 500

  property "stats computed in Python match the Explorer/Polars oracle" do
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

      oracle = explorer_oracle(csv)
      assert_all_stats(py_stats, oracle)
    end
  end

  defp run_pyex_isolated(source, opts) do
    Task.async(fn -> Pyex.run(source, opts) end)
    |> Task.await(@timeout_ms * 5)
  end

  # ---------------------------------------------------------------------------
  # Explorer/Polars oracle
  # ---------------------------------------------------------------------------

  defp explorer_oracle(csv) when is_binary(csv) do
    lines =
      csv
      |> String.split(~r/\r\n|\n|\r/)
      |> Enum.reject(&(&1 == ""))

    [header | data_lines] = lines
    fieldnames = String.split(header, ",")

    values_by_field =
      Enum.reduce(data_lines, %{}, fn line, acc ->
        fields = String.split(line, ",")

        Enum.zip(fieldnames, fields)
        |> Enum.reduce(acc, fn {name, val}, acc2 ->
          Map.update(acc2, name, [String.to_integer(val)], fn xs ->
            xs ++ [String.to_integer(val)]
          end)
        end)
      end)

    values_by_field
    |> Enum.map(fn {name, xs} ->
      s = Series.from_list(xs)
      {name, explorer_stats_for_series(s, xs)}
    end)
    |> Map.new()
  end

  defp explorer_stats_for_series(s, xs) do
    n = Series.count(s)
    sorted = Series.sort(s) |> Series.to_list()
    sorted_desc = Series.sort(s, direction: :desc) |> Series.to_list()

    abs_s = Series.abs(s)
    rank = Series.argsort(abs_s)
    sorted_abs = Series.slice(s, rank) |> Series.to_list()

    sample_var = if n > 1, do: Series.variance(s), else: 0.0
    pop_var = if n > 1, do: sample_var * (n - 1) / n, else: 0.0

    neg_mask = Series.less(s, 0)
    neg = Series.mask(s, neg_mask)
    even_mask = Series.equal(Series.remainder(s, 2), 0)
    even = Series.mask(s, even_mask)
    smallabs_mask = Series.less_equal(abs_s, 10)
    smallabs = Series.mask(s, smallabs_mask)

    %{
      "count" => n,
      "sum" => Series.sum(s),
      "min" => Series.min(s),
      "max" => Series.max(s),
      "mean" => Series.mean(s),
      "median" => Series.median(s),
      "variance_pop" => pop_var,
      "stddev_pop" => :math.sqrt(pop_var),
      "sorted" => sorted,
      "sorted_reverse" => sorted_desc,
      "sorted_abs" => sorted_abs,
      "subsets" => %{
        "neg" => explorer_subset_stats(neg, Enum.filter(xs, &(&1 < 0))),
        "even" => explorer_subset_stats(even, Enum.filter(xs, &(rem(&1, 2) == 0))),
        "smallabs" => explorer_subset_stats(smallabs, Enum.filter(xs, &(abs(&1) <= 10)))
      }
    }
  end

  defp explorer_subset_stats(series, _xs) do
    n = Series.count(series)

    if n == 0 do
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
      sorted = Series.sort(series) |> Series.to_list()
      sorted_desc = Series.sort(series, direction: :desc) |> Series.to_list()

      abs_s = Series.abs(series)
      rank = Series.argsort(abs_s)
      sorted_abs = Series.slice(series, rank) |> Series.to_list()

      sample_var = if n > 1, do: Series.variance(series), else: 0.0
      pop_var = if n > 1, do: sample_var * (n - 1) / n, else: 0.0

      %{
        "count" => n,
        "sum" => Series.sum(series),
        "min" => Series.min(series),
        "max" => Series.max(series),
        "mean" => Series.mean(series),
        "median" => Series.median(series),
        "variance_pop" => pop_var,
        "stddev_pop" => :math.sqrt(pop_var),
        "sorted" => sorted,
        "sorted_reverse" => sorted_desc,
        "sorted_abs" => sorted_abs
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Python source generator
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Assertion helpers
  # ---------------------------------------------------------------------------

  defp assert_all_stats(py_stats, oracle)
       when is_map(py_stats) and is_map(oracle) do
    assert Map.keys(py_stats) |> Enum.sort() == Map.keys(oracle) |> Enum.sort()

    Enum.each(oracle, fn {name, expected} ->
      py = Map.fetch!(py_stats, name)
      variants = Map.fetch!(py, "variants")
      py_subsets = Map.fetch!(py, "subsets")
      oracle_subsets = Map.fetch!(expected, "subsets")

      assert py["count"] == expected["count"]
      assert py["sum"] == expected["sum"]
      assert py["min"] == expected["min"]
      assert py["max"] == expected["max"]

      assert_close(py["mean"], expected["mean"])
      assert_close(py["median"], expected["median"])
      assert_close(py["variance_pop"], expected["variance_pop"])
      assert_close(py["stddev_pop"], expected["stddev_pop"])

      assert py["sorted"] == expected["sorted"]
      assert py["sorted_reverse"] == expected["sorted_reverse"]
      assert py["sorted_abs"] == expected["sorted_abs"]

      assert variants["sum_loop"] == expected["sum"]
      assert variants["sum_reduce"] == expected["sum"]
      assert variants["min_loop"] == expected["min"]
      assert variants["min_reduce"] == expected["min"]
      assert variants["max_loop"] == expected["max"]
      assert variants["max_reduce"] == expected["max"]

      assert_close(variants["mean_reduce"], expected["mean"])
      assert_close(variants["mean_sum_div"], expected["mean"])
      assert_close(variants["median_reverse"], expected["median"])
      assert_close(variants["median_key_sorted"], expected["median"])
      assert_close(variants["variance_reduce"], expected["variance_pop"])
      assert_close(variants["variance_welford"], expected["variance_pop"])
      assert_close(variants["stddev_via_two_pass"], expected["stddev_pop"])

      assert variants["sorted"] == expected["sorted"]
      assert variants["sorted_reverse"] == expected["sorted_reverse"]
      assert variants["sorted_key"] == expected["sorted"]
      assert variants["sorted_abs"] == expected["sorted_abs"]

      assert is_integer(variants["neg_count"])
      assert variants["neg_count"] >= 0
      assert variants["neg_count"] <= expected["count"]
      assert is_integer(variants["squares_sum"])

      Enum.each(["neg", "even", "smallabs"], fn subset_name ->
        assert_subset_stats(
          Map.fetch!(py_subsets, subset_name),
          Map.fetch!(oracle_subsets, subset_name)
        )
      end)
    end)
  end

  defp assert_subset_stats(py, expected) when is_map(py) and is_map(expected) do
    assert py["count"] == expected["count"]
    assert py["sum"] == expected["sum"]
    assert py["min"] == expected["min"]
    assert py["max"] == expected["max"]

    assert_close_or_nil(py["mean"], expected["mean"])
    assert_close_or_nil(py["median"], expected["median"])
    assert_close_or_nil(py["variance_pop"], expected["variance_pop"])
    assert_close_or_nil(py["stddev_pop"], expected["stddev_pop"])

    assert py["sorted"] == expected["sorted"]
    assert py["sorted_reverse"] == expected["sorted_reverse"]
    assert py["sorted_abs"] == expected["sorted_abs"]
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
