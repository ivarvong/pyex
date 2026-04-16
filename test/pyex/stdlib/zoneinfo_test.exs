defmodule Pyex.Stdlib.ZoneinfoTest do
  use ExUnit.Case, async: true

  describe "ZoneInfo import" do
    test "from zoneinfo import ZoneInfo succeeds" do
      result =
        Pyex.run!("""
        from zoneinfo import ZoneInfo
        ZoneInfo is not None
        """)

      assert result == true
    end

    test "ZoneInfo('UTC') constructs without error" do
      result =
        Pyex.run!("""
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("UTC")
        str(tz)
        """)

      assert result == "UTC"
    end

    test "ZoneInfo('America/New_York') constructs" do
      result =
        Pyex.run!("""
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("America/New_York")
        str(tz)
        """)

      assert result == "America/New_York"
    end

    test "ZoneInfo('Europe/London') constructs" do
      result =
        Pyex.run!("""
        from zoneinfo import ZoneInfo
        str(ZoneInfo("Europe/London"))
        """)

      assert result == "Europe/London"
    end

    test "ZoneInfo('Asia/Tokyo') constructs" do
      result =
        Pyex.run!("""
        from zoneinfo import ZoneInfo
        str(ZoneInfo("Asia/Tokyo"))
        """)

      assert result == "Asia/Tokyo"
    end

    test "ZoneInfo with invalid zone raises ZoneInfoNotFoundError" do
      {:error, error} =
        Pyex.run("""
        from zoneinfo import ZoneInfo
        ZoneInfo("Not/A/Zone")
        """)

      assert error.message =~ "ZoneInfoNotFoundError"
    end
  end

  describe "available_timezones" do
    test "returns a non-empty set" do
      result =
        Pyex.run!("""
        from zoneinfo import available_timezones
        tzs = available_timezones()
        len(tzs) > 0
        """)

      assert result == true
    end

    test "contains major zones" do
      result =
        Pyex.run!("""
        from zoneinfo import available_timezones
        tzs = available_timezones()
        ["America/New_York" in tzs, "Europe/London" in tzs, "Asia/Tokyo" in tzs, "UTC" in tzs]
        """)

      assert result == [true, true, true, true]
    end
  end

  describe "DST-aware utcoffset" do
    test "EST before DST transition" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        ny = ZoneInfo("America/New_York")
        dt = datetime(2026, 3, 7, 12, tzinfo=ny)
        dt.utcoffset().total_seconds()
        """)

      assert result == -5 * 3600.0
    end

    test "EDT after DST transition" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        ny = ZoneInfo("America/New_York")
        dt = datetime(2026, 3, 9, 12, tzinfo=ny)
        dt.utcoffset().total_seconds()
        """)

      assert result == -4 * 3600.0
    end

    test "Tokyo is always +9 (no DST)" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        tokyo = ZoneInfo("Asia/Tokyo")
        dt = datetime(2026, 7, 1, 12, tzinfo=tokyo)
        dt.utcoffset().total_seconds()
        """)

      assert result == 9 * 3600.0
    end
  end

  describe "datetime with ZoneInfo" do
    test "datetime.now(ZoneInfo) returns tz-aware" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        dt = datetime.now(ZoneInfo("America/New_York"))
        dt.tzinfo is not None
        """)

      assert result == true
    end

    test "astimezone with ZoneInfo" do
      result =
        Pyex.run!("""
        from datetime import datetime, timezone
        from zoneinfo import ZoneInfo
        dt = datetime(2026, 7, 1, 14, 0, 0, tzinfo=timezone.utc)
        ny = dt.astimezone(ZoneInfo("America/New_York"))
        ny.hour
        """)

      assert result == 10
    end

    test "DST-aware scheduling scenario" do
      result =
        Pyex.run!("""
        from datetime import datetime, timezone
        from zoneinfo import ZoneInfo
        t = datetime(2026, 7, 1, 14, 0, tzinfo=timezone.utc).astimezone(ZoneInfo("America/New_York"))
        t.hour
        """)

      assert result == 10
    end

    test "isoformat with ZoneInfo shows offset" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        dt = datetime(2026, 7, 1, 12, 0, 0, tzinfo=ZoneInfo("Asia/Tokyo"))
        dt.isoformat()
        """)

      assert result == "2026-07-01T12:00:00+09:00"
    end

    test "strftime %Z with ZoneInfo shows abbreviation" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        dt = datetime(2026, 1, 15, 12, 0, 0, tzinfo=ZoneInfo("America/New_York"))
        dt.strftime("%Z")
        """)

      assert result == "EST"
    end

    test "dst() returns timedelta for DST zone in summer" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        dt = datetime(2026, 7, 15, 12, 0, 0, tzinfo=ZoneInfo("America/New_York"))
        dt.dst().total_seconds()
        """)

      assert result == 3600.0
    end

    test "dst() returns zero timedelta for non-DST period" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        dt = datetime(2026, 1, 15, 12, 0, 0, tzinfo=ZoneInfo("America/New_York"))
        dt.dst().total_seconds()
        """)

      assert result == 0.0
    end

    test "dst() returns zero timedelta for zone without DST" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        dt = datetime(2026, 7, 1, 12, 0, 0, tzinfo=ZoneInfo("Asia/Tokyo"))
        dt.dst().total_seconds()
        """)

      assert result == 0.0
    end

    test "dst() returns None for fixed-offset timezone" do
      result =
        Pyex.run!("""
        from datetime import datetime, timezone, timedelta
        dt = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone(timedelta(hours=-5)))
        dt.dst() is None
        """)

      assert result == true
    end

    test "strftime %Z shows EDT in summer" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        dt = datetime(2026, 7, 15, 12, 0, 0, tzinfo=ZoneInfo("America/New_York"))
        dt.strftime("%Z")
        """)

      assert result == "EDT"
    end

    test "astimezone(ZoneInfo) produces correct local hour and offset" do
      result =
        Pyex.run!("""
        from datetime import datetime, timezone
        from zoneinfo import ZoneInfo
        utc_dt = datetime(2026, 7, 1, 18, 0, 0, tzinfo=timezone.utc)
        ny_dt = utc_dt.astimezone(ZoneInfo("America/New_York"))
        [ny_dt.hour, ny_dt.utcoffset().total_seconds()]
        """)

      assert result == [14, -4 * 3600.0]
    end

    test "datetime(..., tzinfo=ZoneInfo) isoformat shows correct offset" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        dt = datetime(2026, 7, 1, 14, 0, 0, tzinfo=ZoneInfo("America/New_York"))
        dt.isoformat()
        """)

      assert result == "2026-07-01T14:00:00-04:00"
    end

    test "timedelta addition across DST boundary re-resolves offset" do
      result =
        Pyex.run!("""
        from datetime import datetime, timedelta
        from zoneinfo import ZoneInfo
        ny = ZoneInfo("America/New_York")
        winter = datetime(2026, 3, 7, 12, 0, 0, tzinfo=ny)
        spring = winter + timedelta(days=2)
        [winter.utcoffset().total_seconds(), spring.utcoffset().total_seconds()]
        """)

      assert result == [-5 * 3600.0, -4 * 3600.0]
    end

    test "timedelta subtraction across DST boundary re-resolves offset" do
      result =
        Pyex.run!("""
        from datetime import datetime, timedelta
        from zoneinfo import ZoneInfo
        ny = ZoneInfo("America/New_York")
        spring = datetime(2026, 3, 9, 12, 0, 0, tzinfo=ny)
        winter = spring - timedelta(days=2)
        [spring.utcoffset().total_seconds(), winter.utcoffset().total_seconds()]
        """)

      assert result == [-4 * 3600.0, -5 * 3600.0]
    end

    test "ZoneInfo.dst(dt) returns correct DST offset" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        ny = ZoneInfo("America/New_York")
        dt = datetime(2026, 7, 15, 12, 0, 0, tzinfo=ny)
        ny.dst(dt).total_seconds()
        """)

      assert result == 3600.0
    end

    test "ZoneInfo.dst(dt) returns zero in winter" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        ny = ZoneInfo("America/New_York")
        dt = datetime(2026, 1, 15, 12, 0, 0, tzinfo=ny)
        ny.dst(dt).total_seconds()
        """)

      assert result == 0.0
    end

    test "replace on ZoneInfo-aware datetime preserves tzinfo" do
      result =
        Pyex.run!("""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        dt = datetime(2026, 7, 1, 12, 0, 0, tzinfo=ZoneInfo("Asia/Tokyo"))
        dt2 = dt.replace(hour=15)
        dt2.isoformat()
        """)

      assert result == "2026-07-01T15:00:00+09:00"
    end
  end
end
