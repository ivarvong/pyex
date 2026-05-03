"""Compute the four annual Manhattanhenge sunset dates.

Algorithm: Meeus low-precision solar position (Chap. 25), Bennett 1982
atmospheric refraction, parameterized local horizon (Palisades cliffs
viewed from midtown). Bisects time-of-day on apparent altitude until
the sun's center reaches the horizon target, then sweeps candidate
days for the minimum azimuth error against the Manhattan grid bearing
(28.9 deg clockwise of N -> 298.9 deg at sunset).

Pure stdlib: math, datetime, zoneinfo. No host capabilities required.
"""

import math
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo


GRID_AZIMUTH_DEG = 298.9       # Manhattan cross-streets, sunset side
LOCAL_HORIZON_DEG = 0.7        # Palisades from elevated midtown viewpoint
SOLAR_RADIUS_DEG = 0.265       # mean apparent solar radius

OBS_LAT = 40.7484              # Empire State Building (deg N)
OBS_LON = -73.9857             # Empire State Building (deg E)
LOCAL_TZ = ZoneInfo("America/New_York")


def julian_date(unix_ts):
    return unix_ts / 86400.0 + 2440587.5


def solar_position(unix_ts):
    """Return (right_ascension_deg, declination_deg, gmst_deg) for given UTC."""
    jd = julian_date(unix_ts)
    t = (jd - 2451545.0) / 36525.0

    L0 = math.fmod(280.46646 + 36000.76983 * t + 0.0003032 * t * t, 360.0)
    M = 357.52911 + 35999.05029 * t - 0.0001537 * t * t
    M_rad = math.radians(M)

    C = ((1.914602 - 0.004817 * t - 0.000014 * t * t) * math.sin(M_rad)
         + (0.019993 - 0.000101 * t) * math.sin(2.0 * M_rad)
         + 0.000289 * math.sin(3.0 * M_rad))

    true_long = L0 + C
    omega = 125.04 - 1934.136 * t
    omega_rad = math.radians(omega)
    app_long = true_long - 0.00569 - 0.00478 * math.sin(omega_rad)

    eps0 = (23.0 + 26.0 / 60.0 + 21.448 / 3600.0
            - (46.8150 / 3600.0) * t
            - (0.00059 / 3600.0) * t * t
            + (0.001813 / 3600.0) * t * t * t)
    eps = eps0 + 0.00256 * math.cos(omega_rad)

    eps_rad = math.radians(eps)
    app_long_rad = math.radians(app_long)

    ra = math.degrees(math.atan2(math.cos(eps_rad) * math.sin(app_long_rad),
                                 math.cos(app_long_rad)))
    ra = math.fmod(ra + 360.0, 360.0)
    dec = math.degrees(math.asin(math.sin(eps_rad) * math.sin(app_long_rad)))

    gmst = (280.46061837 + 360.98564736629 * (jd - 2451545.0)
            + 0.000387933 * t * t - (t * t * t) / 38710000.0)
    gmst = math.fmod(math.fmod(gmst, 360.0) + 360.0, 360.0)

    return ra, dec, gmst


def horizontal_coords(unix_ts, lat_deg, lon_deg):
    """Return (azimuth_deg, true_altitude_deg). Azimuth from N, increasing E."""
    ra, dec, gmst = solar_position(unix_ts)
    lst = math.fmod(gmst + lon_deg + 360.0, 360.0)
    H = math.radians(math.fmod(lst - ra + 720.0, 360.0))

    lat = math.radians(lat_deg)
    dec_r = math.radians(dec)

    sin_alt = (math.sin(lat) * math.sin(dec_r)
               + math.cos(lat) * math.cos(dec_r) * math.cos(H))
    alt = math.degrees(math.asin(sin_alt))

    sinA = -math.sin(H) * math.cos(dec_r)
    cosA = math.sin(dec_r) * math.cos(lat) - math.cos(dec_r) * math.sin(lat) * math.cos(H)
    az = math.fmod(math.degrees(math.atan2(sinA, cosA)) + 360.0, 360.0)

    return az, alt


def refraction_bennett(true_alt_deg):
    """Bennett 1982 atmospheric refraction in degrees."""
    h = true_alt_deg + 7.31 / (true_alt_deg + 4.4)
    return (1.0 / math.tan(math.radians(h))) / 60.0


