defmodule Pyex.Stdlib.JsonTest do
  use ExUnit.Case, async: true

  alias Pyex.Error

  describe "json.loads" do
    test "parses a JSON array" do
      result =
        Pyex.run!("""
        import json
        json.loads("[1, 2, 3]")
        """)

      assert result == [1, 2, 3]
    end

    test "parses a JSON object" do
      result =
        Pyex.run!("""
        import json
        json.loads('{"name": "test", "value": 42}')
        """)

      assert result == %{"name" => "test", "value" => 42}
    end

    test "raises on invalid JSON" do
      assert_raise RuntimeError, ~r/json\.loads failed/, fn ->
        Pyex.run!("""
        import json
        json.loads("not valid json")
        """)
      end
    end
  end

  describe "json.loads edge cases" do
    test "parses nested structures" do
      result =
        Pyex.run!("""
        import json
        data = json.loads('{"users": [{"name": "alice", "scores": [1, 2, 3]}, {"name": "bob", "scores": []}]}')
        (data["users"][0]["name"], len(data["users"][1]["scores"]))
        """)

      assert result == {:tuple, ["alice", 0]}
    end

    test "parses null as None" do
      result =
        Pyex.run!("""
        import json
        json.loads("null")
        """)

      assert result == nil
    end

    test "parses true and false" do
      result =
        Pyex.run!("""
        import json
        data = json.loads('[true, false]')
        (data[0], data[1])
        """)

      assert result == {:tuple, [true, false]}
    end

    test "parses numeric values" do
      result =
        Pyex.run!("""
        import json
        data = json.loads('[42, 3.14, -1, 0]')
        data
        """)

      assert result == [42, 3.14, -1, 0]
    end

    test "parses empty structures" do
      result =
        Pyex.run!("""
        import json
        (json.loads("{}"), json.loads("[]"))
        """)

      assert result == {:tuple, [%{}, []]}
    end

    test "parses unicode strings" do
      result =
        Pyex.run!("""
        import json
        json.loads('"hello \\\\u0041"')
        """)

      assert result == "hello A"
    end
  end

  describe "json.dumps" do
    test "serializes a list" do
      result =
        Pyex.run!("""
        import json
        json.dumps([1, 2, 3])
        """)

      assert result == "[1,2,3]"
    end

    test "serializes a dict" do
      result =
        Pyex.run!("""
        import json
        json.dumps({"a": 1})
        """)

      assert Jason.decode!(result) == %{"a" => 1}
    end

    test "serializes None as null" do
      result =
        Pyex.run!("""
        import json
        json.dumps(None)
        """)

      assert result == "null"
    end

    test "serializes booleans" do
      result =
        Pyex.run!("""
        import json
        json.dumps([True, False])
        """)

      assert result == "[true,false]"
    end

    test "serializes nested structures" do
      result =
        Pyex.run!("""
        import json
        json.dumps({"items": [1, 2, 3], "meta": {"count": 3}})
        """)

      decoded = Jason.decode!(result)
      assert decoded == %{"items" => [1, 2, 3], "meta" => %{"count" => 3}}
    end
  end

  describe "json roundtrip" do
    test "loads(dumps(x)) preserves value" do
      result =
        Pyex.run!("""
        import json
        data = {"name": "test", "values": [1, 2.5, True, None, "hello"]}
        restored = json.loads(json.dumps(data))
        restored == data
        """)

      assert result == true
    end
  end

  describe "indent amplification protection" do
    test "rejects indent > 32" do
      assert {:error, %Error{message: msg}} =
               Pyex.run("""
               import json
               json.dumps({"a": 1}, indent=1000000)
               """)

      assert msg =~ "ValueError"
      assert msg =~ "indent must be <= 32"
    end

    test "indent at boundary works" do
      result =
        Pyex.run!("""
        import json
        json.dumps({"a": 1}, indent=32)
        """)

      assert is_binary(result)
      assert result =~ "\"a\""
    end
  end
end
