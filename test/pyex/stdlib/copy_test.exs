defmodule Pyex.Stdlib.CopyTest do
  use ExUnit.Case, async: true

  describe "copy.copy" do
    test "shallow copy of list creates independent list" do
      result =
        Pyex.run!("""
        import copy
        a = [1, 2, 3]
        b = copy.copy(a)
        a.append(4)
        b
        """)

      assert result == [1, 2, 3]
    end

    test "shallow copy of dict creates independent dict" do
      result =
        Pyex.run!("""
        import copy
        a = {'x': 1, 'y': 2}
        b = copy.copy(a)
        a['z'] = 3
        b
        """)

      assert result == %{"x" => 1, "y" => 2}
    end

    test "copy of int returns same value" do
      assert Pyex.run!("import copy\ncopy.copy(42)") == 42
    end

    test "copy of string returns same value" do
      assert Pyex.run!("import copy\ncopy.copy('hello')") == "hello"
    end

    test "copy of tuple returns same value" do
      assert Pyex.run!("import copy\ncopy.copy((1, 2, 3))") == {:tuple, [1, 2, 3]}
    end

    test "shallow copy shares nested references" do
      result =
        Pyex.run!("""
        import copy
        a = [[1, 2]]
        b = copy.copy(a)
        a[0].append(3)
        b[0]
        """)

      assert result == [1, 2, 3]
    end
  end

  describe "copy.deepcopy" do
    test "deep copy of nested list creates fully independent copy" do
      result =
        Pyex.run!("""
        import copy
        a = [[1, 2], [3, 4]]
        b = copy.deepcopy(a)
        a[0].append(99)
        a.append([5])
        b
        """)

      assert result == [[1, 2], [3, 4]]
    end

    test "deep copy of dict with list values creates fully independent copy" do
      result =
        Pyex.run!("""
        import copy
        a = {'x': [1, 2], 'y': [3, 4]}
        b = copy.deepcopy(a)
        a['x'].append(99)
        b['x']
        """)

      assert result == [1, 2]
    end

    test "deep copy does NOT share nested references" do
      result =
        Pyex.run!("""
        import copy
        a = [[1, 2]]
        b = copy.deepcopy(a)
        a[0].append(3)
        b[0]
        """)

      assert result == [1, 2]
    end
  end
end
