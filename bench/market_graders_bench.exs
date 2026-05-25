# Public-market price-math grader benchmark.
#
# Scenario: a market-data system feeds 1000 one-minute bars of a
# single equity to a customer-supplied scoring suite (300 graders).
# Bars cover a full session (pre / regular / post) with mid-session
# regime changes and two trading halts.  Each grader returns
# (value, passed) — the same shape used by the robot grader bench.
#
# Bars are *injected* via the :modules option:
#
#     import market
#     bars = market.fetch()
#
# Correctness: each grader is re-implemented in Elixir against the
# same dataset; the two outputs must match exactly (1e-9 tolerance
# on floats, exact pass/fail).
#
# Run with:  mix run scratch/market_graders_bench.exs

# ─────────────────────────────────────────────────────────────────
#  1. Deterministic bar generator (1000 one-minute bars)
# ─────────────────────────────────────────────────────────────────

defmodule Market do
  @moduledoc false

  # Sessions: pre 0-100, regular 100-900, post 900-1000.  Volatility
  # cycles every ~250 bars to give the bench a non-trivial path
  # (calm → vol burst → calm → vol burst → calm).
  @sessions [
    {0, 100, "pre"},
    {100, 900, "regular"},
    {900, 1000, "post"}
  ]

  # Trading halts at these bar indices (close, spread balloons, volume = 0).
  @halts MapSet.new([347, 612])

  def gen(n) when n == 1000 do
    # Start with a fixed seed price and walk it deterministically.
    {bars, _} =
      Enum.map_reduce(0..(n - 1), 100.0, fn i, prev_close ->
        session = session_for(i)
        regime_sigma = sigma_at(i)
        halted? = MapSet.member?(@halts, i)

        # Per-bar log return derived deterministically from i (no
        # external RNG state required).
        r_close = noise(i, :close_ret) * regime_sigma

        close =
          if halted?,
            do: prev_close,
            else: Float.round(prev_close * :math.exp(r_close), 4)

        # Open ≈ prev close + small overnight-ish jitter (most bars
        # are intra-session so this is small).
        open_jitter = noise(i, :open) * regime_sigma * 0.25

        open =
          if halted?,
            do: prev_close,
            else: Float.round(prev_close * :math.exp(open_jitter), 4)

        # High/low straddle max(open, close) and min(open, close).
        spread_amp = abs(noise(i, :hl)) * regime_sigma * 1.4
        high = Float.round(max(open, close) * (1.0 + spread_amp), 4)
        low = Float.round(min(open, close) * (1.0 - spread_amp), 4)

        volume =
          cond do
            halted? -> 0
            session == "regular" -> trunc(50_000 + 30_000 * abs(noise(i, :vol)))
            true -> trunc(5_000 + 5_000 * abs(noise(i, :vol)))
          end

        vwap =
          if volume == 0,
            do: close,
            else: Float.round((high + low + close) / 3.0, 4)

        spread_bps =
          cond do
            halted? -> Float.round(50.0 + 20.0 * abs(noise(i, :spr)), 3)
            session == "regular" -> Float.round(2.0 + 1.5 * abs(noise(i, :spr)), 3)
            true -> Float.round(8.0 + 6.0 * abs(noise(i, :spr)), 3)
          end

        # Bid/ask quoted around close to match spread_bps.
        half = close * spread_bps / 10_000.0 / 2.0

        bid = Float.round(close - half, 4)
        ask = Float.round(close + half, 4)

        bar = %{
          "bar" => i,
          "t" => Float.round(i * 60.0, 1),
          "session" => session,
          "open" => open,
          "high" => high,
          "low" => low,
          "close" => close,
          "volume" => volume,
          "vwap" => vwap,
          "bid" => bid,
          "ask" => ask,
          "spread_bps" => spread_bps,
          "trades" =>
            cond do
              halted? -> 0
              session == "regular" -> trunc(80 + 40 * abs(noise(i, :tr)))
              true -> trunc(8 + 8 * abs(noise(i, :tr)))
            end,
          "is_halted" => halted?
        }

        {bar, close}
      end)

    bars
  end

  defp session_for(i) do
    Enum.find_value(@sessions, fn {lo, hi, name} ->
      if i >= lo and i < hi, do: name
    end)
  end

  # Volatility schedule: small base + bursts.
  defp sigma_at(i) do
    base = 0.0008
    burst = if rem(div(i, 250), 2) == 1, do: 0.0030, else: 0.0
    base + burst
  end

  # Deterministic noise in (-1, 1) for a given (i, key).
  defp noise(i, key) do
    :erlang.phash2({i, key}) / 2_147_483_647.5 - 1.0
  end
