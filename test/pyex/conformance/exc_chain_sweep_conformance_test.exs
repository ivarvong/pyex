defmodule Pyex.ExcChainSweepConformanceTest do
  @moduledoc "Statement-level product-space conformance: exc_chain. See Pyex.Test.Sweep."
  use ExUnit.Case, async: true

  test "exc_chain conforms to CPython" do
    Pyex.Test.Sweep.check!("exc_chain")
  end
end
