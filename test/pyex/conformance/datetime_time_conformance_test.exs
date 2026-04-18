defmodule Pyex.Conformance.DatetimeTimeTest do
  @moduledoc """
  Live CPython conformance tests for `datetime.time`.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "constructor" do
    for {label, args} <- [
          {"default", "0"},
          {"hour only", "12"},
          {"hour minute", "12, 30"},
          {"with second", "12, 30, 45"},
          {"with us", "12, 30, 45, 123456"}
        ] do
      test "time(#{args})" do
        args = unquote(args)

        check!("""
        from datetime import time
        t = time(#{args})
        print(t.hour, t.minute, t.second, t.microsecond)
        """)
      end
    end
  end

  describe "isoformat" do
    for {label, args, expected} <- [
          {"basic", "12, 30", "12:30:00"},
          {"with sec", "12, 30, 45", "12:30:45"},
          {"with us", "12, 30, 45, 123456", "12:30:45.123456"},
          {"zero", "0, 0, 0", "00:00:00"}
        ] do
      test "isoformat #{label}" do
        check!("""
        from datetime import time
        print(time(#{unquote(args)}).isoformat())
        """)
      end
    end
  end

  describe "repr matches CPython" do
    test "minute only" do
      check!("from datetime import time\nprint(repr(time(12, 30)))")
    end

    test "with seconds" do
      check!("from datetime import time\nprint(repr(time(12, 30, 45)))")
    end

    test "with microseconds" do
      check!("from datetime import time\nprint(repr(time(12, 30, 45, 123456)))")
    end
  end

  describe "comparisons" do
    test "eq" do
      check!("""
      from datetime import time
      print(time(12, 30) == time(12, 30))
      print(time(12, 30) == time(12, 31))
      """)
    end

    test "ordering" do
      check!("""
      from datetime import time
      print(time(9, 0) < time(12, 30))
      print(time(23, 59) > time(0, 0))
      """)
    end
  end

  describe "replace" do
    test "replace hour" do
      check!("""
      from datetime import time
      t = time(12, 30, 45)
      print(t.replace(hour=15).isoformat())
      """)
    end

    test "replace microsecond" do
      check!("""
      from datetime import time
      t = time(12, 30, 45)
      print(t.replace(microsecond=500000).isoformat())
      """)
    end
  end

  describe "fromisoformat" do
    for s <- ["12:30", "12:30:45", "12:30:45.123456"] do
      test "fromisoformat(#{s})" do
        check!("""
        from datetime import time
        print(time.fromisoformat(#{inspect(unquote(s))}).isoformat())
        """)
      end
    end
  end

  describe "class singletons" do
    test "time.min" do
      check!("""
      from datetime import time
      print(time.min.isoformat())
      """)
    end

    test "time.max" do
      check!("""
      from datetime import time
      print(time.max.isoformat())
      """)
    end
  end

  describe "validation" do
    test "hour out of range raises" do
      check!("""
      from datetime import time
      try:
          time(25, 0)
          print("no error")
      except ValueError:
          print("ValueError")
      """)
    end
  end
end
