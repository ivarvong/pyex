# Robot systems-checkout grader benchmark.
#
# Scenario: a robot emits 1000 telemetry samples (one per ~100 ms of
# mission time).  Customer-provided Python defines a handful of
# generic grader patterns and then runs 300 parameterised grader
# calls — exactly the shape of a real systems-checkout suite where
# many similar thresholds and statistics are evaluated against the
# same run.
#
# Telemetry is *injected* via the :modules option:
#
#     import telemetry
#     samples = telemetry.fetch()
#
# Correctness: every grader's result is also computed in Elixir
# from the same dataset, and the two must match exactly.
#
# Run with:  mix run scratch/robot_graders_bench.exs

# ─────────────────────────────────────────────────────────────────
#  1. Deterministic telemetry generator (1000 samples)
# ─────────────────────────────────────────────────────────────────

defmodule Telemetry do
  @moduledoc false

  # Mission phases: drive a state machine deterministically so the
  # dataset has realistic shape (init → idle → navigate ⇄ manipulate
  # → idle).  Values are derived from the sample index with phash2
  # so the data is reproducible without RNG state plumbing.

  @phases [
    {0, 50, "init"},
    {50, 150, "idle"},
    {150, 550, "navigate"},
    {550, 750, "manipulate"},
    {750, 900, "navigate"},
    {900, 1000, "idle"}
  ]

  def gen(n) when n == 1000 do
    for i <- 0..(n - 1) do
      mode = mode_for(i)
      noise = noise(i)

      %{
        "t" => Float.round(i * 0.1, 3),
        "mode" => mode,
        # Battery declines linearly from 28.0 V to ~22.5 V across the run
        # with small bounded jitter.  Always strictly decreasing in
        # expectation, with small per-tick noise.
        "battery_v" => Float.round(28.0 - i * 0.0055 + 0.02 * noise.(:b), 4),
        # Motor temp ramps up during navigate/manipulate
        "motor_temp_c" =>
          Float.round(
            22.0 +
              case mode do
                "navigate" -> 25.0 + 5.0 * noise.(:t1)
                "manipulate" -> 35.0 + 8.0 * noise.(:t1)
                _ -> 2.0 * noise.(:t1)
              end,
            3
          ),
        "vel_x" =>
          Float.round(
            case mode do
              "navigate" -> 0.40 + 0.05 * noise.(:vx)
              "manipulate" -> 0.0 + 0.01 * noise.(:vx)
              _ -> 0.0
            end,
            4
          ),
        "vel_y" =>
          Float.round(
            case mode do
              "navigate" -> 0.05 * noise.(:vy)
              _ -> 0.0
            end,
            4
          ),
        "gyro_z" => Float.round(0.02 * noise.(:gz), 4),
        # error_code 0 = nominal; inject ~5 transient faults
        "error_code" =>
          cond do
            i in [212, 387, 488, 661, 802] -> 17
            true -> 0
          end,
        "grip_force_n" =>
          Float.round(
            case mode do
              "manipulate" -> 12.0 + 2.0 * noise.(:gf)
              _ -> 0.0
            end,
            3
          ),
        "obstacles_detected" =>
          case mode do
            "navigate" -> if rem(:erlang.phash2({i, :obs}), 11) == 0, do: 1, else: 0
            _ -> 0
          end
      }
    end
  end

  defp mode_for(i) do
    Enum.find_value(@phases, fn {lo, hi, name} ->
      if i >= lo and i < hi, do: name
    end)
  end

  # Deterministic noise in [-1.0, 1.0] derived from (i, key).
  defp noise(i) do
    fn key ->
      :erlang.phash2({i, key}) / 2_147_483_647.5 - 1.0
    end
  end
end

samples = Telemetry.gen(1000)
1000 = length(samples)

# ─────────────────────────────────────────────────────────────────
#  2. Customer Python: grader patterns + 300 parameterised calls
# ─────────────────────────────────────────────────────────────────
#
# Eleven distinct grader patterns covering the things real checkout
# suites care about: thresholds, statistics, mode-aware aggregates,
# event counting, and frame-to-frame deltas.  The driver below
# expands each pattern across a parameter sweep until we have 300
# total calls, then collects (name, score, passed) tuples.

