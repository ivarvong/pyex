defmodule Pyex.Conformance.UformatSweepTest do
  @moduledoc "Product-space conformance: format. See Pyex.Test.Sweep."
  use ExUnit.Case, async: true

  test "format conforms to CPython" do
    Pyex.Test.Sweep.check!("format")
  end
end
