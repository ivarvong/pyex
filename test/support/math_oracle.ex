defmodule Pyex.Test.MathOracle do
  @moduledoc """
  Shared helpers for math oracle property tests.

  Provides CSV generation, Pyex execution with in-memory filesystem,
  Explorer/Polars oracle computation, and tolerance assertions.
  """

  alias Explorer.Series
  alias Pyex.Filesystem.Memory

  @timeout_ms 500

  @doc """
  Builds a single-column integer CSV, writes it to a Memory filesystem,
  and returns opts suitable for `Pyex.run/2`.
  """
  @spec int_csv_opts([integer()]) :: keyword()
  def int_csv_opts(xs) do
    csv = "x\r\n" <> Enum.map_join(xs, "\r\n", &Integer.to_string/1) <> "\r\n"
    fs = Memory.new()
    {:ok, fs} = Memory.write(fs, "data.csv", csv, :write)
    [filesystem: fs, timeout_ms: @timeout_ms]
  end

  @doc """
  Builds a single-column float CSV, writes it to a Memory filesystem,
  and returns opts suitable for `Pyex.run/2`.
  """
  @spec float_csv_opts([float()]) :: keyword()
  def float_csv_opts(xs) do
    csv = "x\r\n" <> Enum.map_join(xs, "\r\n", &Float.to_string/1) <> "\r\n"
    fs = Memory.new()
    {:ok, fs} = Memory.write(fs, "data.csv", csv, :write)
    [filesystem: fs, timeout_ms: @timeout_ms]
  end

  @doc """
  Runs a Python program that reads `data.csv` (single column `x`)
  and returns the final expression value.
  """
  @spec run_with_csv(String.t(), keyword()) :: term()
  def run_with_csv(source, opts) do
    Pyex.run!(source, opts)
  end

  @doc """
  Python preamble that reads data.csv into a list `xs` (integers).
  """
  @spec int_preamble() :: String.t()
  def int_preamble do
    """
    import csv
    f = open("data.csv")
    xs = [int(row["x"]) for row in csv.DictReader(f)]
    f.close()
    """
  end

  @doc """
  Python preamble that reads data.csv into a list `xs` (floats).
  """
  @spec float_preamble() :: String.t()
  def float_preamble do
    """
    import csv
    f = open("data.csv")
    xs = [float(row["x"]) for row in csv.DictReader(f)]
    f.close()
    """
  end

  @doc """
  Computes a scalar stat via Polars for an integer series.
  """
  @spec polars_int(atom(), [integer()]) :: number() | nil
  def polars_int(stat, xs), do: polars_stat(Series.from_list(xs), stat)

  @doc """
  Computes a scalar stat via Polars for a float series.
  """
  @spec polars_float(atom(), [float()]) :: number() | nil
  def polars_float(stat, xs), do: polars_stat(Series.from_list(xs), stat)

  defp polars_stat(s, stat) do
    case stat do
      :count -> Series.count(s)
      :sum -> Series.sum(s)
      :min -> Series.min(s)
      :max -> Series.max(s)
      :mean -> Series.mean(s)
      :median -> Series.median(s)
      :variance_pop -> pop_variance(s)
      :stddev_pop -> pop_variance(s) |> safe_sqrt()
    end
  end

  @doc """
  Returns sorted list via Polars.
  """
  @spec polars_sorted([number()]) :: [number()]
  def polars_sorted(xs) do
    xs |> Series.from_list() |> Series.sort() |> Series.to_list()
  end

  @doc """
  Returns reverse-sorted list via Polars.
  """
  @spec polars_sorted_desc([number()]) :: [number()]
  def polars_sorted_desc(xs) do
    xs |> Series.from_list() |> Series.sort(direction: :desc) |> Series.to_list()
  end

  @doc """
  Returns list sorted by absolute value via Polars.
  """
  @spec polars_sorted_abs([number()]) :: [number()]
  def polars_sorted_abs(xs) do
    s = Series.from_list(xs)
    rank = s |> Series.abs() |> Series.argsort()
    Series.slice(s, rank) |> Series.to_list()
  end

  @doc """
  Filters a series via Polars and returns the matching values.
  """
  @spec polars_filter([number()], :neg | :even | :smallabs | :small | :large) :: [number()]
  def polars_filter(xs, subset) do
    s = Series.from_list(xs)

    mask =
      case subset do
        :neg -> Series.less(s, 0)
        :even -> Series.equal(Series.remainder(s, 2), 0)
        :smallabs -> Series.less_equal(Series.abs(s), 10)
        :small -> Series.less_equal(Series.abs(s), 1.0)
        :large -> Series.greater(Series.abs(s), 1000.0)
      end

    Series.mask(s, mask) |> Series.to_list()
  end

  @doc """
  Generates a random float with mixed magnitudes (0.001 to 1M).
  """
  @spec random_float() :: float()
  def random_float do
    sign = if :rand.uniform() < 0.5, do: -1.0, else: 1.0

    base =
      case Enum.random(0..3) do
        0 -> :rand.uniform() * 0.001
        1 -> :rand.uniform() * 1.0
        2 -> :rand.uniform() * 1000.0
        3 -> :rand.uniform() * 1_000_000.0
      end

    sign * base
  end

  defp pop_variance(s) do
    n = Series.count(s)
    if n > 1, do: Series.variance(s) * (n - 1) / n, else: 0.0
  end

  defp safe_sqrt(v) when is_number(v), do: :math.sqrt(v)
end
