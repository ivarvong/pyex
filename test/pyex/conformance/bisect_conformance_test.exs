defmodule Pyex.Conformance.BisectTest do
  @moduledoc """
  Live CPython conformance tests for the `bisect` module.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "bisect_left" do
    for {label, args} <- [
          {"middle", "[1, 3, 5, 7], 4"},
          {"existing", "[1, 3, 5, 7], 3"},
          {"before start", "[1, 3, 5], 0"},
          {"after end", "[1, 3, 5], 10"},
          {"duplicates", "[1, 2, 2, 2, 3], 2"},
          {"empty", "[], 5"}
        ] do
      test "bisect_left #{label}" do
        check!("""
        import bisect
        print(bisect.bisect_left(#{unquote(args)}))
        """)
      end
    end
  end

  describe "bisect_right" do
    for {label, args} <- [
          {"middle", "[1, 3, 5, 7], 4"},
          {"existing", "[1, 3, 5, 7], 3"},
          {"duplicates", "[1, 2, 2, 2, 3], 2"},
          {"before start", "[1, 3, 5], 0"},
          {"after end", "[1, 3, 5], 10"}
        ] do
      test "bisect_right #{label}" do
        check!("""
        import bisect
        print(bisect.bisect_right(#{unquote(args)}))
        """)
      end
    end

    test "bisect alias" do
      check!("""
      import bisect
      print(bisect.bisect([1, 3, 5], 4))
      """)
    end
  end

  describe "insort" do
    test "insort keeps sorted" do
      check!("""
      import bisect
      xs = [1, 3, 5, 7]
      bisect.insort(xs, 4)
      print(xs)
      """)
    end

    test "insort_left at duplicate" do
      check!("""
      import bisect
      xs = [1, 2, 2, 2, 3]
      bisect.insort_left(xs, 2)
      print(xs)
      """)
    end

    test "insort_right at duplicate" do
      check!("""
      import bisect
      xs = [1, 2, 2, 2, 3]
      bisect.insort_right(xs, 2)
      print(xs)
      """)
    end

    test "insort at end" do
      check!("""
      import bisect
      xs = [1, 3, 5]
      bisect.insort(xs, 10)
      print(xs)
      """)
    end

    test "insort at start" do
      check!("""
      import bisect
      xs = [5, 10, 15]
      bisect.insort(xs, 0)
      print(xs)
      """)
    end
  end

  describe "bisect with lo/hi" do
    test "bounds slice of list" do
      check!("""
      import bisect
      xs = [0, 1, 2, 3, 4, 5, 6, 7]
      # search for 3 only in indices [2, 5)
      print(bisect.bisect_left(xs, 3, 2, 5))
      """)
    end
  end
end
