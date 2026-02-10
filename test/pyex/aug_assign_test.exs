defmodule Pyex.AugAssignTest do
  use ExUnit.Case, async: true

  describe "+=" do
    test "increment integer" do
      assert Pyex.run!("x = 10\nx += 5\nx") == 15
    end

    test "concatenate strings" do
      assert Pyex.run!("x = \"hello\"\nx += \" world\"\nx") == "hello world"
    end

    test "concatenate lists" do
      assert Pyex.run!("x = [1, 2]\nx += [3, 4]\nx") == [1, 2, 3, 4]
    end
  end

  describe "-=" do
    test "decrement integer" do
      assert Pyex.run!("x = 10\nx -= 3\nx") == 7
    end
  end

  describe "*=" do
    test "multiply integer" do
      assert Pyex.run!("x = 4\nx *= 3\nx") == 12
    end

    test "repeat string" do
      assert Pyex.run!("x = \"ab\"\nx *= 3\nx") == "ababab"
    end
  end

  describe "/=" do
    test "divide" do
      assert Pyex.run!("x = 10\nx /= 4\nx") == 2.5
    end
  end

  describe "//=" do
    test "floor divide" do
      assert Pyex.run!("x = 10\nx //= 3\nx") == 3
    end
  end

  describe "%=" do
    test "modulo" do
      assert Pyex.run!("x = 10\nx %= 3\nx") == 1
    end
  end

  describe "**=" do
    test "power" do
      assert Pyex.run!("x = 2\nx **= 10\nx") == 1024
    end
  end

  describe "augmented assignment in loops" do
    test "+= in for loop" do
      assert Pyex.run!("""
             total = 0
             for i in range(5):
               total += i
             total
             """) == 10
    end

    test "+= in while loop" do
      assert Pyex.run!("""
             x = 0
             while x < 10:
               x += 3
             x
             """) == 12
    end
  end
end
