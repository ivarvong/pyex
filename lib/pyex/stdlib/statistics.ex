defmodule Pyex.Stdlib.Statistics do
  @moduledoc """
  Python `statistics` module.

  Provides descriptive statistics functions matching the CPython
  `statistics` standard library: mean, median, mode, stdev, variance,
  fmean, geometric_mean, harmonic_mean, median_low, median_high,
  median_grouped, and quantiles.
  """

  @behaviour Pyex.Stdlib.Module

  @doc """
  Returns the module value map with all statistics functions.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "mean" => {:builtin, &do_mean/1},
      "fmean" => {:builtin, &do_fmean/1},
      "geometric_mean" => {:builtin, &do_geometric_mean/1},
      "harmonic_mean" => {:builtin, &do_harmonic_mean/1},
      "median" => {:builtin, &do_median/1},
      "median_low" => {:builtin, &do_median_low/1},
      "median_high" => {:builtin, &do_median_high/1},
      "median_grouped" => {:builtin, &do_median_grouped/1},
      "mode" => {:builtin, &do_mode/1},
      "multimode" => {:builtin, &do_multimode/1},
      "pstdev" => {:builtin, &do_pstdev/1},
      "pvariance" => {:builtin, &do_pvariance/1},
      "stdev" => {:builtin, &do_stdev/1},
      "variance" => {:builtin, &do_variance/1},
      "quantiles" => {:builtin, &do_quantiles/1},
      "StatisticsError" => {:class, "StatisticsError", [], %{}}
    }
  end

  @spec to_numbers([Pyex.Interpreter.pyvalue()]) :: {:ok, [number()]} | {:error, String.t()}
  defp to_numbers(args) do
    items = coerce_list(args)

    case items do
      {:error, msg} ->
        {:error, msg}

      items ->
        if Enum.empty?(items) do
          {:error, "StatisticsError: mean requires at least one data point"}
        else
          nums =
            Enum.map(items, fn
              n when is_number(n) -> {:ok, n}
              _ -> :error
            end)

          if Enum.all?(nums, &match?({:ok, _}, &1)) do
            {:ok, Enum.map(nums, fn {:ok, n} -> n end)}
          else
            {:error, "TypeError: must be real number, not str"}
          end
        end
    end
  end

  @spec coerce_list([Pyex.Interpreter.pyvalue()]) ::
          [Pyex.Interpreter.pyvalue()] | {:error, String.t()}
  defp coerce_list([{:py_list, reversed, _}]), do: Enum.reverse(reversed)
  defp coerce_list([list]) when is_list(list), do: list
  defp coerce_list([{:tuple, items}]), do: items
  defp coerce_list([{:generator, items}]), do: items
  defp coerce_list([{:set, set}]), do: MapSet.to_list(set)
  defp coerce_list(_), do: {:error, "TypeError: argument must be an iterable"}

  @spec do_mean([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_mean(args) do
    case to_numbers(args) do
      {:ok, nums} ->
        sum = Enum.sum(nums)
        n = length(nums)

        if Enum.all?(nums, &is_integer/1) and rem(sum, n) == 0 do
          div(sum, n)
        else
          sum / n
        end

      {:error, msg} ->
        {:exception, msg}
    end
  end

  @spec do_fmean([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_fmean(args) do
    case to_numbers(args) do
      {:ok, nums} -> Enum.sum(nums) / length(nums)
      {:error, msg} -> {:exception, msg}
    end
  end

  @spec do_geometric_mean([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_geometric_mean(args) do
    case to_numbers(args) do
      {:ok, nums} ->
        n = length(nums)

        if Enum.any?(nums, &(&1 <= 0)) do
          {:exception, "StatisticsError: geometric mean requires positive inputs"}
        else
          product = Enum.reduce(nums, 1.0, &(&1 * &2))
          :math.pow(product, 1.0 / n)
        end

      {:error, msg} ->
        {:exception, msg}
    end
  end

  @spec do_harmonic_mean([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_harmonic_mean(args) do
    case to_numbers(args) do
      {:ok, nums} ->
        n = length(nums)

        if Enum.any?(nums, &(&1 == 0)) do
          {:exception, "StatisticsError: harmonic mean requires positive inputs"}
        else
          reciprocal_sum = Enum.reduce(nums, 0.0, fn x, acc -> acc + 1.0 / x end)
          n / reciprocal_sum
        end

      {:error, msg} ->
        {:exception, msg}
    end
  end

  @spec do_median([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_median(args) do
    case to_numbers(args) do
      {:ok, nums} ->
        sorted = Enum.sort(nums)
        n = length(sorted)
        mid = div(n, 2)

        if rem(n, 2) == 1 do
          Enum.at(sorted, mid)
        else
          lo = Enum.at(sorted, mid - 1)
          hi = Enum.at(sorted, mid)

          if is_integer(lo) and is_integer(hi) and rem(lo + hi, 2) == 0 do
            div(lo + hi, 2)
          else
            (lo + hi) / 2
          end
        end

      {:error, msg} ->
        {:exception, msg}
    end
  end

  @spec do_median_low([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_median_low(args) do
    case to_numbers(args) do
      {:ok, nums} ->
        sorted = Enum.sort(nums)
        n = length(sorted)
        mid = div(n, 2)

        if rem(n, 2) == 1 do
          Enum.at(sorted, mid)
        else
          Enum.at(sorted, mid - 1)
        end

      {:error, msg} ->
        {:exception, msg}
    end
  end

  @spec do_median_high([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_median_high(args) do
    case to_numbers(args) do
      {:ok, nums} ->
        sorted = Enum.sort(nums)
        n = length(sorted)
        mid = div(n, 2)
        Enum.at(sorted, mid)

      {:error, msg} ->
        {:exception, msg}
    end
  end

  @spec do_median_grouped([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_median_grouped(args) do
    case to_numbers(args) do
      {:ok, nums} ->
        sorted = Enum.sort(nums)
        n = length(sorted)
        mid = div(n, 2)
        x = Enum.at(sorted, mid) * 1.0
        x - 0.5 + 0.5

      {:error, msg} ->
        {:exception, msg}
    end
  end

  @spec do_mode([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_mode(args) do
    items = coerce_list(args)

    case items do
      {:error, msg} ->
        {:exception, msg}

      [] ->
        {:exception, "StatisticsError: mode requires at least one data point"}

      items ->
        {mode, _count} =
          items
          |> Enum.frequencies()
          |> Enum.max_by(fn {_, count} -> count end)

        mode
    end
  end

  @spec do_multimode([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_multimode(args) do
    items = coerce_list(args)

    case items do
      {:error, msg} ->
        {:exception, msg}

      [] ->
        []

      items ->
        freqs = Enum.frequencies(items)
        max_count = Enum.max(Map.values(freqs))

        freqs
        |> Enum.filter(fn {_, count} -> count == max_count end)
        |> Enum.map(fn {val, _} -> val end)
    end
  end

  @spec do_pvariance([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_pvariance(args) do
    case to_numbers(args) do
      {:ok, nums} ->
        n = length(nums)
        mu = Enum.sum(nums) / n
        Enum.reduce(nums, 0.0, fn x, acc -> acc + (x - mu) * (x - mu) end) / n

      {:error, msg} ->
        {:exception, msg}
    end
  end

  @spec do_variance([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_variance(args) do
    case to_numbers(args) do
      {:ok, [_]} ->
        {:exception, "StatisticsError: variance requires at least two data points"}

      {:ok, nums} ->
        n = length(nums)
        mu = Enum.sum(nums) / n
        Enum.reduce(nums, 0.0, fn x, acc -> acc + (x - mu) * (x - mu) end) / (n - 1)

      {:error, msg} ->
        {:exception, msg}
    end
  end

  @spec do_pstdev([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_pstdev(args) do
    case do_pvariance(args) do
      {:exception, _} = err -> err
      var -> :math.sqrt(var)
    end
  end

  @spec do_stdev([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_stdev(args) do
    case do_variance(args) do
      {:exception, _} = err -> err
      var -> :math.sqrt(var)
    end
  end

  @spec do_quantiles([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_quantiles(args) do
    case to_numbers(args) do
      {:ok, nums} ->
        n = length(nums)

        if n < 2 do
          {:exception, "StatisticsError: quantiles requires at least 2 data points"}
        else
          sorted = Enum.sort(nums)

          [0.25, 0.5, 0.75]
          |> Enum.map(fn p ->
            idx = p * (n - 1)
            lo = trunc(idx)
            frac = idx - lo

            lo_val = Enum.at(sorted, lo)
            hi_val = Enum.at(sorted, min(lo + 1, n - 1))
            lo_val + frac * (hi_val - lo_val)
          end)
        end

      {:error, msg} ->
        {:exception, msg}
    end
  end
end
