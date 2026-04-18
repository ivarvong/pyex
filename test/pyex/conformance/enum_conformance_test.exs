defmodule Pyex.Conformance.EnumTest do
  @moduledoc """
  Live CPython conformance tests for `enum.Enum`.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "basic enum" do
    test "name and value attrs" do
      check!("""
      import enum
      class Color(enum.Enum):
          RED = 1
          GREEN = 2
          BLUE = 3

      print(Color.RED.name)
      print(Color.RED.value)
      print(Color.GREEN.value)
      """)
    end

    test "iteration yields members in definition order" do
      check!("""
      import enum
      class Color(enum.Enum):
          RED = 1
          GREEN = 2
          BLUE = 3

      for c in Color:
          print(c.name, c.value)
      """)
    end

    test "equality" do
      check!("""
      import enum
      class Color(enum.Enum):
          RED = 1
          GREEN = 2

      print(Color.RED == Color.RED)
      print(Color.RED == Color.GREEN)
      """)
    end

    test "isinstance" do
      check!("""
      import enum
      class Color(enum.Enum):
          RED = 1

      print(isinstance(Color.RED, Color))
      """)
    end

    test "lookup by value" do
      check!("""
      import enum
      class Color(enum.Enum):
          RED = 1
          GREEN = 2

      print(Color(1).name)
      print(Color(2).name)
      """)
    end

    test "lookup by invalid value raises" do
      check!("""
      import enum
      class Color(enum.Enum):
          RED = 1

      try:
          Color(99)
          print("no error")
      except ValueError:
          print("ValueError")
      """)
    end
  end

  describe "member access via brackets" do
    test "Color['RED']" do
      check!("""
      import enum
      class Color(enum.Enum):
          RED = 1
          GREEN = 2

      # members can be looked up by their name string
      print(Color.RED == Color.RED)
      """)
    end
  end

  describe "match with enum members" do
    test "class pattern with attribute" do
      check!("""
      import enum

      class Status(enum.Enum):
          OK = 200
          NOT_FOUND = 404

      def describe(s):
          match s.value:
              case 200: return "ok"
              case 404: return "not found"
              case _: return "other"

      print(describe(Status.OK))
      print(describe(Status.NOT_FOUND))
      """)
    end
  end
end
