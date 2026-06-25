defmodule Pyex.Conformance.IterablePolymorphismTest do
  @moduledoc """
  Conformance over the *product space* of iterables and the builtins that
  consume them.

  The invariant: in CPython anything iterable works in every
  iterable-consuming builtin. pyex used to hand-roll "what counts as
  iterable" inside each consumer, so each had a different, silently
  incomplete subset (the `max`/`min`/`sum`-reject-a-dict bug was one
  cell). Every consumer now defers to the single `Interpreter.to_iterable`
  coercion, so the grid below should be fully conformant — and stays that
  way: a new consumer that forgets to defer, or a new iterable type the
  coercion misses, fails here against live CPython.

  This is the conformance sweep, not a snapshot of past bugs: it asserts
  the invariant directly and is green because the implementation holds it.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  # Each producer yields the multiset {1, 2, 3} via a different iterable type.
  @producers [
    {"list", "[3,1,2]"},
    {"tuple", "(3,1,2)"},
    {"set", "{3,1,2}"},
    {"frozenset", "frozenset([3,1,2])"},
    {"dict", "{3:0,1:0,2:0}"},
    {"range", "range(1,4)"},
    {"genexpr", "(x for x in [3,1,2])"},
    {"dict_keys", "{3:0,1:0,2:0}.keys()"},
    {"dict_values", "{1:3,2:1,3:2}.values()"},
    {"bytes", "bytes([3,1,2])"},
    {"map", "map(lambda x:x,[3,1,2])"},
    {"filter", "filter(lambda x:True,[3,1,2])"},
    {"str", "'312'"}
  ]

  # Each consumer reduces its argument to a deterministic value (unordered
  # producers are wrapped in `sorted` so the result is implementation-stable).
  @consumers [
    {"min", "min({it})"},
    {"max", "max({it})"},
    {"sorted", "sorted({it})"},
    {"list", "sorted(list({it}))"},
    {"tuple", "tuple(sorted({it}))"},
    {"set", "sorted(set({it}))"},
    {"frozenset", "sorted(frozenset({it}))"},
    {"len", "len(list({it}))"},
    {"any", "any({it})"},
    {"all", "all({it})"},
    {"map", "sorted(map(lambda x:x,{it}))"},
    {"filter", "sorted(filter(lambda x:True,{it}))"},
    {"enumerate", "len(list(enumerate({it})))"},
    {"zip", "len(list(zip({it},{it})))"},
    # `sum` is numeric, so it is excluded for the str producer below.
    {"sum", "sum({it})"}
  ]

  for {pname, pexpr} <- @producers, {cname, ctemplate} <- @consumers do
    # str yields characters, which sum() cannot add — CPython rejects it too.
    unless pname == "str" and cname == "sum" do
      @code "print(" <> String.replace(ctemplate, "{it}", pexpr) <> ")"

      test "#{cname} over #{pname}" do
        check!(@code)
      end
    end
  end
end
