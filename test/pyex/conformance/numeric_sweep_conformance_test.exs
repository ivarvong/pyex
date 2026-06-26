defmodule Pyex.NumericSweepConformanceTest do
  @moduledoc "Product-space conformance: the numeric tower. See Pyex.Test.Sweep."
  use ExUnit.Case, async: true

  test "numeric conforms to CPython" do
    Pyex.Test.Sweep.check!("numeric")
  end
end
