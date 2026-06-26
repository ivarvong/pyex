defmodule Pyex.DecoratorSweepConformanceTest do
  @moduledoc "Statement-level product-space conformance: decorator. See Pyex.Test.Sweep."
  use ExUnit.Case, async: true

  test "decorator conforms to CPython" do
    Pyex.Test.Sweep.check!("decorator")
  end
end
