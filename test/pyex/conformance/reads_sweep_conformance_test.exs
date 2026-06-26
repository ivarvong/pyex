defmodule Pyex.ReadsSweepConformanceTest do
  @moduledoc "Statement-level product-space conformance: reads. See Pyex.Test.Sweep."
  use ExUnit.Case, async: true

  test "reads conforms to CPython" do
    Pyex.Test.Sweep.check!("reads")
  end
end
