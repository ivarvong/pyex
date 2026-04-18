defmodule Pyex.Conformance.FunctoolsTest do
  @moduledoc """
  Live CPython conformance tests for the `functools` module.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "reduce" do
    for {label, expr} <- [
          {"sum", "functools.reduce(lambda a, b: a + b, [1, 2, 3, 4, 5])"},
          {"product", "functools.reduce(lambda a, b: a * b, [1, 2, 3, 4, 5])"},
          {"with initial", "functools.reduce(lambda a, b: a + b, [1, 2, 3], 100)"},
          {"empty with initial", "functools.reduce(lambda a, b: a + b, [], 42)"},
          {"str concat", ~S|functools.reduce(lambda a, b: a + b, ["a", "b", "c"])|},
          {"max-like",
           "functools.reduce(lambda a, b: a if a > b else b, [3, 1, 4, 1, 5, 9, 2, 6])"}
        ] do
      test "reduce #{label}" do
        check!("""
        import functools
        print(#{unquote(expr)})
        """)
      end
    end

    test "empty without initial raises" do
      check!("""
      import functools
      try:
          functools.reduce(lambda a, b: a + b, [])
          print("no error")
      except TypeError:
          print("TypeError")
      """)
    end
  end

  describe "partial" do
    test "positional args" do
      check!("""
      import functools
      add10 = functools.partial(lambda a, b: a + b, 10)
      print(add10(5))
      """)
    end

    test "multiple pre-bound args" do
      check!("""
      import functools
      f = functools.partial(lambda a, b, c: a * b + c, 2, 3)
      print(f(10))
      """)
    end

    test "used with map" do
      check!("""
      import functools
      mul2 = functools.partial(lambda a, b: a * b, 2)
      print(list(map(mul2, [1, 2, 3, 4])))
      """)
    end
  end

  describe "lru_cache / cache" do
    test "cache memoizes" do
      check!("""
      import functools

      calls = [0]

      @functools.cache
      def expensive(n):
          calls[0] += 1
          return n * 2

      # Repeated calls with same arg
      print(expensive(5))
      print(expensive(5))
      print(expensive(5))
      print(expensive(7))
      print(calls[0])  # should be 2, not 4
      """)
    end

    test "lru_cache works as decorator with parens" do
      check!("""
      import functools

      @functools.lru_cache(maxsize=128)
      def square(n):
          return n * n

      print(square(4))
      print(square(4))
      """)
    end
  end

  describe "reduce with real sequences" do
    test "word frequency via reduce" do
      check!("""
      import functools

      words = ["apple", "banana", "apple", "cherry", "banana", "apple"]

      def add_count(acc, word):
          acc = dict(acc)
          acc[word] = acc.get(word, 0) + 1
          return acc

      result = functools.reduce(add_count, words, {})
      print(sorted(result.items()))
      """)
    end
  end
end
