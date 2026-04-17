#!/usr/bin/env python3
"""
Timezone handling conformance test.
Exercises datetime.timezone, zoneinfo.ZoneInfo, and tz-aware datetime operations.
"""

from datetime import datetime, timezone, timedelta, date
from zoneinfo import ZoneInfo

_pass = 0
_fail = 0


def check(name, condition, detail=""):
    global _pass, _fail
    if condition:
        _pass += 1
        print(f"PASS {name}")
    else:
        _fail += 1
        print(f"FAIL {name}: {detail}")


# ── 1. timezone.utc ──────────────────────────────────────────────────────────
check("tz_utc_str", str(timezone.utc) == "UTC")
check("tz_utc_not_none", timezone.utc is not None)

# ── 2. Fixed-offset timezones ────────────────────────────────────────────────
est = timezone(timedelta(hours=-5))
check("fixed_offset_str", str(est) == "UTC-05:00")

ist = timezone(timedelta(hours=5, minutes=30))
check("fixed_offset_positive", str(ist) == "UTC+05:30")

zero = timezone(timedelta(0))
check("zero_offset_is_utc", str(zero) == "UTC")

named = timezone(timedelta(hours=-5), "EST")
check("named_tz_str", str(named) == "EST")

# ── 3. Timezone-aware construction ───────────────────────────────────────────
dt_utc = datetime(2026, 4, 15, 10, 0, 0, tzinfo=timezone.utc)
check("aware_utc_year", dt_utc.year == 2026)
check("aware_utc_hour", dt_utc.hour == 10)
check("aware_utc_tzinfo", dt_utc.tzinfo is not None)

# ── 4. Isoformat with timezone ───────────────────────────────────────────────
check("isoformat_utc", dt_utc.isoformat() == "2026-04-15T10:00:00+00:00")

dt_est = datetime(2026, 4, 15, 10, 0, 0, tzinfo=est)
check("isoformat_negative", dt_est.isoformat() == "2026-04-15T10:00:00-05:00")

dt_naive = datetime(2026, 4, 15, 10, 0, 0)
check("isoformat_naive", dt_naive.isoformat() == "2026-04-15T10:00:00")

# ── 5. strftime %z and %Z ───────────────────────────────────────────────────
check("strftime_z_utc", dt_utc.strftime("%z") == "+0000")
check("strftime_z_est", dt_est.strftime("%z") == "-0500")
check("strftime_Z_utc", dt_utc.strftime("%Z") == "UTC")
check("strftime_z_naive", dt_naive.strftime("X%zX") == "XX")

# ── 6. RFC-822 formatting ───────────────────────────────────────────────────
rfc822 = dt_utc.strftime("%a, %d %b %Y %H:%M:%S %z")
check("rfc822_format", rfc822 == "Wed, 15 Apr 2026 10:00:00 +0000")

# ── 7. utcoffset() ──────────────────────────────────────────────────────────
check("utcoffset_utc", dt_utc.utcoffset().total_seconds() == 0.0)
check("utcoffset_est", dt_est.utcoffset().total_seconds() == -18000.0)
check("utcoffset_naive", dt_naive.utcoffset() is None)

# ── 8. astimezone ────────────────────────────────────────────────────────────
converted = dt_utc.astimezone(est)
check("astimezone_hour", converted.hour == 5)
check("astimezone_iso", converted.isoformat() == "2026-04-15T05:00:00-05:00")

# ── 9. Arithmetic preserves tzinfo ──────────────────────────────────────────
dt_plus = dt_utc + timedelta(hours=3)
check("add_preserves_tz", dt_plus.isoformat() == "2026-04-15T13:00:00+00:00")

dt_minus = dt_utc - timedelta(hours=2)
check("sub_preserves_tz", dt_minus.isoformat() == "2026-04-15T08:00:00+00:00")

# ── 10. Aware datetime subtraction ──────────────────────────────────────────
dt1 = datetime(2026, 4, 15, 10, 0, 0, tzinfo=timezone.utc)
dt2 = datetime(2026, 4, 15, 15, 0, 0, tzinfo=timezone.utc)
diff = dt2 - dt1
check("aware_sub_seconds", diff.total_seconds() == 18000.0)

# ── 11. Staleness check ─────────────────────────────────────────────────────
ref = datetime(2026, 1, 1, tzinfo=timezone.utc)
now = datetime(2026, 4, 15, tzinfo=timezone.utc)
check("staleness_check", (now - ref) > timedelta(days=90))
check("td_total_seconds", timedelta(days=90).total_seconds() == 7776000.0)

