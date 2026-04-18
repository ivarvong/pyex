defmodule Pyex.Conformance.MatchCaseTest do
  @moduledoc """
  Live CPython conformance tests for Python 3.10+ `match`/`case`
  structural pattern matching.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "literal patterns" do
    test "int literal" do
      check!("""
      for x in [1, 2, 3]:
          match x:
              case 1: print("one")
              case 2: print("two")
              case _: print("other")
      """)
    end

    test "string literal" do
      check!(~S"""
      for name in ["alice", "bob", "eve"]:
          match name:
              case "alice": print("hi alice")
              case "bob": print("hi bob")
              case _: print("stranger")
      """)
    end

    test "None / True / False" do
      check!("""
      for v in [None, True, False, 1]:
          match v:
              case None: print("none")
              case True: print("yes")
              case False: print("no")
              case _: print("other")
      """)
    end

    test "negative numbers" do
      check!("""
      for x in [-5, 0, 5]:
          match x:
              case -5: print("neg")
              case 0: print("zero")
              case _: print("other")
      """)
    end
  end

  describe "capture pattern" do
    test "bind name" do
      check!("""
      x = 42
      match x:
          case y:
              print(f"captured {y}")
      """)
    end

    test "wildcard doesn't bind" do
      check!("""
      match 42:
          case _:
              print("matched wildcard")
      """)
    end
  end

  describe "or pattern" do
    test "multiple alternatives" do
      check!("""
      for x in [1, 2, 3, 4]:
          match x:
              case 1 | 2: print("small")
              case 3 | 4: print("big")
              case _: print("other")
      """)
    end
  end

  describe "sequence patterns" do
    test "list pattern" do
      check!("""
      for xs in [[1, 2], [1, 2, 3], [], [5]]:
          match xs:
              case [1, 2]: print("exactly two")
              case [1, 2, _]: print("three starting 1, 2")
              case []: print("empty")
              case [single]: print(f"single {single}")
      """)
    end

    test "tuple pattern" do
      check!("""
      point = (3, 4)
      match point:
          case (0, 0): print("origin")
          case (x, 0): print(f"on x axis at {x}")
          case (0, y): print(f"on y axis at {y}")
          case (x, y): print(f"point ({x}, {y})")
      """)
    end

    test "star pattern" do
      check!("""
      for xs in [[1], [1, 2, 3, 4], [1, 2]]:
          match xs:
              case [first, *rest]: print(f"first={first} rest={rest}")
      """)
    end

    test "star with wildcard name" do
      check!("""
      match [1, 2, 3, 4, 5]:
          case [first, *_, last]: print(f"first={first} last={last}")
      """)
    end
  end

  describe "mapping patterns" do
    test "exact keys" do
      check!(~S"""
      d = {"status": "ok", "code": 200}
      match d:
          case {"status": "ok", "code": 200}: print("ok")
          case {"status": "error"}: print("error")
          case _: print("other")
      """)
    end

    test "capture values" do
      check!(~S"""
      d = {"name": "alice", "age": 30}
      match d:
          case {"name": n, "age": a}: print(f"{n} is {a}")
      """)
    end
  end

  describe "guards" do
    test "if guard" do
      check!("""
      for x in [-1, 0, 5]:
          match x:
              case n if n < 0: print(f"negative {n}")
              case 0: print("zero")
              case n: print(f"positive {n}")
      """)
    end
  end

  describe "class patterns" do
    test "class with attributes" do
      check!("""
      class Point:
          __match_args__ = ("x", "y")
          def __init__(self, x, y):
              self.x = x
              self.y = y

      p = Point(0, 5)
      match p:
          case Point(0, 0): print("origin")
          case Point(0, y): print(f"y axis {y}")
          case Point(x, 0): print(f"x axis {x}")
          case Point(x, y): print(f"point {x} {y}")
      """)
    end
  end

  describe "real-world" do
    test "command dispatch" do
      check!("""
      def handle(cmd):
          match cmd:
              case {"action": "greet", "name": name}:
                  return f"Hello, {name}"
              case {"action": "add", "a": a, "b": b}:
                  return a + b
              case {"action": "quit"}:
                  return "bye"
              case _:
                  return "unknown"

      print(handle({"action": "greet", "name": "world"}))
      print(handle({"action": "add", "a": 2, "b": 3}))
      print(handle({"action": "quit"}))
      print(handle({"foo": "bar"}))
      """)
    end

    test "http status code routing" do
      check!("""
      for code in [200, 404, 500, 302]:
          match code:
              case 200: print("ok")
              case 301 | 302 | 303: print("redirect")
              case 404: print("not found")
              case n if 500 <= n < 600: print(f"server error {n}")
              case _: print("other")
      """)
    end
  end
end
