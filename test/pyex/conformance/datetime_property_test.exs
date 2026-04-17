defmodule Pyex.Conformance.DatetimePropertyTest do
  @moduledoc """
  Property-based conformance tests for datetime.

  Each property generates random datetime components and asserts a
  semantic invariant that must hold regardless of input.  These catch
  bugs that combinatorial matrices miss because the inputs were never
  imagined.

  Every property compares against CPython when the invariant relies
  on byte-identical output; others are pure Pyex-side invariants
  (roundtrip, ordering monotonicity, etc.) that don't need an oracle.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :requires_python3

  import Pyex.Test.Oracle

  @imports """
  from datetime import datetime, timedelta, timezone
  from zoneinfo import ZoneInfo
  """

  describe "isoformat -> fromisoformat roundtrip (naive)" do
    property "any valid naive datetime roundtrips exactly" do
      check all(
              year <- integer(1..9999),
              month <- integer(1..12),
              day <- integer(1..28),
              hour <- integer(0..23),
              minute <- integer(0..59),
              second <- integer(0..59),
              us <- integer(0..999_999),
              max_runs: 200
            ) do
        result =
          Pyex.run!("""
          from datetime import datetime
          dt = datetime(#{year}, #{month}, #{day}, #{hour}, #{minute}, #{second}, #{us})
          round = datetime.fromisoformat(dt.isoformat())
          [round == dt, round.isoformat()]
          """)

        [eq, iso] = result
        assert eq == true, "fromisoformat(isoformat(dt)) != dt for #{iso}"
      end
    end
  end

  describe "isoformat -> fromisoformat roundtrip (aware UTC)" do
    property "any valid aware UTC datetime roundtrips exactly" do
      check all(
              year <- integer(2000..2099),
              month <- integer(1..12),
              day <- integer(1..28),
              hour <- integer(0..23),
              minute <- integer(0..59),
              second <- integer(0..59),
              us <- integer(0..999_999),
              max_runs: 200
            ) do
        result =
          Pyex.run!("""
          from datetime import datetime, timezone
          dt = datetime(#{year}, #{month}, #{day}, #{hour}, #{minute}, #{second}, #{us}, tzinfo=timezone.utc)
          round = datetime.fromisoformat(dt.isoformat())
          round == dt
          """)

        assert result == true
      end
    end
  end

  describe "arithmetic inverse" do
    property "(dt + td) - td == dt for naive datetimes" do
      check all(
              year <- integer(2000..2099),
              month <- integer(1..12),
              day <- integer(1..28),
              hour <- integer(0..23),
              minute <- integer(0..59),
              second <- integer(0..59),
              td_secs <- integer(-86_400..86_400),
              max_runs: 200
            ) do
        result =
          Pyex.run!("""
          from datetime import datetime, timedelta
          dt = datetime(#{year}, #{month}, #{day}, #{hour}, #{minute}, #{second})
          td = timedelta(seconds=#{td_secs})
          (dt + td) - td == dt
          """)

        assert result == true
      end
    end

    property "(dt + td) - td == dt for aware datetimes" do
      check all(
              year <- integer(2000..2099),
              month <- integer(1..12),
              day <- integer(1..28),
              hour <- integer(0..23),
              td_secs <- integer(-86_400..86_400),
              max_runs: 100
            ) do
        result =
          Pyex.run!("""
          from datetime import datetime, timedelta, timezone
          dt = datetime(#{year}, #{month}, #{day}, #{hour}, 0, 0, tzinfo=timezone.utc)
          td = timedelta(seconds=#{td_secs})
          (dt + td) - td == dt
          """)

        assert result == true
      end
    end
  end

  describe "timedelta normalization" do
    property "timedelta days/seconds/microseconds match CPython" do
      check all(
              days <- integer(-1000..1000),
              seconds <- integer(-100_000..100_000),
              microseconds <- integer(-10_000_000..10_000_000),
              max_runs: 100
            ) do
        check!("""
        #{@imports}
        td = timedelta(days=#{days}, seconds=#{seconds}, microseconds=#{microseconds})
        print(td.days, td.seconds, td.microseconds, td.total_seconds())
        """)
      end
    end
  end

  describe "astimezone invariants" do
    property "astimezone preserves UTC instant for ZoneInfo zones" do
      zones = [
        "America/New_York",
        "Europe/London",
        "Asia/Tokyo",
        "Australia/Sydney",
        "Pacific/Auckland"
      ]

      check all(
              year <- integer(2020..2030),
              month <- integer(1..12),
              day <- integer(1..28),
              hour <- integer(0..23),
              zone <- member_of(zones),
              max_runs: 100
            ) do
        result =
          Pyex.run!("""
          from datetime import datetime, timezone
          from zoneinfo import ZoneInfo
          dt = datetime(#{year}, #{month}, #{day}, #{hour}, 0, 0, tzinfo=timezone.utc)
          local = dt.astimezone(ZoneInfo("#{zone}"))
          back = local.astimezone(timezone.utc)
          back == dt
          """)

        assert result == true
      end
    end
  end

  describe "ordering is total and consistent" do
    property "trichotomy holds for any pair of aware datetimes" do
      check all(
              y1 <- integer(2000..2099),
              m1 <- integer(1..12),
              d1 <- integer(1..28),
              y2 <- integer(2000..2099),
              m2 <- integer(1..12),
              d2 <- integer(1..28),
              max_runs: 200
            ) do
        result =
          Pyex.run!("""
          from datetime import datetime, timezone
          a = datetime(#{y1}, #{m1}, #{d1}, tzinfo=timezone.utc)
          b = datetime(#{y2}, #{m2}, #{d2}, tzinfo=timezone.utc)
          [a < b, a == b, a > b]
          """)

        [lt, eq, gt] = result
        # Exactly one must be true — trichotomy.
        count = Enum.count([lt, eq, gt], & &1)
        assert count == 1, "trichotomy violation: #{inspect(result)}"
      end
    end
  end

  describe "date arithmetic conformance" do
    property "date + timedelta matches CPython for any day-valued td" do
      check all(
              year <- integer(1..9999),
              month <- integer(1..12),
              day <- integer(1..28),
              td_hours <- integer(-100..100),
              max_runs: 100
            ) do
        check!("""
        #{@imports}
        from datetime import date
        d = date(#{year}, #{month}, #{day})
        td = timedelta(hours=#{td_hours})
        print((d + td).isoformat())
        """)
      end
    end
  end

  describe "repr conformance" do
    property "repr(datetime(...)) matches CPython across component space" do
      check all(
              year <- integer(1..9999),
              month <- integer(1..12),
              day <- integer(1..28),
              hour <- integer(0..23),
              minute <- integer(0..59),
              second <- integer(0..59),
              us <- integer(0..999_999),
              max_runs: 100
            ) do
        check!("""
        #{@imports}
        print(repr(datetime(#{year}, #{month}, #{day}, #{hour}, #{minute}, #{second}, #{us})))
        """)
      end
    end

    property "str(timedelta(...)) matches CPython" do
      check all(
              days <- integer(-100..100),
              seconds <- integer(-200_000..200_000),
              us <- integer(-2_000_000..2_000_000),
              max_runs: 100
            ) do
        check!("""
        #{@imports}
        print(str(timedelta(days=#{days}, seconds=#{seconds}, microseconds=#{us})))
        """)
      end
    end
  end
end
