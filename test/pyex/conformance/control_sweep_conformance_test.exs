defmodule Pyex.Conformance.UcontrolSweepTest do
  @moduledoc "Statement-level product-space conformance: control. See Pyex.Test.Sweep."
  use ExUnit.Case, async: true

  test "control conforms to CPython" do
    Pyex.Test.Sweep.check!("control")
  end
end
