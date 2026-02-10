defmodule Pyex.Stdlib.CsvTest do
  use ExUnit.Case, async: true

  describe "csv.reader" do
    test "parses simple CSV lines" do
      assert Pyex.run!("""
             import csv
             rows = list(csv.reader(["name,age,city", "Alice,30,NYC"]))
             rows
             """) == [["name", "age", "city"], ["Alice", "30", "NYC"]]
    end

    test "parses quoted fields" do
      assert Pyex.run!("""
             import csv
             rows = list(csv.reader(['a,"b,c",d']))
             rows
             """) == [["a", "b,c", "d"]]
    end

    test "handles doubled quotes inside quoted fields" do
      assert Pyex.run!("""
             import csv
             rows = list(csv.reader(['a,"he said ""hi\""",b']))
             rows
             """) == [["a", "he said \"hi\"", "b"]]
    end

    test "handles empty fields" do
      assert Pyex.run!("""
             import csv
             rows = list(csv.reader(["a,,b"]))
             rows
             """) == [["a", "", "b"]]
    end

    test "handles single column" do
      assert Pyex.run!("""
             import csv
             rows = list(csv.reader(["hello"]))
             rows
             """) == [["hello"]]
    end

    test "handles empty input" do
      assert Pyex.run!("""
             import csv
             rows = list(csv.reader([]))
             rows
             """) == []
    end

    test "handles newline inside quoted field" do
      result =
        Pyex.run!("""
        import csv
        rows = list(csv.reader(['a,"line1\\nline2",b']))
        rows
        """)

      assert result == [["a", "line1\nline2", "b"]]
    end

    test "custom delimiter" do
      assert Pyex.run!("""
             import csv
             rows = list(csv.reader(["a;b;c"], delimiter=";"))
             rows
             """) == [["a", "b", "c"]]
    end

    test "custom quotechar" do
      assert Pyex.run!("""
             import csv
             rows = list(csv.reader(["a|'b,c'|d"], delimiter="|", quotechar="'"))
             rows
             """) == [["a", "b,c", "d"]]
    end

    test "tab delimiter" do
      assert Pyex.run!("""
             import csv
             rows = list(csv.reader(["a\\tb\\tc"], delimiter="\\t"))
             rows
             """) == [["a", "b", "c"]]
    end

    test "iterating with for loop" do
      result =
        Pyex.run!("""
        import csv
        result = []
        for row in csv.reader(["x,y", "1,2", "3,4"]):
            result.append(row[0])
        result
        """)

      assert result == ["x", "1", "3"]
    end

    test "empty quoted field" do
      assert Pyex.run!("""
             import csv
             rows = list(csv.reader(['a,"",b']))
             rows
             """) == [["a", "", "b"]]
    end

    test "strips trailing line endings" do
      assert Pyex.run!("""
             import csv
             rows = list(csv.reader(["a,b,c\\r\\n"]))
             rows
             """) == [["a", "b", "c"]]
    end
  end

  describe "csv.DictReader" do
    test "auto-detects headers from first row" do
      result =
        Pyex.run!("""
        import csv
        rows = list(csv.DictReader(["name,age", "Alice,30", "Bob,25"]))
        rows
        """)

      assert result == [
               %{"name" => "Alice", "age" => "30"},
               %{"name" => "Bob", "age" => "25"}
             ]
    end

    test "uses provided fieldnames" do
      result =
        Pyex.run!("""
        import csv
        rows = list(csv.DictReader(["Alice,30", "Bob,25"], fieldnames=["name", "age"]))
        rows
        """)

      assert result == [
               %{"name" => "Alice", "age" => "30"},
               %{"name" => "Bob", "age" => "25"}
             ]
    end

    test "fills missing fields with restval" do
      result =
        Pyex.run!("""
        import csv
        rows = list(csv.DictReader(["name,age,city", "Alice,30"], restval="N/A"))
        rows
        """)

      assert result == [%{"name" => "Alice", "age" => "30", "city" => "N/A"}]
    end

    test "stores extra fields under restkey" do
      result =
        Pyex.run!("""
        import csv
        rows = list(csv.DictReader(["name,age", "Alice,30,NYC,extra"], restkey="overflow"))
        rows
        """)

      assert result == [
               %{"name" => "Alice", "age" => "30", "overflow" => ["NYC", "extra"]}
             ]
    end

    test "empty input" do
      assert Pyex.run!("""
             import csv
             rows = list(csv.DictReader([]))
             rows
             """) == []
    end

    test "header only, no data rows" do
      assert Pyex.run!("""
             import csv
             rows = list(csv.DictReader(["name,age"]))
             rows
             """) == []
    end

    test "custom delimiter" do
      result =
        Pyex.run!("""
        import csv
        rows = list(csv.DictReader(["name;age", "Alice;30"], delimiter=";"))
        rows
        """)

      assert result == [%{"name" => "Alice", "age" => "30"}]
    end

    test "iteration with for loop and field access" do
      result =
        Pyex.run!("""
        import csv
        names = []
        for row in csv.DictReader(["name,age", "Alice,30", "Bob,25"]):
            names.append(row["name"])
        names
        """)

      assert result == ["Alice", "Bob"]
    end
  end

  describe "csv.writer" do
    test "writerow formats a simple row" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer()
        w.writerow(["Alice", "30", "NYC"])
        """)

      assert result == "Alice,30,NYC\r\n"
    end

    test "writerow quotes fields containing delimiter" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer()
        w.writerow(["hello, world", "test"])
        """)

      assert result == "\"hello, world\",test\r\n"
    end

    test "writerow quotes fields containing quotechar" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer()
        w.writerow(['he said "hi"', "ok"])
        """)

      assert result == "\"he said \"\"hi\"\"\",ok\r\n"
    end

    test "writerow quotes fields containing newline" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer()
        w.writerow(["line1\\nline2", "ok"])
        """)

      assert result == "\"line1\nline2\",ok\r\n"
    end

    test "writerow handles numeric values" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer()
        w.writerow(["Alice", 30, 1.5])
        """)

      assert result == "Alice,30,1.5\r\n"
    end

    test "writerow handles None" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer()
        w.writerow(["Alice", None, "NYC"])
        """)

      assert result == "Alice,,NYC\r\n"
    end

    test "writerow handles boolean values" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer()
        w.writerow([True, False])
        """)

      assert result == "True,False\r\n"
    end

    test "writerow with tuple" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer()
        w.writerow(("a", "b", "c"))
        """)

      assert result == "a,b,c\r\n"
    end

    test "writerows formats multiple rows" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer()
        w.writerows([["a", "b"], ["c", "d"]])
        """)

      assert result == "a,b\r\nc,d\r\n"
    end

    test "custom delimiter" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer(delimiter=";")
        w.writerow(["a", "b", "c"])
        """)

      assert result == "a;b;c\r\n"
    end

    test "QUOTE_ALL quotes every field" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer(quoting=csv.QUOTE_ALL)
        w.writerow(["a", "b"])
        """)

      assert result == "\"a\",\"b\"\r\n"
    end

    test "QUOTE_NONNUMERIC quotes only non-numeric" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer(quoting=csv.QUOTE_NONNUMERIC)
        w.writerow(["hello", 42])
        """)

      assert result == "\"hello\",42\r\n"
    end

    test "QUOTE_NONE never quotes" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer(quoting=csv.QUOTE_NONE)
        w.writerow(["a", "b"])
        """)

      assert result == "a,b\r\n"
    end

    test "custom lineterminator" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer(lineterminator="\\n")
        w.writerow(["a", "b"])
        """)

      assert result == "a,b\n"
    end
  end

  describe "csv.DictWriter" do
    test "writeheader writes field names" do
      result =
        Pyex.run!("""
        import csv
        w = csv.DictWriter(["name", "age"])
        w.writeheader()
        """)

      assert result == "name,age\r\n"
    end

    test "writerow maps dict keys to fieldnames order" do
      result =
        Pyex.run!("""
        import csv
        w = csv.DictWriter(["name", "age"])
        w.writerow({"name": "Alice", "age": "30"})
        """)

      assert result == "Alice,30\r\n"
    end

    test "writerow uses restval for missing keys" do
      result =
        Pyex.run!("""
        import csv
        w = csv.DictWriter(["name", "age", "city"], restval="N/A")
        w.writerow({"name": "Alice"})
        """)

      assert result == "Alice,N/A,N/A\r\n"
    end

    test "writerow raises on extra keys by default" do
      assert_raise RuntimeError, ~r/ValueError.*not in fieldnames/, fn ->
        Pyex.run!("""
        import csv
        w = csv.DictWriter(["name"])
        w.writerow({"name": "Alice", "extra": "value"})
        """)
      end
    end

    test "writerow ignores extra keys when extrasaction is ignore" do
      result =
        Pyex.run!("""
        import csv
        w = csv.DictWriter(["name"], extrasaction="ignore")
        w.writerow({"name": "Alice", "extra": "value"})
        """)

      assert result == "Alice\r\n"
    end

    test "writerows formats multiple dicts" do
      result =
        Pyex.run!("""
        import csv
        w = csv.DictWriter(["name", "age"])
        w.writerows([{"name": "Alice", "age": "30"}, {"name": "Bob", "age": "25"}])
        """)

      assert result == "Alice,30\r\nBob,25\r\n"
    end

    test "custom delimiter" do
      result =
        Pyex.run!("""
        import csv
        w = csv.DictWriter(["a", "b"], delimiter=";")
        w.writerow({"a": "1", "b": "2"})
        """)

      assert result == "1;2\r\n"
    end

    test "writeheader then writerows" do
      result =
        Pyex.run!("""
        import csv
        w = csv.DictWriter(["name", "age"])
        header = w.writeheader()
        body = w.writerows([{"name": "Alice", "age": "30"}])
        header + body
        """)

      assert result == "name,age\r\nAlice,30\r\n"
    end
  end

  describe "quoting constants" do
    test "constants have correct integer values" do
      result =
        Pyex.run!("""
        import csv
        (csv.QUOTE_MINIMAL, csv.QUOTE_ALL, csv.QUOTE_NONNUMERIC, csv.QUOTE_NONE)
        """)

      assert result == {:tuple, [0, 1, 2, 3]}
    end
  end

  describe "roundtrip" do
    test "write then read produces original data" do
      result =
        Pyex.run!("""
        import csv
        data = [["name", "age"], ["Alice", "30"], ["Bob", "25"]]
        w = csv.writer()
        lines = []
        for row in data:
            lines.append(w.writerow(row))
        parsed = list(csv.reader(lines))
        parsed
        """)

      assert result == [["name", "age"], ["Alice", "30"], ["Bob", "25"]]
    end

    test "DictWriter then DictReader roundtrip" do
      result =
        Pyex.run!("""
        import csv
        fieldnames = ["name", "age"]
        w = csv.DictWriter(fieldnames)
        lines = [w.writeheader()]
        rows = [{"name": "Alice", "age": "30"}, {"name": "Bob", "age": "25"}]
        for row in rows:
            lines.append(w.writerow(row))
        parsed = list(csv.DictReader(lines))
        parsed
        """)

      assert result == [
               %{"name" => "Alice", "age" => "30"},
               %{"name" => "Bob", "age" => "25"}
             ]
    end

    test "quoted fields survive roundtrip" do
      result =
        Pyex.run!("""
        import csv
        w = csv.writer()
        line = w.writerow(["hello, world", 'say "hi"', "line1\\nline2"])
        parsed = list(csv.reader([line]))
        parsed[0]
        """)

      assert result == ["hello, world", "say \"hi\"", "line1\nline2"]
    end
  end

  describe "from_import" do
    test "from csv import reader" do
      result =
        Pyex.run!("""
        from csv import reader
        list(reader(["a,b", "1,2"]))
        """)

      assert result == [["a", "b"], ["1", "2"]]
    end

    test "from csv import DictReader" do
      result =
        Pyex.run!("""
        from csv import DictReader
        list(DictReader(["name,age", "Alice,30"]))
        """)

      assert result == [%{"name" => "Alice", "age" => "30"}]
    end

    test "from csv import QUOTE_ALL" do
      assert Pyex.run!("""
             from csv import QUOTE_ALL
             QUOTE_ALL
             """) == 1
    end
  end

  describe "error handling" do
    test "reader with non-list argument" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!("""
        import csv
        csv.reader(42)
        """)
      end
    end

    test "DictReader with non-list argument" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!("""
        import csv
        csv.DictReader(42)
        """)
      end
    end

    test "DictWriter with non-list fieldnames" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!("""
        import csv
        csv.DictWriter(42)
        """)
      end
    end
  end

  describe "file I/O" do
    @fs_opts [
      filesystem: Pyex.Filesystem.Memory.new(),
      fs_module: Pyex.Filesystem.Memory
    ]

    defp fs_with_file(path, content) do
      fs = Pyex.Filesystem.Memory.new()
      {:ok, fs} = Pyex.Filesystem.Memory.write(fs, path, content, :write)
      [filesystem: fs, fs_module: Pyex.Filesystem.Memory]
    end

    test "csv.reader reads from file handle" do
      opts = fs_with_file("data.csv", "name,age\nAlice,30\nBob,25\n")

      result =
        Pyex.run!(
          """
          import csv
          f = open("data.csv")
          rows = list(csv.reader(f))
          f.close()
          rows
          """,
          opts
        )

      assert result == [["name", "age"], ["Alice", "30"], ["Bob", "25"]]
    end

    test "csv.DictReader reads from file handle" do
      opts = fs_with_file("data.csv", "name,age\nAlice,30\nBob,25\n")

      result =
        Pyex.run!(
          """
          import csv
          f = open("data.csv")
          rows = list(csv.DictReader(f))
          f.close()
          rows
          """,
          opts
        )

      assert result == [
               %{"name" => "Alice", "age" => "30"},
               %{"name" => "Bob", "age" => "25"}
             ]
    end

    test "csv.writer writes to file handle" do
      {:ok, _result, ctx} =
        Pyex.run(
          """
          import csv
          f = open("output.csv", "w")
          writer = csv.writer(f)
          writer.writerow(["name", "age"])
          writer.writerow(["Alice", "30"])
          f.close()
          """,
          @fs_opts
        )

      assert {:ok, "name,age\r\nAlice,30\r\n"} =
               Pyex.Filesystem.Memory.read(ctx.filesystem, "output.csv")
    end

    test "csv.writer writerow returns the formatted line" do
      result =
        Pyex.run!(
          """
          import csv
          f = open("output.csv", "w")
          writer = csv.writer(f)
          line = writer.writerow(["a", "b"])
          f.close()
          line
          """,
          @fs_opts
        )

      assert result == "a,b\r\n"
    end

    test "csv.DictWriter writes to file handle" do
      {:ok, _result, ctx} =
        Pyex.run(
          """
          import csv
          f = open("output.csv", "w")
          writer = csv.DictWriter(f, ["name", "age"])
          writer.writeheader()
          writer.writerow({"name": "Alice", "age": "30"})
          f.close()
          """,
          @fs_opts
        )

      assert {:ok, "name,age\r\nAlice,30\r\n"} =
               Pyex.Filesystem.Memory.read(ctx.filesystem, "output.csv")
    end

    test "full file roundtrip: write then read" do
      result =
        Pyex.run!(
          """
          import csv
          f = open("data.csv", "w")
          writer = csv.writer(f)
          writer.writerow(["name", "age"])
          writer.writerow(["Alice", "30"])
          writer.writerow(["Bob", "25"])
          f.close()

          f = open("data.csv")
          rows = list(csv.reader(f))
          f.close()
          rows
          """,
          @fs_opts
        )

      assert result == [["name", "age"], ["Alice", "30"], ["Bob", "25"]]
    end

    test "DictWriter + DictReader file roundtrip" do
      result =
        Pyex.run!(
          """
          import csv
          f = open("data.csv", "w")
          writer = csv.DictWriter(f, ["name", "age"])
          writer.writeheader()
          writer.writerow({"name": "Alice", "age": "30"})
          writer.writerow({"name": "Bob", "age": "25"})
          f.close()

          f = open("data.csv")
          rows = list(csv.DictReader(f))
          f.close()
          rows
          """,
          @fs_opts
        )

      assert result == [
               %{"name" => "Alice", "age" => "30"},
               %{"name" => "Bob", "age" => "25"}
             ]
    end

    test "csv.reader with file handle and custom delimiter" do
      opts = fs_with_file("data.tsv", "name\tage\nAlice\t30\n")

      result =
        Pyex.run!(
          """
          import csv
          f = open("data.tsv")
          rows = list(csv.reader(f, delimiter="\\t"))
          f.close()
          rows
          """,
          opts
        )

      assert result == [["name", "age"], ["Alice", "30"]]
    end

    test "csv.writer writerows writes all rows to file" do
      {:ok, _result, ctx} =
        Pyex.run(
          """
          import csv
          f = open("output.csv", "w")
          writer = csv.writer(f)
          writer.writerows([["a", "b"], ["c", "d"]])
          f.close()
          """,
          @fs_opts
        )

      assert {:ok, "a,b\r\nc,d\r\n"} =
               Pyex.Filesystem.Memory.read(ctx.filesystem, "output.csv")
    end
  end

  describe "edge cases" do
    test "single empty string produces one empty field" do
      assert Pyex.run!("""
             import csv
             list(csv.reader([""]))
             """) == [[""]]
    end

    test "handles whitespace-only fields" do
      assert Pyex.run!("""
             import csv
             list(csv.reader(["  , ,  "]))
             """) == [["  ", " ", "  "]]
    end

    test "handles very long rows" do
      result =
        Pyex.run!("""
        import csv
        row = ",".join([str(i) for i in range(100)])
        rows = list(csv.reader([row]))
        len(rows[0])
        """)

      assert result == 100
    end
  end
end