end

bars = Market.gen(1000)
1000 = length(bars)

# ─────────────────────────────────────────────────────────────────
#  2. Customer Python: grader patterns + 300 parameterised calls
# ─────────────────────────────────────────────────────────────────

source = ~S"""
import math
import market

bars = market.fetch()
N = len(bars)


# ----- pattern implementations -----

def min_close_above(thresh):
    m = bars[0]["close"]
    for b in bars:
        c = b["close"]
        if c < m:
            m = c
    return m, m >= thresh


def max_drawdown_below(max_dd_pct):
    peak = bars[0]["close"]
    worst = 0.0
    for b in bars:
        c = b["close"]
        if c > peak:
            peak = c
        dd = (c - peak) / peak
        if dd < worst:
            worst = dd
    pct = -worst * 100.0
    return pct, pct <= max_dd_pct


def realized_vol_below(max_vol_pct):
    s = 0.0
    cnt = 0
    prev = bars[0]["close"]
    log_rets = []
    for i in range(1, N):
        c = bars[i]["close"]
        r = math.log(c / prev)
        log_rets.append(r)
        s += r
        cnt += 1
        prev = c
    m = s / cnt
    var = 0.0
    for r in log_rets:
        d = r - m
        var += d * d
    var /= cnt
    sd = var ** 0.5
    annual_pct = sd * (252.0 * 390.0) ** 0.5 * 100.0
    return annual_pct, annual_pct <= max_vol_pct


def mean_log_return_in_range(lo_bps, hi_bps):
    s = 0.0
    cnt = 0
    prev = bars[0]["close"]
    for i in range(1, N):
        c = bars[i]["close"]
        s += math.log(c / prev)
        cnt += 1
        prev = c
    mean_bps = (s / cnt) * 10_000.0
    return mean_bps, (lo_bps <= mean_bps <= hi_bps)


def spread_p_below(p, max_bps):
    vals = sorted(b["spread_bps"] for b in bars)
    idx = int((p / 100.0) * (len(vals) - 1))
    v = vals[idx]
    return v, v <= max_bps


def vwap_diverge_max_below(max_pct):
    worst = 0.0
    for b in bars:
        if b["is_halted"]:
            continue
        diff = abs(b["close"] - b["vwap"]) / b["vwap"] * 100.0
        if diff > worst:
            worst = diff
    return worst, worst <= max_pct


def sma_crossover_count_eq(fast, slow, expected):
    # Count fast-over-slow crossovers (golden-cross style).
    closes = [b["close"] for b in bars]
    crossovers = 0
    prev_above = None
    for i in range(slow - 1, N):
        fast_sum = 0.0
        for j in range(i - fast + 1, i + 1):
            fast_sum += closes[j]
        slow_sum = 0.0
        for j in range(i - slow + 1, i + 1):
            slow_sum += closes[j]
        fast_avg = fast_sum / fast
        slow_avg = slow_sum / slow
        above = fast_avg > slow_avg
        if prev_above is not None and above != prev_above:
            crossovers += 1
        prev_above = above
    return crossovers, crossovers == expected


def bars_above_sma_share(window, min_share):
    closes = [b["close"] for b in bars]
    above = 0
    counted = 0
    for i in range(window - 1, N):
        s = 0.0
        for j in range(i - window + 1, i + 1):
            s += closes[j]
        avg = s / window
        if closes[i] > avg:
            above += 1
        counted += 1
    share = above / counted
    return share, share >= min_share


def consecutive_red_below(max_streak):
    best = 0
    cur = 0
    for b in bars:
        if b["close"] < b["open"]:
            cur += 1
            if cur > best:
                best = cur
        else:
            cur = 0
    return best, best <= max_streak


def volume_zscore_max_below(window, max_z):
    vols = [b["volume"] for b in bars]
    worst = 0.0
    for i in range(window, N):
        s = 0.0
        for j in range(i - window, i):
            s += vols[j]
        m = s / window
        var = 0.0
        for j in range(i - window, i):
            d = vols[j] - m
            var += d * d
        var /= window
        sd = var ** 0.5
        if sd > 0:
            z = (vols[i] - m) / sd
            if z > worst:
                worst = z
    return worst, worst <= max_z


def session_volume_share_above(session, min_share):
    in_sess = 0
    total = 0
    for b in bars:
        v = b["volume"]
        total += v
        if b["session"] == session:
            in_sess += v
    if total == 0:
        share = 0.0
    else:
        share = in_sess / total
    return share, share >= min_share


def gap_count_below(min_gap_bps, max_count):
    cnt = 0
    prev = bars[0]["close"]
    for i in range(1, N):
        c = bars[i]["close"]
        gap_bps = abs(c - prev) / prev * 10_000.0
        if gap_bps >= min_gap_bps:
            cnt += 1
        prev = c
    return cnt, cnt <= max_count


# ----- 300-grader sweep -----

graders = []

# 1. min close above ladder (12)
for t in [60.0, 70.0, 80.0, 85.0, 88.0, 90.0, 92.0, 94.0, 96.0, 98.0, 99.0, 100.0]:
    graders.append(("min_close_above_%s" % t, min_close_above(t)))

# 2. max drawdown below ladder (12)
for t in [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 7.0, 10.0, 15.0, 25.0]:
    graders.append(("max_dd_below_%s" % t, max_drawdown_below(t)))

# 3. realized vol below ladder (12)
for t in [20.0, 25.0, 30.0, 35.0, 40.0, 50.0, 60.0, 75.0, 100.0, 125.0, 150.0, 200.0]:
    graders.append(("rvol_below_%s" % t, realized_vol_below(t)))

# 4. mean log return in range (10)
for lo, hi in [(-2.0, 2.0), (-1.0, 1.0), (-0.5, 0.5), (-2.0, 0.0), (0.0, 2.0),
               (-1.5, 1.5), (-0.25, 0.25), (-3.0, 3.0), (-0.1, 0.1), (-5.0, 5.0)]:
    graders.append(("ret_mean_in_%s_%s" % (lo, hi),
                    mean_log_return_in_range(lo, hi)))

# 5. spread percentile below (5 percentiles × 5 thresholds = 25)
for p in [50, 75, 90, 95, 99]:
    for t in [2.0, 3.0, 5.0, 10.0, 50.0]:
        graders.append(("spread_p%s_below_%s" % (p, t),
                        spread_p_below(p, t)))

# 6. vwap divergence max below (12)
for t in [0.05, 0.1, 0.2, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 7.5, 10.0, 20.0]:
    graders.append(("vwap_div_max_below_%s" % t, vwap_diverge_max_below(t)))

# 7. SMA crossover counts (4 pairs × 4 expected = 16)
for fast, slow in [(5, 20), (10, 30), (20, 50), (5, 50)]:
    for expected in [0, 5, 15, 50]:
        graders.append(("sma_cross_%s_%s_eq_%s" % (fast, slow, expected),
                        sma_crossover_count_eq(fast, slow, expected)))

# 8. bars-above-SMA share (4 windows × 5 thresholds = 20)
for window in [5, 20, 50, 100]:
    for share in [0.3, 0.4, 0.5, 0.6, 0.7]:
        graders.append(("bars_above_sma%s_ge_%s" % (window, share),
                        bars_above_sma_share(window, share)))

# 9. consecutive red bars below (12)
for t in [3, 5, 7, 10, 15, 20, 25, 30, 40, 50, 75, 100]:
    graders.append(("cons_red_le_%s" % t, consecutive_red_below(t)))

# 10. volume z-score max below (4 windows × 5 thresholds = 20)
for window in [10, 30, 60, 120]:
    for z in [2.0, 3.0, 4.0, 6.0, 10.0]:
        graders.append(("vol_z_max_w%s_le_%s" % (window, z),
                        volume_zscore_max_below(window, z)))

# 11. session volume share above (3 sessions × 5 thresholds = 15)
for session in ["pre", "regular", "post"]:
    for share in [0.0, 0.05, 0.20, 0.50, 0.80]:
        graders.append(("vol_share_%s_ge_%s" % (session, share),
                        session_volume_share_above(session, share)))

# 12. gap count below (5 gap thresholds × 6 count thresholds = 30)
for gap_bps in [25.0, 50.0, 100.0, 200.0, 500.0]:
    for max_cnt in [0, 5, 10, 25, 50, 100]:
        graders.append(("gap_ge_%s_le_%s" % (gap_bps, max_cnt),
                        gap_count_below(gap_bps, max_cnt)))

# Top up to exactly 300 — these are deliberately broad to fill the
# parameter sweep without duplicating shapes already covered above.
# Total so far = 12+12+12+10+25+12+16+20+12+20+15+30 = 196; need 104.

# 13. min close above more granular ladder (40 thresholds)
for t in [50.0 + 1.25 * k for k in range(40)]:
    graders.append(("min_close_fine_%s" % t, min_close_above(t)))

# 14. max drawdown finer ladder (32)
for t in [0.10 + 0.10 * k for k in range(32)]:
    graders.append(("max_dd_fine_%s" % round(t, 4),
                    max_drawdown_below(round(t, 4))))

# 15. mean log return tighter ranges (16)
for half in [0.01, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0,
             1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 7.5]:
    graders.append(("ret_mean_pm_%s" % half,
                    mean_log_return_in_range(-half, half)))

# 16. consecutive red wider sweep (16)
for t in [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 256, 512]:
    graders.append(("cons_red_sweep_%s" % t, consecutive_red_below(t)))

flat = []

for entry in graders:
    nm = entry[0]
    pair = entry[1]
    flat.append((nm, pair[0], pair[1]))

result = {
    "n_graders": len(graders),
    "n_bars": N,
    "results": flat,
}
result
"""

