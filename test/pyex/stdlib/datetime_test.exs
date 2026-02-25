defmodule Pyex.Stdlib.DatetimeTest do
  use ExUnit.Case, async: true

  describe "datetime.datetime.now" do
    test "returns a datetime dict with year, month, day" do
      result =
        Pyex.run!("""
        import datetime
        dt = datetime.datetime.now()
        dt.year
        """)

      assert is_integer(result)
      assert result >= 2024
    end

    test "has isoformat method" do
      result =
        Pyex.run!("""
        import datetime
        dt = datetime.datetime.now()
        dt.isoformat()
        """)

      assert is_binary(result)
      assert String.contains?(result, "T")
    end

    test "has strftime method" do
      result =
        Pyex.run!("""
        import datetime
        dt = datetime.datetime.now()
        dt.strftime("%Y-%m-%d")
        """)

      assert is_binary(result)
      assert String.match?(result, ~r/\d{4}-\d{2}-\d{2}/)
    end
  end

  describe "datetime.date.today" do
    test "returns a date dict" do
      result =
        Pyex.run!("""
        import datetime
        d = datetime.date.today()
        d.year
        """)

      assert is_integer(result)
      assert result >= 2024
    end

    test "has isoformat" do
      result =
        Pyex.run!("""
        import datetime
        d = datetime.date.today()
        d.isoformat()
        """)

      assert is_binary(result)
      assert String.match?(result, ~r/\d{4}-\d{2}-\d{2}/)
    end
  end

  describe "datetime.timedelta" do
    test "creates timedelta with days" do
      result =
        Pyex.run!("""
        import datetime
        td = datetime.timedelta(7)
        td.days
        """)

      assert result == 7
    end

    test "total_seconds" do
      result =
        Pyex.run!("""
        import datetime
        td = datetime.timedelta(1)
        td.total_seconds()
        """)

      assert result == 86400.0
    end
  end

  describe "datetime.datetime.fromisoformat" do
    test "parses ISO datetime string" do
      result =
        Pyex.run!("""
        import datetime
        dt = datetime.datetime.fromisoformat("2024-01-15T10:30:00")
        dt.year
        """)

      assert result == 2024
    end

    test "parses ISO date string" do
      result =
        Pyex.run!("""
        import datetime
        d = datetime.datetime.fromisoformat("2024-06-15")
        d.month
        """)

      assert result == 6
    end
  end

  describe "from datetime import" do
    test "from datetime import datetime" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime.now()
        dt.year
        """)

      assert is_integer(result)
      assert result >= 2024
    end
  end

  describe "datetime constructor" do
    test "positional args" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime(2024, 3, 15, 10, 30, 45)
        [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
        """)

      assert result == [2024, 3, 15, 10, 30, 45]
    end

    test "year month day only defaults to midnight" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime(2024, 12, 25)
        [dt.hour, dt.minute, dt.second]
        """)

      assert result == [0, 0, 0]
    end

    test "keyword args" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime(year=2024, month=6, day=15, hour=14)
        [dt.year, dt.month, dt.day, dt.hour]
        """)

      assert result == [2024, 6, 15, 14]
    end

    test "invalid date raises ValueError" do
      {:error, error} =
        Pyex.run("""
        from datetime import datetime
        datetime(2024, 13, 1)
        """)

      assert error.message =~ "ValueError"
    end
  end

  describe "date constructor" do
    test "positional args" do
      result =
        Pyex.run!("""
        from datetime import date
        d = date(2024, 7, 4)
        [d.year, d.month, d.day]
        """)

      assert result == [2024, 7, 4]
    end

    test "keyword args" do
      result =
        Pyex.run!("""
        from datetime import date
        d = date(year=2000, month=1, day=1)
        d.isoformat()
        """)

      assert result == "2000-01-01"
    end

    test "invalid date raises ValueError" do
      {:error, error} =
        Pyex.run("""
        from datetime import date
        date(2024, 2, 30)
        """)

      assert error.message =~ "ValueError"
    end
  end

  describe "timedelta keyword args" do
    test "hours" do
      result =
        Pyex.run!("""
        from datetime import timedelta
        td = timedelta(hours=2)
        td.total_seconds()
        """)

      assert result == 7200.0
    end

    test "minutes" do
      result =
        Pyex.run!("""
        from datetime import timedelta
        td = timedelta(minutes=90)
        td.total_seconds()
        """)

      assert result == 5400.0
    end

    test "weeks" do
      result =
        Pyex.run!("""
        from datetime import timedelta
        td = timedelta(weeks=2)
        td.days
        """)

      assert result == 14
    end

    test "combined" do
      result =
        Pyex.run!("""
        from datetime import timedelta
        td = timedelta(days=1, hours=12, minutes=30, seconds=15)
        td.total_seconds()
        """)

      assert result == 1 * 86400.0 + 12 * 3600 + 30 * 60 + 15
    end

    test "no args gives zero timedelta" do
      result =
        Pyex.run!("""
        from datetime import timedelta
        td = timedelta()
        td.total_seconds()
        """)

      assert result == 0.0
    end
  end

  describe "datetime + timedelta" do
    test "add days" do
      result =
        Pyex.run!("""
        from datetime import datetime, timedelta
        dt = datetime(2024, 1, 1, 12, 0, 0)
        result = dt + timedelta(days=30)
        result.isoformat()
        """)

      assert result == "2024-01-31T12:00:00"
    end

    test "add hours" do
      result =
        Pyex.run!("""
        from datetime import datetime, timedelta
        dt = datetime(2024, 1, 1, 10, 0, 0)
        result = dt + timedelta(hours=5)
        [result.hour, result.minute]
        """)

      assert result == [15, 0]
    end

    test "add crosses midnight" do
      result =
        Pyex.run!("""
        from datetime import datetime, timedelta
        dt = datetime(2024, 1, 1, 23, 0, 0)
        result = dt + timedelta(hours=3)
        [result.day, result.hour]
        """)

      assert result == [2, 2]
    end

    test "subtract timedelta" do
      result =
        Pyex.run!("""
        from datetime import datetime, timedelta
        dt = datetime(2024, 6, 15, 12, 0, 0)
        result = dt - timedelta(days=15)
        result.isoformat()
        """)

      assert result == "2024-05-31T12:00:00"
    end
  end

  describe "datetime - datetime" do
    test "returns timedelta" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt1 = datetime(2024, 1, 1)
        dt2 = datetime(2024, 1, 31)
        td = dt2 - dt1
        td.days
        """)

      assert result == 30
    end

    test "negative difference" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt1 = datetime(2024, 3, 1)
        dt2 = datetime(2024, 1, 1)
        td = dt2 - dt1
        td.days
        """)

      assert result == -60
    end

    test "total_seconds on difference" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt1 = datetime(2024, 1, 1, 10, 0, 0)
        dt2 = datetime(2024, 1, 1, 13, 30, 0)
        td = dt2 - dt1
        td.total_seconds()
        """)

      assert result == 12600.0
    end
  end

  describe "date + timedelta" do
    test "add days to date" do
      result =
        Pyex.run!("""
        from datetime import date, timedelta
        d = date(2024, 1, 1)
        result = d + timedelta(days=365)
        result.isoformat()
        """)

      assert result == "2024-12-31"
    end

    test "subtract timedelta from date" do
      result =
        Pyex.run!("""
        from datetime import date, timedelta
        d = date(2024, 3, 1)
        result = d - timedelta(days=1)
        result.isoformat()
        """)

      assert result == "2024-02-29"
    end
  end

  describe "date - date" do
    test "returns timedelta" do
      result =
        Pyex.run!("""
        from datetime import date
        d1 = date(2024, 1, 1)
        d2 = date(2024, 12, 31)
        td = d2 - d1
        td.days
        """)

      assert result == 365
    end
  end

  describe "comparisons" do
    test "datetime less than" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt1 = datetime(2024, 1, 1)
        dt2 = datetime(2024, 6, 1)
        dt1 < dt2
        """)

      assert result == true
    end

    test "datetime greater than" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt1 = datetime(2024, 12, 31)
        dt2 = datetime(2024, 1, 1)
        dt1 > dt2
        """)

      assert result == true
    end

    test "datetime equal" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt1 = datetime(2024, 6, 15, 12, 0, 0)
        dt2 = datetime(2024, 6, 15, 12, 0, 0)
        dt1 == dt2
        """)

      assert result == true
    end

    test "datetime not equal" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt1 = datetime(2024, 6, 15, 12, 0, 0)
        dt2 = datetime(2024, 6, 15, 12, 0, 1)
        dt1 != dt2
        """)

      assert result == true
    end

    test "datetime less than or equal" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt1 = datetime(2024, 6, 15)
        dt2 = datetime(2024, 6, 15)
        [dt1 <= dt2, dt1 >= dt2]
        """)

      assert result == [true, true]
    end

    test "date comparisons" do
      result =
        Pyex.run!("""
        from datetime import date
        d1 = date(2024, 1, 1)
        d2 = date(2024, 12, 31)
        [d1 < d2, d1 == d2, d2 > d1]
        """)

      assert result == [true, false, true]
    end

    test "timedelta comparisons" do
      result =
        Pyex.run!("""
        from datetime import timedelta
        td1 = timedelta(days=1)
        td2 = timedelta(hours=25)
        [td1 < td2, td1 == timedelta(hours=24)]
        """)

      assert result == [true, true]
    end
  end

  describe "str() and repr()" do
    test "str(datetime)" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime(2024, 3, 15, 10, 30, 45)
        str(dt)
        """)

      assert result == "2024-03-15T10:30:45"
    end

    test "str(date)" do
      result =
        Pyex.run!("""
        from datetime import date
        str(date(2024, 7, 4))
        """)

      assert result == "2024-07-04"
    end

    test "str(timedelta)" do
      result =
        Pyex.run!("""
        from datetime import timedelta
        str(timedelta(days=3, hours=5, minutes=30))
        """)

      assert result == "3 days, 5:30:00"
    end

    test "str(timedelta) zero days" do
      result =
        Pyex.run!("""
        from datetime import timedelta
        str(timedelta(hours=2, minutes=15))
        """)

      assert result == "2:15:00"
    end

    test "repr(datetime)" do
      result =
        Pyex.run!("""
        from datetime import datetime
        repr(datetime(2024, 3, 15, 10, 30, 0))
        """)

      assert result == "datetime.datetime(2024, 3, 15, 10, 30, 0)"
    end
  end

  describe "strptime" do
    test "parses date format" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime.strptime("2024-03-15", "%Y-%m-%d")
        [dt.year, dt.month, dt.day]
        """)

      assert result == [2024, 3, 15]
    end

    test "parses datetime format" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime.strptime("2024-03-15 14:30:00", "%Y-%m-%d %H:%M:%S")
        [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
        """)

      assert result == [2024, 3, 15, 14, 30, 0]
    end

    test "parses with month abbreviation" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime.strptime("15 Mar 2024", "%d %b %Y")
        [dt.year, dt.month, dt.day]
        """)

      assert result == [2024, 3, 15]
    end

    test "raises on mismatch" do
      {:error, error} =
        Pyex.run("""
        from datetime import datetime
        datetime.strptime("not-a-date", "%Y-%m-%d")
        """)

      assert error.message =~ "ValueError"
    end
  end

  describe "strftime" do
    test "datetime strftime with full format" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime(2024, 3, 15, 14, 30, 45)
        dt.strftime("%Y-%m-%d %H:%M:%S")
        """)

      assert result == "2024-03-15 14:30:45"
    end

    test "date strftime" do
      result =
        Pyex.run!("""
        from datetime import date
        d = date(2024, 7, 4)
        d.strftime("%Y/%m/%d")
        """)

      assert result == "2024/07/04"
    end

    test "strftime day and month names" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime(2024, 3, 15, 14, 30, 0)
        dt.strftime("%A, %B %d, %Y")
        """)

      assert result == "Friday, March 15, 2024"
    end

    test "strftime AM/PM" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime(2024, 1, 1, 14, 30, 0)
        dt.strftime("%I:%M %p")
        """)

      assert result == "02:30 PM"
    end
  end

  describe "replace" do
    test "datetime replace" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime(2024, 1, 15, 10, 30, 0)
        dt2 = dt.replace(year=2025, month=6)
        [dt2.year, dt2.month, dt2.day, dt2.hour]
        """)

      assert result == [2025, 6, 15, 10]
    end

    test "date replace" do
      result =
        Pyex.run!("""
        from datetime import date
        d = date(2024, 1, 15)
        d2 = d.replace(month=12, day=25)
        d2.isoformat()
        """)

      assert result == "2024-12-25"
    end
  end

  describe "timestamp" do
    test "returns unix timestamp" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime(2024, 1, 1, 0, 0, 0)
        ts = dt.timestamp()
        ts > 0
        """)

      assert result == true
    end

    test "round-trip via fromisoformat" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime(2024, 6, 15, 12, 0, 0)
        ts = dt.timestamp()
        ts
        """)

      assert is_float(result)
      assert result > 1_700_000_000.0
    end
  end

  describe "datetime.date() method" do
    test "extracts date from datetime" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime(2024, 6, 15, 14, 30, 0)
        d = dt.date()
        [d.year, d.month, d.day]
        """)

      assert result == [2024, 6, 15]
    end

    test "extracted date has strftime" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime(2024, 6, 15, 14, 30, 0)
        dt.date().strftime("%Y-%m-%d")
        """)

      assert result == "2024-06-15"
    end
  end

  describe "timedelta arithmetic" do
    test "timedelta + timedelta" do
      result =
        Pyex.run!("""
        from datetime import timedelta
        td1 = timedelta(days=1)
        td2 = timedelta(hours=12)
        td3 = td1 + td2
        td3.total_seconds()
        """)

      assert result == 86400.0 + 43200.0
    end

    test "timedelta - timedelta" do
      result =
        Pyex.run!("""
        from datetime import timedelta
        td1 = timedelta(days=5)
        td2 = timedelta(days=3)
        td3 = td1 - td2
        td3.days
        """)

      assert result == 2
    end

    test "timedelta * int" do
      result =
        Pyex.run!("""
        from datetime import timedelta
        td = timedelta(hours=3)
        td2 = td * 4
        td2.total_seconds()
        """)

      assert result == 43200.0
    end

    test "int * timedelta" do
      result =
        Pyex.run!("""
        from datetime import timedelta
        td = timedelta(days=1)
        td2 = 7 * td
        td2.days
        """)

      assert result == 7
    end
  end

  describe "real-world patterns" do
    test "calculate days until deadline" do
      result =
        Pyex.run!("""
        from datetime import datetime, timedelta
        now = datetime(2024, 6, 1, 12, 0, 0)
        deadline = datetime(2024, 6, 30, 23, 59, 59)
        remaining = deadline - now
        remaining.days
        """)

      assert result == 29
    end

    test "generate date range" do
      result =
        Pyex.run!("""
        from datetime import date, timedelta
        start = date(2024, 1, 1)
        dates = []
        for i in range(5):
            dates.append((start + timedelta(days=i)).isoformat())
        dates
        """)

      assert result == [
               "2024-01-01",
               "2024-01-02",
               "2024-01-03",
               "2024-01-04",
               "2024-01-05"
             ]
    end

    test "sort datetimes" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dates = [
            datetime(2024, 12, 25),
            datetime(2024, 1, 1),
            datetime(2024, 7, 4),
        ]
        sorted_dates = sorted(dates)
        [str(d) for d in sorted_dates]
        """)

      assert result == [
               "2024-01-01T00:00:00",
               "2024-07-04T00:00:00",
               "2024-12-25T00:00:00"
             ]
    end

    test "business hours calculation" do
      result =
        Pyex.run!("""
        from datetime import datetime, timedelta
        start = datetime(2024, 1, 15, 9, 0, 0)
        end = start + timedelta(hours=8)
        str(end)
        """)

      assert result == "2024-01-15T17:00:00"
    end

    test "age calculation" do
      result =
        Pyex.run!("""
        from datetime import date
        birth = date(1990, 5, 15)
        today = date(2024, 6, 1)
        age_days = (today - birth).days
        age_years = age_days // 365
        age_years
        """)

      assert result == 12_436 |> div(365)
    end

    test "parse and reformat date string" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime.strptime("03/15/2024", "%m/%d/%Y")
        dt.strftime("%Y-%m-%d")
        """)

      assert result == "2024-03-15"
    end

    test "min and max datetime" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dates = [datetime(2024, 3, 15), datetime(2024, 1, 1), datetime(2024, 12, 31)]
        [str(min(dates)), str(max(dates))]
        """)

      assert result == ["2024-01-01T00:00:00", "2024-12-31T00:00:00"]
    end

    test "timedelta with f-string" do
      result =
        Pyex.run!("""
        from datetime import timedelta
        td = timedelta(days=2, hours=5, minutes=30)
        f"Duration: {td}"
        """)

      assert result == "Duration: 2 days, 5:30:00"
    end
  end

  describe "datetime.datetime.fromtimestamp" do
    test "known unix timestamp returns correct datetime" do
      result =
        Pyex.run!("""
        import datetime
        dt = datetime.datetime.fromtimestamp(0)
        [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
        """)

      assert result == [1970, 1, 1, 0, 0, 0]
    end

    test "integer seconds" do
      result =
        Pyex.run!("""
        import datetime
        dt = datetime.datetime.fromtimestamp(1700000000)
        dt.year >= 2023
        """)

      assert result == true
    end

    test "float seconds with sub-second precision" do
      result =
        Pyex.run!("""
        import datetime
        dt = datetime.datetime.fromtimestamp(1700000000.5)
        dt.year >= 2023
        """)

      assert result == true
    end

    test "roundtrip: fromtimestamp(timestamp()) == original" do
      result =
        Pyex.run!("""
        import datetime
        original = datetime.datetime(2024, 6, 15, 12, 30, 45)
        ts = original.timestamp()
        recovered = datetime.datetime.fromtimestamp(ts)
        [recovered.year, recovered.month, recovered.day,
         recovered.hour, recovered.minute, recovered.second]
        """)

      assert result == [2024, 6, 15, 12, 30, 45]
    end

    test "type error on non-number" do
      result =
        Pyex.run("""
        import datetime
        datetime.datetime.fromtimestamp("not a number")
        """)

      assert {:error, %Pyex.Error{kind: :python}} = result
    end
  end

  describe "datetime.datetime.utcfromtimestamp" do
    test "epoch returns 1970-01-01T00:00:00" do
      result =
        Pyex.run!("""
        import datetime
        dt = datetime.datetime.utcfromtimestamp(0)
        [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
        """)

      assert result == [1970, 1, 1, 0, 0, 0]
    end

    test "matches fromtimestamp for UTC timestamps" do
      result =
        Pyex.run!("""
        import datetime
        ts = 1700000000
        dt1 = datetime.datetime.fromtimestamp(ts)
        dt2 = datetime.datetime.utcfromtimestamp(ts)
        dt1 == dt2
        """)

      assert result == true
    end

    test "roundtrip via utcfromtimestamp" do
      result =
        Pyex.run!("""
        import datetime
        original = datetime.datetime(2023, 11, 14, 22, 13, 20)
        ts = original.timestamp()
        recovered = datetime.datetime.utcfromtimestamp(ts)
        str(recovered)
        """)

      assert result == "2023-11-14T22:13:20"
    end

    test "from datetime import works for both methods" do
      result =
        Pyex.run!("""
        from datetime import datetime
        dt = datetime.utcfromtimestamp(0)
        dt.isoformat()
        """)

      assert result == "1970-01-01T00:00:00"
    end
  end

  describe "datetime.date.fromisoformat" do
    test "parses a date string" do
      result =
        Pyex.run!("""
        from datetime import date
        d = date.fromisoformat("2024-03-15")
        (d.year, d.month, d.day)
        """)

      assert result == {:tuple, [2024, 3, 15]}
    end

    test "isoformat round-trips" do
      result =
        Pyex.run!("""
        from datetime import date
        date.fromisoformat("2026-01-15").isoformat()
        """)

      assert result == "2026-01-15"
    end

    test "raises on invalid string" do
      assert {:error, %Pyex.Error{message: msg}} =
               Pyex.run("""
               from datetime import date
               date.fromisoformat("not-a-date")
               """)

      assert msg =~ "ValueError"
    end

    test "raises on non-string argument" do
      assert {:error, %Pyex.Error{message: msg}} =
               Pyex.run("""
               from datetime import date
               date.fromisoformat(20240101)
               """)

      assert msg =~ "TypeError"
    end

    test "supports comparisons" do
      result =
        Pyex.run!("""
        from datetime import date
        a = date.fromisoformat("2024-01-01")
        b = date.fromisoformat("2024-06-15")
        (a < b, a > b, a == b)
        """)

      assert result == {:tuple, [true, false, false]}
    end
  end

  describe "sorted() with date/datetime key functions" do
    test "sorts strings by date key ascending" do
      result =
        Pyex.run!("""
        from datetime import date
        strs = ["2026-03-05", "2026-01-15", "2026-02-10"]
        sorted(strs, key=lambda s: date.fromisoformat(s))
        """)

      assert result == ["2026-01-15", "2026-02-10", "2026-03-05"]
    end

    test "sorts strings by date key descending" do
      result =
        Pyex.run!("""
        from datetime import date
        strs = ["2026-03-05", "2026-01-15", "2026-02-10"]
        sorted(strs, key=lambda s: date.fromisoformat(s), reverse=True)
        """)

      assert result == ["2026-03-05", "2026-02-10", "2026-01-15"]
    end

    test "sorts objects by date field" do
      result =
        Pyex.run!("""
        from datetime import date
        from pydantic import BaseModel

        class Event(BaseModel):
            name: str
            on: str

        events = [
            Event(name="c", on="2026-03-01"),
            Event(name="a", on="2026-01-01"),
            Event(name="b", on="2026-02-01"),
        ]
        [e.name for e in sorted(events, key=lambda e: date.fromisoformat(e.on))]
        """)

      assert result == ["a", "b", "c"]
    end

    test "sorts strings by datetime key ascending" do
      result =
        Pyex.run!("""
        from datetime import datetime
        strs = ["2026-03-05T12:00:00", "2026-01-15T08:00:00", "2026-02-10T23:59:00"]
        sorted(strs, key=lambda s: datetime.fromisoformat(s))
        """)

      assert result == ["2026-01-15T08:00:00", "2026-02-10T23:59:00", "2026-03-05T12:00:00"]
    end

    test "sorts strings by datetime key descending" do
      result =
        Pyex.run!("""
        from datetime import datetime
        strs = ["2026-03-05T12:00:00", "2026-01-15T08:00:00", "2026-02-10T23:59:00"]
        sorted(strs, key=lambda s: datetime.fromisoformat(s), reverse=True)
        """)

      assert result == ["2026-03-05T12:00:00", "2026-02-10T23:59:00", "2026-01-15T08:00:00"]
    end

    test "stable sort preserves order of equal keys" do
      result =
        Pyex.run!("""
        from datetime import date
        pairs = [("b", "2026-01-01"), ("a", "2026-01-01"), ("c", "2026-02-01")]
        [name for name, _ in sorted(pairs, key=lambda p: date.fromisoformat(p[1]))]
        """)

      assert result == ["b", "a", "c"]
    end
  end
end