def apparent_altitude(unix_ts, lat_deg, lon_deg):
    az, true_alt = horizontal_coords(unix_ts, lat_deg, lon_deg)
    clamp = true_alt if true_alt > -1.0 else -1.0
    return az, true_alt + refraction_bennett(clamp)


def find_sunset(date_local, target_alt_deg):
    """Bisect for the sunset crossing of `target_alt_deg` (descending)."""
    start_local = datetime(date_local.year, date_local.month, date_local.day,
                           17, 0, 0, tzinfo=LOCAL_TZ)
    end_local = datetime(date_local.year, date_local.month, date_local.day,
                         23, 59, 0, tzinfo=LOCAL_TZ)
    lo = start_local.timestamp()
    hi = end_local.timestamp()

    step = 600.0
    _, alt_prev = apparent_altitude(lo, OBS_LAT, OBS_LON)
    t_prev = lo
    bracket = None
    t = lo + step
    while t <= hi:
        _, alt = apparent_altitude(t, OBS_LAT, OBS_LON)
        if alt_prev > target_alt_deg and alt <= target_alt_deg:
            bracket = (t_prev, t)
            break
        t_prev, alt_prev = t, alt
        t += step

    if bracket is None:
        return None

    a, b = bracket
    for _ in range(50):
        mid = (a + b) / 2.0
        _, alt = apparent_altitude(mid, OBS_LAT, OBS_LON)
        if alt > target_alt_deg:
            a = mid
        else:
            b = mid
        if (b - a) < 0.05:
            break
    return (a + b) / 2.0


def henge_event(target_alt_deg, search_start, search_end):
    best = None
    d = search_start
    while d <= search_end:
        ts = find_sunset(d, target_alt_deg)
        if ts is not None:
            az, _ = apparent_altitude(ts, OBS_LAT, OBS_LON)
            err = az - GRID_AZIMUTH_DEG
            if best is None or abs(err) < abs(best[1]):
                best = (ts, err, d)
        d = d + timedelta(days=1)
    return best


def henge_dates(year, local_horizon_deg=LOCAL_HORIZON_DEG):
    target_half = local_horizon_deg
    target_full = local_horizon_deg + SOLAR_RADIUS_DEG

    pre_start = datetime(year, 5, 15, tzinfo=LOCAL_TZ).date()
    pre_end = datetime(year, 6, 20, tzinfo=LOCAL_TZ).date()
    post_start = datetime(year, 6, 22, tzinfo=LOCAL_TZ).date()
    post_end = datetime(year, 7, 31, tzinfo=LOCAL_TZ).date()

    raw = []
    for label, target in (("half", target_half), ("full", target_full)):
        ev = henge_event(target, pre_start, pre_end)
        if ev is not None:
            raw.append((label, ev[0], ev[1]))
    for label, target in (("full", target_full), ("half", target_half)):
        ev = henge_event(target, post_start, post_end)
        if ev is not None:
            raw.append((label, ev[0], ev[1]))

    raw.sort(key=lambda e: e[1])

    out = []
    for label, ts, err in raw:
        local = datetime.fromtimestamp(ts, LOCAL_TZ)
        az, _ = apparent_altitude(ts, OBS_LAT, OBS_LON)
        out.append((label, local, az, err))
    return out


def format_event(ev):
    label, local, az, err = ev
    sign = "+" if err >= 0 else "-"
    return ("{label:<5} {date}  sunset {time}  az {az:.2f} deg  "
            "(err {sign}{abs_err:.2f} deg)").format(
        label=label,
        date=local.strftime("%a %b %d %Y"),
        time=local.strftime("%H:%M:%S %Z"),
        az=az,
        sign=sign,
        abs_err=abs(err),
    )


def main():
    year = 2026
    print("Manhattanhenge {}".format(year))
    print("  observer: {:.4f} N, {:.4f} W".format(OBS_LAT, -OBS_LON))
    print("  local horizon: {:.2f} deg".format(LOCAL_HORIZON_DEG))
    print("  grid bearing at sunset: {:.2f} deg".format(GRID_AZIMUTH_DEG))
    print("")

    for ev in henge_dates(year):
        print(format_event(ev))

    print("")
    print("sensitivity sweep across local-horizon altitudes:")
    for h in (0.0, 0.4, 0.7, 1.0, 1.3):
        print("")
        print("  LOCAL_HORIZON_DEG = {:.2f}".format(h))
        for ev in henge_dates(year, local_horizon_deg=h):
            print("    " + format_event(ev))


if __name__ == "__main__":
    main()
