defmodule Pyex.Stdlib.YamlTest do
  use ExUnit.Case, async: true

  alias Pyex.{Builtins, Env, Error, Interpreter}

  describe "yaml.safe_load" do
    test "parses a mapping" do
      result =
        Pyex.run!("""
        import yaml
        yaml.safe_load("name: alice\\nage: 30")
        """)

      assert result == %{"name" => "alice", "age" => 30}
    end

    test "parses a sequence" do
      result =
        Pyex.run!("""
        import yaml
        yaml.safe_load("- 1\\n- 2\\n- 3")
        """)

      assert result == [1, 2, 3]
    end

    test "parses nested structures" do
      result =
        Pyex.run!("""
        import yaml
        data = yaml.safe_load("users:\\n  - name: alice\\n    score: 10\\n  - name: bob\\n    score: 20")
        (data["users"][0]["name"], data["users"][1]["score"])
        """)

      assert result == {:tuple, ["alice", 20]}
    end

    test "parses an empty document as None" do
      result =
        Pyex.run!("""
        import yaml
        yaml.safe_load("")
        """)

      assert result == nil
    end

    test "parses booleans" do
      result =
        Pyex.run!("""
        import yaml
        data = yaml.safe_load("a: true\\nb: false")
        (data["a"], data["b"])
        """)

      assert result == {:tuple, [true, false]}
    end

    test "parses floats and integers" do
      result =
        Pyex.run!("""
        import yaml
        data = yaml.safe_load("x: 42\\ny: 3.14")
        (data["x"], data["y"])
        """)

      assert result == {:tuple, [42, 3.14]}
    end

    test "parses null value in a mapping as None" do
      result =
        Pyex.run!("""
        import yaml
        data = yaml.safe_load("key: null")
        data["key"] is None
        """)

      assert result == true
    end

    test "raises on invalid YAML" do
      assert {:error, %Error{message: msg}} =
               Pyex.run("""
               import yaml
               yaml.safe_load("key: [unclosed")
               """)

      assert msg =~ "yaml.YAMLError"
    end

    test "raises on non-string argument" do
      assert {:error, %Error{message: msg}} =
               Pyex.run("""
               import yaml
               yaml.safe_load(42)
               """)

      assert msg =~ "TypeError"
    end
  end

  describe "safety" do
    test "returns string keys, not atoms" do
      result =
        Pyex.run!("""
        import yaml
        yaml.safe_load("definitely_not_an_existing_atom_key_xyz: 1")
        """)

      assert %{"definitely_not_an_existing_atom_key_xyz" => 1} = result
      assert Map.keys(result) |> Enum.all?(&is_binary/1)
    end

    test "rejects YAML with overly deep nesting" do
      deeply_nested =
        Enum.map_join(1..101, "", fn i -> String.duplicate(" ", i * 2) <> "x:\n" end)

      assert {:error, %Error{message: msg}} =
               run_with_var("doc", deeply_nested, """
               import yaml
               yaml.safe_load(doc)
               """)

      assert msg =~ "yaml.YAMLError"
    end

    test "rejects input exceeding size limit" do
      huge = String.duplicate("a: b\n", 200_001)

      assert {:error, %Error{message: msg}} =
               run_with_var("doc", huge, """
               import yaml
               yaml.safe_load(doc)
               """)

      assert msg =~ "ValueError"
    end
  end

  defp run_with_var(name, value, code) do
    {:ok, ast} = Pyex.compile(code)
    env = Env.put(Builtins.env(), name, value)
    ctx = Pyex.Ctx.new()

    case Interpreter.run_with_ctx(ast, env, ctx) do
      {:ok, result, _env, ctx} -> {:ok, result, ctx}
      {:error, msg} -> {:error, %Error{message: msg, kind: :python}}
    end
  end
end