# ─────────────────────────────────────────────────────────────────
#  3. Inject bars as a module — Python calls market.fetch()
# ─────────────────────────────────────────────────────────────────

modules = %{
  "market" => %{
    "fetch" => {:builtin, fn [] -> bars end}
  }
}

# ─────────────────────────────────────────────────────────────────
#  4. Elixir oracle — re-implement each grader exactly, compute
#     expected scores in the same order, and compare to Pyex.
# ─────────────────────────────────────────────────────────────────

defmodule MarketOracle do
  @moduledoc false

  def min_close_above(bars, thresh) do
    m = bars |> Enum.map(& &1["close"]) |> Enum.min()
    {m, m >= thresh}
  end

  def max_drawdown_below(bars, max_dd) do
    [first | _] = bars

    {_peak, worst} =
      Enum.reduce(bars, {first["close"], 0.0}, fn b, {peak, worst} ->
        c = b["close"]
        peak = if c > peak, do: c, else: peak
        dd = (c - peak) / peak
        worst = if dd < worst, do: dd, else: worst
        {peak, worst}
      end)

    pct = -worst * 100.0
    {pct, pct <= max_dd}
  end

  def realized_vol_below(bars, max_vol) do
    closes = Enum.map(bars, & &1["close"])
    {log_rets, _} =
      closes
      |> tl()
      |> Enum.map_reduce(hd(closes), fn c, prev ->
        {:math.log(c / prev), c}
      end)

    n = length(log_rets)
    mean = Enum.sum(log_rets) / n
    var = Enum.reduce(log_rets, 0.0, fn r, acc -> acc + (r - mean) * (r - mean) end) / n
    sd = :math.sqrt(var)
    annual_pct = sd * :math.sqrt(252.0 * 390.0) * 100.0
    {annual_pct, annual_pct <= max_vol}
  end

  def mean_log_return_in_range(bars, lo, hi) do
    closes = Enum.map(bars, & &1["close"])
    {log_rets, _} =
      closes
      |> tl()
      |> Enum.map_reduce(hd(closes), fn c, prev ->
        {:math.log(c / prev), c}
      end)

    n = length(log_rets)
    mean_bps = Enum.sum(log_rets) / n * 10_000.0
    {mean_bps, lo <= mean_bps and mean_bps <= hi}
  end

  def spread_p_below(bars, p, max_bps) do
    vals = bars |> Enum.map(& &1["spread_bps"]) |> Enum.sort()
    idx = trunc(p / 100.0 * (length(vals) - 1))
    v = Enum.at(vals, idx)
    {v, v <= max_bps}
  end

  def vwap_diverge_max_below(bars, max_pct) do
    worst =
      Enum.reduce(bars, 0.0, fn b, worst ->
        if b["is_halted"] do
          worst
        else
          diff = abs(b["close"] - b["vwap"]) / b["vwap"] * 100.0
          if diff > worst, do: diff, else: worst
        end
      end)

    {worst, worst <= max_pct}
  end

  def sma_crossover_count_eq(bars, fast, slow, expected) do
    closes = Enum.map(bars, & &1["close"]) |> List.to_tuple()
    n = tuple_size(closes)

    {crossovers, _prev_above} =
      Enum.reduce((slow - 1)..(n - 1)//1, {0, nil}, fn i, {cnt, prev_above} ->
        fast_sum =
          Enum.reduce((i - fast + 1)..i, 0.0, fn j, acc -> acc + elem(closes, j) end)

        slow_sum =
          Enum.reduce((i - slow + 1)..i, 0.0, fn j, acc -> acc + elem(closes, j) end)

        fast_avg = fast_sum / fast
        slow_avg = slow_sum / slow
        above = fast_avg > slow_avg

        cnt =
          if prev_above != nil and above != prev_above,
            do: cnt + 1,
            else: cnt

        {cnt, above}
      end)

    {crossovers, crossovers == expected}
  end

  def bars_above_sma_share(bars, window, min_share) do
    closes = Enum.map(bars, & &1["close"]) |> List.to_tuple()
    n = tuple_size(closes)

    {above, counted} =
      Enum.reduce((window - 1)..(n - 1)//1, {0, 0}, fn i, {above, counted} ->
        s = Enum.reduce((i - window + 1)..i, 0.0, fn j, acc -> acc + elem(closes, j) end)
        avg = s / window
        above = if elem(closes, i) > avg, do: above + 1, else: above
        {above, counted + 1}
      end)

    share = above / counted
    {share, share >= min_share}
  end

  def consecutive_red_below(bars, max_streak) do
    {_, best} =
      Enum.reduce(bars, {0, 0}, fn b, {cur, best} ->
        if b["close"] < b["open"] do
          c = cur + 1
          {c, max(best, c)}
        else
          {0, best}
        end
      end)

    {best, best <= max_streak}
  end

  def volume_zscore_max_below(bars, window, max_z) do
    vols = Enum.map(bars, & &1["volume"]) |> List.to_tuple()
    n = tuple_size(vols)

    worst =
      Enum.reduce(window..(n - 1)//1, 0.0, fn i, worst ->
        s =
          Enum.reduce((i - window)..(i - 1), 0.0, fn j, acc -> acc + elem(vols, j) end)

        m = s / window

        var =
          Enum.reduce((i - window)..(i - 1), 0.0, fn j, acc ->
            d = elem(vols, j) - m
            acc + d * d
          end) / window

        sd = :math.sqrt(var)

        if sd > 0 do
          z = (elem(vols, i) - m) / sd
          if z > worst, do: z, else: worst
        else
          worst
        end
      end)

    {worst, worst <= max_z}
  end

  def session_volume_share_above(bars, session, min_share) do
    {in_sess, total} =
      Enum.reduce(bars, {0, 0}, fn b, {in_sess, total} ->
        v = b["volume"]
        in_sess = if b["session"] == session, do: in_sess + v, else: in_sess
        {in_sess, total + v}
      end)

    share = if total == 0, do: 0.0, else: in_sess / total
    {share, share >= min_share}
  end

  def gap_count_below(bars, min_gap_bps, max_count) do
    closes = Enum.map(bars, & &1["close"])

    {_, cnt} =
      closes
      |> tl()
      |> Enum.reduce({hd(closes), 0}, fn c, {prev, cnt} ->
        gap_bps = abs(c - prev) / prev * 10_000.0
        cnt = if gap_bps >= min_gap_bps, do: cnt + 1, else: cnt
        {c, cnt}
      end)

    {cnt, cnt <= max_count}
  end

  # Build the same 300-element grader list the Python script does,
  # in the same order — exact one-to-one for index comparison.
  def expected(bars) do
    rows = []

    rows =
      rows ++
        for t <- [60.0, 70.0, 80.0, 85.0, 88.0, 90.0, 92.0, 94.0, 96.0, 98.0, 99.0, 100.0] do
          {v, p} = min_close_above(bars, t)
          {"min_close_above_#{t}", v, p}
        end

    rows =
      rows ++
        for t <- [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 7.0, 10.0, 15.0, 25.0] do
          {v, p} = max_drawdown_below(bars, t)
          {"max_dd_below_#{t}", v, p}
        end

    rows =
      rows ++
        for t <- [20.0, 25.0, 30.0, 35.0, 40.0, 50.0, 60.0, 75.0, 100.0, 125.0, 150.0, 200.0] do
          {v, p} = realized_vol_below(bars, t)
          {"rvol_below_#{t}", v, p}
        end

    rows =
      rows ++
        for {lo, hi} <- [
              {-2.0, 2.0},
              {-1.0, 1.0},
              {-0.5, 0.5},
              {-2.0, 0.0},
              {0.0, 2.0},
              {-1.5, 1.5},
              {-0.25, 0.25},
              {-3.0, 3.0},
              {-0.1, 0.1},
              {-5.0, 5.0}
            ] do
          {v, p} = mean_log_return_in_range(bars, lo, hi)
          {"ret_mean_in_#{lo}_#{hi}", v, p}
        end

    rows =
      rows ++
        for p <- [50, 75, 90, 95, 99],
            t <- [2.0, 3.0, 5.0, 10.0, 50.0] do
          {v, passed} = spread_p_below(bars, p, t)
          {"spread_p#{p}_below_#{t}", v, passed}
        end

    rows =
      rows ++
        for t <- [0.05, 0.1, 0.2, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 7.5, 10.0, 20.0] do
          {v, p} = vwap_diverge_max_below(bars, t)
          {"vwap_div_max_below_#{t}", v, p}
        end

    rows =
      rows ++
        for {fast, slow} <- [{5, 20}, {10, 30}, {20, 50}, {5, 50}],
            expected <- [0, 5, 15, 50] do
          {v, p} = sma_crossover_count_eq(bars, fast, slow, expected)
          {"sma_cross_#{fast}_#{slow}_eq_#{expected}", v, p}
        end

    rows =
      rows ++
        for window <- [5, 20, 50, 100],
            share <- [0.3, 0.4, 0.5, 0.6, 0.7] do
          {v, p} = bars_above_sma_share(bars, window, share)
          {"bars_above_sma#{window}_ge_#{share}", v, p}
        end

    rows =
      rows ++
        for t <- [3, 5, 7, 10, 15, 20, 25, 30, 40, 50, 75, 100] do
          {v, p} = consecutive_red_below(bars, t)
          {"cons_red_le_#{t}", v, p}
        end

    rows =
      rows ++
        for window <- [10, 30, 60, 120],
            z <- [2.0, 3.0, 4.0, 6.0, 10.0] do
          {v, p} = volume_zscore_max_below(bars, window, z)
          {"vol_z_max_w#{window}_le_#{z}", v, p}
        end

    rows =
      rows ++
        for session <- ["pre", "regular", "post"],
            share <- [0.0, 0.05, 0.20, 0.50, 0.80] do
          {v, p} = session_volume_share_above(bars, session, share)
          {"vol_share_#{session}_ge_#{share}", v, p}
        end

    rows =
      rows ++
        for gap_bps <- [25.0, 50.0, 100.0, 200.0, 500.0],
            max_cnt <- [0, 5, 10, 25, 50, 100] do
          {v, p} = gap_count_below(bars, gap_bps, max_cnt)
          {"gap_ge_#{gap_bps}_le_#{max_cnt}", v, p}
        end

    rows =
      rows ++
        for k <- 0..39 do
          t = 50.0 + 1.25 * k
          {v, p} = min_close_above(bars, t)
          {"min_close_fine_#{t}", v, p}
        end

    rows =
      rows ++
        for k <- 0..31 do
          t = Float.round(0.10 + 0.10 * k, 4)
          {v, p} = max_drawdown_below(bars, t)
          {"max_dd_fine_#{t}", v, p}
        end

    rows =
      rows ++
        for half <- [
              0.01,
              0.05,
              0.1,
              0.2,
              0.3,
              0.5,
              0.75,
              1.0,
              1.25,
              1.5,
              2.0,
              2.5,
              3.0,
              4.0,
              5.0,
              7.5
            ] do
          {v, p} = mean_log_return_in_range(bars, -half, half)
          {"ret_mean_pm_#{half}", v, p}
        end

    rows =
      rows ++
        for t <- [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 256, 512] do
          {v, p} = consecutive_red_below(bars, t)
          {"cons_red_sweep_#{t}", v, p}
        end

    rows
  end
