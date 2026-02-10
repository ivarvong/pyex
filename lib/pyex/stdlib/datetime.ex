defmodule Pyex.Stdlib.Datetime do
  @moduledoc """
  Python `datetime` module providing date, time, and duration operations.

  Provides `datetime.datetime`, `datetime.date`, and `datetime.timedelta`
  as proper class instances with full arithmetic, comparison, and
  formatting support.

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
      datetime.date.today()
  """

  @behaviour Pyex.Stdlib.Module

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "datetime" => datetime_class(),
      "date" => date_class(),
      "timedelta" => timedelta_class()
    }
  end

  @spec datetime_class() ::
          {:class, String.t(), [Pyex.Interpreter.pyvalue()],
           %{optional(String.t()) => Pyex.Interpreter.pyvalue()}}
  defp datetime_class do
    {:class, "datetime", [],
     Map.merge(datetime_dunders(), %{
       "__init__" => {:builtin_kw, &datetime_init/2},
       "now" => {:builtin, &datetime_now/1},
       "utcnow" => {:builtin, &datetime_utcnow/1},
       "fromisoformat" => {:builtin, &datetime_fromisoformat/1},
       "strptime" => {:builtin, &datetime_strptime/1}
     })}
  end

  @spec date_class() ::
          {:class, String.t(), [Pyex.Interpreter.pyvalue()],
           %{optional(String.t()) => Pyex.Interpreter.pyvalue()}}
  defp date_class do
    {:class, "date", [],
     Map.merge(date_dunders(), %{
       "__init__" => {:builtin_kw, &date_init/2},
       "today" => {:builtin, &date_today/1}
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

  @spec datetime_dunders() :: %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
  defp datetime_dunders do
    %{
      "__str__" => {:builtin, fn [self] -> dt_str(self) end},
      "__repr__" => {:builtin, fn [self] -> dt_repr(self) end},
      "__eq__" => {:builtin, fn [self, other] -> dt_eq(self, other) end},
      "__ne__" => {:builtin, fn [self, other] -> not dt_eq(self, other) end},
      "__lt__" => {:builtin, fn [self, other] -> dt_cmp(self, other) == :lt end},
      "__le__" => {:builtin, fn [self, other] -> dt_cmp(self, other) != :gt end},
      "__gt__" => {:builtin, fn [self, other] -> dt_cmp(self, other) == :gt end},
      "__ge__" => {:builtin, fn [self, other] -> dt_cmp(self, other) != :lt end},
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
    {year, month, day, hour, minute, second, microsecond} =
      case args do
        [y, m, d] -> {y, m, d, 0, 0, 0, 0}
        [y, m, d, h] -> {y, m, d, h, 0, 0, 0}
        [y, m, d, h, mi] -> {y, m, d, h, mi, 0, 0}
        [y, m, d, h, mi, s] -> {y, m, d, h, mi, s, 0}
        [y, m, d, h, mi, s, us] -> {y, m, d, h, mi, s, us}
        [] -> {nil, nil, nil, 0, 0, 0, 0}
        _ -> {nil, nil, nil, nil, nil, nil, nil}
      end

    year = Map.get(kwargs, "year", year)
    month = Map.get(kwargs, "month", month)
    day = Map.get(kwargs, "day", day)
    hour = Map.get(kwargs, "hour", hour)
    minute = Map.get(kwargs, "minute", minute)
    second = Map.get(kwargs, "second", second)
    microsecond = Map.get(kwargs, "microsecond", microsecond)

    if not is_integer(year) or not is_integer(month) or not is_integer(day) do
      {:exception, "TypeError: an integer is required for year, month, day"}
    else
      case NaiveDateTime.new(year, month, day, hour, minute, second, {microsecond, 6}) do
        {:ok, ndt} -> make_datetime(ndt)
        {:error, _} -> {:exception, "ValueError: invalid datetime arguments"}
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
  defp datetime_now([]), do: make_datetime(NaiveDateTime.utc_now())

  @spec datetime_utcnow([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp datetime_utcnow([]), do: make_datetime(NaiveDateTime.utc_now())

  @spec datetime_fromisoformat([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp datetime_fromisoformat([s]) when is_binary(s) do
    case NaiveDateTime.from_iso8601(s) do
      {:ok, ndt} ->
        make_datetime(ndt)

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
      {:ok, ndt} -> make_datetime(ndt)
      {:error, msg} -> {:exception, "ValueError: #{msg}"}
    end
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

  @spec normalize_timedelta(number()) :: Pyex.Interpreter.pyvalue()
  defp normalize_timedelta(total_seconds) do
    days = trunc(Float.floor(total_seconds / 86400.0))
    remaining = total_seconds - days * 86400
    secs = if is_float(remaining), do: remaining, else: remaining + 0.0

    make_timedelta_instance(days, secs)
  end

  @spec make_timedelta_instance(integer(), number()) :: Pyex.Interpreter.pyvalue()
  defp make_timedelta_instance(days, seconds) do
    total = days * 86400.0 + seconds

    {:instance, timedelta_class(),
     %{
       "days" => days,
       "seconds" => trunc(seconds),
       "microseconds" => trunc(round((seconds - trunc(seconds)) * 1_000_000)),
       "total_seconds" => {:builtin, fn [] -> total end},
       "__total_seconds__" => total
     }}
  end

  @spec make_datetime(NaiveDateTime.t()) :: Pyex.Interpreter.pyvalue()
  defp make_datetime(ndt) do
    ndt = NaiveDateTime.truncate(ndt, :second)
    iso = NaiveDateTime.to_iso8601(ndt)
    {us, _} = ndt.microsecond

    {:instance, datetime_class(),
     %{
       "year" => ndt.year,
       "month" => ndt.month,
       "day" => ndt.day,
       "hour" => ndt.hour,
       "minute" => ndt.minute,
       "second" => ndt.second,
       "microsecond" => us,
       "isoformat" => {:builtin, fn [] -> iso end},
       "strftime" => {:builtin_kw, &strftime_method(ndt, &1, &2)},
       "timestamp" => {:builtin, fn [] -> ndt_to_timestamp(ndt) end},
       "replace" => {:builtin_kw, &dt_replace(ndt, &1, &2)},
       "date" => {:builtin, fn [] -> make_date(NaiveDateTime.to_date(ndt)) end},
       "__ndt__" => ndt
     }}
  end

  @spec make_date(Date.t()) :: Pyex.Interpreter.pyvalue()
  defp make_date(d) do
    iso = Date.to_iso8601(d)

    {:instance, date_class(),
     %{
       "year" => d.year,
       "month" => d.month,
       "day" => d.day,
       "isoformat" => {:builtin, fn [] -> iso end},
       "strftime" => {:builtin_kw, &date_strftime_method(d, &1, &2)},
       "replace" => {:builtin_kw, &d_replace(d, &1, &2)},
       "__date__" => d
     }}
  end

  @spec ndt_to_timestamp(NaiveDateTime.t()) :: float()
  defp ndt_to_timestamp(ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
    |> Kernel./(1000.0)
  end

  @spec strftime_method(NaiveDateTime.t(), [Pyex.Interpreter.pyvalue()], map()) ::
          Pyex.Interpreter.pyvalue()
  defp strftime_method(ndt, [fmt], _kwargs) when is_binary(fmt) do
    format_strftime(ndt.year, ndt.month, ndt.day, ndt.hour, ndt.minute, ndt.second, fmt)
  end

  @spec date_strftime_method(Date.t(), [Pyex.Interpreter.pyvalue()], map()) ::
          Pyex.Interpreter.pyvalue()
  defp date_strftime_method(d, [fmt], _kwargs) when is_binary(fmt) do
    format_strftime(d.year, d.month, d.day, 0, 0, 0, fmt)
  end

  @spec format_strftime(
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          String.t()
        ) :: String.t()
  defp format_strftime(year, month, day, hour, minute, second, fmt) do
    dow = Date.new!(year, month, day) |> Date.day_of_week()

    day_abbrs = %{
      1 => "Mon",
      2 => "Tue",
      3 => "Wed",
      4 => "Thu",
      5 => "Fri",
      6 => "Sat",
      7 => "Sun"
    }

    day_names = %{
      1 => "Monday",
      2 => "Tuesday",
      3 => "Wednesday",
      4 => "Thursday",
      5 => "Friday",
      6 => "Saturday",
      7 => "Sunday"
    }

    month_abbrs = %{
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

    month_names = %{
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

    fmt
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
    |> String.replace("%a", Map.get(day_abbrs, dow, ""))
    |> String.replace("%A", Map.get(day_names, dow, ""))
    |> String.replace("%b", Map.get(month_abbrs, month, ""))
    |> String.replace("%B", Map.get(month_names, month, ""))
    |> String.replace("%j", pad3(day_of_year(year, month, day)))
    |> String.replace("%%", "%")
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

  @spec dt_replace(NaiveDateTime.t(), [Pyex.Interpreter.pyvalue()], map()) ::
          Pyex.Interpreter.pyvalue()
  defp dt_replace(ndt, _args, kwargs) do
    year = Map.get(kwargs, "year", ndt.year)
    month = Map.get(kwargs, "month", ndt.month)
    day = Map.get(kwargs, "day", ndt.day)
    hour = Map.get(kwargs, "hour", ndt.hour)
    minute = Map.get(kwargs, "minute", ndt.minute)
    second = Map.get(kwargs, "second", ndt.second)

    case NaiveDateTime.new(year, month, day, hour, minute, second) do
      {:ok, new_ndt} -> make_datetime(new_ndt)
      {:error, _} -> {:exception, "ValueError: invalid replacement values"}
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
  defp dt_str({:instance, _, %{"__ndt__" => ndt}}) do
    NaiveDateTime.to_iso8601(ndt)
  end

  defp dt_str(_), do: "datetime.datetime(...)"

  @spec dt_repr(Pyex.Interpreter.pyvalue()) :: String.t()
  defp dt_repr(
         {:instance, _,
          %{"year" => y, "month" => m, "day" => d, "hour" => h, "minute" => mi, "second" => s}}
       ) do
    "datetime.datetime(#{y}, #{m}, #{d}, #{h}, #{mi}, #{s})"
  end

  defp dt_repr(_), do: "datetime.datetime(...)"

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
  defp td_str({:instance, _, %{"__total_seconds__" => total}}) do
    abs_total = abs(total)
    sign = if total < 0, do: "-", else: ""
    days = trunc(abs_total / 86400)
    remaining = abs_total - days * 86400
    hours = trunc(remaining / 3600)
    remaining = remaining - hours * 3600
    minutes = trunc(remaining / 60)
    secs = trunc(remaining - minutes * 60)

    time_part = "#{pad_int(hours)}:#{pad2(minutes)}:#{pad2(secs)}"

    if days > 0 do
      day_word = if days == 1, do: "day", else: "days"
      "#{sign}#{days} #{day_word}, #{time_part}"
    else
      "#{sign}#{time_part}"
    end
  end

  defp td_str(_), do: "datetime.timedelta(...)"

  @spec pad_int(integer()) :: String.t()
  defp pad_int(n), do: Integer.to_string(n)

  @spec td_repr_args(Pyex.Interpreter.pyvalue()) :: String.t()
  defp td_repr_args({:instance, _, %{"days" => days, "seconds" => secs}}) do
    cond do
      secs > 0 -> "days=#{days}, seconds=#{secs}"
      days != 0 -> "days=#{days}"
      true -> "0"
    end
  end

  defp td_repr_args(_), do: "0"

  @spec extract_ndt(Pyex.Interpreter.pyvalue()) :: NaiveDateTime.t() | nil
  defp extract_ndt({:instance, {:class, "datetime", _, _}, %{"__ndt__" => ndt}}), do: ndt
  defp extract_ndt(_), do: nil

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
    case {extract_ndt(a), extract_ndt(b)} do
      {%NaiveDateTime{} = na, %NaiveDateTime{} = nb} -> NaiveDateTime.compare(na, nb) == :eq
      _ -> false
    end
  end

  @spec dt_cmp(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) :: :lt | :eq | :gt
  defp dt_cmp(a, b) do
    case {extract_ndt(a), extract_ndt(b)} do
      {%NaiveDateTime{} = na, %NaiveDateTime{} = nb} -> NaiveDateTime.compare(na, nb)
      _ -> :eq
    end
  end

  @spec dt_add(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          Pyex.Interpreter.pyvalue()
  defp dt_add(dt, td) do
    case {extract_ndt(dt), extract_total_seconds(td)} do
      {%NaiveDateTime{} = ndt, ts} when is_number(ts) ->
        make_datetime(NaiveDateTime.add(ndt, trunc(ts * 1_000_000), :microsecond))

      _ ->
        {:exception,
         "TypeError: unsupported operand type(s) for +: 'datetime' and '#{py_type_name(td)}'"}
    end
  end

  @spec dt_sub(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          Pyex.Interpreter.pyvalue()
  defp dt_sub(dt, other) do
    ndt = extract_ndt(dt)

    cond do
      ndt == nil ->
        {:exception, "TypeError: unsupported operand type(s) for -"}

      is_timedelta?(other) ->
        ts = extract_total_seconds(other)
        make_datetime(NaiveDateTime.add(ndt, trunc(-ts * 1_000_000), :microsecond))

      extract_ndt(other) != nil ->
        other_ndt = extract_ndt(other)
        diff_seconds = NaiveDateTime.diff(ndt, other_ndt, :second)
        normalize_timedelta(diff_seconds)

      true ->
        {:exception,
         "TypeError: unsupported operand type(s) for -: 'datetime' and '#{py_type_name(other)}'"}
    end
  end

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
    case {extract_date(dt), extract_total_seconds(td)} do
      {%Date{} = d, ts} when is_number(ts) ->
        days = trunc(Float.round(ts / 86400.0))
        make_date(Date.add(d, days))

      _ ->
        {:exception,
         "TypeError: unsupported operand type(s) for +: 'date' and '#{py_type_name(td)}'"}
    end
  end

  @spec date_sub(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          Pyex.Interpreter.pyvalue()
  defp date_sub(dt, other) do
    d = extract_date(dt)

    cond do
      d == nil ->
        {:exception, "TypeError: unsupported operand type(s) for -"}

      is_timedelta?(other) ->
        ts = extract_total_seconds(other)
        days = trunc(Float.round(ts / 86400.0))
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
  defp py_type_name(v) when is_map(v), do: "dict"
  defp py_type_name(nil), do: "NoneType"
  defp py_type_name(_), do: "object"

  @spec parse_strptime(String.t(), String.t()) :: {:ok, NaiveDateTime.t()} | {:error, String.t()}
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

            case NaiveDateTime.new(year, month, day, hour, minute, second) do
              {:ok, ndt} -> {:ok, ndt}
              {:error, _} -> {:error, "invalid parsed datetime values"}
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

  @spec parse_month(%{optional(String.t()) => String.t()}) :: integer()
  defp parse_month(caps) do
    month_map = %{
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

    cond do
      Map.has_key?(caps, "month") and caps["month"] != "" ->
        String.to_integer(caps["month"])

      Map.has_key?(caps, "month_abbr") and caps["month_abbr"] != "" ->
        Map.get(month_map, String.downcase(caps["month_abbr"]), 1)

      Map.has_key?(caps, "month_name") and caps["month_name"] != "" ->
        Map.get(month_map, String.downcase(caps["month_name"]), 1)

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