# ── 12. fromisoformat with timezone ──────────────────────────────────────────
parsed_utc = datetime.fromisoformat("2026-04-15T10:00:00+00:00")
check("fromisoformat_utc", parsed_utc.isoformat() == "2026-04-15T10:00:00+00:00")

parsed_z = datetime.fromisoformat("2026-04-15T10:00:00Z")
check("fromisoformat_z", parsed_z.isoformat() == "2026-04-15T10:00:00+00:00")

parsed_neg = datetime.fromisoformat("2026-04-15T10:00:00-05:00")
check("fromisoformat_neg_hour", parsed_neg.hour == 10)

parsed_naive = datetime.fromisoformat("2026-04-15T10:00:00")
check("fromisoformat_naive_tzinfo", parsed_naive.tzinfo is None)

parsed_date = datetime.fromisoformat("2026-04-15")
check("fromisoformat_date_month", parsed_date.month == 4)

# ── 13. ZoneInfo construction ────────────────────────────────────────────────
ny = ZoneInfo("America/New_York")
check("zi_ny_str", str(ny) == "America/New_York")

london = ZoneInfo("Europe/London")
check("zi_london_str", str(london) == "Europe/London")

tokyo = ZoneInfo("Asia/Tokyo")
check("zi_tokyo_str", str(tokyo) == "Asia/Tokyo")

# ── 14. ZoneInfo invalid zone ────────────────────────────────────────────────
try:
    ZoneInfo("Not/A/Zone")
    check("zi_invalid", False, "should have raised")
except Exception as e:
    check(
        "zi_invalid",
        "ZoneInfoNotFoundError" in str(type(e).__name__)
        or "ZoneInfoNotFoundError" in str(e),
    )

# ── 15. DST-aware offsets ────────────────────────────────────────────────────
dt_est_winter = datetime(2026, 1, 15, 12, tzinfo=ny)
check("est_offset", dt_est_winter.utcoffset().total_seconds() == -5 * 3600)

dt_edt_summer = datetime(2026, 7, 15, 12, tzinfo=ny)
check("edt_offset", dt_edt_summer.utcoffset().total_seconds() == -4 * 3600)

dt_tokyo_fixed = datetime(2026, 7, 1, 12, tzinfo=tokyo)
check("tokyo_offset", dt_tokyo_fixed.utcoffset().total_seconds() == 9 * 3600)

# ── 17. DST boundary crossing ────────────────────────────────────────────────
before_dst = datetime(2026, 3, 7, 12, tzinfo=ny)
check("before_dst_offset", before_dst.utcoffset().total_seconds() == -5 * 3600)

after_dst = datetime(2026, 3, 9, 12, tzinfo=ny)
check("after_dst_offset", after_dst.utcoffset().total_seconds() == -4 * 3600)

# ── 18. astimezone with ZoneInfo ─────────────────────────────────────────────
utc_july = datetime(2026, 7, 1, 14, 0, 0, tzinfo=timezone.utc)
ny_july = utc_july.astimezone(ny)
check("astimezone_zi_hour", ny_july.hour == 10)

# ── 19. ZoneInfo isoformat ───────────────────────────────────────────────────
dt_tokyo_iso = datetime(2026, 7, 1, 12, 0, 0, tzinfo=tokyo)
check("zi_isoformat", dt_tokyo_iso.isoformat() == "2026-07-01T12:00:00+09:00")

# ── 20. strftime %Z with ZoneInfo ────────────────────────────────────────────
dt_est_str = datetime(2026, 1, 15, 12, 0, 0, tzinfo=ny)
check("strftime_Z_est", dt_est_str.strftime("%Z") == "EST")

dt_edt_str = datetime(2026, 7, 15, 12, 0, 0, tzinfo=ny)
check("strftime_Z_edt", dt_edt_str.strftime("%Z") == "EDT")

# ── 21. dst() method ─────────────────────────────────────────────────────────
dt_dst_summer = datetime(2026, 7, 15, 12, 0, 0, tzinfo=ny)
check("dst_summer_ny", dt_dst_summer.dst().total_seconds() == 3600.0)

dt_dst_winter = datetime(2026, 1, 15, 12, 0, 0, tzinfo=ny)
check("dst_winter_ny", dt_dst_winter.dst().total_seconds() == 0.0)

dt_dst_tokyo = datetime(2026, 7, 1, 12, 0, 0, tzinfo=tokyo)
check("dst_tokyo", dt_dst_tokyo.dst().total_seconds() == 0.0)