end

# ─────────────────────────────────────────────────────────────────
#  5. Correctness check — single run, row-by-row vs oracle
# ─────────────────────────────────────────────────────────────────

IO.puts(String.duplicate("=", 70))
IO.puts("Market grader benchmark — 300 graders × 1000 bars")
IO.puts(String.duplicate("=", 70))
IO.puts("")
IO.puts("Source: #{byte_size(source)} bytes")
IO.puts("Bars: #{length(bars)}")
IO.puts("")

{:ok, ast} = Pyex.compile(source)

{:ok, result, _ctx} = Pyex.run(ast, modules: modules)

300 = result["n_graders"]
1000 = result["n_bars"]

unwrap = fn
  {:tuple, [name, value, passed]} -> {name, value, passed}
  [name, value, passed] -> {name, value, passed}
end

got_rows = Enum.map(result["results"], unwrap)
expected_rows = MarketOracle.expected(bars)

{matches, mismatches} =
  Enum.zip(expected_rows, got_rows)
  |> Enum.reduce({0, []}, fn {{ename, evalue, epass}, {gname, gvalue, gpass}}, {ok, bad} ->
    name_ok = ename == gname
    pass_ok = epass == gpass

    value_ok =
      cond do
        is_number(evalue) and is_number(gvalue) ->
          diff = abs(evalue - gvalue)
          diff <= 1.0e-9 or diff <= 1.0e-9 * max(abs(evalue), abs(gvalue))

        true ->
          evalue == gvalue
      end

    if name_ok and pass_ok and value_ok do
      {ok + 1, bad}
    else
      {ok,
       [
         %{
           name_expected: ename,
           name_got: gname,
           value_expected: evalue,
           value_got: gvalue,
           pass_expected: epass,
           pass_got: gpass
         }
         | bad
       ]}
    end
  end)

