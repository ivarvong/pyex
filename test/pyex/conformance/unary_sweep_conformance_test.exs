defmodule Pyex.Conformance.UunarySweepTest do
  @moduledoc "Product-space conformance: unary. See Pyex.Test.Sweep."
  use ExUnit.Case, async: true

  test "unary conforms to CPython" do
    Pyex.Test.Sweep.check!("unary")
  end
end
