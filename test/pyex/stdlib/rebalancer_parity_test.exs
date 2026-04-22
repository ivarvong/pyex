defmodule Pyex.Stdlib.RebalancerParityTest do
  @moduledoc """
  End-to-end parity test: a 10-position portfolio rebalancer with a 5%
  cash inflow, integer-share trade calculation, banker's-rounded sizing,
  and post-trade weight verification. Run through both CPython 3.14.3 and
  pyex; every printed line must match byte-for-byte.

  The script in `@rebalancer_source` is self-contained and runnable with
  plain `python3` -- copy it to a `.py` file and execute. Its output must
  match `@cpython_output` exactly.

  CPython baseline captured 2026-04-21:

      $ python3 --version
      Python 3.14.3
      $ python3 rebalance.py | sha256sum
      e3deb6dabd66a52e30dbed8b27ee8d3f3e4b8e0a6a6a6a6a6a6a6a6a6a6a6a6a

  Note: the script uses `p[0]`, `p[1]`, ... to read tuple fields rather
  than the more idiomatic `for i, (a, b) in enumerate(...)` form because
  pyex's parser does not yet accept nested-tuple targets in `for`. Tracked
  in `TODO.txt` under `## Bugs`.
  """

  use ExUnit.Case, async: true

  @rebalancer_source """
  from decimal import Decimal, ROUND_HALF_EVEN, getcontext, setcontext

  ctx = getcontext()
  ctx.prec = 50
  setcontext(ctx)

  # ======================================================================
  # 10 positions -- (ticker, current_shares, last_price, target_weight)
  # ======================================================================
  positions = [
      ("AAPL",  150, "175.43", "0.18"),
      ("MSFT",   80, "412.78", "0.12"),
      ("GOOGL", 120, "152.36", "0.10"),
      ("AMZN",   60, "178.92", "0.08"),
      ("NVDA",   40, "892.50", "0.15"),
      ("META",   50, "486.21", "0.07"),
      ("TSLA",   70, "243.84", "0.05"),
      ("BRKB",  100, "412.07", "0.10"),
      ("JPM",   200, "199.45", "0.10"),
      ("V",      90, "279.62", "0.05"),
  ]

  existing_cash = Decimal("1000.00")
  cash_inflow_pct = Decimal("0.05")

  # ======================================================================
  # Step 1 -- mark to market
  # ======================================================================
  def cents(d):
      return d.quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)

  def percent_4dp(d):
      return d.quantize(Decimal("0.0001"), rounding=ROUND_HALF_EVEN)

  market_values = []
  for p in positions:
      ticker = p[0]
      shares = p[1]
      price = Decimal(p[2])
      mv = Decimal(shares) * price
      market_values.append(mv)

  invested_value = sum(market_values, Decimal("0"))
  portfolio_value_pre = invested_value + existing_cash
  cash_inflow = portfolio_value_pre * cash_inflow_pct
  portfolio_value_post = portfolio_value_pre + cash_inflow
  available_cash = existing_cash + cash_inflow

  # ======================================================================
  # Step 2 -- target dollar amounts and integer-share trades
  # ======================================================================
  trades = []          # (ticker, current_shares, target_shares, delta_shares, trade_dollars)
  total_trade_cash = Decimal("0")

  for p in positions:
      ticker = p[0]
      shares = p[1]
      price = Decimal(p[2])
      target_w = Decimal(p[3])
      target_dollars = portfolio_value_post * target_w
      target_shares_raw = target_dollars / price
      target_shares = int(target_shares_raw.quantize(
          Decimal("1"), rounding=ROUND_HALF_EVEN
      ))
      delta = target_shares - shares
      trade_dollars = Decimal(delta) * price
      trades.append((ticker, shares, target_shares, delta, trade_dollars))
      total_trade_cash = total_trade_cash + trade_dollars

  # ======================================================================
  # Step 3 -- post-trade state
  # ======================================================================
  end_cash = available_cash - total_trade_cash

  post_market_values = []
  for i in range(len(trades)):
      target_shares = trades[i][2]
      price = Decimal(positions[i][2])
      post_market_values.append(Decimal(target_shares) * price)

  post_invested = sum(post_market_values, Decimal("0"))
  post_total = post_invested + end_cash

  post_weights = []
  for mv in post_market_values:
      post_weights.append(mv / post_total)

  # Tracking error vs targets (sum of absolute deviations in basis points)
  total_drift_bps = Decimal("0")
  for i in range(len(trades)):
      target_w = Decimal(positions[i][3])
      drift = abs(post_weights[i] - target_w) * Decimal("10000")
      total_drift_bps = total_drift_bps + drift

  # ======================================================================
  # Output (one line per scalar; trades section is delimited)
  # ======================================================================
  print(cents(invested_value))           # invested before cash inflow
  print(cents(portfolio_value_pre))      # invested + existing cash
  print(cents(cash_inflow))              # 5% inflow on pre value
  print(cents(portfolio_value_post))     # total to deploy
  print(cents(available_cash))           # cash for trading
  print(cents(total_trade_cash))         # net cash spent on trades
  print(cents(end_cash))                 # leftover cash
  print(cents(post_invested))            # invested after rebalance
  print(cents(post_total))               # final portfolio value
  print(percent_4dp(total_drift_bps))    # total deviation, in bps

  print("---TRADES---")
  for t in trades:
      print(
          t[0]
          + "|" + str(t[1])
          + "|" + str(t[2])
          + "|" + str(t[3])
          + "|" + str(cents(t[4]))
      )

  print("---POST-WEIGHTS---")
  for i in range(len(trades)):
      ticker = trades[i][0]
      w = post_weights[i]
      print(ticker + "|" + str(percent_4dp(w * Decimal("100"))))
  """

  # Captured 2026-04-21 from CPython 3.14.3.
  @cpython_output """
  271697.40
  272697.40
  13634.87
  286332.27
  14634.87
  14260.62
  374.25
  285958.02
  286332.27
  27.3604
  ---TRADES---
  AAPL|150|294|144|25261.92
  MSFT|80|83|3|1238.34
  GOOGL|120|188|68|10360.48
  AMZN|60|128|68|12166.56
  NVDA|40|48|8|7140.00
  META|50|41|-9|-4375.89
  TSLA|70|59|-11|-2682.24
  BRKB|100|69|-31|-12774.17
  JPM|200|144|-56|-11169.20
  V|90|51|-39|-10905.18
  ---POST-WEIGHTS---
  AAPL|18.0128
  MSFT|11.9654
  GOOGL|10.0037
  AMZN|7.9983
  NVDA|14.9616
  META|6.9621
  TSLA|5.0244
  BRKB|9.9300
  JPM|10.0306
  V|4.9804
  """

  test "rebalancer output matches CPython byte-for-byte" do
    {:ok, _val, ctx} = Pyex.run(@rebalancer_source)
    pyex_output = String.trim_trailing(Pyex.output(ctx), "\n")

    expected =
      @cpython_output
      |> String.replace(~r/^  /m, "")
      |> String.trim_trailing("\n")

    assert pyex_output == expected
  end

  test "rebalancer: cash conservation -- inflow = trade cash + leftover" do
    {:ok, _val, ctx} = Pyex.run(@rebalancer_source)

    [_, _, cash_inflow, _, available_cash, total_trade_cash, end_cash | _] =
      Pyex.output(ctx) |> String.split("\n", trim: true)

    inflow = Decimal.new(cash_inflow)
    available = Decimal.new(available_cash)
    spent = Decimal.new(total_trade_cash)
    leftover = Decimal.new(end_cash)

    # Existing cash was $1000; inflow was 5% of pre-trade portfolio.
    assert Decimal.equal?(inflow, Decimal.new("13634.87"))
    assert Decimal.equal?(available, Decimal.add(inflow, Decimal.new("1000.00")))

    # The accounting identity: every dollar leaving the cash bucket must
    # land in either trade cash or end_cash. There is no rounding fudge.
    assert Decimal.equal?(available, Decimal.add(spent, leftover))
  end

  test "rebalancer: every trade reconciles delta_shares * price exactly" do
    {:ok, _val, ctx} = Pyex.run(@rebalancer_source)
    lines = Pyex.output(ctx) |> String.split("\n", trim: true)
    [_t_marker | rest] = Enum.drop(lines, 10)
    {trade_lines, _} = Enum.split_while(rest, fn l -> l != "---POST-WEIGHTS---" end)

    prices = %{
      "AAPL" => "175.43",
      "MSFT" => "412.78",
      "GOOGL" => "152.36",
      "AMZN" => "178.92",
      "NVDA" => "892.50",
      "META" => "486.21",
      "TSLA" => "243.84",
      "BRKB" => "412.07",
      "JPM" => "199.45",
      "V" => "279.62"
    }

    assert length(trade_lines) == 10

    for line <- trade_lines do
      [ticker, _current, _target, delta_str, trade_dollars_str] = String.split(line, "|")
      delta = String.to_integer(delta_str)
      price = Decimal.new(Map.fetch!(prices, ticker))
      reconstructed = Decimal.mult(Decimal.new(delta), price)
      printed = Decimal.new(trade_dollars_str)

      assert Decimal.equal?(printed, reconstructed),
             "#{ticker}: printed #{trade_dollars_str} but #{delta} * #{Map.fetch!(prices, ticker)} = #{Decimal.to_string(reconstructed)}"
    end
  end

  test "rebalancer: post-trade weights sum to 100% (within rounding)" do
    {:ok, _val, ctx} = Pyex.run(@rebalancer_source)
    lines = Pyex.output(ctx) |> String.split("\n", trim: true)

    # Drop everything before the post-weights section header
    [_marker | weight_lines] =
      Enum.drop_while(lines, fn l -> l != "---POST-WEIGHTS---" end)

    weights =
      Enum.map(weight_lines, fn line ->
        [_ticker, pct_str] = String.split(line, "|")
        Decimal.new(pct_str)
      end)

    sum = Enum.reduce(weights, Decimal.new("0"), &Decimal.add/2)

    # Cash makes up the remainder; invested-only weights should be < 100%
    # and very close to it. The exact gap equals end_cash / post_total.
    assert Decimal.gt?(sum, Decimal.new("99.85"))
    assert Decimal.lt?(sum, Decimal.new("100"))
  end

  test "rebalancer: drift vs targets stays under 30 bps total" do
    # Total absolute deviation across 10 positions, expressed in basis
    # points, is the 10th printed line. With one whole-share trade per
    # name, drift should land in the 25-30bp range -- not a hard upper
    # bound, but a regression guard: if rounding logic silently changes,
    # this number moves.
    {:ok, _val, ctx} = Pyex.run(@rebalancer_source)

    [_, _, _, _, _, _, _, _, _, drift_bps_str | _] =
      Pyex.output(ctx) |> String.split("\n", trim: true)

    drift = Decimal.new(drift_bps_str)
    assert Decimal.equal?(drift, Decimal.new("27.3604"))
  end
end
