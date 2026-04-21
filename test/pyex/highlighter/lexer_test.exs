defmodule Pyex.Highlighter.LexerTest do
  use ExUnit.Case, async: true

  alias Pyex.Highlighter.Lexer
  alias Pyex.Highlighter.Lexers.JSON

  describe "JSON tokenization (smoke test for the engine)" do
    test "string, number, punctuation" do
      tokens = Lexer.tokenize(JSON, ~s({"n": 42}))

      assert tokens == [
               {:punctuation, "{"},
               {:name_tag, ~s("n")},
               {:punctuation, ":"},
               {:whitespace, " "},
               {:number, "42"},
               {:punctuation, "}"}
             ]
    end

    test "nested objects and arrays" do
      src = ~s({"a":[1,2],"b":null})
      tokens = Lexer.tokenize(JSON, src)

      assert Enum.all?(tokens, fn {_type, text} -> text != "" end)
      reconstructed = tokens |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
      assert reconstructed == src
    end

    test "booleans and null" do
      tokens = Lexer.tokenize(JSON, ~s([true, false, null]))
      types = Enum.map(tokens, &elem(&1, 0))
      assert :keyword_constant in types
    end

    test "strings that are values, not keys" do
      tokens = Lexer.tokenize(JSON, ~s({"k": "v"}))
      types = Enum.map(tokens, &elem(&1, 0))
      # Key is name_tag, value is string_double
      assert :name_tag in types
      assert :string_double in types
    end

    test "round-trips losslessly" do
      src = ~s({\n  "greeting": "hello, world",\n  "count": 3\n})
      tokens = Lexer.tokenize(JSON, src)
      reconstructed = tokens |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
      assert reconstructed == src
    end

    test "escaped quotes inside strings" do
      src = ~s({"msg": "she said \\"hi\\""})
      tokens = Lexer.tokenize(JSON, src)
      reconstructed = tokens |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
      assert reconstructed == src
    end
  end
end