IO.puts("--- Correctness ---")
IO.puts("  matched:   #{matches} / 300")
IO.puts("  mismatched: #{length(mismatches)}")

if mismatches != [] do
  IO.puts("")
  IO.puts("First few mismatches:")

  for m <- Enum.take(mismatches, 5) do
    IO.inspect(m, label: "  mismatch")
  end

  System.halt(1)
end

passed_count = Enum.count(got_rows, fn {_, _, p} -> p end)
IO.puts("  graders passing:  #{passed_count} / 300")
IO.puts("")

# ─────────────────────────────────────────────────────────────────
#  6. Timing — phase breakdown, warm sequential, parallel scaling
# ─────────────────────────────────────────────────────────────────

IO.puts("--- Phase breakdown (single run) ---")
{compile_us, {:ok, _}} = :timer.tc(fn -> Pyex.compile(source) end)
{cold_us, {:ok, _, _}} = :timer.tc(fn -> Pyex.run(source, modules: modules) end)
{warm_us, {:ok, _, _}} = :timer.tc(fn -> Pyex.run(ast, modules: modules) end)

IO.puts("  compile (lex+parse): #{Float.round(compile_us / 1000, 2)} ms")
IO.puts("  cold (source→result): #{Float.round(cold_us / 1000, 2)} ms")
IO.puts("  warm (AST→result):    #{Float.round(warm_us / 1000, 2)} ms")
IO.puts("")

