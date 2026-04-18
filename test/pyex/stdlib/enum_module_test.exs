defmodule Pyex.Stdlib.EnumModuleTest do
  use ExUnit.Case, async: true

  describe "basic enum" do
    test "class attribute returns enum member (not raw value)" do
      result =
        Pyex.run!("""
        from enum import Enum
        class Color(Enum):
            RED = 1
            GREEN = 2
            BLUE = 3
        Color.RED.value
        """)

      assert result == 1
    end

    test "enum member has .name" do
      result =
        Pyex.run!("""
        from enum import Enum
        class Color(Enum):
            RED = 1
        Color.RED.name
        """)

      assert result == "RED"
    end

    test "multiple enum values are distinct" do
      result =
        Pyex.run!("""
        from enum import Enum
        class Color(Enum):
            RED = 1
            GREEN = 2
            BLUE = 3
        (Color.RED.value, Color.GREEN.value, Color.BLUE.value)
        """)

      assert result == {:tuple, [1, 2, 3]}
    end
  end

  describe "IntEnum" do
    test "IntEnum members have integer values" do
      result =
        Pyex.run!("""
        from enum import IntEnum
        class Status(IntEnum):
            OK = 200
            NOT_FOUND = 404
        Status.OK.value
        """)

      assert result == 200
    end
  end

  describe "auto()" do
    test "auto() returns incrementing distinct values" do
      result =
        Pyex.run!("""
        from enum import Enum, auto
        class Direction(Enum):
            NORTH = auto()
            SOUTH = auto()
        Direction.NORTH != Direction.SOUTH
        """)

      assert result == true
    end

    test "auto() values are accessible as class attributes" do
      result =
        Pyex.run!("""
        from enum import Enum, auto
        class Direction(Enum):
            NORTH = auto()
            SOUTH = auto()
            EAST = auto()
        (Direction.NORTH.value, Direction.SOUTH.value, Direction.EAST.value)
        """)

      {_, [a, b, c]} = result
      assert is_integer(a)
      assert is_integer(b)
      assert is_integer(c)
      assert a != b
      assert b != c
      assert a != c
    end
  end

  describe "imports" do
    test "from enum import Enum, IntEnum, auto does not crash" do
      Pyex.run!("from enum import Enum, IntEnum, auto")
    end

    test "from enum import unique does not crash" do
      Pyex.run!("from enum import unique")
    end
  end
end
