defmodule Pyex.Conformance.CsvTest do
  @moduledoc """
  Live CPython conformance tests for the `csv` module.

  Pyex's `csv.reader` accepts any iterable of strings, matching CPython.
  `csv.writer` requires a file-like object; we use `io.StringIO` for
  parity with CPython.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "reader" do
    test "simple rows" do
      check!("""
      import csv
      rows = list(csv.reader(["a,b,c", "1,2,3", "4,5,6"]))
      print(rows)
      """)
    end

    test "quoted fields" do
      check!(~S"""
      import csv
      rows = list(csv.reader(['"a","b","c"', '"1","2","3"']))
      print(rows)
      """)
    end

    test "quoted field with embedded comma" do
      check!(~S"""
      import csv
      rows = list(csv.reader(['"hello, world",foo,bar']))
      print(rows)
      """)
    end

    test "quoted field with embedded quote (doubled)" do
      check!(~S"""
      import csv
      rows = list(csv.reader(['"he said ""hi\""",foo']))
      print(rows)
      """)
    end

    test "empty field" do
      check!("""
      import csv
      rows = list(csv.reader(["a,,c", ",,"]))
      print(rows)
      """)
    end

    test "trailing empty field" do
      check!("""
      import csv
      rows = list(csv.reader(["a,b,", "1,2,"]))
      print(rows)
      """)
    end

    test "single column" do
      check!("""
      import csv
      rows = list(csv.reader(["hello", "world"]))
      print(rows)
      """)
    end

    test "custom delimiter (tab)" do
      check!(~S"""
      import csv
      rows = list(csv.reader(["a\tb\tc", "1\t2\t3"], delimiter="\t"))
      print(rows)
      """)
    end

    test "custom delimiter (semicolon)" do
      check!("""
      import csv
      rows = list(csv.reader(["a;b;c"], delimiter=";"))
      print(rows)
      """)
    end
  end

  describe "DictReader" do
    test "with header inference" do
      check!("""
      import csv
      rows = list(csv.DictReader(["name,age", "alice,30", "bob,25"]))
      for r in rows:
          print(sorted(r.items()))
      """)
    end

    test "with explicit fieldnames" do
      check!("""
      import csv
      rows = list(csv.DictReader(["1,2,3", "4,5,6"], fieldnames=["a", "b", "c"]))
      for r in rows:
          print(sorted(r.items()))
      """)
    end

    test "quoted fields with DictReader" do
      check!(~S"""
      import csv
      rows = list(csv.DictReader(['name,note', 'alice,"quoted, value"']))
      for r in rows:
          print(sorted(r.items()))
      """)
    end
  end

  describe "roundtrip via splitlines" do
    test "reader consumes string lines" do
      check!("""
      import csv
      data = "a,b,c\\n1,2,3\\n"
      rows = list(csv.reader(data.splitlines()))
      print(rows)
      """)
    end
  end
end
