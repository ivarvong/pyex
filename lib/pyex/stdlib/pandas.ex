defmodule Pyex.Stdlib.Pandas do
  @moduledoc """
  Python `pandas` module backed by Explorer (Polars/Rust).

  Provides `pd.Series()` for creating series from lists and
  `pd.DataFrame()` for creating DataFrames from dicts.
  Series and DataFrame methods (`.mean()`, `.rolling()`,
  `.sum()`, etc.) are dispatched via `Pyex.Methods`.

  Requires the optional `explorer` dependency at runtime.
  All heavy computation runs in Rust via Polars NIFs --
  no interpreter loop overhead for numeric operations.

  ## Supported API

  ### Module-level

      import pandas as pd
      s = pd.Series([1, 2, 3])
      df = pd.DataFrame({"a": [1, 2], "b": [3, 4]})

  ### Series methods

      s.sum(), s.mean(), s.std(), s.min(), s.max(), s.median()
      s.cumsum(), s.diff(), s.shift(n), s.abs()
      s.rolling(window)              # returns Rolling object
      s.tolist()                     # convert back to Python list
      len(s)                         # via __len__

  ### Rolling methods

      s.rolling(50).mean()
      s.rolling(50).sum()
      s.rolling(50).min()
      s.rolling(50).max()
      s.rolling(50).std()

  ### DataFrame methods

      df["col"]                      # column access returns Series
      df.columns                     # list of column names
      len(df)                        # number of rows

  ### Vectorized operations

      s + s, s - s, s * s, s / s     # element-wise arithmetic
      s > 0, s < 0, s >= 0, s <= 0   # element-wise comparison (returns bool Series)
      s[bool_series]                 # boolean indexing
  """

  @behaviour Pyex.Stdlib.Module

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    if Code.ensure_loaded?(Explorer.Series) do
      %{
        "Series" => {:builtin, &do_series/1},
        "DataFrame" => {:builtin, &do_dataframe/1}
      }
    else
      %{
        "Series" =>
          {:builtin,
           fn _ ->
             {:exception,
              "ImportError: pandas requires the :explorer dependency. " <>
                "Add {:explorer, \"~> 0.10\"} to your mix.exs deps."}
           end},
        "DataFrame" =>
          {:builtin,
           fn _ ->
             {:exception,
              "ImportError: pandas requires the :explorer dependency. " <>
                "Add {:explorer, \"~> 0.10\"} to your mix.exs deps."}
           end}
      }
    end
  end

  @spec do_series([term()]) :: {:pandas_series, Explorer.Series.t()}
  defp do_series([values]) when is_list(values) do
    {:pandas_series, Explorer.Series.from_list(coerce_values(values))}
  end

  @spec do_dataframe([term()]) :: {:pandas_dataframe, Explorer.DataFrame.t()}
  defp do_dataframe([dict]) when is_map(dict) do
    columns =
      Enum.map(dict, fn {name, values} ->
        {name, coerce_values(values)}
      end)

    {:pandas_dataframe, Explorer.DataFrame.new(columns)}
  end

  @spec coerce_values([term()]) :: [number()] | [String.t()]
  defp coerce_values(values) do
    Enum.map(values, fn
      nil -> nil
      v -> v
    end)
  end
end
