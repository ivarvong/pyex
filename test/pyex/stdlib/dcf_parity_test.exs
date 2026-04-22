defmodule Pyex.Stdlib.DCFParityTest do
  @moduledoc """
  End-to-end parity test: a non-trivial multi-stage discounted cash flow
  valuation, run through both CPython 3.14.3 and pyex with byte-identical
  output.

  The model exercises the full Decimal surface a real valuation analyst
  would touch: precision context, integer + Decimal mixing, exponentiation,
  division, summation, conditional growth schedules, nested helper
  functions, banker's-rounded `quantize`, sensitivity tables, and string
  interpolation. The script string in `@dcf_source` is kept self-contained
  and copy-paste-runnable -- save it to a `.py` file and `python3` it; the
  output must match `@cpython_output` to the byte.

  The CPython baseline was captured with:

      $ python3 --version
      Python 3.14.3
      $ python3 dcf_model.py | sha256sum
      1bdb15c0c7c45a30013f0b18a96d4a7c0fee47a3afe0b71d65adff61bcca0a36

  If the assertion in this file fails, *one* of the following changed:

    * Pyex's Decimal arithmetic semantics drifted
    * The default Decimal context (precision 28, banker's rounding) was
      altered
    * The Decimal library shipped with pyex changed its rounding behaviour

  Any of those is a regression that warrants investigation, not a test
  update.
  """

  use ExUnit.Case, async: true

  @dcf_source """
  from decimal import Decimal, ROUND_HALF_EVEN, getcontext, setcontext

  # Increase precision so accumulated rounding error stays well below
  # half a cent for billion-dollar enterprise values.
  ctx = getcontext()
  ctx.prec = 50
  setcontext(ctx)

  # ======================================================================
  # Assumptions
  # ======================================================================
  revenue_year_0 = Decimal("1_000_000_000")          # $1.0B baseline revenue
  fcf_margin = Decimal("0.15")                       # 15% FCF / revenue
  years_explicit = 10
  growth_high = Decimal("0.15")                      # years 1-5
  growth_low = Decimal("0.05")                       # year 10
  terminal_growth = Decimal("0.03")
  shares_outstanding = Decimal("100_000_000")        # 100M shares
  net_debt = Decimal("250_000_000")                  # $250M

  # WACC inputs
  risk_free = Decimal("0.045")
  equity_premium = Decimal("0.06")
  beta = Decimal("1.20")
  debt_cost = Decimal("0.06")
  tax_rate = Decimal("0.25")
  debt_weight = Decimal("0.30")
  equity_weight = Decimal("0.70")

  # ======================================================================
  # WACC = w_e * Re + w_d * Rd * (1-t)
  # ======================================================================
  cost_of_equity = risk_free + beta * equity_premium
  after_tax_debt = debt_cost * (Decimal("1") - tax_rate)
  wacc = equity_weight * cost_of_equity + debt_weight * after_tax_debt

  # ======================================================================
  # Growth schedule: 15% for years 1-5, linear taper to 5% by year 10
  # ======================================================================
  growths = []
  for y in range(1, years_explicit + 1):
      if y <= 5:
          growths.append(growth_high)
      else:
          offset = y - 5
          delta = (growth_high - growth_low) * Decimal(offset) / Decimal("5")
          growths.append(growth_high - delta)

  # ======================================================================
  # Project FCF year-by-year
  # ======================================================================
  fcfs = []
  revenue = revenue_year_0
  for g in growths:
      revenue = revenue * (Decimal("1") + g)
      fcfs.append(revenue * fcf_margin)

  # ======================================================================
  # Discount each year's FCF
  # ======================================================================
  pv_explicit = Decimal("0")
  discount_factors = []
  for t in range(1, years_explicit + 1):
      df = (Decimal("1") + wacc) ** Decimal(t)
      discount_factors.append(df)
      pv_explicit = pv_explicit + fcfs[t - 1] / df

  # ======================================================================
  # Gordon-growth terminal value, discounted to t=0
  # ======================================================================
  final_fcf = fcfs[-1]
  tv_year_n = (final_fcf * (Decimal("1") + terminal_growth)) / (wacc - terminal_growth)
  pv_tv = tv_year_n / discount_factors[-1]

  # ======================================================================
  # Bridge to equity
  # ======================================================================
  enterprise_value = pv_explicit + pv_tv
  equity_value = enterprise_value - net_debt
  fair_value_per_share = equity_value / shares_outstanding

  # ======================================================================
  # Sensitivity matrix: WACC ±100bp, terminal growth ±100bp
  # ======================================================================
  def value_per_share(wacc_in, tg_in):
      pve = Decimal("0")
      last_df = None
      for t in range(1, years_explicit + 1):
          df = (Decimal("1") + wacc_in) ** Decimal(t)
          pve = pve + fcfs[t - 1] / df
          last_df = df
      tv = (fcfs[-1] * (Decimal("1") + tg_in)) / (wacc_in - tg_in)
      pvt = tv / last_df
      return ((pve + pvt - net_debt) / shares_outstanding).quantize(
          Decimal("0.01"), rounding=ROUND_HALF_EVEN
      )

  wacc_offsets = [Decimal("-0.01"), Decimal("0"), Decimal("0.01")]
  tg_offsets = [Decimal("-0.01"), Decimal("0"), Decimal("0.01")]

  sensitivity_rows = []
  for w_off in wacc_offsets:
      row = []
      for tg_off in tg_offsets:
          row.append(str(value_per_share(wacc + w_off, terminal_growth + tg_off)))
      sensitivity_rows.append(row)

  # ======================================================================
  # Format outputs (each rounded to cents with banker's rounding)
  # ======================================================================
  def cents(d):
      return str(d.quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN))

  results = [
      cents(wacc * Decimal("100")),                  # WACC as a percentage
      cents(cost_of_equity * Decimal("100")),
      cents(after_tax_debt * Decimal("100")),
      cents(fcfs[0]),                                # Year 1 FCF
      cents(fcfs[4]),                                # Year 5 FCF
      cents(fcfs[9]),                                # Year 10 FCF
      cents(sum(fcfs, Decimal("0"))),                # Sum of explicit-period FCFs
      cents(pv_explicit),                            # PV of explicit period
      cents(tv_year_n),                              # Terminal value (year 10)
      cents(pv_tv),                                  # Discounted terminal value
      cents(enterprise_value),
      cents(equity_value),
      cents(fair_value_per_share),
  ]

  # Print one value per line so the test can split & compare cleanly.
  for r in results:
      print(r)

  print("---SENSITIVITY---")
  for row in sensitivity_rows:
      print("|".join(row))
  """

  # Captured 2026-04-21 from CPython 3.14.3 running the script above.
  # See @dcf_source moduledoc for the reproduction command.
  @cpython_output """
  9.54
  11.70
  4.50
  172500000.00
  301703578.12
  463427133.28
  3199684124.66
  1846884760.54
  7298623047.14
  2934361177.93
  4781245938.48
  4531245938.48
  45.31
  ---SENSITIVITY---
  48.81|54.93|63.74
  41.17|45.31|50.95
  35.37|38.29|42.10
  """

  test "DCF model output matches CPython byte-for-byte" do
    {:ok, _val, ctx} = Pyex.run(@dcf_source)
    pyex_output = String.trim_trailing(Pyex.output(ctx), "\n")

    expected =
      @cpython_output
      |> String.replace(~r/^  /m, "")
      |> String.trim_trailing("\n")

    assert pyex_output == expected
  end

  test "DCF: enterprise value, equity, and fair value land on the cent" do
    {:ok, _val, ctx} = Pyex.run(@dcf_source)
    lines = Pyex.output(ctx) |> String.split("\n", trim: true)

    # The first 13 printed lines are the labelled scalar outputs in the
    # order the model emits them.
    [
      wacc_pct,
      cost_of_equity_pct,
      after_tax_debt_pct,
      year1_fcf,
      year5_fcf,
      year10_fcf,
      sum_fcfs,
      pv_explicit,
      tv_year_10,
      pv_tv,
      enterprise_value,
      equity_value,
      fair_value
      | _rest
    ] = lines

    # WACC: 0.70 * (4.5% + 1.20*6%) + 0.30 * 6% * 0.75 = 9.54%
    assert wacc_pct == "9.54"
    assert cost_of_equity_pct == "11.70"
    assert after_tax_debt_pct == "4.50"

    # Year 1 FCF: 1B * 1.15 * 0.15 = 172.5M
    assert year1_fcf == "172500000.00"
    # Year 5 FCF: 1B * 1.15^5 * 0.15 = ~301.7M
    assert year5_fcf == "301703578.12"
    # Year 10 FCF: full taper applied
    assert year10_fcf == "463427133.28"

    assert sum_fcfs == "3199684124.66"
    assert pv_explicit == "1846884760.54"
    assert tv_year_10 == "7298623047.14"
    assert pv_tv == "2934361177.93"

    # EV = PV(explicit) + PV(TV)
    assert enterprise_value == "4781245938.48"

    # Equity = EV - net debt (250M)
    assert equity_value == "4531245938.48"

    # Per-share value at 100M shares outstanding
    assert fair_value == "45.31"
  end

  test "DCF: sensitivity table matches CPython at every cell" do
    {:ok, _val, ctx} = Pyex.run(@dcf_source)

    [_marker | sens_lines] =
      Pyex.output(ctx)
      |> String.split("\n", trim: true)
      |> Enum.drop(13)

    rows = Enum.map(sens_lines, &String.split(&1, "|"))

    # 3x3 sensitivity matrix:  rows = WACC offsets (-100bp, 0, +100bp)
    #                         cols = terminal-growth offsets (-100bp, 0, +100bp)
    expected = [
      ["48.81", "54.93", "63.74"],
      ["41.17", "45.31", "50.95"],
      ["35.37", "38.29", "42.10"]
    ]

    assert rows == expected

    # Spot-check the centre cell against the headline fair-value calculation
    # — both should equal $45.31 (no offsets applied).
    assert Enum.at(Enum.at(rows, 1), 1) == "45.31"

    # Sanity: lowering WACC raises value, raising terminal growth raises value
    # (monotonicity per row and per column).
    for row <- rows do
      [low, mid, high] = row
      assert Decimal.new(low) |> Decimal.lt?(Decimal.new(mid))
      assert Decimal.new(mid) |> Decimal.lt?(Decimal.new(high))
    end

    for col_idx <- 0..2 do
      col = Enum.map(rows, &Enum.at(&1, col_idx))
      [top, mid, bottom] = col
      # As WACC rises (going down rows), value falls.
      assert Decimal.new(top) |> Decimal.gt?(Decimal.new(mid))
      assert Decimal.new(mid) |> Decimal.gt?(Decimal.new(bottom))
    end
  end
end