source = ~S"""
import telemetry

samples = telemetry.fetch()
N = len(samples)


# ----- pattern implementations -----

def min_above(key, thresh):
    m = min(s[key] for s in samples)
    return m, m >= thresh


def max_below(key, thresh):
    m = max(s[key] for s in samples)
    return m, m <= thresh


def mean_in_range(key, lo, hi):
    total = 0.0
    for s in samples:
        total += s[key]
    mean = total / N
    return mean, (lo <= mean <= hi)


def fraction_in_mode(mode, max_frac):
    c = 0
    for s in samples:
        if s["mode"] == mode:
            c += 1
    frac = c / N
    return frac, frac <= max_frac


def fraction_in_mode_at_least(mode, min_frac):
    c = 0
    for s in samples:
        if s["mode"] == mode:
            c += 1
    frac = c / N
    return frac, frac >= min_frac


def no_errors():
    c = 0
    for s in samples:
        if s["error_code"] != 0:
            c += 1
    return c, c == 0


def errors_below(max_count):
    c = 0
    for s in samples:
        if s["error_code"] != 0:
            c += 1
    return c, c <= max_count


def longest_run_in_mode_below(mode, max_len):
    best = 0
    cur = 0
    for s in samples:
        if s["mode"] == mode:
            cur += 1
            if cur > best:
                best = cur
        else:
            cur = 0
    return best, best <= max_len


def transitions_eq(mode_a, mode_b, expected):
    c = 0
    prev = None
    for s in samples:
        m = s["mode"]
        if prev == mode_a and m == mode_b:
            c += 1
        prev = m
    return c, c == expected


def max_delta_below(key, max_delta):
    prev = None
    worst = 0.0
    for s in samples:
        v = s[key]
        if prev is not None:
            d = v - prev
            if d < 0:
                d = -d
            if d > worst:
                worst = d
        prev = v
    return worst, worst <= max_delta


def percentile_below(key, p, thresh):
    # p in [0, 100]
    vals = sorted(s[key] for s in samples)
    # nearest-rank
    idx = int((p / 100.0) * (len(vals) - 1))
    v = vals[idx]
    return v, v <= thresh


def mode_specific_max_below(mode, key, thresh):
    worst = None
    for s in samples:
        if s["mode"] == mode:
            v = s[key]
            if worst is None or v > worst:
                worst = v
    if worst is None:
        worst = 0.0
    return worst, worst <= thresh


# ----- 300-grader sweep -----

graders = []

# 1. battery min above N volts  (12 values)
for thresh in [22.0, 22.2, 22.4, 22.5, 22.6, 22.8, 23.0, 23.2, 23.4, 23.6, 23.8, 24.0]:
    graders.append(("battery_min_above_%s" % thresh, min_above("battery_v", thresh)))

# 2. motor temp max below N C  (12 values)
for thresh in [40.0, 45.0, 50.0, 55.0, 60.0, 62.0, 64.0, 66.0, 68.0, 70.0, 75.0, 80.0]:
    graders.append(("motor_temp_max_below_%s" % thresh, max_below("motor_temp_c", thresh)))

# 3. vel_x mean in range  (10 values)
for lo, hi in [(-0.1, 0.5), (-0.05, 0.5), (0.0, 0.5),
               (-0.1, 0.4), (-0.05, 0.4), (0.0, 0.4),
               (-0.1, 0.3), (-0.05, 0.3), (0.0, 0.3),
               (0.1, 0.3)]:
    graders.append(("vel_x_mean_in_%s_%s" % (lo, hi), mean_in_range("vel_x", lo, hi)))

# 4. fraction in fault/idle/etc bounded above  (5 modes × 4 thresholds = 20)
for mode in ["init", "idle", "navigate", "manipulate", "fault"]:
    for thresh in [0.10, 0.50, 0.80, 1.00]:
        graders.append(("frac_%s_le_%s" % (mode, thresh),
                        fraction_in_mode(mode, thresh)))

# 5. fraction in mode at least  (5 modes × 4 thresholds = 20)
for mode in ["init", "idle", "navigate", "manipulate", "fault"]:
    for thresh in [0.00, 0.05, 0.10, 0.20]:
        graders.append(("frac_%s_ge_%s" % (mode, thresh),
                        fraction_in_mode_at_least(mode, thresh)))

# 6. error counts  (10 thresholds)
for thresh in [0, 1, 2, 3, 5, 7, 10, 15, 20, 50]:
    graders.append(("errors_le_%s" % thresh, errors_below(thresh)))

# 7. no_errors flag  (1)
graders.append(("no_errors", no_errors()))

# 8. longest run in mode bounded  (5 modes × 6 thresholds = 30)
for mode in ["init", "idle", "navigate", "manipulate", "fault"]:
    for thresh in [50, 100, 150, 200, 400, 800]:
        graders.append(("longest_%s_le_%s" % (mode, thresh),
                        longest_run_in_mode_below(mode, thresh)))

# 9. transitions A→B equal expected  (combinations × expected counts)
trans_cases = [
    ("init", "idle", 1),
    ("idle", "navigate", 1),
    ("navigate", "manipulate", 1),
    ("manipulate", "navigate", 1),
    ("navigate", "idle", 1),
    ("idle", "init", 0),
    ("idle", "manipulate", 0),
    ("manipulate", "idle", 0),
    ("init", "navigate", 0),
    ("navigate", "fault", 0),
]
for a, b, n in trans_cases:
    graders.append(("trans_%s_to_%s_eq_%s" % (a, b, n), transitions_eq(a, b, n)))

# 10. max frame-to-frame delta below  (5 keys × 8 thresholds = 40)
for key in ["battery_v", "motor_temp_c", "vel_x", "gyro_z", "grip_force_n"]:
    for thresh in [0.01, 0.05, 0.1, 0.5, 1.0, 2.5, 5.0, 10.0]:
        graders.append(("delta_%s_le_%s" % (key, thresh),
                        max_delta_below(key, thresh)))

# 11. percentile below  (5 keys × 5 percentiles × 3 thresholds = 75)
for key, thresholds in [
    ("battery_v", [23.0, 24.0, 25.0]),
    ("motor_temp_c", [40.0, 50.0, 60.0]),
    ("vel_x", [0.1, 0.3, 0.5]),
    ("gyro_z", [0.01, 0.02, 0.05]),
    ("grip_force_n", [0.5, 10.0, 15.0]),
]:
    for p in [50, 75, 90, 95, 99]:
        for thresh in thresholds:
            graders.append(("p%s_%s_le_%s" % (p, key, thresh),
                            percentile_below(key, p, thresh)))

# 12. mode-specific max bounded  (4 modes × 3 keys × 5 thresholds = 60)
for mode in ["navigate", "manipulate", "idle", "init"]:
    for key in ["motor_temp_c", "gyro_z", "vel_x"]:
        for thresh in [40.0, 50.0, 60.0, 70.0, 80.0]:
            graders.append(("max_%s_in_%s_le_%s" % (key, mode, thresh),
                            mode_specific_max_below(mode, key, thresh)))

flat = []
for entry in graders:
    nm = entry[0]
    pair = entry[1]
    flat.append((nm, pair[0], pair[1]))

result = {
    "n_graders": len(graders),
    "n_samples": N,
    "results": flat,
}
result
"""

