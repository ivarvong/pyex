defmodule Pyex.OOPSweepConformanceTest do
  @moduledoc "Statement-level product-space conformance: oop. See Pyex.Test.Sweep."
  use ExUnit.Case, async: true

  test "oop conforms to CPython" do
    Pyex.Test.Sweep.check!("oop")
  end
end
