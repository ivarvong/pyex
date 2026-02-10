defmodule Pyex.MatchCaseTest do
  use ExUnit.Case, async: true

  describe "match/case" do
    test "literal integer matching" do
      code = """
      x = 2
      match x:
          case 1:
              result = "one"
          case 2:
              result = "two"
          case 3:
              result = "three"
      result
      """

      assert Pyex.run!(code) == "two"
    end

    test "literal string matching" do
      code = """
      cmd = "quit"
      match cmd:
          case "start":
              result = 1
          case "quit":
              result = 2
      result
      """

      assert Pyex.run!(code) == 2
    end

    test "wildcard pattern" do
      code = """
      x = 99
      match x:
          case 1:
              result = "one"
          case _:
              result = "other"
      result
      """

      assert Pyex.run!(code) == "other"
    end

    test "capture pattern" do
      code = """
      x = 42
      match x:
          case n:
              result = n * 2
      result
      """

      assert Pyex.run!(code) == 84
    end

    test "OR pattern" do
      code = """
      x = 2
      match x:
          case 1 | 2 | 3:
              result = "small"
          case _:
              result = "big"
      result
      """

      assert Pyex.run!(code) == "small"
    end

    test "guard clause" do
      code = """
      x = 15
      match x:
          case n if n < 0:
              result = "negative"
          case n if n < 10:
              result = "small"
          case n if n < 100:
              result = "medium"
          case _:
              result = "large"
      result
      """

      assert Pyex.run!(code) == "medium"
    end

    test "sequence pattern with list" do
      code = """
      point = [1, 2]
      match point:
          case [0, 0]:
              result = "origin"
          case [x, 0]:
              result = f"x-axis at {x}"
          case [0, y]:
              result = f"y-axis at {y}"
          case [x, y]:
              result = f"point at {x},{y}"
      result
      """

      assert Pyex.run!(code) == "point at 1,2"
    end

    test "sequence pattern with tuple" do
      code = """
      point = (0, 5)
      match point:
          case (0, 0):
              result = "origin"
          case (0, y):
              result = f"y-axis at {y}"
          case (x, y):
              result = f"point at {x},{y}"
      result
      """

      assert Pyex.run!(code) == "y-axis at 5"
    end

    test "mapping pattern" do
      code = """
      data = {"action": "move", "x": 10, "y": 20}
      match data:
          case {"action": "move", "x": x, "y": y}:
              result = f"move to {x},{y}"
          case {"action": "stop"}:
              result = "stopping"
      result
      """

      assert Pyex.run!(code) == "move to 10,20"
    end

    test "no match returns None" do
      code = """
      x = 99
      match x:
          case 1:
              result = "one"
          case 2:
              result = "two"
      """

      assert Pyex.run!(code) == nil
    end

    test "None pattern" do
      code = """
      x = None
      match x:
          case None:
              result = "nothing"
          case _:
              result = "something"
      result
      """

      assert Pyex.run!(code) == "nothing"
    end

    test "boolean patterns" do
      code = """
      x = True
      match x:
          case True:
              result = "yes"
          case False:
              result = "no"
      result
      """

      assert Pyex.run!(code) == "yes"
    end

    test "star capture in sequence" do
      code = """
      items = [1, 2, 3, 4, 5]
      match items:
          case [first, *rest]:
              result = [first, rest]
      result
      """

      assert Pyex.run!(code) == [1, [2, 3, 4, 5]]
    end

    test "star wildcard in sequence" do
      code = """
      items = [1, 2, 3, 4, 5]
      match items:
          case [first, second, *_]:
              result = first + second
      result
      """

      assert Pyex.run!(code) == 3
    end

    test "negative number pattern" do
      code = """
      x = -1
      match x:
          case -1:
              result = "neg one"
          case 0:
              result = "zero"
          case 1:
              result = "one"
      result
      """

      assert Pyex.run!(code) == "neg one"
    end

    test "match as soft keyword in assignment" do
      code = """
      match = 5
      match
      """

      assert Pyex.run!(code) == 5
    end

    test "nested sequence patterns" do
      code = """
      data = [[1, 2], [3, 4]]
      match data:
          case [[a, b], [c, d]]:
              result = a + b + c + d
      result
      """

      assert Pyex.run!(code) == 10
    end

    test "match with class pattern" do
      code = """
      class Point:
          def __init__(self, x, y):
              self.x = x
              self.y = y

      p = Point(3, 4)
      match p:
          case Point(x=0, y=0):
              result = "origin"
          case Point(x=x, y=y):
              result = f"({x}, {y})"
      result
      """

      assert Pyex.run!(code) == "(3, 4)"
    end

    test "match with function call subject" do
      code = """
      def get_status():
          return "ok"

      match get_status():
          case "ok":
              result = 200
          case "error":
              result = 500
      result
      """

      assert Pyex.run!(code) == 200
    end

    test "match with float pattern" do
      code = """
      x = 3.14
      match x:
          case 3.14:
              result = "pi"
          case _:
              result = "other"
      result
      """

      assert Pyex.run!(code) == "pi"
    end
  end
end
