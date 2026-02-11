defmodule Pyex.MathOracleTest do
  @moduledoc """
  Property tests that cross-check Python math against an Explorer/Polars oracle.

  Data flows: Elixir generates random numbers, writes CSV to an in-memory
  filesystem, Python reads the CSV and computes stats, Elixir asserts
  against Polars. Three languages, three implementations, zero shared code.

  Each property tests one stat computed one way. When a test fails you
  know exactly which algorithm on which number type disagreed with Polars.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pyex.Test.MathOracle, as: Oracle

  @int_runs 200
  @float_runs 200
  @float_tol 1.0e-6

  # ---- generators ----

  defp int_list do
    gen all(
          n <- integer(1..60),
          xs <- list_of(integer(-1000..1000), length: n)
        ) do
      xs
    end
  end

  defp float_list do
    gen all(n <- integer(1..40)) do
      for _ <- 1..n, do: Oracle.random_float()
    end
  end

  # ---- Python function library (shared across tests) ----

  @reduce """
  def reduce(fn, xs, init):
      acc = init
      for x in xs:
          acc = fn(acc, x)
      return acc
  """

  # ---- integer stats ----

  describe "integer sum" do
    property "builtin sum() matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.int_preamble() <> "sum(xs)", opts)
        assert py == Oracle.polars_int(:sum, xs), "sum(xs) for #{inspect(xs)}"
      end
    end

    property "loop accumulator matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              """
              total = 0
              for x in xs:
                  total += x
              total
              """,
            opts
          )

        assert py == Oracle.polars_int(:sum, xs)
      end
    end

    property "reduce with lambda matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              @reduce <>
              "reduce(lambda acc, x: acc + x, xs, 0)",
            opts
          )

        assert py == Oracle.polars_int(:sum, xs)
      end
    end
  end

  describe "integer min" do
    property "builtin min() matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.int_preamble() <> "min(xs)", opts)
        assert py == Oracle.polars_int(:min, xs)
      end
    end

    property "loop scan matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              """
              m = xs[0]
              for x in xs:
                  if x < m:
                      m = x
              m
              """,
            opts
          )

        assert py == Oracle.polars_int(:min, xs)
      end
    end

    property "reduce with ternary lambda matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              @reduce <>
              "reduce(lambda m, x: x if x < m else m, xs[1:], xs[0])",
            opts
          )

        assert py == Oracle.polars_int(:min, xs)
      end
    end
  end

  describe "integer max" do
    property "builtin max() matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.int_preamble() <> "max(xs)", opts)
        assert py == Oracle.polars_int(:max, xs)
      end
    end

    property "loop scan matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              """
              m = xs[0]
              for x in xs:
                  if x > m:
                      m = x
              m
              """,
            opts
          )

        assert py == Oracle.polars_int(:max, xs)
      end
    end

    property "reduce with ternary lambda matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              @reduce <>
              "reduce(lambda m, x: x if x > m else m, xs[1:], xs[0])",
            opts
          )

        assert py == Oracle.polars_int(:max, xs)
      end
    end
  end

  describe "integer mean" do
    property "sum/len matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.int_preamble() <> "sum(xs) / len(xs)", opts)
        assert_close(py, Oracle.polars_int(:mean, xs))
      end
    end

    property "loop-based mean matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              """
              total = 0
              for x in xs:
                  total += x
              total / len(xs)
              """,
            opts
          )

        assert_close(py, Oracle.polars_int(:mean, xs))
      end
    end
  end

  describe "integer median" do
    property "forward sorted median matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              """
              ys = sorted(xs)
              n = len(ys)
              mid = n // 2
              if n % 2 == 1:
                  result = ys[mid]
              else:
                  result = (ys[mid - 1] + ys[mid]) / 2
              result
              """,
            opts
          )

        assert_close(py, Oracle.polars_int(:median, xs))
      end
    end

    property "reverse sorted median matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              """
              ys = sorted(xs, reverse=True)
              n = len(ys)
              mid = n // 2
              if n % 2 == 1:
                  result = ys[n - 1 - mid]
              else:
                  a = ys[n - 1 - (mid - 1)]
                  b = ys[n - 1 - mid]
                  result = (a + b) / 2
              result
              """,
            opts
          )

        assert_close(py, Oracle.polars_int(:median, xs))
      end
    end
  end

  describe "integer variance (population)" do
    property "two-pass (map + sum of squares) matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              """
              mean = sum(xs) / len(xs)
              squares = list(map(lambda x: (x - mean) * (x - mean), xs))
              sum(squares) / len(xs)
              """,
            opts
          )

        assert_close(py, Oracle.polars_int(:variance_pop, xs))
      end
    end

    property "reduce-based matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              @reduce <>
              """
              mean = sum(xs) / len(xs)
              reduce(lambda a, x: a + (x - mean) * (x - mean), xs, 0.0) / len(xs)
              """,
            opts
          )

        assert_close(py, Oracle.polars_int(:variance_pop, xs))
      end
    end

    property "Welford one-pass matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              """
              n = 0
              mean = 0.0
              m2 = 0.0
              for x in xs:
                  n += 1
                  dx = x - mean
                  mean += dx / n
                  m2 += dx * (x - mean)
              m2 / n
              """,
            opts
          )

        assert_close(py, Oracle.polars_int(:variance_pop, xs))
      end
    end
  end

  describe "integer stddev (population)" do
    property "sqrt of two-pass variance matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              """
              mean = sum(xs) / len(xs)
              squares = list(map(lambda x: (x - mean) * (x - mean), xs))
              (sum(squares) / len(xs)) ** 0.5
              """,
            opts
          )

        assert_close(py, Oracle.polars_int(:stddev_pop, xs))
      end
    end
  end

  # ---- integer sorting ----

  describe "integer sorting" do
    property "sorted() matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.int_preamble() <> "sorted(xs)", opts)
        assert py == Oracle.polars_sorted(xs)
      end
    end

    property "sorted(reverse=True) matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.int_preamble() <> "sorted(xs, reverse=True)", opts)
        assert py == Oracle.polars_sorted_desc(xs)
      end
    end

    property "sorted(key=abs) matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.int_preamble() <> "sorted(xs, key=abs)", opts)
        assert py == Oracle.polars_sorted_abs(xs)
      end
    end

    property "sorted(key=lambda x: x) matches sorted()" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.int_preamble() <> "sorted(xs, key=lambda x: x)", opts)
        assert py == Oracle.polars_sorted(xs)
      end
    end
  end

  # ---- integer subsets ----

  describe "integer filtered subsets" do
    property "filter(neg) count and sum match Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              """
              neg = list(filter(lambda x: x < 0, xs))
              neg_sum = sum(neg) if len(neg) > 0 else 0
              {"count": len(neg), "sum": neg_sum}
              """,
            opts
          )

        expected = Oracle.polars_filter(xs, :neg)
        assert py["count"] == length(expected)

        if length(expected) > 0 do
          assert py["sum"] == Oracle.polars_int(:sum, expected)
        end
      end
    end

    property "filter(even) sorted matches Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              "sorted(list(filter(lambda x: x % 2 == 0, xs)))",
            opts
          )

        expected = Oracle.polars_filter(xs, :even)
        assert py == Oracle.polars_sorted(expected)
      end
    end

    property "comprehension filter(smallabs) stats match Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              """
              small = [x for x in xs if abs(x) <= 10]
              {"count": len(small), "sorted": sorted(small)}
              """,
            opts
          )

        expected = Oracle.polars_filter(xs, :smallabs)
        assert py["count"] == length(expected)
        assert py["sorted"] == Oracle.polars_sorted(expected)
      end
    end

    property "negative subset full stats match Polars" do
      check all(xs <- int_list(), max_runs: @int_runs) do
        opts = Oracle.int_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.int_preamble() <>
              """
              neg = list(filter(lambda x: x < 0, xs))
              if len(neg) == 0:
                  result = {"count": 0, "sum": 0, "min": None, "max": None}
              else:
                  result = {"count": len(neg), "sum": sum(neg), "min": min(neg), "max": max(neg)}
              result
              """,
            opts
          )

        expected = Oracle.polars_filter(xs, :neg)
        assert py["count"] == length(expected)

        if length(expected) > 0 do
          assert py["sum"] == Oracle.polars_int(:sum, expected)
          assert py["min"] == Oracle.polars_int(:min, expected)
          assert py["max"] == Oracle.polars_int(:max, expected)
        else
          assert py["sum"] == 0
          assert py["min"] == nil
          assert py["max"] == nil
        end
      end
    end
  end

  # ---- float stats ----

  describe "float sum" do
    property "builtin sum() matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.float_preamble() <> "sum(xs)", opts)
        assert_float_close(py, Oracle.polars_float(:sum, xs))
      end
    end

    property "loop accumulator matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.float_preamble() <>
              """
              total = 0.0
              for x in xs:
                  total += x
              total
              """,
            opts
          )

        assert_float_close(py, Oracle.polars_float(:sum, xs))
      end
    end

    property "reduce with lambda matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.float_preamble() <>
              @reduce <>
              "reduce(lambda acc, x: acc + x, xs, 0.0)",
            opts
          )

        assert_float_close(py, Oracle.polars_float(:sum, xs))
      end
    end
  end

  describe "float min/max" do
    property "builtin min() matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.float_preamble() <> "min(xs)", opts)
        assert_float_close(py, Oracle.polars_float(:min, xs))
      end
    end

    property "builtin max() matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.float_preamble() <> "max(xs)", opts)
        assert_float_close(py, Oracle.polars_float(:max, xs))
      end
    end

    property "loop min matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.float_preamble() <>
              """
              m = xs[0]
              for x in xs:
                  if x < m:
                      m = x
              m
              """,
            opts
          )

        assert_float_close(py, Oracle.polars_float(:min, xs))
      end
    end

    property "loop max matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.float_preamble() <>
              """
              m = xs[0]
              for x in xs:
                  if x > m:
                      m = x
              m
              """,
            opts
          )

        assert_float_close(py, Oracle.polars_float(:max, xs))
      end
    end
  end

  describe "float mean" do
    property "sum/len matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.float_preamble() <> "sum(xs) / len(xs)", opts)
        assert_float_close(py, Oracle.polars_float(:mean, xs))
      end
    end
  end

  describe "float median" do
    property "forward sorted median matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.float_preamble() <>
              """
              ys = sorted(xs)
              n = len(ys)
              mid = n // 2
              if n % 2 == 1:
                  result = ys[mid]
              else:
                  result = (ys[mid - 1] + ys[mid]) / 2
              result
              """,
            opts
          )

        assert_float_close(py, Oracle.polars_float(:median, xs))
      end
    end
  end

  describe "float variance (population)" do
    property "two-pass matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.float_preamble() <>
              """
              mean = sum(xs) / len(xs)
              squares = list(map(lambda x: (x - mean) * (x - mean), xs))
              sum(squares) / len(xs)
              """,
            opts
          )

        assert_float_close(py, Oracle.polars_float(:variance_pop, xs))
      end
    end

    property "Welford one-pass matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.float_preamble() <>
              """
              n = 0
              mean = 0.0
              m2 = 0.0
              for x in xs:
                  n += 1
                  dx = x - mean
                  mean += dx / n
                  m2 += dx * (x - mean)
              m2 / n
              """,
            opts
          )

        assert_float_close(py, Oracle.polars_float(:variance_pop, xs))
      end
    end
  end

  describe "float sorting" do
    property "sorted() matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.float_preamble() <> "sorted(xs)", opts)
        assert py == Oracle.polars_sorted(xs)
      end
    end

    property "sorted(reverse=True) matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.float_preamble() <> "sorted(xs, reverse=True)", opts)
        assert py == Oracle.polars_sorted_desc(xs)
      end
    end

    property "sorted(key=abs) matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)
        py = Oracle.run_with_csv(Oracle.float_preamble() <> "sorted(xs, key=abs)", opts)
        assert py == Oracle.polars_sorted_abs(xs)
      end
    end
  end

  describe "float filtered subsets" do
    property "filter(neg) sorted matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.float_preamble() <>
              "sorted(list(filter(lambda x: x < 0, xs)))",
            opts
          )

        expected = Oracle.polars_filter(xs, :neg)
        assert py == Oracle.polars_sorted(expected)
      end
    end

    property "filter(small abs <= 1.0) count matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.float_preamble() <>
              "len(list(filter(lambda x: abs(x) <= 1.0, xs)))",
            opts
          )

        expected = Oracle.polars_filter(xs, :small)
        assert py == length(expected)
      end
    end

    property "comprehension filter(large abs > 1000) sorted matches Polars" do
      check all(xs <- float_list(), max_runs: @float_runs) do
        opts = Oracle.float_csv_opts(xs)

        py =
          Oracle.run_with_csv(
            Oracle.float_preamble() <>
              "sorted([x for x in xs if abs(x) > 1000.0])",
            opts
          )

        expected = Oracle.polars_filter(xs, :large)
        assert py == Oracle.polars_sorted(expected)
      end
    end
  end

  # ---- tolerance helpers ----

  defp assert_close(a, b) when is_integer(a) and is_integer(b), do: assert(a == b)

  defp assert_close(a, b) when is_number(a) and is_number(b) do
    a = a * 1.0
    b = b * 1.0
    diff = abs(a - b)
    scale = max(abs(a), abs(b))
    tol = max(1.0e-9, scale * 1.0e-9)
    assert diff <= tol, "expected #{b}, got #{a}, diff=#{diff}, tol=#{tol}"
  end

  defp assert_float_close(a, b) when is_number(a) and is_number(b) do
    a = a * 1.0
    b = b * 1.0
    diff = abs(a - b)
    scale = max(abs(a), abs(b))
    tol = max(@float_tol, scale * @float_tol)
    assert diff <= tol, "expected #{b}, got #{a}, diff=#{diff}, tol=#{tol}"
  end
end
