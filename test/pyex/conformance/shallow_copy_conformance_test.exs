defmodule Pyex.Conformance.ShallowCopyTest do
  @moduledoc """
  Live CPython conformance for the shallow-copy semantics of the
  iterable-materializing builtins. `sorted`/`list`/`reversed`/`tuple`
  build a new outer container holding the *same* inner objects, so a
  mutation reached through the result is visible in the original.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "materializers share inner elements (shallow copy)" do
    test "list() shares inner objects" do
      check!("x = [[1, 2]]\ns = list(x)\ns[0][1] = 99\nprint(x)")
    end

    test "sorted() shares inner objects" do
      check!("x = [[1, 2]]\ns = sorted(x)\ns[0][1] = 99\nprint(x)")
    end

    test "reversed() shares inner objects" do
      check!("x = [[1, 2]]\ns = list(reversed(x))\ns[0][1] = 99\nprint(x)")
    end

    # Mutated via .append rather than t[0][1] = 99: subscript-assignment
    # through a tuple element is a separate, pre-existing gap (it fails the
    # same way for a plain tuple literal), independent of shallow copy.
    test "tuple() shares inner objects" do
      check!("x = [[1, 2]]\nt = tuple(x)\nt[0].append(99)\nprint(x)")
    end

    test "list() element is the same object (identity)" do
      check!("x = [[1, 2]]\nprint(list(x)[0] is x[0])")
    end

    test "sorted() element is the same object (identity)" do
      check!("x = [[3], [1], [2]]\ns = sorted(x)\nprint(s[0] is x[1])")
    end
  end

  describe "materializers produce a distinct outer container" do
    test "list() is not the same object as its argument" do
      check!("x = [1, 2]\nprint(list(x) is x)")
    end

    test "appending to the new list does not touch the original" do
      check!("x = [[1, 2]]\ns = list(x)\ns.append([3])\nprint(x)")
    end

    test "sorting reorders the copy, not the original" do
      check!("x = [3, 1, 2]\ns = sorted(x)\nprint(x, s)")
    end
  end
end
