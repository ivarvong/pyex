defmodule Pyex.Conformance.UstdlibUiterSweepTest do
  @moduledoc "Product-space conformance: stdlib_iter. See Pyex.Test.Sweep."
  use ExUnit.Case, async: true

  test "stdlib_iter conforms to CPython" do
    Pyex.Test.Sweep.check!("stdlib_iter")
  end
end
