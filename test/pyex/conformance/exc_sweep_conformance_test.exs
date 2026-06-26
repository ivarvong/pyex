defmodule Pyex.Conformance.UexcSweepTest do
  @moduledoc "Statement-level product-space conformance: exc. See Pyex.Test.Sweep."
  use ExUnit.Case, async: true

  test "exc conforms to CPython" do
    Pyex.Test.Sweep.check!("exc")
  end
end
