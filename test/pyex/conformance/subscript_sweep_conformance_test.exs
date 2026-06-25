defmodule Pyex.Conformance.UsubscriptSweepTest do
  @moduledoc "Product-space conformance: subscript. See Pyex.Test.Sweep."
  use ExUnit.Case, async: true

  test "subscript conforms to CPython" do
    Pyex.Test.Sweep.check!("subscript")
  end
end