# ─────────────────────────────────────────────────────────────────
#  3. Inject telemetry as a module — Python calls telemetry.fetch()
# ─────────────────────────────────────────────────────────────────

modules = %{
  "telemetry" => %{
    "fetch" => {:builtin, fn [] -> samples end}
  }
}

# ─────────────────────────────────────────────────────────────────
#  4. Elixir oracle: re-implement each grader, compute expected
#     scores, and compare to the Pyex output exactly.
# ─────────────────────────────────────────────────────────────────

defmodule Oracle do
  @moduledoc false

  def min_above(samples, key, thresh) do
    m = samples |> Enum.map(& &1[key]) |> Enum.min()
    {m, m >= thresh}
  end

  def max_below(samples, key, thresh) do
    m = samples |> Enum.map(& &1[key]) |> Enum.max()
    {m, m <= thresh}
  end

  def mean_in_range(samples, key, lo, hi) do
    n = length(samples)
    mean = (samples |> Enum.map(& &1[key]) |> Enum.sum()) / n
    {mean, lo <= mean and mean <= hi}
  end

  def fraction_in_mode(samples, mode, max_frac) do
    c = Enum.count(samples, &(&1["mode"] == mode))
    frac = c / length(samples)
    {frac, frac <= max_frac}
  end

  def fraction_in_mode_at_least(samples, mode, min_frac) do
    c = Enum.count(samples, &(&1["mode"] == mode))
    frac = c / length(samples)
    {frac, frac >= min_frac}
  end

  def no_errors(samples) do
    c = Enum.count(samples, &(&1["error_code"] != 0))
    {c, c == 0}
  end

  def errors_below(samples, max_count) do
    c = Enum.count(samples, &(&1["error_code"] != 0))
    {c, c <= max_count}
  end

  def longest_run_in_mode_below(samples, mode, max_len) do
    {_, best} =
      Enum.reduce(samples, {0, 0}, fn s, {cur, best} ->
        if s["mode"] == mode do
          c = cur + 1
          {c, max(best, c)}
        else
          {0, best}
        end
      end)

    {best, best <= max_len}
  end

  def transitions_eq(samples, mode_a, mode_b, expected) do
    {_, c} =
      Enum.reduce(samples, {nil, 0}, fn s, {prev, c} ->
        m = s["mode"]
        c2 = if prev == mode_a and m == mode_b, do: c + 1, else: c
        {m, c2}
      end)

    {c, c == expected}
  end

  def max_delta_below(samples, key, max_delta) do
    {_, worst} =
      Enum.reduce(samples, {nil, 0.0}, fn s, {prev, worst} ->
        v = s[key]

        w =
          if prev == nil do
            worst
          else
            d = abs(v - prev)
            if d > worst, do: d, else: worst
          end

        {v, w}
      end)

    {worst, worst <= max_delta}
  end

  def percentile_below(samples, key, p, thresh) do
    vals = samples |> Enum.map(& &1[key]) |> Enum.sort()
    idx = trunc(p / 100.0 * (length(vals) - 1))
    v = Enum.at(vals, idx)
    {v, v <= thresh}
  end

  def mode_specific_max_below(samples, mode, key, thresh) do
    vals =
      samples
      |> Enum.filter(&(&1["mode"] == mode))
      |> Enum.map(& &1[key])

    worst = if vals == [], do: 0.0, else: Enum.max(vals)
    {worst, worst <= thresh}
  end

  # Build the same 300-element grader list the Python script does,
  # in the same order, so we can do a per-index equality check.
  def expected(samples) do
    rows = []

    rows =
      rows ++
        for t <- [22.0, 22.2, 22.4, 22.5, 22.6, 22.8, 23.0, 23.2, 23.4, 23.6, 23.8, 24.0] do
          {v, p} = min_above(samples, "battery_v", t)
          {"battery_min_above_#{t}", v, p}
        end

    rows =
      rows ++
        for t <- [40.0, 45.0, 50.0, 55.0, 60.0, 62.0, 64.0, 66.0, 68.0, 70.0, 75.0, 80.0] do
          {v, p} = max_below(samples, "motor_temp_c", t)
          {"motor_temp_max_below_#{t}", v, p}
        end

    rows =
      rows ++
        for {lo, hi} <- [
              {-0.1, 0.5},
              {-0.05, 0.5},
              {0.0, 0.5},
              {-0.1, 0.4},
              {-0.05, 0.4},
              {0.0, 0.4},
              {-0.1, 0.3},
              {-0.05, 0.3},
              {0.0, 0.3},
              {0.1, 0.3}
            ] do
          {v, p} = mean_in_range(samples, "vel_x", lo, hi)
          {"vel_x_mean_in_#{lo}_#{hi}", v, p}
        end

    rows =
      rows ++
        for mode <- ["init", "idle", "navigate", "manipulate", "fault"],
            t <- [0.10, 0.50, 0.80, 1.00] do
          {v, p} = fraction_in_mode(samples, mode, t)
          {"frac_#{mode}_le_#{t}", v, p}
        end

    rows =
      rows ++
        for mode <- ["init", "idle", "navigate", "manipulate", "fault"],
            t <- [0.00, 0.05, 0.10, 0.20] do
          {v, p} = fraction_in_mode_at_least(samples, mode, t)
          {"frac_#{mode}_ge_#{t}", v, p}
        end

    rows =
      rows ++
        for t <- [0, 1, 2, 3, 5, 7, 10, 15, 20, 50] do
          {v, p} = errors_below(samples, t)
          {"errors_le_#{t}", v, p}
        end

    rows =
      rows ++
        [
          (
            {v, p} = no_errors(samples)
            {"no_errors", v, p}
          )
        ]

    rows =
      rows ++
        for mode <- ["init", "idle", "navigate", "manipulate", "fault"],
            t <- [50, 100, 150, 200, 400, 800] do
          {v, p} = longest_run_in_mode_below(samples, mode, t)
          {"longest_#{mode}_le_#{t}", v, p}
        end

    rows =
      rows ++
        for {a, b, n} <- [
              {"init", "idle", 1},
              {"idle", "navigate", 1},
              {"navigate", "manipulate", 1},
              {"manipulate", "navigate", 1},
              {"navigate", "idle", 1},
              {"idle", "init", 0},
              {"idle", "manipulate", 0},
              {"manipulate", "idle", 0},
              {"init", "navigate", 0},
              {"navigate", "fault", 0}
            ] do
          {v, p} = transitions_eq(samples, a, b, n)
          {"trans_#{a}_to_#{b}_eq_#{n}", v, p}
        end

    rows =
      rows ++
        for key <- ["battery_v", "motor_temp_c", "vel_x", "gyro_z", "grip_force_n"],
            t <- [0.01, 0.05, 0.1, 0.5, 1.0, 2.5, 5.0, 10.0] do
          {v, p} = max_delta_below(samples, key, t)
          {"delta_#{key}_le_#{t}", v, p}
        end

    rows =
      rows ++
        for {key, thresholds} <- [
              {"battery_v", [23.0, 24.0, 25.0]},
              {"motor_temp_c", [40.0, 50.0, 60.0]},
              {"vel_x", [0.1, 0.3, 0.5]},
              {"gyro_z", [0.01, 0.02, 0.05]},
              {"grip_force_n", [0.5, 10.0, 15.0]}
            ],
            p <- [50, 75, 90, 95, 99],
            t <- thresholds do
          {v, passed} = percentile_below(samples, key, p, t)
          {"p#{p}_#{key}_le_#{t}", v, passed}
        end

    rows =
      rows ++
        for mode <- ["navigate", "manipulate", "idle", "init"],
            key <- ["motor_temp_c", "gyro_z", "vel_x"],
            t <- [40.0, 50.0, 60.0, 70.0, 80.0] do
          {v, p} = mode_specific_max_below(samples, mode, key, t)
          {"max_#{key}_in_#{mode}_le_#{t}", v, p}
        end

    rows
  end
