defmodule Pyex.Conformance.MutateSweepTest do
  @moduledoc """
  Statement-level product-space conformance: item/slice assignment, del,
  augmented assignment, and unpacking. See `Pyex.Test.Sweep`. Regenerate
  with `python3 test/fixtures/sweeps/mutate_gen.py`.
  """
  use ExUnit.Case, async: true

  test "mutation/assignment statements conform to CPython" do
    Pyex.Test.Sweep.check!("mutate")
  end
end
