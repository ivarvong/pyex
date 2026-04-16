defmodule Pyex.Conformance.DatetimeAdversarialTest do
  @moduledoc """
  Targeted weird-case conformance checks for datetime/zoneinfo.

  Each test exercises a specific known-painful corner of CPython's
  date/time semantics.  Adding entries here is cheap insurance against
  future regressions — when a bug is found in the wild, paste a
  one-line `check!` reproducer here and it's guarded forever.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  @imports """
  from datetime import datetime, date, timedelta, timezone
  from zoneinfo import ZoneInfo
  """

  describe "min/max year boundaries" do
    test "datetime(1, 1, 1) round-trips through isoformat" do
      check!("""
      #{@imports}
      dt = datetime(1, 1, 1)
      print(dt.isoformat())
      print(repr(dt))
      print(datetime.fromisoformat(dt.isoformat()) == dt)
      """)
    end

    test "datetime(9999, 12, 31, 23, 59, 59, 999999) round-trips" do
      check!("""
      #{@imports}
      dt = datetime(9999, 12, 31, 23, 59, 59, 999999)
      print(dt.isoformat())
      print(datetime.fromisoformat(dt.isoformat()) == dt)
      """)
    end

    test "date(1, 1, 1) and date(9999, 12, 31)" do
      check!("""
      #{@imports}
      print(date(1, 1, 1).isoformat())
      print(date(9999, 12, 31).isoformat())
      """)
    end
  end

  describe "timedelta extremes" do
    test "timedelta(days=999999999) str and total_seconds" do
      check!("""
      #{@imports}
      td = timedelta(days=999999999)
      print(str(td))
      print(td.total_seconds())
      """)
    end

    test "timedelta(days=-999999999) str and total_seconds" do
      check!("""
      #{@imports}
      td = timedelta(days=-999999999)
      print(str(td))
      print(td.total_seconds())
      """)
    end

    test "timedelta microsecond normalization across many inputs" do
      check!("""
      #{@imports}
      for us in [-1, 0, 1, 999999, 1000000, 1000001, -999999, -1000001]:
          td = timedelta(microseconds=us)
          print(us, '->', td.days, td.seconds, td.microseconds, str(td))
      """)
    end

    test "timedelta from many fractional components" do
      check!("""
      #{@imports}
      td = timedelta(weeks=1, days=2, hours=3, minutes=4, seconds=5,
                     milliseconds=6, microseconds=7)
      print(td.days, td.seconds, td.microseconds)
      print(str(td))
      print(td.total_seconds())
      print(repr(td))
      """)
    end
  end

  describe "isoformat edge cases" do
    test "midnight" do
      check!("""
      #{@imports}
      print(datetime(2026, 1, 1).isoformat())
      print(datetime(2026, 1, 1, 0, 0, 0).isoformat())
      print(datetime(2026, 1, 1, 0, 0, 0, 0).isoformat())
      """)
    end

    test "fractional second trimming" do
      check!("""
      #{@imports}
      # CPython does NOT trim zeros from the microsecond field
      print(datetime(2026, 1, 15, 10, 30, 45, 100000).isoformat())
      print(datetime(2026, 1, 15, 10, 30, 45, 1).isoformat())
      print(datetime(2026, 1, 15, 10, 30, 45, 999999).isoformat())
      """)
    end

    test "fromisoformat with Z suffix" do
      check!("""
      #{@imports}
      dt = datetime.fromisoformat("2026-04-15T10:00:00Z")
      print(dt.isoformat())
      print(dt.utcoffset())
      """)
    end

    test "fromisoformat with fractional Z suffix" do
      check!("""
      #{@imports}
      dt = datetime.fromisoformat("2026-04-15T10:00:00.123456Z")
      print(dt.isoformat())
      print(dt.microsecond)
      """)
    end

    test "fromisoformat with odd offsets" do
      check!("""
      #{@imports}
      for s in ["2026-04-15T10:00:00+05:45", "2026-04-15T10:00:00-09:30"]:
          dt = datetime.fromisoformat(s)
          print(dt.isoformat(), dt.utcoffset())
      """)
    end
  end

  describe "timezone() validation" do
    test "accepts sub-minute offsets" do
      check!("""
      #{@imports}
      tz = timezone(timedelta(seconds=30))
      print(str(tz))
      print(repr(tz))
      """)
    end

    test "rejects exact 24h offset" do
      check!("""
      #{@imports}
      try:
          timezone(timedelta(hours=24))
          print("no error")
      except ValueError as e:
          print("ValueError")
      """)
    end

    test "rejects exact -24h offset" do
      check!("""
      #{@imports}
      try:
          timezone(timedelta(hours=-24))
          print("no error")
      except ValueError as e:
          print("ValueError")
      """)
    end
  end

  describe "DST transitions in ZoneInfo" do
    test "spring forward local time sequence" do
      # On 2026-03-08, America/New_York jumps 02:00 -> 03:00
      check!("""
      #{@imports}
      ny = ZoneInfo("America/New_York")
      for hour in [1, 3, 4]:
          dt = datetime(2026, 3, 8, hour, 30, 0, tzinfo=ny)
          print(hour, dt.isoformat(), dt.utcoffset())
      """)
    end

    test "fall back local time sequence" do
      # On 2026-11-01, America/New_York jumps 02:00 -> 01:00
      check!("""
      #{@imports}
      ny = ZoneInfo("America/New_York")
      for hour in [0, 1, 3]:
          dt = datetime(2026, 11, 1, hour, 30, 0, tzinfo=ny)
          print(hour, dt.isoformat(), dt.utcoffset())
      """)
    end

    test "pure UTC datetime never shifts" do
      check!("""
      #{@imports}
      for month in range(1, 13):
          dt = datetime(2026, month, 15, 12, 0, 0, tzinfo=timezone.utc)
          print(month, dt.utcoffset().total_seconds())
      """)
    end
  end

  describe "astimezone contract" do
    test "astimezone to UTC and back is identity" do
      check!("""
      #{@imports}
      ny = ZoneInfo("America/New_York")
      for month in [1, 4, 7, 10]:
          dt = datetime(2026, month, 15, 12, 30, 45, 123456, tzinfo=ny)
          round = dt.astimezone(timezone.utc).astimezone(ny)
          print(month, round == dt, round.isoformat())
      """)
    end

    test "astimezone between two ZoneInfos preserves instant" do
      check!("""
      #{@imports}
      utc = datetime(2026, 7, 4, 18, 30, 0, tzinfo=timezone.utc)
      tokyo = utc.astimezone(ZoneInfo("Asia/Tokyo"))
      london = tokyo.astimezone(ZoneInfo("Europe/London"))
      back = london.astimezone(timezone.utc)
      print(back == utc)
      print(back.isoformat())
      """)
    end
  end

  describe "equality semantics" do
    test "same instant different tz compares equal" do
      check!("""
      #{@imports}
      a = datetime(2026, 1, 15, 12, 0, 0, tzinfo=timezone.utc)
      b = datetime(2026, 1, 15, 7, 0, 0, tzinfo=timezone(timedelta(hours=-5)))
      print(a == b)
      """)
    end

    test "naive vs aware equality is False, not error" do
      check!("""
      #{@imports}
      a = datetime(2026, 1, 15)
      b = datetime(2026, 1, 15, tzinfo=timezone.utc)
      print(a == b)
      print(a != b)
      """)
    end
  end

  describe "timedelta arithmetic normalization" do
    test "td + -td equals zero td" do
      check!("""
      #{@imports}
      for secs in [30, -30, 0, 3600, -86400, 86401, 999999]:
          td = timedelta(seconds=secs)
          zero = td + (-td)
          print(secs, str(zero), zero.total_seconds())
      """)
    end

    test "abs(negative td) matches positive td" do
      check!("""
      #{@imports}
      a = timedelta(hours=-5)
      b = timedelta(hours=5)
      print(abs(a) == b)
      print(str(abs(a)))
      """)
    end
  end

  describe "strftime literal percent" do
    test "double-percent produces literal %" do
      check!("""
      #{@imports}
      dt = datetime(2026, 1, 15)
      print(dt.strftime("%%Y is %Y"))
      print(dt.strftime("%%%%"))
      """)
    end
  end

  describe "fromtimestamp precision" do
    test "fractional timestamp preserves microseconds" do
      check!("""
      #{@imports}
      dt = datetime.fromtimestamp(1700000000.5)
      print(dt.microsecond)
      """)
    end

    test "integer timestamp has zero microseconds" do
      check!("""
      #{@imports}
      dt = datetime.fromtimestamp(1700000000)
      print(dt.microsecond)
      """)
    end
  end
end
