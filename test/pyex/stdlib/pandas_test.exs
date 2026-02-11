defmodule Pyex.Stdlib.PandasTest do
  use ExUnit.Case, async: true

  describe "Series basics" do
    test "create Series from list" do
      result =
        Pyex.run!("""
        import pandas as pd
        s = pd.Series([10, 20, 30])
        s.tolist()
        """)

      assert result == [10, 20, 30]
    end

    test "Series sum" do
      result =
        Pyex.run!("""
        import pandas as pd
        s = pd.Series([1, 2, 3, 4, 5])
        s.sum()
        """)

      assert result == 15
    end

    test "Series mean" do
      result =
        Pyex.run!("""
        import pandas as pd
        s = pd.Series([10, 20, 30])
        s.mean()
        """)

      assert result == 20.0
    end

    test "Series len" do
      result =
        Pyex.run!("""
        import pandas as pd
        s = pd.Series([1, 2, 3, 4])
        len(s)
        """)

      assert result == 4
    end

    test "Series indexing" do
      result =
        Pyex.run!("""
        import pandas as pd
        s = pd.Series([10, 20, 30])
        [s[0], s[1], s[-1]]
        """)

      assert result == [10, 20, 30]
    end
  end

  describe "Series arithmetic" do
    test "series + series" do
      result =
        Pyex.run!("""
        import pandas as pd
        a = pd.Series([1, 2, 3])
        b = pd.Series([10, 20, 30])
        (a + b).tolist()
        """)

      assert result == [11, 22, 33]
    end

    test "series + scalar" do
      result =
        Pyex.run!("""
        import pandas as pd
        s = pd.Series([1, 2, 3])
        (s + 10).tolist()
        """)

      assert result == [11, 12, 13]
    end

    test "series - series" do
      result =
        Pyex.run!("""
        import pandas as pd
        a = pd.Series([10, 20, 30])
        b = pd.Series([1, 2, 3])
        (a - b).tolist()
        """)

      assert result == [9, 18, 27]
    end

    test "series * scalar" do
      result =
        Pyex.run!("""
        import pandas as pd
        s = pd.Series([1, 2, 3])
        (s * 2).tolist()
        """)

      assert result == [2, 4, 6]
    end

    test "series / scalar" do
      result =
        Pyex.run!("""
        import pandas as pd
        s = pd.Series([10.0, 20.0, 30.0])
        (s / 10).tolist()
        """)

      assert result == [1.0, 2.0, 3.0]
    end
  end

  describe "Series comparison" do
    test "series > scalar returns bool series for masking" do
      result =
        Pyex.run!("""
        import pandas as pd
        s = pd.Series([1, 5, 3, 8, 2])
        mask = s > 3
        s[mask].tolist()
        """)

      assert result == [5, 8]
    end

    test "series < scalar" do
      result =
        Pyex.run!("""
        import pandas as pd
        s = pd.Series([1, 5, 3, 8, 2])
        s[s < 4].tolist()
        """)

      assert result == [1, 3, 2]
    end
  end

  describe "rolling window" do
    test "rolling mean with small window" do
      result =
        Pyex.run!("""
        import pandas as pd
        s = pd.Series([1, 2, 3, 4, 5])
        r = s.rolling(3).mean().tolist()
        r
        """)

      assert length(result) == 5
      assert result |> Enum.take(2) |> Enum.all?(&is_nil/1)
      assert_in_delta Enum.at(result, 2), 2.0, 0.001
      assert_in_delta Enum.at(result, 3), 3.0, 0.001
      assert_in_delta Enum.at(result, 4), 4.0, 0.001
    end

    test "rolling sum" do
      result =
        Pyex.run!("""
        import pandas as pd
        s = pd.Series([1, 2, 3, 4, 5])
        s.rolling(2).sum().tolist()
        """)

      assert length(result) == 5
      assert Enum.at(result, 0) == nil
      assert Enum.at(result, 1) == 3
      assert Enum.at(result, 4) == 9
    end
  end

  describe "DataFrame basics" do
    test "create DataFrame and access column" do
      result =
        Pyex.run!("""
        import pandas as pd
        df = pd.DataFrame({"price": [100, 200, 300], "volume": [10, 20, 30]})
        df["price"].tolist()
        """)

      assert result == [100, 200, 300]
    end

    test "DataFrame columns" do
      result =
        Pyex.run!("""
        import pandas as pd
        df = pd.DataFrame({"a": [1], "b": [2]})
        df.columns
        """)

      assert is_list(result)
      assert "a" in result
      assert "b" in result
    end

    test "DataFrame len" do
      result =
        Pyex.run!("""
        import pandas as pd
        df = pd.DataFrame({"x": [1, 2, 3]})
        len(df)
        """)

      assert result == 3
    end
  end

  describe "golden cross via platform.get_prices" do
    @tag timeout: 30_000

    setup do
      prices = generate_prices(300)
      series = Explorer.Series.from_list(prices)

      platform = %{
        "get_prices" => {:builtin, fn [_symbol] -> {:pandas_series, series} end}
      }

      expected_signals = golden_cross_oracle(series, 50, 200)

      %{platform: platform, expected_signals: expected_signals}
    end

    test "naive Python matches Elixir oracle", %{
      platform: platform,
      expected_signals: expected_signals
    } do
      opts = [timeout_ms: 20_000, modules: %{"platform" => platform}]

      naive_code = """
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

      assert Pyex.run!(naive_code, opts) == expected_signals
    end

    test "pandas Python matches Elixir oracle", %{
      platform: platform,
      expected_signals: expected_signals
    } do
      opts = [timeout_ms: 20_000, modules: %{"platform" => platform}]

      pandas_code = """
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

      assert Pyex.run!(pandas_code, opts) == expected_signals
    end

    @tag timeout: 30_000
    test "pandas via platform.get_prices is faster than naive", %{platform: platform} do
      opts = [timeout_ms: 20_000, modules: %{"platform" => platform}]

      naive_code = """
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

      pandas_code = """
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

      {naive_us, _} = :timer.tc(fn -> Pyex.run!(naive_code, opts) end)
      {pandas_us, _} = :timer.tc(fn -> Pyex.run!(pandas_code, opts) end)

      speedup = naive_us / max(pandas_us, 1)

      if System.get_env("PYEX_BENCH") do
        IO.puts(
          "\n  Golden cross 300 days: naive=#{fmt(naive_us)} pandas=#{fmt(pandas_us)} speedup=#{Float.round(speedup, 1)}x"
        )
      end

      assert pandas_us < naive_us,
             "pandas (#{fmt(pandas_us)}) should be faster than naive (#{fmt(naive_us)})"
    end

    test "platform.get_prices returns Series usable with .tolist()", %{platform: platform} do
      result =
        Pyex.run!(
          """
          import platform
          prices = platform.get_prices("AAPL")
          len(prices)
          """,
          modules: %{"platform" => platform}
        )

      assert result == 300
    end

    test "platform.get_prices Series supports method chaining", %{platform: platform} do
      result =
        Pyex.run!(
          """
          import platform
          prices = platform.get_prices("AAPL")
          prices.rolling(5).mean().tolist()[-1]
          """,
          modules: %{"platform" => platform}
        )

      assert is_float(result)
    end
  end

  defp golden_cross_oracle(series, short_window, long_window) do
    sma_short = Explorer.Series.window_mean(series, short_window, min_periods: short_window)
    sma_long = Explorer.Series.window_mean(series, long_window, min_periods: long_window)
    diff = Explorer.Series.subtract(sma_short, sma_long)
    diff_list = Explorer.Series.to_list(diff)

    diff_list
    |> Enum.with_index()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{prev, _}, {curr, i}] ->
      case {prev, curr} do
        {p, c} when is_number(p) and is_number(c) and p <= 0 and c > 0 -> [i]
        _ -> []
      end
    end)
  end

  defp generate_prices(n) do
    :rand.seed(:exsss, {42, 42, 42})

    Enum.scan(1..n, 100.0, fn _, prev ->
      change = (:rand.uniform() - 0.48) * 4
      Float.round(max(prev + change, 1.0), 2)
    end)
  end

  defp fmt(us) when us < 1_000, do: "#{us}us"
  defp fmt(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  defp fmt(us), do: "#{Float.round(us / 1_000_000, 2)}s"
end