# Warmup
for _ <- 1..3, do: Pyex.run!(ast, modules: modules)

iters = 10

samples_us =
  for _ <- 1..iters do
    {us, {:ok, _, _}} = :timer.tc(fn -> Pyex.run(ast, modules: modules) end)
    us
  end

mean = Enum.sum(samples_us) / iters
min_us = Enum.min(samples_us)
max_us = Enum.max(samples_us)
sorted = Enum.sort(samples_us)
p50 = Enum.at(sorted, div(iters, 2))
p95 = Enum.at(sorted, min(iters - 1, trunc(iters * 0.95)))

IO.puts("--- Sequential timing (#{iters} warm iterations) ---")
IO.puts("  mean: #{Float.round(mean / 1000, 2)} ms")
IO.puts("  min:  #{Float.round(min_us / 1000, 2)} ms")
IO.puts("  p50:  #{Float.round(p50 / 1000, 2)} ms")
IO.puts("  p95:  #{Float.round(p95 / 1000, 2)} ms")
IO.puts("  max:  #{Float.round(max_us / 1000, 2)} ms")

per_grader_us = mean / 300
IO.puts("")
IO.puts("  per grader (mean):              #{Float.round(per_grader_us, 2)} µs")
IO.puts("")

parallel_n = 8

{par_us, par_results} =
  :timer.tc(fn ->
    1..parallel_n
    |> Task.async_stream(
      fn _ -> Pyex.run!(ast, modules: modules) end,
      max_concurrency: parallel_n,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, r} -> r end)
  end)

parallel_n = length(par_results)

IO.puts("--- Parallel timing (#{parallel_n} concurrent suites) ---")
IO.puts("  wall: #{Float.round(par_us / 1000, 2)} ms")

IO.puts(
  "  speedup over sequential: #{Float.round(mean * parallel_n / par_us, 2)}× (ideal = #{parallel_n}×)"
)

IO.puts("")
IO.puts(String.duplicate("=", 70))
