defmodule Pyex.CollectionsSweepConformanceTest do
  @moduledoc "Statement-level product-space conformance: collections. See Pyex.Test.Sweep."
  use ExUnit.Case, async: true

  test "collections conforms to CPython" do
    Pyex.Test.Sweep.check!("collections")
  end
end
