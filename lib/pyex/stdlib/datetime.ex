defmodule Pyex.Stdlib.Datetime do
  @moduledoc """
  Python `datetime` module providing date, time, and duration operations.

  Provides `datetime.datetime`, `datetime.date`, and `datetime.timedelta`
  as proper class instances with full arithmetic, comparison, and
  formatting support.

  Internally, `datetime.datetime` instances are backed by Elixir `DateTime`
  structs in the UTC timezone. This means `now()` and `utcnow()` both return
  the current UTC time, and `timestamp()` / `fromtimestamp()` round-trip
  cleanly without any naive-to-UTC conversion.

  ## Constructors

      datetime.datetime(2024, 1, 15, 10, 30, 0)
      datetime.date(2024, 1, 15)
      datetime.timedelta(days=7, hours=3, minutes=30)

  ## Arithmetic

      dt + timedelta(days=1)
      dt - timedelta(hours=12)
      dt2 - dt1  # returns timedelta

  ## Comparisons

      dt1 < dt2
      d1 == d2

  ## Class methods

      datetime.datetime.now()
      datetime.datetime.utcnow()
      datetime.datetime.fromisoformat("2024-01-15T10:30:00")
      datetime.datetime.strptime("2024-01-15", "%Y-%m-%d")
      datetime.datetime.fromtimestamp(1_700_000_000)
      datetime.datetime.fromtimestamp(1_700_000_000.5)
      datetime.datetime.utcfromtimestamp(1_700_000_000)
      datetime.date.today()
  """

  @behaviour Pyex.Stdlib.Module

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "datetime" => datetime_class(),
      "date" => date_class(),
      "time" => time_class(),
      "timedelta" => timedelta_class(),
      "timezone" => timezone_class()
    }
  end

  @spec time_class() :: Pyex.Interpreter.pyvalue()
  defp time_class do
    methods = %{
      "__init__" => {:builtin_kw, &time_init/2},
      "__repr__" => {:builtin, &time_repr/1},
      "__str__" => {:builtin, &time_str/1},
      "__eq__" => {:builtin, &time_eq/1},
      "__lt__" => {:builtin, &time_lt/1},
      "__le__" => {:builtin, &time_le/1},
      "__gt__" => {:builtin, &time_gt/1},
      "__ge__" => {:builtin, &time_ge/1},
      "__hash__" => {:builtin, &time_hash/1},
      "isoformat" => {:builtin, &time_isoformat/1},
      "replace" => {:builtin_kw, &time_replace/2},
      "strftime" => {:builtin, &time_strftime/1},
      "fromisoformat" => {:builtin, &time_fromisoformat/1}
    }

    base = {:class, "time", [], methods}

    # Attach class-level singletons (min/max/resolution) whose values
    # reference the bare class itself, avoiding infinite recursion.
    singletons = %{
      "min" =>
        {:instance, base,
         %{
           "hour" => 0,
           "minute" => 0,
           "second" => 0,
           "microsecond" => 0,
           "__time_components__" => {0, 0, 0, 0}
         }},
      "max" =>
        {:instance, base,
         %{
           "hour" => 23,
           "minute" => 59,
           "second" => 59,
           "microsecond" => 999_999,
           "__time_components__" => {23, 59, 59, 999_999}
         }},
      "resolution" => make_timedelta_instance(0, 0.000001)
    }

    {:class, "time", [], Map.merge(methods, singletons)}
  end

  @spec time_init([Pyex.Interpreter.pyvalue()], map()) :: Pyex.Interpreter.pyvalue()
  defp time_init([_self | args], kwargs) do
    {hour, minute, second, microsecond} =
      case args do
        [] -> {0, 0, 0, 0}
        [h] -> {h, 0, 0, 0}
        [h, m] -> {h, m, 0, 0}
        [h, m, s] -> {h, m, s, 0}
        [h, m, s, us] -> {h, m, s, us}
        _ -> {nil, nil, nil, nil}
      end

    hour = Map.get(kwargs, "hour", hour)
    minute = Map.get(kwargs, "minute", minute)
    second = Map.get(kwargs, "second", second)
    microsecond = Map.get(kwargs, "microsecond", microsecond)

    cond do
      not (is_integer(hour) and hour >= 0 and hour <= 23) ->
        {:exception, "ValueError: hour must be in 0..23"}

      not (is_integer(minute) and minute >= 0 and minute <= 59) ->
        {:exception, "ValueError: minute must be in 0..59"}

      not (is_integer(second) and second >= 0 and second <= 59) ->
        {:exception, "ValueError: second must be in 0..59"}

      not (is_integer(microsecond) and microsecond >= 0 and microsecond <= 999_999) ->
        {:exception, "ValueError: microsecond must be in 0..999999"}

      true ->
        make_time_instance(hour, minute, second, microsecond)
    end
  end

  @spec make_time_instance(integer(), integer(), integer(), integer()) ::
          Pyex.Interpreter.pyvalue()
  defp make_time_instance(h, m, s, us) do
    {:instance, time_class(),
     %{
       "hour" => h,
       "minute" => m,
       "second" => s,
       "microsecond" => us,
       "__time_components__" => {h, m, s, us}
     }}
  end

  defp time_repr([
         {:instance, _, %{"hour" => h, "minute" => m, "second" => s, "microsecond" => us}}
       ]) do
    args =
      cond do
        us != 0 -> "#{h}, #{m}, #{s}, #{us}"
        s != 0 -> "#{h}, #{m}, #{s}"
        true -> "#{h}, #{m}"
      end

    "datetime.time(#{args})"
  end

  defp time_repr(_), do: "datetime.time(...)"

  defp time_str([inst]), do: time_isoformat([inst])

  defp time_isoformat([
         {:instance, _, %{"hour" => h, "minute" => m, "second" => s, "microsecond" => us}}
       ]) do
    base = "#{pad2(h)}:#{pad2(m)}:#{pad2(s)}"

    if us == 0 do
      base
    else
      base <> "." <> String.pad_leading(Integer.to_string(us), 6, "0")
    end
  end

  defp time_isoformat(_), do: "00:00:00"

  defp time_components([{:instance, _, attrs}]), do: Map.get(attrs, "__time_components__")
  defp time_components(_), do: nil

  defp time_eq([a, b]) do
    case {time_components([a]), time_components([b])} do
      {nil, _} -> false
      {_, nil} -> false
      {x, y} -> x == y
    end
  end

  defp time_lt([a, b]) do
    case {time_components([a]), time_components([b])} do
      {nil, _} -> false
      {_, nil} -> false
      {x, y} -> x < y
    end
  end

  defp time_le([a, b]) do
    case {time_components([a]), time_components([b])} do
      {nil, _} -> false
      {_, nil} -> false
      {x, y} -> x <= y
    end
  end

  defp time_gt([a, b]) do
    case {time_components([a]), time_components([b])} do
      {nil, _} -> false
      {_, nil} -> false
      {x, y} -> x > y
    end
  end

  defp time_ge([a, b]) do
    case {time_components([a]), time_components([b])} do
      {nil, _} -> false
      {_, nil} -> false
      {x, y} -> x >= y
    end
  end

  defp time_hash([{:instance, _, attrs}]) do
    {h, m, s, us} = Map.get(attrs, "__time_components__", {0, 0, 0, 0})
    :erlang.phash2({h, m, s, us})
  end

  defp time_hash(_), do: 0

  defp time_replace([{:instance, _, attrs}], kwargs) do
    h = Map.get(kwargs, "hour", Map.get(attrs, "hour"))
    m = Map.get(kwargs, "minute", Map.get(attrs, "minute"))
    s = Map.get(kwargs, "second", Map.get(attrs, "second"))
    us = Map.get(kwargs, "microsecond", Map.get(attrs, "microsecond"))
    make_time_instance(h, m, s, us)
  end

  defp time_replace(_, _), do: {:exception, "TypeError: replace() argument must be a time"}

  defp time_strftime([inst, fmt]) when is_binary(fmt) do
    # Minimal strftime: reuse the datetime strftime path by synthesizing
    # a datetime on 1900-01-01 with the time's components.
    {:instance, _, %{"hour" => h, "minute" => m, "second" => s, "microsecond" => us}} = inst
    naive = NaiveDateTime.new!(1900, 1, 1, h, m, s, {us, 6})

    fmt
    |> String.replace("%H", pad2(h))
    |> String.replace("%M", pad2(m))
    |> String.replace("%S", pad2(s))
    |> String.replace("%f", String.pad_leading(Integer.to_string(us), 6, "0"))
    |> String.replace("%p", if(h < 12, do: "AM", else: "PM"))
    |> String.replace("%I", pad2(rem(h + 11, 12) + 1))
    |> then(fn s ->
      # catch any unhandled % directive
      _ = naive
      s
    end)
  end

  defp time_strftime(_), do: {:exception, "TypeError: strftime() requires a format string"}

  defp time_fromisoformat([s]) when is_binary(s) do
    case parse_iso_time(s) do
      {:ok, {h, m, sec, us}} -> make_time_instance(h, m, sec, us)
      :error -> {:exception, "ValueError: Invalid isoformat string: '#{s}'"}
    end
  end

  defp time_fromisoformat(_), do: {:exception, "TypeError: fromisoformat expects a string"}

  defp parse_iso_time(s) do
    # Accepts HH, HH:MM, HH:MM:SS, HH:MM:SS.ffffff
    case String.split(s, ":") do
      [hh] ->
        with {h, ""} <- Integer.parse(hh), do: {:ok, {h, 0, 0, 0}}

      [hh, mm] ->
        with {h, ""} <- Integer.parse(hh),
             {m, ""} <- Integer.parse(mm),
             do: {:ok, {h, m, 0, 0}}

      [hh, mm, ss] ->
        with {h, ""} <- Integer.parse(hh),
             {m, ""} <- Integer.parse(mm) do
          case String.split(ss, ".") do
            [sec] ->
              with {s, ""} <- Integer.parse(sec), do: {:ok, {h, m, s, 0}}

            [sec, us_str] ->
              with {s, ""} <- Integer.parse(sec),
                   {us, ""} <-
                     Integer.parse(String.pad_trailing(us_str, 6, "0") |> String.slice(0, 6)) do
                {:ok, {h, m, s, us}}
              end
          end
        end

      _ ->
        :error
    end
    |> case do
      {:ok, _} = ok -> ok
      _ -> :error
    end
  end

  @spec datetime_class() ::
          {:class, String.t(), [Pyex.Interpreter.pyvalue()],
           %{optional(String.t()) => Pyex.Interpreter.pyvalue()}}
  defp datetime_class do
    {:class, "datetime", [date_class()],
     Map.merge(datetime_dunders(), %{
       "__init__" => {:builtin_kw, &datetime_init/2},
       "now" => {:builtin, &datetime_now/1},
       "utcnow" => {:builtin, &datetime_utcnow/1},
       "fromisoformat" => {:builtin, &datetime_fromisoformat/1},
       "strptime" => {:builtin, &datetime_strptime/1},
       "fromtimestamp" => {:builtin, &datetime_fromtimestamp/1},
       "utcfromtimestamp" => {:builtin, &datetime_fromtimestamp/1},
       "combine" => {:builtin_kw, &datetime_combine/2}
     })}
  end

  @spec date_class() ::
          {:class, String.t(), [Pyex.Interpreter.pyvalue()],
           %{optional(String.t()) => Pyex.Interpreter.pyvalue()}}
  defp date_class do
    {:class, "date", [],
     Map.merge(date_dunders(), %{
       "__init__" => {:builtin_kw, &date_init/2},
       "today" => {:builtin, &date_today/1},
       "fromisoformat" => {:builtin, &date_fromisoformat/1}
     })}
  end

  @spec timedelta_class() ::
          {:class, String.t(), [Pyex.Interpreter.pyvalue()],
           %{optional(String.t()) => Pyex.Interpreter.pyvalue()}}
  defp timedelta_class do
    {:class, "timedelta", [],
     Map.merge(timedelta_dunders(), %{
       "__init__" => {:builtin_kw, &timedelta_init/2}
     })}
  end

  @spec timezone_class() ::
          {:class, String.t(), [Pyex.Interpreter.pyvalue()],
           %{optional(String.t()) => Pyex.Interpreter.pyvalue()}}
  defp timezone_class do
    cls = timezone_class_bare()

    {:class, "timezone", [],
     Map.merge(timezone_dunders(), %{
       "__init__" => {:builtin_kw, &timezone_init/2},
       "utc" => make_utc_singleton(cls)
     })}
  end

  @spec make_utc_singleton(Pyex.Interpreter.pyvalue()) :: Pyex.Interpreter.pyvalue()
  defp make_utc_singleton(cls) do
    {:instance, inner_cls, attrs} = make_timezone_instance(cls, 0, "UTC")
    {:instance, inner_cls, Map.put(attrs, "__utc_singleton__", true)}
  end

  @spec timezone_class_bare() ::
          {:class, String.t(), [Pyex.Interpreter.pyvalue()],
           %{optional(String.t()) => Pyex.Interpreter.pyvalue()}}
  defp timezone_class_bare do
    {:class, "timezone", [],
     Map.merge(timezone_dunders(), %{
       "__init__" => {:builtin_kw, &timezone_init/2}
     })}
  end

  @spec timezone_dunders() :: %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
  defp timezone_dunders do
    %{
      "__str__" => {:builtin, fn [self] -> tz_str(self) end},
      "__repr__" => {:builtin, fn [self] -> tz_repr(self) end},
      "__eq__" =>
        {:builtin,
         fn [self, other] ->
           extract_offset_seconds(self) == extract_offset_seconds(other)
         end}
    }
  end

  @spec tz_str(Pyex.Interpreter.pyvalue()) :: String.t()
  defp tz_str({:instance, _, %{"__tz_name__" => name}}), do: name
  defp tz_str(_), do: "timezone(...)"

  @spec tz_repr(Pyex.Interpreter.pyvalue()) :: String.t()
  defp tz_repr({:instance, _, %{"__zoneinfo_key__" => key}}),
    do: "zoneinfo.ZoneInfo(key='#{key}')"

  defp tz_repr({:instance, _, %{"__utc_singleton__" => true}}),
    do: "datetime.timezone.utc"

  defp tz_repr({:instance, _, %{"__offset_seconds__" => offset, "__user_name__" => user_name}})
       when is_number(offset) do
    case user_name do
      nil -> "datetime.timezone(#{td_repr_for_offset(offset)})"
      n -> "datetime.timezone(#{td_repr_for_offset(offset)}, '#{n}')"
    end
  end

  defp tz_repr({:instance, _, %{"__tz_name__" => name}}),
    do: "datetime.timezone(#{name})"

  defp tz_repr(_), do: "datetime.timezone(...)"

  @spec td_repr_for_offset(number()) :: String.t()
  defp td_repr_for_offset(offset_seconds) do
    td = normalize_timedelta(offset_seconds)
    "datetime.timedelta(#{td_repr_args(td)})"
  end

  @spec extract_offset_seconds(Pyex.Interpreter.pyvalue()) :: number() | nil
  defp extract_offset_seconds(
         {:instance, {:class, "timezone", _, _}, %{"__offset_seconds__" => s}}
       ),
       do: s

  defp extract_offset_seconds(_), do: nil

  @spec timezone_init([Pyex.Interpreter.pyvalue()], map()) :: Pyex.Interpreter.pyvalue()
  defp timezone_init([_self, offset_td], _kwargs) do
    case extract_total_seconds(offset_td) do
      ts when is_number(ts) ->
        make_timezone(ts, nil)

      nil ->
        {:exception, "TypeError: timezone() argument must be a timedelta"}
    end
  end

  defp timezone_init([_self, offset_td, name], _kwargs) when is_binary(name) do
    case extract_total_seconds(offset_td) do
      ts when is_number(ts) ->
        make_timezone(ts, name)

      nil ->
        {:exception, "TypeError: timezone() argument must be a timedelta"}
    end
  end

  @max_tz_offset 86400

  @doc false
  @spec make_timezone(number(), String.t() | nil) :: Pyex.Interpreter.pyvalue()
  def make_timezone(offset_seconds, name) do
    if abs(offset_seconds) >= @max_tz_offset do
      {:exception,
       "ValueError: offset must be a timedelta strictly between -timedelta(hours=24) and timedelta(hours=24)"}
    else
      make_timezone_instance(timezone_class_bare(), offset_seconds, name)
    end
  end

  @spec make_timezone_instance(Pyex.Interpreter.pyvalue(), number(), String.t() | nil) ::
          Pyex.Interpreter.pyvalue()
  defp make_timezone_instance(cls, offset_seconds, name) do
    display_name = name || format_utc_offset(offset_seconds)

    {:instance, cls,
     %{
       "__offset_seconds__" => offset_seconds,
       "__tz_name__" => display_name,
       "__user_name__" => name,
       "utcoffset" => {:builtin, fn [_dt] -> normalize_timedelta(offset_seconds) end},
       "tzname" => {:builtin, fn [_dt] -> display_name end},
       "dst" => {:builtin, fn [_dt] -> nil end}
     }}
  end

  @spec format_utc_offset(number()) :: String.t()
  defp format_utc_offset(offset_seconds) when offset_seconds == 0, do: "UTC"

  defp format_utc_offset(offset_seconds) do
    "UTC" <> format_offset_iso_full(offset_seconds)
  end

  @spec format_offset_iso_full(number()) :: String.t()
  defp format_offset_iso_full(offset_seconds) do
    sign = if offset_seconds < 0, do: "-", else: "+"
    abs_total = abs(offset_seconds)
    abs_secs = trunc(abs_total)
    frac = abs_total - abs_secs
    hours = div(abs_secs, 3600)
    minutes = div(rem(abs_secs, 3600), 60)
    seconds = rem(abs_secs, 60)
    base = "#{sign}#{pad2(hours)}:#{pad2(minutes)}"

    cond do
      frac != 0 ->
        us = round(frac * 1_000_000)
        base <> ":#{pad2(seconds)}.#{String.pad_leading(Integer.to_string(us), 6, "0")}"

      seconds != 0 ->
        base <> ":#{pad2(seconds)}"

      true ->
        base
    end
  end

  @spec datetime_dunders() :: %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
  defp datetime_dunders do
    %{
      "__str__" => {:builtin, fn [self] -> dt_str(self) end},
      "__repr__" => {:builtin, fn [self] -> dt_repr(self) end},
      "__eq__" => {:builtin, fn [self, other] -> dt_eq(self, other) end},
      "__ne__" => {:builtin, fn [self, other] -> not dt_eq(self, other) end},
      "__lt__" => {:builtin, fn [self, other] -> dt_cmp_check(self, other, :lt) end},
      "__le__" => {:builtin, fn [self, other] -> dt_cmp_not(self, other, :gt) end},
      "__gt__" => {:builtin, fn [self, other] -> dt_cmp_check(self, other, :gt) end},
      "__ge__" => {:builtin, fn [self, other] -> dt_cmp_not(self, other, :lt) end},
      "__add__" => {:builtin, fn [self, other] -> dt_add(self, other) end},
      "__sub__" => {:builtin, fn [self, other] -> dt_sub(self, other) end},
      "__radd__" => {:builtin, fn [self, other] -> dt_add(self, other) end}
    }
  end

  @spec date_dunders() :: %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
  defp date_dunders do
    %{
      "__str__" => {:builtin, fn [self] -> date_str(self) end},
      "__repr__" => {:builtin, fn [self] -> date_repr(self) end},
      "__eq__" => {:builtin, fn [self, other] -> date_eq(self, other) end},
      "__ne__" => {:builtin, fn [self, other] -> not date_eq(self, other) end},
      "__lt__" => {:builtin, fn [self, other] -> date_cmp(self, other) == :lt end},
      "__le__" => {:builtin, fn [self, other] -> date_cmp(self, other) != :gt end},
      "__gt__" => {:builtin, fn [self, other] -> date_cmp(self, other) == :gt end},
      "__ge__" => {:builtin, fn [self, other] -> date_cmp(self, other) != :lt end},
      "__add__" => {:builtin, fn [self, other] -> date_add(self, other) end},
      "__sub__" => {:builtin, fn [self, other] -> date_sub(self, other) end},
      "__radd__" => {:builtin, fn [self, other] -> date_add(self, other) end}
    }
  end

  @spec timedelta_dunders() :: %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
  defp timedelta_dunders do
    %{
      "__str__" => {:builtin, fn [self] -> td_str(self) end},
      "__repr__" => {:builtin, fn [self] -> "datetime.timedelta(#{td_repr_args(self)})" end},
      "__eq__" => {:builtin, fn [self, other] -> td_eq(self, other) end},
      "__ne__" => {:builtin, fn [self, other] -> not td_eq(self, other) end},
      "__lt__" => {:builtin, fn [self, other] -> td_cmp(self, other) == :lt end},
      "__le__" => {:builtin, fn [self, other] -> td_cmp(self, other) != :gt end},
      "__gt__" => {:builtin, fn [self, other] -> td_cmp(self, other) == :gt end},
      "__ge__" => {:builtin, fn [self, other] -> td_cmp(self, other) != :lt end},
      "__add__" => {:builtin, fn [self, other] -> td_add(self, other) end},
      "__sub__" => {:builtin, fn [self, other] -> td_sub(self, other) end},
      "__neg__" => {:builtin, fn [self] -> td_neg(self) end},
      "__abs__" => {:builtin, fn [self] -> td_abs(self) end},
      "__mul__" => {:builtin, fn [self, other] -> td_mul(self, other) end},
      "__rmul__" => {:builtin, fn [self, other] -> td_mul(self, other) end}
    }
  end

  @spec datetime_init([Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) ::
          Pyex.Interpreter.pyvalue()
  defp datetime_init([_self | args], kwargs) do
    {year, month, day, hour, minute, second, microsecond, pos_tzinfo} =
      case args do
        [y, m, d] -> {y, m, d, 0, 0, 0, 0, nil}
        [y, m, d, h] -> {y, m, d, h, 0, 0, 0, nil}
        [y, m, d, h, mi] -> {y, m, d, h, mi, 0, 0, nil}
        [y, m, d, h, mi, s] -> {y, m, d, h, mi, s, 0, nil}
        [y, m, d, h, mi, s, us] -> {y, m, d, h, mi, s, us, nil}
        [y, m, d, h, mi, s, us, tz] -> {y, m, d, h, mi, s, us, tz}
        [] -> {nil, nil, nil, 0, 0, 0, 0, nil}
        _ -> {nil, nil, nil, nil, nil, nil, nil, nil}
      end

    year = Map.get(kwargs, "year", year)
    month = Map.get(kwargs, "month", month)
    day = Map.get(kwargs, "day", day)
    hour = Map.get(kwargs, "hour", hour)
    minute = Map.get(kwargs, "minute", minute)
    second = Map.get(kwargs, "second", second)
    microsecond = Map.get(kwargs, "microsecond", microsecond)
    tzinfo = Map.get(kwargs, "tzinfo", pos_tzinfo)

    if not is_integer(year) or not is_integer(month) or not is_integer(day) do
      {:exception, "TypeError: an integer is required for year, month, day"}
    else
      with {:ok, date} <- Date.new(year, month, day),
           {:ok, time} <- Time.new(hour, minute, second, {microsecond, 6}),
           {:ok, dt} <- DateTime.new(date, time, "Etc/UTC") do
        case tzinfo do
          nil ->
            make_datetime(dt, nil)

          tz_instance ->
            make_datetime_from_wall(dt, tz_instance)
        end
      else
        _ -> {:exception, "ValueError: invalid datetime arguments"}
      end
    end
  end

  @spec date_init([Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) ::
          Pyex.Interpreter.pyvalue()
  defp date_init([_self | args], kwargs) do
    {year, month, day} =
      case args do
        [y, m, d] -> {y, m, d}
        _ -> {nil, nil, nil}
      end

    year = Map.get(kwargs, "year", year)
    month = Map.get(kwargs, "month", month)
    day = Map.get(kwargs, "day", day)

    if not is_integer(year) or not is_integer(month) or not is_integer(day) do
      {:exception, "TypeError: an integer is required for year, month, day"}
    else
      case Date.new(year, month, day) do
        {:ok, d} -> make_date(d)
        {:error, _} -> {:exception, "ValueError: invalid date arguments"}
      end
    end
  end

  @spec datetime_now([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp datetime_now([]), do: make_datetime(DateTime.utc_now(:second), nil)

  defp datetime_now([tz_instance]) do
    make_datetime_from_utc(DateTime.utc_now(:second), tz_instance)
  end

  @spec datetime_utcnow([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp datetime_utcnow([]), do: make_datetime(DateTime.utc_now(:second), nil)

  @spec datetime_fromisoformat([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp datetime_fromisoformat([s]) when is_binary(s) do
    normalized = String.replace_suffix(s, "Z", "+00:00")

    case DateTime.from_iso8601(normalized) do
      {:ok, dt, offset_seconds} ->
        utc_dt = DateTime.shift_zone!(dt, "Etc/UTC")

        if offset_seconds == 0 and not String.contains?(s, "+") and not String.ends_with?(s, "Z") and
             not String.contains?(s, "-00") do
          try_naive_parse(s)
        else
          tz = make_timezone(offset_seconds, nil)
          make_datetime_with_tz(utc_dt, tz)
        end

      {:error, _} ->
        try_naive_parse(s)
    end
  end

  @spec try_naive_parse(String.t()) :: Pyex.Interpreter.pyvalue()
  defp try_naive_parse(s) do
    case NaiveDateTime.from_iso8601(s) do
      {:ok, ndt} ->
        make_naive_datetime(DateTime.from_naive!(ndt, "Etc/UTC"))

      {:error, _} ->
        case Date.from_iso8601(s) do
          {:ok, d} -> make_date(d)
          {:error, _} -> {:exception, "ValueError: Invalid isoformat string: '#{s}'"}
        end
    end
  end

  @spec datetime_strptime([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp datetime_strptime([s, fmt]) when is_binary(s) and is_binary(fmt) do
    case parse_strptime(s, fmt) do
      {:ok, dt} -> make_datetime(dt)
      {:error, msg} -> {:exception, "ValueError: #{msg}"}
    end
  end

  @spec datetime_fromtimestamp([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp datetime_fromtimestamp([ts]) when is_number(ts) do
    microseconds = round(ts * 1_000_000)

    case DateTime.from_unix(microseconds, :microsecond) do
      {:ok, dt} -> make_naive_datetime(dt)
      {:error, _} -> {:exception, "ValueError: timestamp out of range for platform datetime"}
    end
  end

  defp datetime_fromtimestamp([ts]) do
    {:exception, "TypeError: an integer or float is required, got #{py_type_name(ts)}"}
  end

  @spec datetime_combine([Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) ::
          Pyex.Interpreter.pyvalue()
  defp datetime_combine([_self | args], kwargs) do
    {date_arg, time_arg, pos_tz} =
      case args do
        [d, t] -> {d, t, nil}
        [d, t, tz] -> {d, t, tz}
        _ -> {nil, nil, nil}
      end

    tzinfo = Map.get(kwargs, "tzinfo", pos_tz)

    with {:ok, d} <- combine_extract_date(date_arg),
         {:ok, {h, mi, s, us}, time_tz} <- combine_extract_time(time_arg) do
      # Mirror CPython: when tzinfo is not supplied, inherit it from the time
      # argument (if it was a datetime-valued argument with tzinfo).
      tz = if tzinfo == nil, do: time_tz, else: tzinfo

      with {:ok, time} <- Time.new(h, mi, s, {us, 6}),
           {:ok, dt} <- DateTime.new(d, time, "Etc/UTC") do
        case tz do
          nil -> make_datetime(dt, nil)
          tz_instance -> make_datetime_from_wall(dt, tz_instance)
        end
      else
        _ -> {:exception, "ValueError: invalid combine arguments"}
      end
    else
      {:error, msg} -> {:exception, msg}
    end
  end

  @spec combine_extract_date(Pyex.Interpreter.pyvalue()) ::
          {:ok, Date.t()} | {:error, String.t()}
  defp combine_extract_date({:instance, {:class, "datetime", _, _}, %{"__dt__" => dt}}) do
    {:ok, DateTime.to_date(dt)}
  end

  defp combine_extract_date({:instance, {:class, "date", _, _}, %{"__date__" => d}}) do
    {:ok, d}
  end

  defp combine_extract_date({:instance, _, %{"__date__" => d}}), do: {:ok, d}
  defp combine_extract_date({:instance, _, %{"__dt__" => dt}}), do: {:ok, DateTime.to_date(dt)}
  defp combine_extract_date(_), do: {:error, "TypeError: combine() argument 1 must be date"}

  @spec combine_extract_time(Pyex.Interpreter.pyvalue()) ::
          {:ok, {integer(), integer(), integer(), integer()}, Pyex.Interpreter.pyvalue() | nil}
          | {:error, String.t()}
  defp combine_extract_time(
         {:instance, {:class, "time", _, _}, %{"__time_components__" => {h, m, s, us}}}
       ) do
    {:ok, {h, m, s, us}, nil}
  end

  defp combine_extract_time({:instance, {:class, "datetime", _, _}, attrs}) do
    dt = Map.get(attrs, "__dt__")
    tz = Map.get(attrs, "__tzinfo__")

    case dt do
      %DateTime{} ->
        {us, _} = dt.microsecond
        {:ok, {dt.hour, dt.minute, dt.second, us}, tz}

      _ ->
        {:error, "TypeError: combine() argument 2 must be time"}
    end
  end

  defp combine_extract_time({:instance, _, %{"__time_components__" => {h, m, s, us}}}) do
    {:ok, {h, m, s, us}, nil}
  end

  defp combine_extract_time(_), do: {:error, "TypeError: combine() argument 2 must be time"}

  @spec date_fromisoformat([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp date_fromisoformat([s]) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> make_date(d)
      {:error, _} -> {:exception, "ValueError: Invalid isoformat string: '#{s}'"}
    end
  end

  defp date_fromisoformat(_args) do
    {:exception, "TypeError: fromisoformat() argument must be a string"}
  end

  @spec date_today([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp date_today([]), do: make_date(Date.utc_today())

  @spec timedelta_init([Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) ::
          Pyex.Interpreter.pyvalue()
  defp timedelta_init([_self | args], kwargs) do
    make_timedelta(args, kwargs)
  end

  @spec make_timedelta([Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) ::
          Pyex.Interpreter.pyvalue()
  defp make_timedelta(args, kwargs) do
    days_arg =
      case args do
        [d] when is_number(d) -> d
        [d, s] when is_number(d) and is_number(s) -> d
        _ -> 0
      end

    secs_arg =
      case args do
        [_d, s] when is_number(s) -> s
        _ -> 0
      end

    days = Map.get(kwargs, "days", days_arg)
    seconds = Map.get(kwargs, "seconds", secs_arg)
    microseconds = Map.get(kwargs, "microseconds", 0)
    milliseconds = Map.get(kwargs, "milliseconds", 0)
    minutes = Map.get(kwargs, "minutes", 0)
    hours = Map.get(kwargs, "hours", 0)
    weeks = Map.get(kwargs, "weeks", 0)

    total_seconds =
      days * 86400 + weeks * 7 * 86400 + hours * 3600 + minutes * 60 + seconds +
        milliseconds / 1000.0 + microseconds / 1_000_000.0

    normalize_timedelta(total_seconds)
  end

  @doc false
  @spec timedelta_from_seconds(number()) :: Pyex.Interpreter.pyvalue()
  def timedelta_from_seconds(total_seconds), do: normalize_timedelta(total_seconds)

  @spec normalize_timedelta(number()) :: Pyex.Interpreter.pyvalue()
  defp normalize_timedelta(total_seconds) do
    days = trunc(Float.floor(total_seconds / 86400.0))
    secs = (total_seconds - days * 86400) * 1.0
    make_timedelta_instance(days, secs)
  end

  @spec make_timedelta_instance(integer(), number()) :: Pyex.Interpreter.pyvalue()
  defp make_timedelta_instance(days, seconds) do
    int_secs = trunc(seconds)
    us = trunc(round((seconds - int_secs) * 1_000_000))
    # Renormalize if rounding pushed microseconds to 1_000_000.
    {int_secs, us} =
      cond do
        us >= 1_000_000 -> {int_secs + 1, us - 1_000_000}
        us < 0 -> {int_secs - 1, us + 1_000_000}
        true -> {int_secs, us}
      end

    {days, int_secs} =
      cond do
        int_secs >= 86400 -> {days + 1, int_secs - 86400}
        int_secs < 0 -> {days - 1, int_secs + 86400}
        true -> {days, int_secs}
      end

    # Match CPython: compute the exact integer microsecond count, then do
    # a single division.  Using divmod avoids losing precision for very
    # large timedeltas (~999_999_999 days exceeds 2^53 microseconds).
    total_us = (days * 86400 + int_secs) * 1_000_000 + us
    q = div(total_us, 1_000_000)
    r = rem(total_us, 1_000_000)
    total = :erlang.float(q) + r / 1_000_000.0

    {:instance, timedelta_class(),
     %{
       "days" => days,
       "seconds" => int_secs,
       "microseconds" => us,
       "total_seconds" => {:builtin, fn [] -> total end},
       "__total_seconds__" => total
     }}
  end

  @doc false
  @spec make_datetime(DateTime.t(), Pyex.Interpreter.pyvalue() | nil) ::
          Pyex.Interpreter.pyvalue()
  def make_datetime(dt, tzinfo \\ nil) do
    if tzinfo != nil do
      make_datetime_with_tz(dt, tzinfo)
    else
      make_naive_datetime(dt)
    end
  end

  @spec make_naive_datetime(DateTime.t()) :: Pyex.Interpreter.pyvalue()
  defp make_naive_datetime(dt) do
    {us, _} = dt.microsecond
    display_dt = if us == 0, do: DateTime.truncate(dt, :second), else: dt
    iso = display_dt |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()

    {:instance, datetime_class(),
     %{
       "year" => dt.year,
       "month" => dt.month,
       "day" => dt.day,
       "hour" => dt.hour,
       "minute" => dt.minute,
       "second" => dt.second,
       "microsecond" => us,
       "tzinfo" => nil,
       "isoformat" => {:builtin, fn [] -> iso end},
       "strftime" => {:builtin_kw, &strftime_method(dt, nil, &1, &2)},
       "timestamp" => {:builtin, fn [] -> dt_to_timestamp(dt) end},
       "replace" => {:builtin_kw, &dt_replace(dt, nil, &1, &2)},
       "date" => {:builtin, fn [] -> make_date(DateTime.to_date(dt)) end},
       "weekday" => {:builtin, fn [] -> Date.day_of_week(DateTime.to_date(dt)) - 1 end},
       "utcoffset" => {:builtin, fn [] -> nil end},
       "dst" => {:builtin, fn [] -> nil end},
       "astimezone" =>
         {:builtin,
          fn [_tz] ->
            {:exception, "ValueError: astimezone() cannot be applied to a naive datetime"}
          end},
       "__dt__" => dt,
       "__tzinfo__" => nil
     }}
  end

  @spec make_datetime_from_wall(DateTime.t(), Pyex.Interpreter.pyvalue()) ::
          Pyex.Interpreter.pyvalue()
  defp make_datetime_from_wall(wall_dt, tz_instance) do
    case tz_instance do
      {:instance, _, %{"__offset_seconds__" => :dynamic, "__zoneinfo_key__" => key}} ->
        ndt = DateTime.to_naive(wall_dt)

        case DateTime.from_naive(ndt, key, Tz.TimeZoneDatabase) do
          {:ok, local_dt} ->
            utc_dt = DateTime.shift_zone!(local_dt, "Etc/UTC", Tz.TimeZoneDatabase)
            offset = local_dt.utc_offset + local_dt.std_offset

            resolved_tz =
              resolve_zoneinfo_tz(tz_instance, offset, local_dt.zone_abbr, local_dt.std_offset)

            make_datetime_with_tz_resolved(utc_dt, resolved_tz, offset)

          {:ambiguous, dt1, _dt2} ->
            utc_dt = DateTime.shift_zone!(dt1, "Etc/UTC", Tz.TimeZoneDatabase)
            offset = dt1.utc_offset + dt1.std_offset
            resolved_tz = resolve_zoneinfo_tz(tz_instance, offset, dt1.zone_abbr, dt1.std_offset)
            make_datetime_with_tz_resolved(utc_dt, resolved_tz, offset)

          {:gap, _dt_before, dt_after} ->
            utc_dt = DateTime.shift_zone!(dt_after, "Etc/UTC", Tz.TimeZoneDatabase)
            offset = dt_after.utc_offset + dt_after.std_offset

            resolved_tz =
              resolve_zoneinfo_tz(tz_instance, offset, dt_after.zone_abbr, dt_after.std_offset)

            make_datetime_with_tz_resolved(utc_dt, resolved_tz, offset)

          {:error, _} ->
            {:exception, "ValueError: invalid datetime for timezone"}
        end

      {:instance, _, %{"__offset_seconds__" => offset}} when is_number(offset) ->
        utc_dt = DateTime.add(wall_dt, -trunc(offset), :second)
        make_datetime_with_tz(utc_dt, tz_instance)

      _ ->
        make_datetime_with_tz(wall_dt, tz_instance)
    end
  end

  @spec resolve_zoneinfo_tz(Pyex.Interpreter.pyvalue(), number(), String.t(), number()) ::
          Pyex.Interpreter.pyvalue()
  defp resolve_zoneinfo_tz(original_zi, offset, abbr, std_offset) do
    {:instance, cls, attrs} = original_zi

    {:instance, cls,
     Map.merge(attrs, %{
       "__resolved_offset__" => offset,
       "__resolved_abbr__" => abbr,
       "__resolved_std_offset__" => std_offset
     })}
  end

  @spec make_datetime_with_tz_resolved(DateTime.t(), Pyex.Interpreter.pyvalue(), number()) ::
          Pyex.Interpreter.pyvalue()
  defp make_datetime_with_tz_resolved(utc_dt, tz_instance, offset) do
    dst_seconds = extract_resolved_std_offset(tz_instance)
    dst_value = {:builtin, fn [] -> normalize_timedelta(dst_seconds) end}
    build_aware_datetime(utc_dt, tz_instance, offset, dst_value)
  end

  @spec make_datetime_from_utc(DateTime.t(), Pyex.Interpreter.pyvalue()) ::
          Pyex.Interpreter.pyvalue()
  defp make_datetime_from_utc(utc_dt, tz_instance) do
    case tz_instance do
      {:instance, _, %{"__offset_seconds__" => :dynamic, "__zoneinfo_key__" => key}} ->
        case DateTime.shift_zone(utc_dt, key, Tz.TimeZoneDatabase) do
          {:ok, local_dt} ->
            offset = local_dt.utc_offset + local_dt.std_offset

            resolved_tz =
              resolve_zoneinfo_tz(tz_instance, offset, local_dt.zone_abbr, local_dt.std_offset)

            make_datetime_with_tz_resolved(utc_dt, resolved_tz, offset)

          {:error, _} ->
            {:exception, "ValueError: invalid timezone conversion"}
        end

      _ ->
        make_datetime_with_tz(utc_dt, tz_instance)
    end
  end

  @doc false
  @spec make_datetime_with_tz(DateTime.t(), Pyex.Interpreter.pyvalue()) ::
          Pyex.Interpreter.pyvalue()
  def make_datetime_with_tz(utc_dt, tz_instance) do
    offset = extract_tz_offset(tz_instance)
    dst_value = {:builtin, fn [] -> nil end}
    build_aware_datetime(utc_dt, tz_instance, offset, dst_value)
  end

  @spec build_aware_datetime(
          DateTime.t(),
          Pyex.Interpreter.pyvalue(),
          number(),
          Pyex.Interpreter.pyvalue()
        ) :: Pyex.Interpreter.pyvalue()
  defp build_aware_datetime(utc_dt, tz_instance, offset, dst_method) do
    local_dt = DateTime.add(utc_dt, trunc(offset), :second)
    {us, _} = local_dt.microsecond
    display_local = if us == 0, do: DateTime.truncate(local_dt, :second), else: local_dt
    offset_str = format_offset_iso(offset)

    iso =
      (display_local |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()) <> offset_str

    {:instance, datetime_class(),
     %{
       "year" => local_dt.year,
       "month" => local_dt.month,
       "day" => local_dt.day,
       "hour" => local_dt.hour,
       "minute" => local_dt.minute,
       "second" => local_dt.second,
       "microsecond" => us,
       "tzinfo" => tz_instance,
       "isoformat" => {:builtin, fn [] -> iso end},
       "strftime" => {:builtin_kw, &strftime_method(local_dt, tz_instance, &1, &2)},
       "timestamp" => {:builtin, fn [] -> dt_to_timestamp(utc_dt) end},
       "dst" => dst_method,
       "replace" => {:builtin_kw, &dt_replace(local_dt, tz_instance, &1, &2)},
       "date" => {:builtin, fn [] -> make_date(DateTime.to_date(local_dt)) end},
       "weekday" => {:builtin, fn [] -> Date.day_of_week(DateTime.to_date(local_dt)) - 1 end},
       "utcoffset" => {:builtin, fn [] -> normalize_timedelta(offset) end},
       "astimezone" => {:builtin, fn [new_tz] -> make_datetime_from_utc(utc_dt, new_tz) end},
       "__dt__" => utc_dt,
       "__tzinfo__" => tz_instance
     }}
  end

  @spec extract_resolved_std_offset(Pyex.Interpreter.pyvalue()) :: number()
  defp extract_resolved_std_offset({:instance, _, %{"__resolved_std_offset__" => s}}), do: s
  defp extract_resolved_std_offset(_), do: 0

  @spec extract_tz_offset(Pyex.Interpreter.pyvalue()) :: number()
  defp extract_tz_offset({:instance, _, %{"__resolved_offset__" => s}}), do: s
  defp extract_tz_offset({:instance, _, %{"__offset_seconds__" => :dynamic}}), do: 0
  defp extract_tz_offset({:instance, _, %{"__offset_seconds__" => s}}), do: s
  defp extract_tz_offset(_), do: 0

  @spec extract_tz_name(Pyex.Interpreter.pyvalue()) :: String.t()
  defp extract_tz_name({:instance, _, %{"__resolved_abbr__" => abbr}}), do: abbr
  defp extract_tz_name({:instance, _, %{"__tz_name__" => name}}), do: name
  defp extract_tz_name(_), do: ""

  @spec format_offset_iso(number()) :: String.t()
  defp format_offset_iso(offset_seconds) do
    sign = if offset_seconds < 0, do: "-", else: "+"
    abs_secs = abs(trunc(offset_seconds))
    hours = div(abs_secs, 3600)
    minutes = div(rem(abs_secs, 3600), 60)
    "#{sign}#{pad2(hours)}:#{pad2(minutes)}"
  end

  @doc false
  @spec make_date(Date.t()) :: Pyex.Interpreter.pyvalue()
  def make_date(d) do
    iso = Date.to_iso8601(d)

    {:instance, date_class(),
     %{
       "year" => d.year,
       "month" => d.month,
       "day" => d.day,
       "isoformat" => {:builtin, fn [] -> iso end},
       "strftime" => {:builtin_kw, &date_strftime_method(d, &1, &2)},
       "replace" => {:builtin_kw, &d_replace(d, &1, &2)},
       "weekday" => {:builtin, fn [] -> Date.day_of_week(d) - 1 end},
       "__date__" => d
     }}
  end

  @spec dt_to_timestamp(DateTime.t()) :: float()
  defp dt_to_timestamp(dt) do
    dt
    |> DateTime.to_unix(:millisecond)
    |> Kernel./(1000.0)
  end

  @spec strftime_method(
          DateTime.t(),
          Pyex.Interpreter.pyvalue(),
          [Pyex.Interpreter.pyvalue()],
          map()
        ) ::
          Pyex.Interpreter.pyvalue()
  defp strftime_method(dt, tzinfo, [fmt], _kwargs) when is_binary(fmt) do
    format_strftime(dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, fmt, tzinfo)
  end

  @spec date_strftime_method(Date.t(), [Pyex.Interpreter.pyvalue()], map()) ::
          Pyex.Interpreter.pyvalue()
  defp date_strftime_method(d, [fmt], _kwargs) when is_binary(fmt) do
    format_strftime(d.year, d.month, d.day, 0, 0, 0, fmt, nil)
  end

  @spec format_strftime(
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          String.t(),
          Pyex.Interpreter.pyvalue()
        ) :: String.t() | {:exception, String.t()}
  defp format_strftime(year, month, day, hour, minute, second, fmt, tzinfo) do
    case Date.new(year, month, day) do
      {:error, _} ->
        {:exception, "ValueError: invalid date components: #{year}-#{month}-#{day}"}

      {:ok, date} ->
        format_strftime_with_date(date, hour, minute, second, fmt, tzinfo)
    end
  end

  @spec format_strftime_with_date(
          Date.t(),
          integer(),
          integer(),
          integer(),
          String.t(),
          Pyex.Interpreter.pyvalue()
        ) :: String.t()
  @day_abbrs %{
    1 => "Mon",
    2 => "Tue",
    3 => "Wed",
    4 => "Thu",
    5 => "Fri",
    6 => "Sat",
    7 => "Sun"
  }

  @day_names %{
    1 => "Monday",
    2 => "Tuesday",
    3 => "Wednesday",
    4 => "Thursday",
    5 => "Friday",
    6 => "Saturday",
    7 => "Sunday"
  }

  @month_abbrs %{
    1 => "Jan",
    2 => "Feb",
    3 => "Mar",
    4 => "Apr",
    5 => "May",
    6 => "Jun",
    7 => "Jul",
    8 => "Aug",
    9 => "Sep",
    10 => "Oct",
    11 => "Nov",
    12 => "Dec"
  }

  @month_names %{
    1 => "January",
    2 => "February",
    3 => "March",
    4 => "April",
    5 => "May",
    6 => "June",
    7 => "July",
    8 => "August",
    9 => "September",
    10 => "October",
    11 => "November",
    12 => "December"
  }

  defp format_strftime_with_date(date, hour, minute, second, fmt, tzinfo) do
    year = date.year
    month = date.month
    day = date.day
    dow = Date.day_of_week(date)

    fmt
    |> String.replace("%%", "\x00PCT\x00")
    |> String.replace("%Y", pad4(year))
    |> String.replace("%m", pad2(month))
    |> String.replace("%d", pad2(day))
    |> String.replace("%H", pad2(hour))
    |> String.replace("%M", pad2(minute))
    |> String.replace("%S", pad2(second))
    |> String.replace(
      "%I",
      pad2(
        rem(if(hour == 0, do: 12, else: hour), 12)
        |> then(fn
          0 -> 12
          h -> h
        end)
      )
    )
    |> String.replace("%p", if(hour < 12, do: "AM", else: "PM"))
    |> String.replace("%a", Map.get(@day_abbrs, dow, ""))
    |> String.replace("%A", Map.get(@day_names, dow, ""))
    |> String.replace("%b", Map.get(@month_abbrs, month, ""))
    |> String.replace("%B", Map.get(@month_names, month, ""))
    |> String.replace("%j", pad3(day_of_year(year, month, day)))
    |> String.replace("%z", format_strftime_z(tzinfo))
    |> String.replace("%Z", format_strftime_zone_abbr(tzinfo))
    |> String.replace("\x00PCT\x00", "%")
  end

  @spec format_strftime_z(Pyex.Interpreter.pyvalue()) :: String.t()
  defp format_strftime_z(nil), do: ""

  defp format_strftime_z(tz_instance) do
    offset = extract_tz_offset(tz_instance)
    sign = if offset < 0, do: "-", else: "+"
    abs_secs = abs(trunc(offset))
    hours = div(abs_secs, 3600)
    minutes = div(rem(abs_secs, 3600), 60)
    "#{sign}#{pad2(hours)}#{pad2(minutes)}"
  end

  @spec format_strftime_zone_abbr(Pyex.Interpreter.pyvalue()) :: String.t()
  defp format_strftime_zone_abbr(nil), do: ""

  defp format_strftime_zone_abbr(tz_instance) do
    extract_tz_name(tz_instance)
  end

  @spec pad2(integer()) :: String.t()
  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @spec pad3(integer()) :: String.t()
  defp pad3(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")

  @spec pad4(integer()) :: String.t()
  defp pad4(n), do: n |> Integer.to_string() |> String.pad_leading(4, "0")

  @spec day_of_year(integer(), integer(), integer()) :: integer()
  defp day_of_year(year, month, day) do
    {:ok, d} = Date.new(year, month, day)
    {:ok, jan1} = Date.new(year, 1, 1)
    Date.diff(d, jan1) + 1
  end

  @spec dt_replace(
          DateTime.t(),
          Pyex.Interpreter.pyvalue() | nil,
          [Pyex.Interpreter.pyvalue()],
          map()
        ) ::
          Pyex.Interpreter.pyvalue()
  defp dt_replace(dt, tzinfo, _args, kwargs) do
    {us, _} = dt.microsecond
    year = Map.get(kwargs, "year", dt.year)
    month = Map.get(kwargs, "month", dt.month)
    day = Map.get(kwargs, "day", dt.day)
    hour = Map.get(kwargs, "hour", dt.hour)
    minute = Map.get(kwargs, "minute", dt.minute)
    second = Map.get(kwargs, "second", dt.second)
    microsecond = Map.get(kwargs, "microsecond", us)
    new_tzinfo = Map.get(kwargs, "tzinfo", tzinfo)

    with {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second, {microsecond, 6}),
         {:ok, new_dt} <- DateTime.new(date, time, "Etc/UTC") do
      case new_tzinfo do
        nil -> make_naive_datetime(new_dt)
        tz -> make_datetime_from_wall(new_dt, tz)
      end
    else
      _ -> {:exception, "ValueError: invalid replacement values"}
    end
  end

  @spec d_replace(Date.t(), [Pyex.Interpreter.pyvalue()], map()) ::
          Pyex.Interpreter.pyvalue()
  defp d_replace(d, _args, kwargs) do
    year = Map.get(kwargs, "year", d.year)
    month = Map.get(kwargs, "month", d.month)
    day = Map.get(kwargs, "day", d.day)

    case Date.new(year, month, day) do
      {:ok, new_d} -> make_date(new_d)
      {:error, _} -> {:exception, "ValueError: invalid replacement values"}
    end
  end

  @spec dt_str(Pyex.Interpreter.pyvalue()) :: String.t()
  defp dt_str({:instance, _, %{"isoformat" => {:builtin, fun}}}), do: fun.([])
  defp dt_str(_), do: "datetime.datetime(...)"

  @spec dt_repr(Pyex.Interpreter.pyvalue()) :: String.t()
  defp dt_repr(
         {:instance, _,
          %{
            "year" => y,
            "month" => m,
            "day" => d,
            "hour" => h,
            "minute" => mi,
            "second" => s,
            "microsecond" => us,
            "tzinfo" => tzinfo
          }}
       ) do
    components = [y, m, d, h, mi] ++ dt_repr_tail(s, us)
    body = Enum.map_join(components, ", ", &Integer.to_string/1)

    case tzinfo do
      nil -> "datetime.datetime(#{body})"
      tz -> "datetime.datetime(#{body}, tzinfo=#{tz_repr(tz)})"
    end
  end

  defp dt_repr(_), do: "datetime.datetime(...)"

  @spec dt_repr_tail(integer(), integer()) :: [integer()]
  defp dt_repr_tail(0, 0), do: []
  defp dt_repr_tail(s, 0), do: [s]
  defp dt_repr_tail(s, us), do: [s, us]

  @spec date_str(Pyex.Interpreter.pyvalue()) :: String.t()
  defp date_str({:instance, _, %{"__date__" => d}}) do
    Date.to_iso8601(d)
  end

  defp date_str(_), do: "datetime.date(...)"

  @spec date_repr(Pyex.Interpreter.pyvalue()) :: String.t()
  defp date_repr({:instance, _, %{"year" => y, "month" => m, "day" => d}}) do
    "datetime.date(#{y}, #{m}, #{d})"
  end

  defp date_repr(_), do: "datetime.date(...)"

  @spec td_str(Pyex.Interpreter.pyvalue()) :: String.t()
  defp td_str({:instance, _, %{"days" => days, "seconds" => secs, "microseconds" => us}})
       when is_integer(days) and is_integer(secs) and is_integer(us) do
    hours = div(secs, 3600)
    minutes = div(rem(secs, 3600), 60)
    seconds = rem(secs, 60)

    secs_part =
      if us == 0 do
        pad2(seconds)
      else
        "#{pad2(seconds)}.#{pad6(us)}"
      end

    time_part = "#{pad_int(hours)}:#{pad2(minutes)}:#{secs_part}"

    case days do
      0 -> time_part
      1 -> "1 day, #{time_part}"
      -1 -> "-1 day, #{time_part}"
      n -> "#{n} days, #{time_part}"
    end
  end

  defp td_str(_), do: "datetime.timedelta(...)"

  @spec pad6(integer()) :: String.t()
  defp pad6(n), do: n |> Integer.to_string() |> String.pad_leading(6, "0")

  @spec pad_int(integer()) :: String.t()
  defp pad_int(n), do: Integer.to_string(n)

  @spec td_repr_args(Pyex.Interpreter.pyvalue()) :: String.t()
  defp td_repr_args({:instance, _, %{"days" => days, "seconds" => secs, "microseconds" => us}}) do
    parts =
      if(days != 0, do: ["days=#{days}"], else: []) ++
        if(secs != 0, do: ["seconds=#{secs}"], else: []) ++
        if us != 0, do: ["microseconds=#{us}"], else: []

    case parts do
      [] -> "0"
      _ -> Enum.join(parts, ", ")
    end
  end

  defp td_repr_args(_), do: "0"

  @spec extract_dt(Pyex.Interpreter.pyvalue()) :: DateTime.t() | nil
  defp extract_dt({:instance, {:class, "datetime", _, _}, %{"__dt__" => dt}}), do: dt
  defp extract_dt(_), do: nil

  @spec extract_date(Pyex.Interpreter.pyvalue()) :: Date.t() | nil
  defp extract_date({:instance, {:class, "date", _, _}, %{"__date__" => d}}), do: d
  defp extract_date(_), do: nil

  @spec extract_total_seconds(Pyex.Interpreter.pyvalue()) :: number() | nil
  defp extract_total_seconds(
         {:instance, {:class, "timedelta", _, _}, %{"__total_seconds__" => ts}}
       ),
       do: ts

  defp extract_total_seconds(_), do: nil

  @spec is_timedelta?(Pyex.Interpreter.pyvalue()) :: boolean()
  defp is_timedelta?({:instance, {:class, "timedelta", _, _}, _}), do: true
  defp is_timedelta?(_), do: false

  @spec dt_eq(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) :: boolean()
  defp dt_eq(a, b) do
    case {extract_dt(a), extract_dt(b)} do
      {%DateTime{} = da, %DateTime{} = db} ->
        # Python: naive and aware datetimes are never equal, regardless
        # of underlying UTC representation.
        if dt_awareness_mismatch?(a, b) do
          false
        else
          DateTime.compare(da, db) == :eq
        end

      _ ->
        false
    end
  end

  @spec dt_cmp(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          :lt | :eq | :gt | {:exception, String.t()}
  defp dt_cmp(a, b) do
    case {extract_dt(a), extract_dt(b)} do
      {%DateTime{} = da, %DateTime{} = db} ->
        if dt_awareness_mismatch?(a, b) do
          {:exception, "TypeError: can't compare offset-naive and offset-aware datetimes"}
        else
          DateTime.compare(da, db)
        end

      _ ->
        :eq
    end
  end

  @spec dt_cmp_check(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue(), :lt | :gt) ::
          boolean() | {:exception, String.t()}
  defp dt_cmp_check(a, b, expected) do
    case dt_cmp(a, b) do
      {:exception, _} = exc -> exc
      result -> result == expected
    end
  end

  @spec dt_cmp_not(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue(), :lt | :gt) ::
          boolean() | {:exception, String.t()}
  defp dt_cmp_not(a, b, excluded) do
    case dt_cmp(a, b) do
      {:exception, _} = exc -> exc
      result -> result != excluded
    end
  end

  @spec dt_awareness_mismatch?(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          boolean()
  defp dt_awareness_mismatch?(
         {:instance, _, %{"__tzinfo__" => tz_a}},
         {:instance, _, %{"__tzinfo__" => tz_b}}
       ) do
    is_nil(tz_a) != is_nil(tz_b)
  end

  defp dt_awareness_mismatch?(_, _), do: false

  @spec dt_add(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          Pyex.Interpreter.pyvalue()
  defp dt_add(dt_inst, td) do
    case {extract_dt(dt_inst), extract_total_seconds(td)} do
      {%DateTime{} = a, ts} when is_number(ts) ->
        new_utc = DateTime.add(a, round(ts * 1_000_000), :microsecond)

        rebuild_datetime(new_utc, extract_instance_tzinfo(dt_inst))

      _ ->
        {:exception,
         "TypeError: unsupported operand type(s) for +: 'datetime' and '#{py_type_name(td)}'"}
    end
  end

  @spec dt_sub(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          Pyex.Interpreter.pyvalue()
  defp dt_sub(dt_inst, other) do
    a = extract_dt(dt_inst)

    cond do
      a == nil ->
        {:exception, "TypeError: unsupported operand type(s) for -"}

      is_timedelta?(other) ->
        ts = extract_total_seconds(other)
        new_utc = DateTime.add(a, round(-ts * 1_000_000), :microsecond)
        rebuild_datetime(new_utc, extract_instance_tzinfo(dt_inst))

      extract_dt(other) != nil ->
        if dt_awareness_mismatch?(dt_inst, other) do
          {:exception, "TypeError: can't subtract offset-naive and offset-aware datetimes"}
        else
          b = extract_dt(other)
          diff_us = DateTime.diff(a, b, :microsecond)
          normalize_timedelta(diff_us / 1_000_000.0)
        end

      true ->
        {:exception,
         "TypeError: unsupported operand type(s) for -: 'datetime' and '#{py_type_name(other)}'"}
    end
  end

  @spec rebuild_datetime(DateTime.t(), Pyex.Interpreter.pyvalue() | nil) ::
          Pyex.Interpreter.pyvalue()
  defp rebuild_datetime(utc_dt, nil), do: make_naive_datetime(utc_dt)
  defp rebuild_datetime(utc_dt, tzinfo), do: make_datetime_from_utc(utc_dt, tzinfo)

  @spec extract_instance_tzinfo(Pyex.Interpreter.pyvalue()) :: Pyex.Interpreter.pyvalue()
  defp extract_instance_tzinfo({:instance, _, %{"__tzinfo__" => tz}}), do: tz
  defp extract_instance_tzinfo(_), do: nil

  @spec date_eq(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) :: boolean()
  defp date_eq(a, b) do
    case {extract_date(a), extract_date(b)} do
      {%Date{} = da, %Date{} = db} -> Date.compare(da, db) == :eq
      _ -> false
    end
  end

  @spec date_cmp(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) :: :lt | :eq | :gt
  defp date_cmp(a, b) do
    case {extract_date(a), extract_date(b)} do
      {%Date{} = da, %Date{} = db} -> Date.compare(da, db)
      _ -> :eq
    end
  end

  @spec date_add(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          Pyex.Interpreter.pyvalue()
  defp date_add(dt, td) do
    case {extract_date(dt), extract_td_days(td)} do
      {%Date{} = d, days} when is_integer(days) ->
        make_date(Date.add(d, days))

      _ ->
        {:exception,
         "TypeError: unsupported operand type(s) for +: 'date' and '#{py_type_name(td)}'"}
    end
  end

  @spec extract_td_days(Pyex.Interpreter.pyvalue()) :: integer() | nil
  defp extract_td_days({:instance, {:class, "timedelta", _, _}, %{"days" => d}})
       when is_integer(d),
       do: d

  defp extract_td_days(_), do: nil

  @spec date_sub(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          Pyex.Interpreter.pyvalue()
  defp date_sub(dt, other) do
    d = extract_date(dt)

    cond do
      d == nil ->
        {:exception, "TypeError: unsupported operand type(s) for -"}

      is_timedelta?(other) ->
        days = extract_td_days(other) || 0
        make_date(Date.add(d, -days))

      extract_date(other) != nil ->
        other_d = extract_date(other)
        diff_days = Date.diff(d, other_d)
        make_timedelta_instance(diff_days, 0.0)

      true ->
        {:exception,
         "TypeError: unsupported operand type(s) for -: 'date' and '#{py_type_name(other)}'"}
    end
  end

  @spec td_eq(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) :: boolean()
  defp td_eq(a, b) do
    case {extract_total_seconds(a), extract_total_seconds(b)} do
      {ta, tb} when is_number(ta) and is_number(tb) -> ta == tb
      _ -> false
    end
  end

  @spec td_cmp(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) :: :lt | :eq | :gt
  defp td_cmp(a, b) do
    case {extract_total_seconds(a), extract_total_seconds(b)} do
      {ta, tb} when is_number(ta) and is_number(tb) ->
        cond do
          ta < tb -> :lt
          ta > tb -> :gt
          true -> :eq
        end

      _ ->
        :eq
    end
  end

  @spec td_add(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          Pyex.Interpreter.pyvalue()
  defp td_add(self, other) do
    case {extract_total_seconds(self), extract_total_seconds(other)} do
      {ta, tb} when is_number(ta) and is_number(tb) ->
        normalize_timedelta(ta + tb)

      _ ->
        {:exception, "TypeError: unsupported operand type(s) for +"}
    end
  end

  @spec td_sub(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          Pyex.Interpreter.pyvalue()
  defp td_sub(self, other) do
    case {extract_total_seconds(self), extract_total_seconds(other)} do
      {ta, tb} when is_number(ta) and is_number(tb) ->
        normalize_timedelta(ta - tb)

      _ ->
        {:exception, "TypeError: unsupported operand type(s) for -"}
    end
  end

  @spec td_neg(Pyex.Interpreter.pyvalue()) :: Pyex.Interpreter.pyvalue()
  defp td_neg(self) do
    case extract_total_seconds(self) do
      ts when is_number(ts) -> normalize_timedelta(-ts)
      _ -> {:exception, "TypeError: bad operand type for unary -: 'timedelta'"}
    end
  end

  @spec td_abs(Pyex.Interpreter.pyvalue()) :: Pyex.Interpreter.pyvalue()
  defp td_abs(self) do
    case extract_total_seconds(self) do
      ts when is_number(ts) -> normalize_timedelta(abs(ts))
      _ -> {:exception, "TypeError: bad operand type for abs(): 'timedelta'"}
    end
  end

  @spec td_mul(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          Pyex.Interpreter.pyvalue()
  defp td_mul(self, other) when is_number(other) do
    case extract_total_seconds(self) do
      ts when is_number(ts) -> normalize_timedelta(ts * other)
      _ -> {:exception, "TypeError: unsupported operand type(s) for *"}
    end
  end

  defp td_mul(_, other) do
    {:exception,
     "TypeError: unsupported operand type(s) for *: 'timedelta' and '#{py_type_name(other)}'"}
  end

  @spec py_type_name(Pyex.Interpreter.pyvalue()) :: String.t()
  defp py_type_name({:instance, {:class, name, _, _}, _}), do: name
  defp py_type_name(v) when is_integer(v), do: "int"
  defp py_type_name(v) when is_float(v), do: "float"
  defp py_type_name(v) when is_binary(v), do: "str"
  defp py_type_name(v) when is_boolean(v), do: "bool"
  defp py_type_name(v) when is_list(v), do: "list"
  defp py_type_name({:py_dict, _, _}), do: "dict"
  defp py_type_name(v) when is_map(v), do: "dict"
  defp py_type_name(nil), do: "NoneType"
  defp py_type_name(_), do: "object"

  @spec parse_strptime(String.t(), String.t()) :: {:ok, DateTime.t()} | {:error, String.t()}
  defp parse_strptime(string, format) do
    regex_str =
      format
      |> String.replace("%Y", "(?P<year>\\d{4})")
      |> String.replace("%m", "(?P<month>\\d{1,2})")
      |> String.replace("%d", "(?P<day>\\d{1,2})")
      |> String.replace("%H", "(?P<hour>\\d{1,2})")
      |> String.replace("%M", "(?P<minute>\\d{1,2})")
      |> String.replace("%S", "(?P<second>\\d{1,2})")
      |> String.replace("%I", "(?P<hour12>\\d{1,2})")
      |> String.replace("%p", "(?P<ampm>AM|PM|am|pm)")
      |> String.replace("%b", "(?P<month_abbr>[A-Za-z]+)")
      |> String.replace("%B", "(?P<month_name>[A-Za-z]+)")
      |> String.replace("%j", "(?P<day_of_year>\\d{1,3})")
      |> String.replace("%%", "%")

    case Regex.compile("^" <> regex_str <> "$") do
      {:ok, regex} ->
        case Regex.named_captures(regex, string) do
          nil ->
            {:error, "time data '#{string}' does not match format '#{format}'"}

          caps ->
            year = parse_cap_int(caps, "year", 1900)
            month = parse_month(caps)
            day = parse_cap_int(caps, "day", 1)
            hour = parse_hour(caps)
            minute = parse_cap_int(caps, "minute", 0)
            second = parse_cap_int(caps, "second", 0)

            with {:ok, date} <- Date.new(year, month, day),
                 {:ok, time} <- Time.new(hour, minute, second),
                 {:ok, dt} <- DateTime.new(date, time, "Etc/UTC") do
              {:ok, dt}
            else
              _ -> {:error, "invalid parsed datetime values"}
            end
        end

      {:error, _} ->
        {:error, "invalid format string '#{format}'"}
    end
  end

  @spec parse_cap_int(%{optional(String.t()) => String.t()}, String.t(), integer()) :: integer()
  defp parse_cap_int(caps, key, default) do
    case Map.get(caps, key) do
      nil -> default
      "" -> default
      s -> String.to_integer(s)
    end
  end

  @month_name_to_num %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12,
    "january" => 1,
    "february" => 2,
    "march" => 3,
    "april" => 4,
    "june" => 6,
    "july" => 7,
    "august" => 8,
    "september" => 9,
    "october" => 10,
    "november" => 11,
    "december" => 12
  }

  @spec parse_month(%{optional(String.t()) => String.t()}) :: integer()
  defp parse_month(caps) do
    cond do
      Map.has_key?(caps, "month") and caps["month"] != "" ->
        String.to_integer(caps["month"])

      Map.has_key?(caps, "month_abbr") and caps["month_abbr"] != "" ->
        Map.get(@month_name_to_num, String.downcase(caps["month_abbr"]), 1)

      Map.has_key?(caps, "month_name") and caps["month_name"] != "" ->
        Map.get(@month_name_to_num, String.downcase(caps["month_name"]), 1)

      true ->
        1
    end
  end

  @spec parse_hour(%{optional(String.t()) => String.t()}) :: integer()
  defp parse_hour(caps) do
    cond do
      Map.has_key?(caps, "hour") and caps["hour"] != "" ->
        String.to_integer(caps["hour"])

      Map.has_key?(caps, "hour12") and caps["hour12"] != "" ->
        h = String.to_integer(caps["hour12"])
        ampm = String.upcase(Map.get(caps, "ampm", "AM"))

        cond do
          ampm == "PM" and h != 12 -> h + 12
          ampm == "AM" and h == 12 -> 0
          true -> h
        end

      true ->
        0
    end
  end
end
