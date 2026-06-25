defmodule Pyex.Conformance.BinopSweepTest do
  @moduledoc """
  Product-space conformance: every binary operator × every operand-type
  pair, against CPython. See `Pyex.Test.Sweep`. Regenerate with
  `python3 test/fixtures/sweeps/binop_gen.py`.
  """
  use ExUnit.Case, async: true

  test "binary operators conform to CPython across operand-type pairs" do
    Pyex.Test.Sweep.check!("binop")
  end
end
