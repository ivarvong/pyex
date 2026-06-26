defmodule Pyex.Stdlib.ImportlibTest do
  use ExUnit.Case, async: true

  defp run!(source) do
    {:ok, _value, ctx} = Pyex.run(source, filesystem: %{})
    Pyex.output(ctx)
  end

  describe "importlib.reload" do
    test "re-reads an edited module's value, bypassing the per-run import cache" do
      out =
        run!(~S"""
        import importlib
        with open("m.py", "w") as f:
            f.write("VALUE = 1\n")
        import m
        print(m.VALUE)
        with open("m.py", "w") as f:
            f.write("VALUE = 99\n")
        import m            # cache hit — still 1
        print(m.VALUE)
        m = importlib.reload(m)
        print(m.VALUE)      # re-read — 99
        """)

      assert out == "1\n1\n99\n"
    end

    test "re-executes an edited module's function definitions" do
      out =
        run!(~S"""
        import importlib
        with open("lib.py", "w") as f:
            f.write("def f():\n    return 'v1'\n")
        import lib
        print(lib.f())
        with open("lib.py", "w") as f:
            f.write("def f():\n    return 'v2'\n")
        print(importlib.reload(lib).f())
        """)

      assert out == "v1\nv2\n"
    end

    test "repopulates the cache so a later plain import sees the reloaded version" do
      out =
        run!(~S"""
        import importlib
        with open("m.py", "w") as f:
            f.write("V = 1\n")
        import m
        with open("m.py", "w") as f:
            f.write("V = 2\n")
        m = importlib.reload(m)
        import m            # cache now holds the reloaded module
        print(m.V)
        """)

      assert out == "2\n"
    end

    test "reloading a stdlib module returns it" do
      assert run!("import importlib, json\nprint(importlib.reload(json).dumps([1, 2]))") ==
               "[1, 2]\n"
    end

    test "rejects a non-module argument with TypeError" do
      {:error, err} = Pyex.run("import importlib\nimportlib.reload(5)", filesystem: %{})
      assert err.exception_type == "TypeError"
    end

    test "surfaces an error when the edited source no longer compiles" do
      out =
        run!(~S"""
        import importlib
        with open("m.py", "w") as f:
            f.write("V = 1\n")
        import m
        with open("m.py", "w") as f:
            f.write("def broken(\n")
        try:
            importlib.reload(m)
        except SyntaxError:
            print("SyntaxError")
        """)

      assert out == "SyntaxError\n"
    end
  end

  describe "importlib.invalidate_caches" do
    test "is a no-op that does not evict already-imported modules (CPython parity)" do
      out =
        run!(~S"""
        import importlib
        with open("m.py", "w") as f:
            f.write("V = 1\n")
        import m
        with open("m.py", "w") as f:
            f.write("V = 2\n")
        importlib.invalidate_caches()
        import m            # cached — invalidate_caches does NOT force a re-read
        print(m.V)
        """)

      assert out == "1\n"
    end

    test "returns None" do
      assert run!("import importlib\nprint(importlib.invalidate_caches())") == "None\n"
    end
  end
end
