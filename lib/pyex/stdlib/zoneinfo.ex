defmodule Pyex.Stdlib.Zoneinfo do
  @moduledoc """
  Python `zoneinfo` module providing IANA timezone support.

  Provides `ZoneInfo` for constructing timezone objects from IANA
  zone names (e.g. "America/New_York", "Europe/London", "Asia/Tokyo"),
  and `available_timezones()` for listing all known zone names.

  Backed by the `tz` library which bundles current IANA timezone data.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Stdlib.Datetime, as: DatetimeModule

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "ZoneInfo" => zoneinfo_class(),
      "available_timezones" => {:builtin, &available_timezones/1},
      "ZoneInfoNotFoundError" => {:class, "ZoneInfoNotFoundError", [], %{}}
    }
  end

  @spec zoneinfo_class() ::
          {:class, String.t(), [Pyex.Interpreter.pyvalue()],
           %{optional(String.t()) => Pyex.Interpreter.pyvalue()}}
  defp zoneinfo_class do
    {:class, "ZoneInfo", [],
     %{
       "__init__" => {:builtin_kw, &zoneinfo_init/2},
       "__str__" => {:builtin, fn [self] -> zi_str(self) end},
       "__repr__" => {:builtin, fn [self] -> "zoneinfo.ZoneInfo(key='#{zi_str(self)}')" end}
     }}
  end

  @spec zoneinfo_init([Pyex.Interpreter.pyvalue()], map()) :: Pyex.Interpreter.pyvalue()
  defp zoneinfo_init([_self, key], _kwargs) when is_binary(key) do
    make_zoneinfo(key)
  end

  defp zoneinfo_init([_self], kwargs) do
    case Map.fetch(kwargs, "key") do
      {:ok, key} when is_binary(key) -> make_zoneinfo(key)
      _ -> {:exception, "TypeError: ZoneInfo() requires a string key argument"}
    end
  end

  @doc false
  @spec make_zoneinfo(String.t()) :: Pyex.Interpreter.pyvalue()
  def make_zoneinfo(key) do
    if valid_timezone?(key) do
      make_zoneinfo_instance(key)
    else
      {:exception, "ZoneInfoNotFoundError: 'No time zone found with key #{key}'"}
    end
  end

  @spec make_zoneinfo_instance(String.t()) :: Pyex.Interpreter.pyvalue()
  defp make_zoneinfo_instance(key) do
    {:instance, zoneinfo_class(),
     %{
       "key" => key,
       "__tz_name__" => key,
       "__offset_seconds__" => :dynamic,
       "__zoneinfo_key__" => key,
       "utcoffset" =>
         {:builtin,
          fn [dt_instance] ->
            offset = compute_offset(key, dt_instance)
            DatetimeModule.timedelta_from_seconds(offset)
          end},
       "tzname" =>
         {:builtin,
          fn [dt_instance] ->
            compute_abbr(key, dt_instance)
          end},
       "dst" =>
         {:builtin,
          fn [dt_instance] ->
            dst_secs = compute_dst(key, dt_instance)
            DatetimeModule.timedelta_from_seconds(dst_secs)
          end}
     }}
  end

  @spec compute_offset(String.t(), Pyex.Interpreter.pyvalue()) :: number()
  defp compute_offset(key, dt_instance) do
    case extract_wall_clock(dt_instance) do
      {:ok, ndt} ->
        case wall_to_utc_offset(key, ndt) do
          {:ok, offset} -> offset
          :error -> 0
        end

      :error ->
        0
    end
  end

  @spec compute_dst(String.t(), Pyex.Interpreter.pyvalue()) :: number()
  defp compute_dst(key, dt_instance) do
    case extract_wall_clock(dt_instance) do
      {:ok, ndt} ->
        case wall_to_std_offset(key, ndt) do
          {:ok, std_offset} -> std_offset
          :error -> 0
        end

      :error ->
        0
    end
  end

  @spec wall_to_std_offset(String.t(), NaiveDateTime.t()) :: {:ok, number()} | :error
  defp wall_to_std_offset(key, ndt) do
    case DateTime.from_naive(ndt, key, Tz.TimeZoneDatabase) do
      {:ok, dt} -> {:ok, dt.std_offset}
      {:ambiguous, dt1, _dt2} -> {:ok, dt1.std_offset}
      {:gap, _dt_before, dt_after} -> {:ok, dt_after.std_offset}
      _ -> :error
    end
  end

  @spec compute_abbr(String.t(), Pyex.Interpreter.pyvalue()) :: String.t()
  defp compute_abbr(key, dt_instance) do
    case extract_wall_clock(dt_instance) do
      {:ok, ndt} ->
        case wall_to_abbr(key, ndt) do
          {:ok, abbr} -> abbr
          :error -> key
        end

      :error ->
        key
    end
  end

  @spec extract_wall_clock(Pyex.Interpreter.pyvalue()) :: {:ok, NaiveDateTime.t()} | :error
  defp extract_wall_clock(
         {:instance, _,
          %{"year" => y, "month" => m, "day" => d, "hour" => h, "minute" => mi, "second" => s}}
       )
       when is_integer(y) and is_integer(m) and is_integer(d) do
    case NaiveDateTime.new(y, m, d, h, mi, s) do
      {:ok, ndt} -> {:ok, ndt}
      _ -> :error
    end
  end

  defp extract_wall_clock(_), do: :error

  @spec wall_to_utc_offset(String.t(), NaiveDateTime.t()) :: {:ok, number()} | :error
  defp wall_to_utc_offset(key, ndt) do
    case DateTime.from_naive(ndt, key, Tz.TimeZoneDatabase) do
      {:ok, dt} ->
        {:ok, dt.utc_offset + dt.std_offset}

      {:ambiguous, dt1, _dt2} ->
        {:ok, dt1.utc_offset + dt1.std_offset}

      {:gap, _dt_before, dt_after} ->
        {:ok, dt_after.utc_offset + dt_after.std_offset}

      _ ->
        :error
    end
  end

  @spec wall_to_abbr(String.t(), NaiveDateTime.t()) :: {:ok, String.t()} | :error
  defp wall_to_abbr(key, ndt) do
    case DateTime.from_naive(ndt, key, Tz.TimeZoneDatabase) do
      {:ok, dt} ->
        {:ok, dt.zone_abbr}

      {:ambiguous, dt1, _dt2} ->
        {:ok, dt1.zone_abbr}

      {:gap, _dt_before, dt_after} ->
        {:ok, dt_after.zone_abbr}

      _ ->
        :error
    end
  end

  @spec valid_timezone?(String.t()) :: boolean()
  defp valid_timezone?("UTC"), do: true
  defp valid_timezone?("Etc/UTC"), do: true

  defp valid_timezone?(key) do
    case DateTime.from_naive(~N[2020-01-01 00:00:00], key, Tz.TimeZoneDatabase) do
      {:ok, _} -> true
      {:ambiguous, _, _} -> true
      {:gap, _, _} -> true
      {:error, _} -> false
    end
  end

  @iana_data_dir (
                   priv = :code.priv_dir(:tz)

                   case File.ls!(priv) |> Enum.find(&String.starts_with?(&1, "tzdata")) do
                     nil -> raise "no tzdata directory found in #{priv}"
                     dir -> Path.join(priv, dir)
                   end
                 )
  @iana_files ~w(africa antarctica asia australasia europe northamerica southamerica etcetera backward)

  @zone_names (for file <- @iana_files,
                   Path.join(@iana_data_dir, file) |> File.exists?(),
                   line <- File.read!(Path.join(@iana_data_dir, file)) |> String.split("\n"),
                   String.starts_with?(line, "Zone") or String.starts_with?(line, "Link") do
                 case String.split(line, ~r/\s+/, parts: 4) do
                   ["Zone", name | _] -> name
                   ["Link", _target, name | _] -> name
                   _ -> nil
                 end
               end)
              |> Enum.reject(&is_nil/1)
              |> MapSet.new()
              |> MapSet.put("UTC")

  @spec available_timezones([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp available_timezones([]) do
    {:set, @zone_names}
  end

  @spec zi_str(Pyex.Interpreter.pyvalue()) :: String.t()
  defp zi_str({:instance, _, %{"key" => key}}), do: key
  defp zi_str(_), do: "ZoneInfo(...)"
end
