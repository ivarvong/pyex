defmodule Pyex.Conformance.PythonExtrasTest do
  @moduledoc """
  Live CPython conformance tests for Python syntactic features that
  don't fit elsewhere: walrus operator, dict |= merge, star-unpack in
  display literals, decorator usage patterns.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "walrus operator (:=)" do
    test "in if condition" do
      check!("""
      data = [1, 2, 3, 4, 5]
      if (count := len(data)) > 3:
          print(f"has {count} items")
      """)
    end

    test "in while loop" do
      check!("""
      lines = ["a", "b", "", "c"]
      idx = [0]

      def next_line():
          if idx[0] >= len(lines):
              return ""
          result = lines[idx[0]]
          idx[0] += 1
          return result

      while (line := next_line()) != "":
          print(line)
      """)
    end

    test "in list comprehension" do
      check!("""
      result = [y for x in range(5) if (y := x * x) > 5]
      print(result)
      """)
    end
  end

  describe "dict |= merge operator" do
    test "mutates in place" do
      check!("""
      a = {"x": 1, "y": 2}
      b = {"y": 20, "z": 30}
      a |= b
      print(sorted(a.items()))
      """)
    end

    test "| produces new dict" do
      check!("""
      a = {"x": 1}
      b = {"y": 2}
      merged = a | b
      # original a unchanged
      print(sorted(a.items()))
      print(sorted(merged.items()))
      """)
    end
  end

  describe "star unpack in displays" do
    test "list literal" do
      check!("""
      a = [1, 2]
      b = [3, 4]
      print([*a, *b, 5])
      """)
    end

    test "set literal" do
      check!("""
      a = {1, 2}
      b = {3, 4}
      print(sorted({*a, *b, 5}))
      """)
    end

    test "tuple literal" do
      check!("""
      a = (1, 2)
      b = (3, 4)
      print((*a, *b, 5))
      """)
    end

    test "dict literal with **" do
      check!("""
      a = {"x": 1, "y": 2}
      b = {"z": 3}
      merged = {**a, **b, "w": 4}
      print(sorted(merged.items()))
      """)
    end

    test "override in dict merge" do
      check!("""
      a = {"x": 1, "y": 2}
      b = {"y": 20}
      print(sorted({**a, **b}.items()))
      """)
    end
  end

  describe "decorators" do
    test "property and setter" do
      check!("""
      class Temp:
          def __init__(self):
              self._c = 0

          @property
          def c(self):
              return self._c

          @c.setter
          def c(self, v):
              if v < -273.15:
                  raise ValueError("below absolute zero")
              self._c = v

      t = Temp()
      t.c = 25
      print(t.c)

      try:
          t.c = -300
      except ValueError as e:
          print("caught:", str(e))
      """)
    end

    test "staticmethod and classmethod" do
      check!("""
      class Greeting:
          greeting = "Hello"

          @staticmethod
          def exclaim(msg):
              return msg + "!"

          @classmethod
          def greet(cls, name):
              return f"{cls.greeting}, {name}"

      print(Greeting.exclaim("wow"))
      print(Greeting.greet("Alice"))
      """)
    end

    test "custom decorator with closure" do
      check!("""
      def repeat(n):
          def decorator(f):
              def wrapped(*args, **kwargs):
                  results = []
                  for _ in range(n):
                      results.append(f(*args, **kwargs))
                  return results
              return wrapped
          return decorator

      @repeat(3)
      def greet(name):
          return f"hi {name}"

      print(greet("world"))
      """)
    end
  end

  describe "advanced unpacking" do
    test "starred in middle of tuple assignment" do
      check!("""
      a, *middle, b = [1, 2, 3, 4, 5]
      print(a, middle, b)
      """)
    end

    test "star-unpack in function call" do
      check!("""
      def f(a, b, c): return a + b + c
      args = [1, 2, 3]
      print(f(*args))
      """)
    end

    test "double-star unpack in function call" do
      check!("""
      def f(a, b, c): return a + b * c
      kw = {"a": 1, "b": 2, "c": 3}
      print(f(**kw))
      """)
    end
  end
end
