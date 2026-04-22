defmodule Pyex.Conformance.JSONTest do
  @moduledoc """
  Live CPython conformance tests for the `json` module.

  Covers `dumps`/`loads` defaults, indent/sort_keys/separators kwargs,
  nested structure handling, escape rules, and float/int edge cases.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "dumps basic types" do
    for {label, expr} <- [
          {"int", "42"},
          {"negative int", "-17"},
          {"zero", "0"},
          {"float", "3.14"},
          {"negative float", "-0.5"},
          {"tiny float", "1e-5"},
          {"big float", "1e20"},
          {"bool true", "True"},
          {"bool false", "False"},
          {"none", "None"},
          {"empty str", ~s|""|},
          {"ascii str", ~s|"hello"|},
          {"str with quote", ~S|"he said \"hi\""|},
          {"str with backslash", ~S|"path\\to\\file"|},
          {"str with newline", ~S|"a\nb"|},
          {"str with tab", ~S|"x\ty"|},
          {"empty list", "[]"},
          {"empty dict", "{}"},
          {"simple list", "[1, 2, 3]"},
          {"mixed list", "[1, \"two\", True, None]"},
          {"nested list", "[[1, 2], [3, 4]]"},
          {"simple dict", ~S|{"a": 1, "b": 2}|},
          {"nested dict", ~S|{"outer": {"inner": [1, 2]}}|}
        ] do
      test "dumps(#{label})" do
        check!("""
        import json
        print(json.dumps(#{unquote(expr)}))
        """)
      end
    end
  end

  describe "dumps kwargs" do
    test "indent=2" do
      check!("""
      import json
      print(json.dumps({"a": 1, "b": [2, 3]}, indent=2))
      """)
    end

    test "indent=4" do
      check!("""
      import json
      print(json.dumps({"nested": {"x": 1, "y": 2}}, indent=4))
      """)
    end

    test "sort_keys=True" do
      check!("""
      import json
      print(json.dumps({"z": 1, "a": 2, "m": 3}, sort_keys=True))
      """)
    end

    test "indent + sort_keys" do
      check!("""
      import json
      print(json.dumps({"z": 1, "a": 2}, indent=2, sort_keys=True))
      """)
    end

    test "separators compact" do
      check!("""
      import json
      print(json.dumps({"a": 1, "b": 2}, separators=(",", ":")))
      """)
    end

    test "ensure_ascii default escapes unicode" do
      check!("""
      import json
      print(json.dumps("café"))
      print(json.dumps("日本"))
      """)
    end

    test "ensure_ascii=False keeps unicode" do
      check!("""
      import json
      print(json.dumps("café", ensure_ascii=False))
      """)
    end
  end

  describe "loads basic types" do
    for {label, src} <- [
          {"int", "42"},
          {"float", "3.14"},
          {"exp", "1e5"},
          {"neg exp", "1e-5"},
          {"true", "true"},
          {"false", "false"},
          {"null", "null"},
          {"empty str", ~S|""|},
          {"ascii str", ~S|"hello"|},
          {"escaped quote", ~S|"he said \"hi\""|},
          {"escaped newline", ~S|"a\nb"|},
          {"unicode escape", ~S|"caf\u00e9"|},
          {"empty list", "[]"},
          {"empty obj", "{}"},
          {"simple list", "[1,2,3]"},
          {"nested", ~S|{"a":[1,{"b":2}]}|}
        ] do
      test "loads(#{label})" do
        check!("""
        import json
        print(repr(json.loads(#{unquote(inspect(src))})))
        """)
      end
    end
  end

  describe "roundtrip dumps -> loads" do
    cases = [
      "42",
      "3.14",
      "[1, 2, 3]",
      ~S|{"a": 1, "b": [2, 3]}|,
      ~S|{"nested": {"deeply": {"value": 42}}}|,
      ~S|[{"x": 1}, {"x": 2}, {"x": 3}]|,
      ~S|"hello world"|,
      ~S|"with \"quotes\""|
    ]

    for src <- cases do
      test "roundtrip #{src}" do
        check!("""
        import json
        original = #{unquote(src)}
        s = json.dumps(original)
        parsed = json.loads(s)
        print(parsed == original)
        print(repr(parsed))
        """)
      end
    end
  end

  describe "edge cases" do
    test "empty object vs empty list order preserved" do
      check!("""
      import json
      print(json.dumps({}))
      print(json.dumps([]))
      """)
    end

    test "key order preservation (insertion order)" do
      check!("""
      import json
      d = {}
      d["z"] = 1
      d["a"] = 2
      d["m"] = 3
      print(json.dumps(d))
      """)
    end

    test "float precision" do
      check!("""
      import json
      print(json.dumps(0.1 + 0.2))
      print(json.dumps(1/3))
      """)
    end

    test "large int" do
      check!("""
      import json
      print(json.dumps(10**18))
      """)
    end

    test "default separators (with spaces)" do
      check!("""
      import json
      # CPython default: ", " and ": "
      print(json.dumps({"a": 1, "b": 2}))
      print(json.dumps([1, 2, 3]))
      """)
    end

    test "indent=0 still inserts newlines" do
      check!("""
      import json
      print(json.dumps([1, 2], indent=0))
      """)
    end

    test "string with special control chars" do
      check!(~S"""
      import json
      print(json.dumps("\b\f\n\r\t"))
      """)
    end

    test "forward slash" do
      check!("""
      import json
      # CPython does NOT escape forward slashes by default
      print(json.dumps("a/b/c"))
      """)
    end
  end

  describe "loads errors" do
    for {label, src} <- [
          {"trailing comma list", "[1, 2, 3,]"},
          {"trailing comma dict", ~S|{"a": 1,}|},
          {"unclosed bracket", "[1, 2"},
          {"naked string", "hello"},
          {"single quotes", "'hi'"}
        ] do
      test "rejects #{label}" do
        check!("""
        import json
        try:
            json.loads(#{unquote(inspect(src))})
            print("no error")
        except Exception as e:
            print(type(e).__name__)
        """)
      end
    end
  end
end
