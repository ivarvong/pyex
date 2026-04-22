defmodule Pyex.Stdlib.RocketParityTest do
  @moduledoc """
  End-to-end parity test: a three-stage launch-vehicle Δv budget using
  the Tsiolkovsky rocket equation, computed three ways and cross-checked:

    1. CPython 3.14.3 with `decimal.Decimal` and a hand-rolled
       high-precision `ln()` (range-reduced artanh series).
    2. Pyex with the same script. Every printed digit must match (1)
       byte-for-byte at 18 decimal places.
    3. CPython and pyex both running a parallel IEEE-754 float version
       (uses `math.log`). Float results match between runtimes to the
       bit, but visibly diverge from the Decimal ground truth at the
       12th-16th decimal -- the sharp edge where doubles lose resolution.

  The scripts in `@decimal_source` / `@float_source` are self-contained
  and runnable with plain `python3`:

      $ python3 rocket_decimal.py
      $ python3 rocket_float.py

  CPython baseline captured 2026-04-22 from Python 3.14.3.

  ## Why this matters

  A 1357.50 m/s margin over LEO insertion is comfortable -- but the
  *last digits* of a Δv budget are how engineers decide whether a
  mission has enough reserve for contingency burns. The Decimal column
  gives exactly-reproducible results across runs and platforms; the
  float column's last digits depend on the order of operations and the
  platform's fused-multiply-add behaviour. Financial simulations that
  iterate similar compound ratios over thousands of steps accumulate
  the float error into cents.
  """

  use ExUnit.Case, async: true

  @decimal_source """
  from decimal import Decimal, getcontext, setcontext, ROUND_HALF_EVEN

  _ctx = getcontext()
  _ctx.prec = 50
  _ctx.rounding = ROUND_HALF_EVEN
  setcontext(_ctx)


  # -------- Custom ln using range reduction + artanh series --------
  def decimal_ln_reduced(x):
      one = Decimal(1)
      two = Decimal(2)
      y = (x - one) / (x + one)
      y2 = y * y
      term = y
      total = y
      for n in range(1, 80):
          term = term * y2
          total = total + term / Decimal(2 * n + 1)
      return total * two


  def _compute_ln2():
      one = Decimal(1)
      two = Decimal(2)
      three = Decimal(3)
      y = one / three
      y2 = y * y
      term = y
      total = y
      for n in range(1, 80):
          term = term * y2
          total = total + term / Decimal(2 * n + 1)
      return total * two


  LN2 = _compute_ln2()


  def decimal_ln(x):
      one = Decimal(1)
      two = Decimal(2)
      k = 0
      reduced = x
      while reduced >= two:
          reduced = reduced / two
          k = k + 1
      while reduced < one:
          reduced = reduced * two
          k = k - 1
      return decimal_ln_reduced(reduced) + Decimal(k) * LN2


  # -------- Three-stage Saturn V-inspired vehicle --------
  G0 = Decimal("9.80665")

  STAGES = [
      (Decimal("263"), Decimal("2290000"), Decimal("135000"), Decimal("168")),
      (Decimal("421"), Decimal("496200"),  Decimal("39100"),  Decimal("360")),
      (Decimal("421"), Decimal("123000"),  Decimal("13500"),  Decimal("165")),
  ]
  PAYLOAD = Decimal("48000")
  LOSSES = [Decimal("1300"), Decimal("300"), Decimal("0")]
  TARGET_DV_LEO = Decimal("9400")


  def stage_delta_v(isp, wet, dry, payload_mass_above):
      m_initial = wet + payload_mass_above
      m_final = dry + payload_mass_above
      return isp * G0 * decimal_ln(m_initial / m_final)


  def total_delta_v():
      total = Decimal(0)
      for i in range(len(STAGES)):
          s = STAGES[i]
          isp = s[0]
          wet = s[1]
          dry = s[2]
          ride_mass = PAYLOAD
          for j in range(i + 1, len(STAGES)):
              ride_mass = ride_mass + STAGES[j][1]
          total = total + stage_delta_v(isp, wet, dry, ride_mass)
      return total


  def net_delta_v():
      gross = total_delta_v()
      losses = Decimal(0)
      for loss in LOSSES:
          losses = losses + loss
      return gross - losses


  def m_per_s(d):
      return str(d.quantize(Decimal("0.000000000000000001"), rounding=ROUND_HALF_EVEN))


  def cents(d):
      return str(d.quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN))


  total = total_delta_v()
  net = net_delta_v()
  margin = net - TARGET_DV_LEO

  print(m_per_s(LN2))
  print(m_per_s(total))
  print(m_per_s(net))
  print(m_per_s(margin))

  for i in range(len(STAGES)):
      s = STAGES[i]
      isp = s[0]
      wet = s[1]
      dry = s[2]
      ride_mass = PAYLOAD
      for j in range(i + 1, len(STAGES)):
          ride_mass = ride_mass + STAGES[j][1]
      dv = stage_delta_v(isp, wet, dry, ride_mass)
      print("stage " + str(i + 1) + " dv = " + m_per_s(dv))

  print("HEADLINE: " + cents(net) + " m/s net, margin " + cents(margin) + " m/s")
  """

  @float_source """
  import math

  G0 = 9.80665

  STAGES = [
      (263.0,  2290000.0, 135000.0, 168.0),
      (421.0,  496200.0,   39100.0, 360.0),
      (421.0,  123000.0,   13500.0, 165.0),
  ]
  PAYLOAD = 48000.0
  LOSSES = [1300.0, 300.0, 0.0]
  TARGET_DV_LEO = 9400.0


  def stage_delta_v(isp, wet, dry, payload_mass_above):
      m_initial = wet + payload_mass_above
      m_final = dry + payload_mass_above
      return isp * G0 * math.log(m_initial / m_final)


  def total_delta_v():
      total = 0.0
      for i in range(len(STAGES)):
          s = STAGES[i]
          isp = s[0]
          wet = s[1]
          dry = s[2]
          ride_mass = PAYLOAD
          for j in range(i + 1, len(STAGES)):
              ride_mass = ride_mass + STAGES[j][1]
          total = total + stage_delta_v(isp, wet, dry, ride_mass)
      return total


  def net_delta_v():
      gross = total_delta_v()
      losses = 0.0
      for loss in LOSSES:
          losses = losses + loss
      return gross - losses


  total = total_delta_v()
  net = net_delta_v()
  margin = net - TARGET_DV_LEO

  print(repr(total))
  print(repr(net))
  print(repr(margin))
  for i in range(len(STAGES)):
      s = STAGES[i]
      isp = s[0]
      wet = s[1]
      dry = s[2]
      ride_mass = PAYLOAD
      for j in range(i + 1, len(STAGES)):
          ride_mass = ride_mass + STAGES[j][1]
      dv = stage_delta_v(isp, wet, dry, ride_mass)
      print("stage " + str(i + 1) + " dv = " + repr(dv))
  """

  # Ground truth captured from CPython 3.14.3.
  @cpython_decimal_output """
  0.693147180559945309
  12357.498995601449128216
  10757.498995601449128216
  1357.498995601449128216
  stage 1 dv = 3364.861402852735319830
  stage 2 dv = 4770.622671221838639448
  stage 3 dv = 4222.014921526875168938
  HEADLINE: 10757.50 m/s net, margin 1357.50 m/s
  """

  @cpython_float_output """
  12357.498995601449
  10757.498995601449
  1357.4989956014488
  stage 1 dv = 3364.8614028527354
  stage 2 dv = 4770.622671221839
  stage 3 dv = 4222.014921526875
  """

  # ----------------------------------------------------------------------

  test "Decimal model: pyex matches CPython byte-for-byte at 18-digit precision" do
    {:ok, _val, ctx} = Pyex.run(@decimal_source)

    actual = String.trim_trailing(Pyex.output(ctx), "\n")

    expected =
      @cpython_decimal_output
      |> String.replace(~r/^  /m, "")
      |> String.trim_trailing("\n")

    assert actual == expected
  end

  test "Float model: pyex matches CPython float to the bit" do
    {:ok, _val, ctx} = Pyex.run(@float_source)

    actual = String.trim_trailing(Pyex.output(ctx), "\n")

    expected =
      @cpython_float_output
      |> String.replace(~r/^  /m, "")
      |> String.trim_trailing("\n")

    assert actual == expected
  end

  test "Decimal vs float: the two are close, but diverge in the 13th digit" do
    # Run both through pyex; confirm the cross-precision relationship.
    {:ok, _, dec_ctx} = Pyex.run(@decimal_source)
    {:ok, _, flt_ctx} = Pyex.run(@float_source)

    [ln2, dec_total, dec_net, dec_margin | _] =
      Pyex.output(dec_ctx) |> String.split("\n", trim: true)

    [flt_total, flt_net, flt_margin | _] =
      Pyex.output(flt_ctx) |> String.split("\n", trim: true)

    # ln(2) to 18 digits
    assert ln2 == "0.693147180559945309"

    # Decimal total and net include the full 18-digit trailing tail.
    assert dec_total == "12357.498995601449128216"
    assert dec_net == "10757.498995601449128216"
    assert dec_margin == "1357.498995601449128216"

    # IEEE double prints to at most 17 significant figures; repr gives
    # only what the shortest-round-trip algorithm emits.
    assert flt_total == "12357.498995601449"
    assert flt_net == "10757.498995601449"
    assert flt_margin == "1357.4989956014488"

    # Difference at 18-digit granularity. The Decimal tail past position
    # 13 is `128216` of drift beyond what the float can represent.
    dec_total_tail =
      Decimal.new(dec_total) |> Decimal.sub(Decimal.new(flt_total)) |> Decimal.abs()

    # This drift is tiny in absolute terms (< 1 nm/s) but non-zero. If
    # pyex ever matched the float output in the Decimal column, something
    # silently truncated precision.
    assert Decimal.gt?(dec_total_tail, Decimal.new(0))
    assert Decimal.lt?(dec_total_tail, Decimal.new("0.001"))
  end

  test "Δv budget clears LEO insertion requirement with margin" do
    {:ok, _, ctx} = Pyex.run(@decimal_source)

    [_, _, _, _margin, _, _, _, headline] =
      Pyex.output(ctx) |> String.split("\n", trim: true)

    assert headline == "HEADLINE: 10757.50 m/s net, margin 1357.50 m/s"
  end

  test "Per-stage Δv contributions sum to the gross total" do
    {:ok, _, ctx} = Pyex.run(@decimal_source)
    lines = Pyex.output(ctx) |> String.split("\n", trim: true)

    # stages are lines 5, 6, 7 in the output
    stage_lines = Enum.slice(lines, 4, 3)

    stage_dvs =
      Enum.map(stage_lines, fn line ->
        [_prefix, val] = String.split(line, " = ")
        Decimal.new(val)
      end)

    sum = Enum.reduce(stage_dvs, Decimal.new(0), &Decimal.add/2)

    # The "total" printed line is the gross (before losses)
    total = Decimal.new(Enum.at(lines, 1))

    assert Decimal.equal?(sum, total),
           "stages sum to #{Decimal.to_string(sum)} but gross total reads #{Decimal.to_string(total)}"
  end
end
