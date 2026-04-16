defmodule Pyex.Conformance.DatetimeTest do
  @moduledoc """
  Live conformance tests for the `datetime` and `zoneinfo` modules.

  Every test in this module runs the same Python snippet through
  CPython and Pyex and diffs stdout.  There is no recorded ground
  truth; CPython on the machine running `mix test` is the oracle.

  These tests are tagged `:requires_python3` so they auto-skip when
  CPython isn't installed.  They're otherwise plain ExUnit tests,
  and `mix test` runs them by default.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  @imports """
  from datetime import datetime, date, timedelta, timezone
  from zoneinfo import ZoneInfo
  """

  describe "timezone repr" do
    for {label, expr} <- [
          {"utc_singleton", "timezone.utc"},
          {"fixed_neg", "timezone(timedelta(hours=-5))"},
          {"fixed_pos", "timezone(timedelta(hours=5, minutes=30))"},
          {"named", ~s|timezone(timedelta(hours=-5), "EST")|},
          {"zero_named", ~s|timezone(timedelta(0), "UTC")|},
          {"fractional_offset", "timezone(timedelta(seconds=30))"}
        ] do
      test "repr(#{label})" do
        check!("""
        #{@imports}
        print(repr(#{unquote(expr)}))
        """)
      end

      test "str(#{label})" do
        check!("""
        #{@imports}
        print(str(#{unquote(expr)}))
        """)
      end
    end
  end

  describe "naive datetime constructors and repr" do
    for {label, args} <- [
          {"ymd", "2026, 4, 15"},
          {"ymdhms", "2026, 4, 15, 10, 30, 45"},
          {"with_us_0", "2026, 4, 15, 10, 30, 45, 0"},
          {"with_us_mid", "2026, 4, 15, 10, 30, 45, 500000"},
          {"with_us_max", "2026, 4, 15, 10, 30, 45, 999999"},
          {"min_year", "1, 1, 1"},
          {"max_year", "9999, 12, 31, 23, 59, 59, 999999"}
        ] do
      test "repr of datetime(#{label})" do
        check!("""
        #{@imports}
        print(repr(datetime(#{unquote(args)})))
        """)
      end

      test "isoformat of datetime(#{label})" do
        check!("""
        #{@imports}
        print(datetime(#{unquote(args)}).isoformat())
        """)
      end
    end
  end

  describe "aware datetime isoformat across tz matrix" do
    tzs = [
      {"utc", "timezone.utc"},
      {"est", "timezone(timedelta(hours=-5))"},
      {"ist", "timezone(timedelta(hours=5, minutes=30))"},
      {"named_est", ~s|timezone(timedelta(hours=-5), "EST")|},
      {"ny", ~s|ZoneInfo("America/New_York")|},
      {"london", ~s|ZoneInfo("Europe/London")|},
      {"tokyo", ~s|ZoneInfo("Asia/Tokyo")|}
    ]

    datetimes = [
      {"winter_no_us", "2026, 1, 15, 10, 30, 45"},
      {"winter_with_us", "2026, 1, 15, 10, 30, 45, 123456"},
      {"summer_no_us", "2026, 7, 15, 10, 30, 45"},
      {"summer_with_us", "2026, 7, 15, 10, 30, 45, 999999"}
    ]

    for {tz_label, tz_expr} <- tzs, {dt_label, dt_args} <- datetimes do
      test "isoformat #{dt_label} / #{tz_label}" do
        check!("""
        #{@imports}
        dt = datetime(#{unquote(dt_args)}, tzinfo=#{unquote(tz_expr)})
        print(dt.isoformat())
        """)
      end

      test "repr #{dt_label} / #{tz_label}" do
        check!("""
        #{@imports}
        dt = datetime(#{unquote(dt_args)}, tzinfo=#{unquote(tz_expr)})
        print(repr(dt))
        """)
      end

      test "utcoffset #{dt_label} / #{tz_label}" do
        check!("""
        #{@imports}
        dt = datetime(#{unquote(dt_args)}, tzinfo=#{unquote(tz_expr)})
        print(dt.utcoffset())
        """)
      end
    end
  end

  describe "isoformat -> fromisoformat roundtrip" do
    cases = [
      "datetime(2026, 4, 15, 10, 30, 45)",
      "datetime(2026, 4, 15, 10, 30, 45, 123456)",
      "datetime(2026, 4, 15, 10, 30, 45, tzinfo=timezone.utc)",
      "datetime(2026, 4, 15, 10, 30, 45, 123456, tzinfo=timezone.utc)",
      "datetime(2026, 4, 15, 10, 30, 45, tzinfo=timezone(timedelta(hours=-5)))",
      "datetime(2026, 7, 15, 10, 30, 45, 999999, tzinfo=timezone(timedelta(hours=5, minutes=30)))"
    ]

    for expr <- cases do
      test "roundtrip: #{expr}" do
        check!("""
        #{@imports}
        original = #{unquote(expr)}
        round = datetime.fromisoformat(original.isoformat())
        print(round.isoformat())
        print(round == original)
        """)
      end
    end
  end

  describe "timedelta arithmetic and normalization" do
    timedeltas = [
      "timedelta()",
      "timedelta(0)",
      "timedelta(days=1)",
      "timedelta(days=-1)",
      "timedelta(seconds=30)",
      "timedelta(seconds=-30)",
      "timedelta(microseconds=100)",
      "timedelta(microseconds=-100)",
      "timedelta(days=1, seconds=30, microseconds=500)",
      "timedelta(hours=25)",
      "timedelta(hours=-25)",
      "timedelta(weeks=1, days=2, hours=3, minutes=4, seconds=5, milliseconds=6, microseconds=7)"
    ]

    for expr <- timedeltas do
      test "repr: #{expr}" do
        check!("""
        #{@imports}
        print(repr(#{unquote(expr)}))
        """)
      end

      test "str: #{expr}" do
        check!("""
        #{@imports}
        print(str(#{unquote(expr)}))
        """)
      end

      test "components: #{expr}" do
        check!("""
        #{@imports}
        td = #{unquote(expr)}
        print(td.days, td.seconds, td.microseconds, td.total_seconds())
        """)
      end
    end
  end

  describe "date + timedelta uses timedelta.days" do
    cases = [
      {"+0h", "date(2026, 1, 15) + timedelta(hours=0)"},
      {"+23h", "date(2026, 1, 15) + timedelta(hours=23, minutes=59)"},
      {"+25h", "date(2026, 1, 15) + timedelta(hours=25)"},
      {"-1h", "date(2026, 1, 15) + timedelta(hours=-1)"},
      {"-25h", "date(2026, 1, 15) + timedelta(hours=-25)"},
      {"-23h sub", "date(2026, 1, 15) - timedelta(hours=23)"},
      {"+25h sub", "date(2026, 1, 15) - timedelta(hours=25)"},
      {"date - date", "date(2026, 3, 15) - date(2026, 1, 15)"}
    ]

    for {label, expr} <- cases do
      test label do
        check!("""
        #{@imports}
        print(repr(#{unquote(expr)}))
        """)
      end
    end
  end

  describe "DST boundary math for America/New_York" do
    test "utcoffset at DST spring-forward" do
      check!("""
      #{@imports}
      ny = ZoneInfo("America/New_York")
      for day in [7, 8, 9]:
          dt = datetime(2026, 3, day, 12, 0, 0, tzinfo=ny)
          print(day, dt.utcoffset())
      """)
    end

    test "utcoffset at DST fall-back" do
      check!("""
      #{@imports}
      ny = ZoneInfo("America/New_York")
      for day in [31, 1, 2]:
          month = 10 if day == 31 else 11
          dt = datetime(2026, month, day, 12, 0, 0, tzinfo=ny)
          print(month, day, dt.utcoffset())
      """)
    end

    test "zone abbreviation changes across DST" do
      check!("""
      #{@imports}
      ny = ZoneInfo("America/New_York")
      for month in [1, 4, 7, 10, 12]:
          dt = datetime(2026, month, 15, 12, 0, 0, tzinfo=ny)
          print(month, dt.strftime("%Z"), dt.strftime("%z"))
      """)
    end

    test "timedelta add across DST re-resolves offset" do
      check!("""
      #{@imports}
      ny = ZoneInfo("America/New_York")
      winter = datetime(2026, 3, 7, 12, 0, 0, tzinfo=ny)
      for days in [0, 1, 2, 3]:
          dt = winter + timedelta(days=days)
          print(days, dt.utcoffset(), dt.strftime("%Z"))
      """)
    end
  end

  describe "astimezone chain consistency" do
    test "UTC -> NY -> Tokyo -> UTC preserves instant" do
      check!("""
      #{@imports}
      utc = datetime(2026, 7, 15, 18, 30, 45, 123456, tzinfo=timezone.utc)
      ny = utc.astimezone(ZoneInfo("America/New_York"))
      tokyo = ny.astimezone(ZoneInfo("Asia/Tokyo"))
      back = tokyo.astimezone(timezone.utc)
      print(back == utc)
      print(back.isoformat())
      """)
    end
  end

  describe "strftime common directives" do
    directives = [
      "%Y-%m-%d",
      "%H:%M:%S",
      "%Y-%m-%dT%H:%M:%S",
      "%a, %d %b %Y %H:%M:%S",
      "%A %B %d %Y",
      "%I:%M %p",
      "%%Y is literal",
      "%j day of year"
    ]

    for fmt <- directives do
      test "strftime #{inspect(fmt)}" do
        check!("""
        #{@imports}
        dt = datetime(2026, 7, 15, 14, 30, 45)
        print(dt.strftime(#{unquote(inspect(fmt))}))
        """)
      end
    end
  end

  describe "comparisons" do
    test "aware datetime ordering matches UTC instant" do
      check!("""
      #{@imports}
      a = datetime(2026, 1, 15, 12, 0, 0, tzinfo=timezone.utc)
      b = datetime(2026, 1, 15, 7, 0, 0, tzinfo=timezone(timedelta(hours=-5)))
      # b in UTC is 12:00 — same instant
      print(a == b, a < b, a > b)
      """)
    end

    test "naive vs aware comparison raises TypeError" do
      check!("""
      #{@imports}
      a = datetime(2026, 1, 15)
      b = datetime(2026, 1, 15, tzinfo=timezone.utc)
      try:
          a < b
          print("no error")
      except TypeError as e:
          print("TypeError")
      """)
    end
  end

  describe "replace preserves tzinfo and microseconds" do
    cases = [
      {"naive replace hour", "datetime(2026, 1, 15, 10, 0, 0, 123456).replace(hour=11)"},
      {"aware replace hour",
       "datetime(2026, 1, 15, 10, 0, 0, 123456, tzinfo=timezone.utc).replace(hour=11)"},
      {"replace microsecond",
       "datetime(2026, 1, 15, 10, 0, 0, tzinfo=timezone.utc).replace(microsecond=500000)"},
      {"replace drops tz",
       "datetime(2026, 1, 15, 10, 0, 0, tzinfo=timezone.utc).replace(tzinfo=None)"},
      {"zoneinfo replace hour",
       ~s|datetime(2026, 7, 1, 12, 0, 0, tzinfo=ZoneInfo("Asia/Tokyo")).replace(hour=15)|}
    ]

    for {label, expr} <- cases do
      test label do
        check!("""
        #{@imports}
        dt = #{unquote(expr)}
        print(dt.isoformat())
        print(dt.microsecond)
        """)
      end
    end
  end
end