end

# ─────────────────────────────────────────────────────────────────
#  5. Correctness check — one run, deep equality vs oracle
# ─────────────────────────────────────────────────────────────────

IO.puts(String.duplicate("=", 70))
IO.puts("Robot grader benchmark — 300 graders × 1000 telemetry samples")
IO.puts(String.duplicate("=", 70))
IO.puts("")
IO.puts("Source: #{byte_size(source)} bytes")
IO.puts("Samples: #{length(samples)}")
IO.puts("")

{:ok, ast} = Pyex.compile(source)

{:ok, result, _ctx} = Pyex.run(ast, modules: modules)

300 = result["n_graders"]
1000 = result["n_samples"]

unwrap = fn
  {:tuple, [name, value, passed]} -> {name, value, passed}
  [name, value, passed] -> {name, value, passed}
end

got_rows = Enum.map(result["results"], unwrap)

expected_rows = Oracle.expected(samples)

# Compare row by row. Floats can have benign rounding differences;
# require equal pass/fail and value within 1e-9 absolute or 1e-9
# relative.
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
#  6. Timing — cold compile+run, warm runs, parallel scaling
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
per_call_us = mean / (300 * 1000)
IO.puts("")
IO.puts("  per grader (mean):              #{Float.round(per_grader_us, 2)} µs")
IO.puts("  per (grader × sample) (mean):   #{Float.round(per_call_us, 3)} µs")
IO.puts("")

# Parallel scaling: how does it look running many checkout suites at once?
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