dt_dst_fixed = datetime(2026, 7, 1, 12, 0, 0, tzinfo=est)
check("dst_fixed_offset", dt_dst_fixed.dst() is None)

dt_dst_naive = datetime(2026, 7, 1, 12, 0, 0)
check("dst_naive", dt_dst_naive.dst() is None)

# ── 22. Microsecond preservation on aware datetimes ─────────────────────────
dt_us_utc = datetime(2026, 1, 15, 10, 30, 45, 123456, tzinfo=timezone.utc)
check("aware_us_microsecond", dt_us_utc.microsecond == 123456)
check("aware_us_isoformat", dt_us_utc.isoformat() == "2026-01-15T10:30:45.123456+00:00")

parsed_us = datetime.fromisoformat("2026-04-15T10:00:00.123456+00:00")
check("fromisoformat_us", parsed_us.microsecond == 123456)
check(
    "fromisoformat_us_iso", parsed_us.isoformat() == "2026-04-15T10:00:00.123456+00:00"
)

dt_us_ny = datetime(2026, 7, 1, 12, 0, 0, 123456, tzinfo=ny)
check("zi_us_microsecond", dt_us_ny.microsecond == 123456)
check("zi_us_isoformat", dt_us_ny.isoformat() == "2026-07-01T12:00:00.123456-04:00")

# ── 23. tzinfo as 8th positional argument ───────────────────────────────────
dt_pos_tz = datetime(2026, 1, 15, 10, 0, 0, 0, timezone.utc)
check("positional_tzinfo", dt_pos_tz.tzinfo is not None)
check("positional_tzinfo_iso", dt_pos_tz.isoformat() == "2026-01-15T10:00:00+00:00")

# ── 24. timezone repr ───────────────────────────────────────────────────────
check("repr_utc_singleton", repr(timezone.utc) == "datetime.timezone.utc")
check(
    "repr_fixed_offset",
    repr(timezone(timedelta(hours=-5)))
    == "datetime.timezone(datetime.timedelta(days=-1, seconds=68400))",
)
check(
    "repr_named_offset",
    repr(timezone(timedelta(hours=-5), "EST"))
    == "datetime.timezone(datetime.timedelta(days=-1, seconds=68400), 'EST')",
)

# ── 25. timedelta repr with microseconds ────────────────────────────────────
check(
    "repr_td_us_only",
    repr(timedelta(microseconds=100)) == "datetime.timedelta(microseconds=100)",
)
check(
    "repr_td_combined",
    repr(timedelta(days=1, seconds=30, microseconds=500))
    == "datetime.timedelta(days=1, seconds=30, microseconds=500)",
)

# ── 26. date arithmetic uses timedelta.days ─────────────────────────────────
check(
    "date_plus_sub_day",
    str(date(2026, 1, 15) + timedelta(hours=23, minutes=59)) == "2026-01-15",
)
check("date_plus_25h", str(date(2026, 1, 15) + timedelta(hours=25)) == "2026-01-16")
check("date_minus_25h", str(date(2026, 1, 15) - timedelta(hours=25)) == "2026-01-14")
check("date_minus_23h", str(date(2026, 1, 15) - timedelta(hours=23)) == "2026-01-15")
check("date_neg_1h", str(date(2026, 1, 15) + timedelta(hours=-1)) == "2026-01-14")
check("date_neg_25h", str(date(2026, 1, 15) + timedelta(hours=-25)) == "2026-01-13")

# ── 27. Sub-minute timezone offsets ─────────────────────────────────────────
check("tz_30sec_str", str(timezone(timedelta(seconds=30))) == "UTC+00:00:30")

try:
    timezone(timedelta(hours=24))
    check("tz_24h_rejects", False, "should have raised")
except ValueError:
    check("tz_24h_rejects", True)

# ── 28. Aware datetime microsecond arithmetic ───────────────────────────────
a_us = datetime(2026, 1, 15, 10, 0, 0, 500000, tzinfo=timezone.utc)
b_us = datetime(2026, 1, 15, 10, 0, 0, 100000, tzinfo=timezone.utc)
diff_us = a_us - b_us
check("aware_diff_total", diff_us.total_seconds() == 0.4)
check("aware_diff_us", diff_us.microseconds == 400000)

dt_add_us = datetime(2026, 1, 15, 10, 0, 0, 100000, tzinfo=timezone.utc) + timedelta(
    microseconds=500
)
check("aware_add_us", dt_add_us.microsecond == 100500)

# ── Summary ──────────────────────────────────────────────────────────────────
print(f"\n{_pass} passed, {_fail} failed out of {_pass + _fail}")
