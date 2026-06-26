defmodule Pyex.CallsSweepConformanceTest do
  @moduledoc "Statement-level product-space conformance: calls. See Pyex.Test.Sweep."
  use ExUnit.Case, async: true

  test "calls conforms to CPython" do
    Pyex.Test.Sweep.check!("calls")
  end
end
