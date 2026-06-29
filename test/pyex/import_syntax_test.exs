defmodule Pyex.ImportSyntaxTest do
  @moduledoc """
  Import-statement syntax that real-world Python relies on but pyex previously
  rejected: parenthesized (often multi-line) `from x import (...)` lists and the
  no-op `from __future__ import ...`. Both appear at the top of a large fraction
  of in-distribution files (e.g. any module with more than one import).
  """

  use ExUnit.Case, async: true

  defp out!(src) do
    {:ok, _v, ctx} = Pyex.run(src)
    String.trim(Pyex.output(ctx))
  end

  describe "parenthesized from-import lists" do
    test "a single-line parenthesized list binds every name" do
      assert out!("""
             from os.path import (join, basename)
             print(join("a", "b"), basename("/x/y.txt"))
             """) == "a/b y.txt"
    end

    test "a multi-line list with a trailing comma is accepted" do
      assert out!("""
             from collections import (
                 OrderedDict,
                 defaultdict,
                 Counter,
             )
             counts = Counter("aab")
             misses = defaultdict(int)
             ordered = OrderedDict([("a", 1), ("b", 2)])
             print(counts["a"], misses["nope"], list(ordered.items()))
             """) == "2 0 [('a', 1), ('b', 2)]"
    end

    test "as-aliases work inside the parentheses" do
      assert out!("""
             from os.path import (
                 join as j,
                 exists as e,
             )
             print(j("p", "q"))
             """) == "p/q"
    end

    test "a single name in parentheses is still a from-import, not a call" do
      assert out!("""
             from math import (pi)
             print(round(pi, 2))
             """) == "3.14"
    end
  end

  describe "__future__ imports are no-ops on Python 3" do
    test "from __future__ import annotations runs and binds nothing harmful" do
      assert out!("""
             from __future__ import annotations
             def f(x: int) -> int:
                 return x + 1
             print(f(41))
             """) == "42"
    end

    test "multiple historical feature flags are accepted" do
      assert out!("""
             from __future__ import division, print_function, annotations
             print(7 / 2)
             """) == "3.5"
    end
  end
end
