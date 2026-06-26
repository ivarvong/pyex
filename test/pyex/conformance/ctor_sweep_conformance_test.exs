defmodule Pyex.Conformance.CtorSweepTest do
  @moduledoc """
  Product-space conformance: every builtin type constructor × diverse
  input values, against CPython. See `Pyex.Test.Sweep`. Regenerate with
  `python3 test/fixtures/sweeps/ctor_gen.py`.
  """
  use ExUnit.Case, async: true

  test "type constructors conform to CPython across input values" do
    Pyex.Test.Sweep.check!("ctor")
  end
end
