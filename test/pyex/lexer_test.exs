defmodule Pyex.LexerTest do
  use ExUnit.Case, async: true

  alias Pyex.Lexer

  describe "atoms and operators" do
    test "integer literals" do
      assert {:ok, [{:integer, 1, 42}]} = Lexer.tokenize("42")
    end

    test "float literals" do
      assert {:ok, [{:float, 1, 3.14}]} = Lexer.tokenize("3.14")
    end

    test "identifiers" do
      assert {:ok, [{:name, 1, "foo"}]} = Lexer.tokenize("foo")
    end

    test "keywords are rewritten from names" do
      assert {:ok, [{:keyword, 1, "def"}]} = Lexer.tokenize("def")
      assert {:ok, [{:keyword, 1, "return"}]} = Lexer.tokenize("return")
      assert {:ok, [{:keyword, 1, "True"}]} = Lexer.tokenize("True")
    end

    test "multi-character operators come before single-character" do
      assert {:ok, [{:op, 1, :double_star}]} = Lexer.tokenize("**")
      assert {:ok, [{:op, 1, :floor_div}]} = Lexer.tokenize("//")
      assert {:ok, [{:op, 1, :eq}]} = Lexer.tokenize("==")
      assert {:ok, [{:op, 1, :neq}]} = Lexer.tokenize("!=")
      assert {:ok, [{:op, 1, :lte}]} = Lexer.tokenize("<=")
      assert {:ok, [{:op, 1, :gte}]} = Lexer.tokenize(">=")
    end

    test "arithmetic expression tokens in order" do
      {:ok, tokens} = Lexer.tokenize("2 + 3 * 4")

      assert [
               {:integer, 1, 2},
               {:op, 1, :plus},
               {:integer, 1, 3},
               {:op, 1, :star},
               {:integer, 1, 4}
             ] = tokens
    end
  end

  describe "indentation" do
    test "simple indent and dedent" do
      {:ok, tokens} = Lexer.tokenize("if x:\n    y")

      assert [
               {:keyword, 1, "if"},
               {:name, 1, "x"},
               {:op, 1, :colon},
               :newline,
               :indent,
               {:name, 2, "y"},
               :dedent
             ] = tokens
    end

    test "function definition produces correct indent structure" do
      source = "def add(a, b):\n    return a + b\n\nadd(1, 2)"
      {:ok, tokens} = Lexer.tokenize(source)

      assert [
               {:keyword, 1, "def"},
               {:name, 1, "add"},
               {:op, 1, :lparen},
               {:name, 1, "a"},
               {:op, 1, :comma},
               {:name, 1, "b"},
               {:op, 1, :rparen},
               {:op, 1, :colon},
               :newline,
               :indent,
               {:keyword, 2, "return"},
               {:name, 2, "a"},
               {:op, 2, :plus},
               {:name, 2, "b"},
               :newline,
               :dedent,
               {:name, 3, "add"},
               {:op, 3, :lparen},
               {:integer, 3, 1},
               {:op, 3, :comma},
               {:integer, 3, 2},
               {:op, 3, :rparen}
             ] = tokens
    end

    test "nested indentation with double dedent" do
      source = "if a:\n    if b:\n        x\ny"
      {:ok, tokens} = Lexer.tokenize(source)

      assert [
               {:keyword, 1, "if"},
               {:name, 1, "a"},
               {:op, 1, :colon},
               :newline,
               :indent,
               {:keyword, 2, "if"},
               {:name, 2, "b"},
               {:op, 2, :colon},
               :newline,
               :indent,
               {:name, 3, "x"},
               :newline,
               :dedent,
               :dedent,
               {:name, 4, "y"}
             ] = tokens
    end
  end

  describe "line tracking" do
    test "tokens carry correct line numbers across newlines" do
      source = "x = 1\ny = 2\nz = 3"
      {:ok, tokens} = Lexer.tokenize(source)

      lines = for {_, line, _} <- tokens, do: line

      assert [1, 1, 1, 2, 2, 2, 3, 3, 3] = lines
    end
  end

  describe "string literals" do
    test "double-quoted string" do
      assert {:ok, [{:string, 1, "hello"}]} = Lexer.tokenize(~s("hello"))
    end

    test "single-quoted string" do
      assert {:ok, [{:string, 1, "world"}]} = Lexer.tokenize("'world'")
    end

    test "string with escape sequences" do
      assert {:ok, [{:string, 1, "line1\nline2"}]} = Lexer.tokenize(~s("line1\\nline2"))
    end

    test "empty string" do
      assert {:ok, [{:string, 1, ""}]} = Lexer.tokenize(~s(""))
    end
  end

  describe "brackets and braces" do
    test "square brackets" do
      {:ok, tokens} = Lexer.tokenize("[1, 2]")

      assert [
               {:op, 1, :lbracket},
               {:integer, 1, 1},
               {:op, 1, :comma},
               {:integer, 1, 2},
               {:op, 1, :rbracket}
             ] = tokens
    end

    test "curly braces" do
      {:ok, tokens} = Lexer.tokenize("{}")
      assert [{:op, 1, :lbrace}, {:op, 1, :rbrace}] = tokens
    end

    test "dot operator" do
      {:ok, tokens} = Lexer.tokenize("foo.bar")

      assert [
               {:name, 1, "foo"},
               {:op, 1, :dot},
               {:name, 1, "bar"}
             ] = tokens
    end
  end

  describe "import keyword" do
    test "import is recognized as keyword" do
      assert {:ok, [{:keyword, 1, "import"}, {:name, 1, "json"}]} = Lexer.tokenize("import json")
    end
  end

  describe "bracket newline suppression" do
    test "newlines inside parentheses are suppressed" do
      {:ok, tokens} =
        Lexer.tokenize("""
        foo(
          1,
          2
        )
        """)

      refute :newline in tokens
      refute :indent in tokens
      refute :dedent in tokens

      assert {:name, 1, "foo"} in tokens
      assert {:op, 1, :lparen} in tokens
      assert {:integer, 2, 1} in tokens
      assert {:integer, 3, 2} in tokens
      assert {:op, 4, :rparen} in tokens
    end

    test "newlines inside square brackets are suppressed" do
      {:ok, tokens} =
        Lexer.tokenize("""
        [
          1,
          2,
          3
        ]
        """)

      refute :newline in tokens
      refute :indent in tokens
    end

    test "newlines inside curly braces are suppressed" do
      {:ok, tokens} =
        Lexer.tokenize("""
        {
          "a": 1,
          "b": 2
        }
        """)

      refute :newline in tokens
      refute :indent in tokens
    end

    test "nested brackets suppress correctly" do
      {:ok, tokens} =
        Lexer.tokenize("""
        foo(
          [1,
           2],
          3
        )
        """)

      refute :newline in tokens
      refute :indent in tokens
    end

    test "newlines outside brackets still produce indent/dedent" do
      {:ok, tokens} =
        Lexer.tokenize("""
        if x:
          y = [
            1,
            2
          ]
        """)

      assert :newline in tokens
      assert :indent in tokens
    end
  end

  describe "comments" do
    test "full-line comment is ignored" do
      assert {:ok, [:newline, {:name, 2, "x"}]} = Lexer.tokenize("# this is a comment\nx")
    end

    test "inline comment is stripped" do
      assert {:ok, [{:name, 1, "x"}, {:op, 1, :assign}, {:integer, 1, 1}]} =
               Lexer.tokenize("x = 1 # set x")
    end

    test "hash inside double-quoted string is preserved" do
      assert {:ok, [{:string, 1, "a#b"}]} = Lexer.tokenize(~s("a#b"))
    end

    test "hash inside single-quoted string is preserved" do
      assert {:ok, [{:string, 1, "a#b"}]} = Lexer.tokenize("'a#b'")
    end

    test "comment after string with hash inside" do
      {:ok, tokens} = Lexer.tokenize(~s(x = "a#b" # comment))

      assert [
               {:name, 1, "x"},
               {:op, 1, :assign},
               {:string, 1, "a#b"}
             ] = tokens
    end

    test "multiple comment lines" do
      source = "# first\n# second\nx = 1"
      {:ok, tokens} = Lexer.tokenize(source)

      names = for {:name, _, val} <- tokens, do: val
      assert "x" in names
    end

    test "comment-only source produces empty token list" do
      assert {:ok, []} = Lexer.tokenize("# just a comment")
    end

    test "comment preserves indentation structure" do
      source = "if x:\n    # a comment\n    y = 1"
      {:ok, tokens} = Lexer.tokenize(source)
      assert :indent in tokens
      assert {:name, _, "y"} = Enum.find(tokens, fn t -> match?({:name, _, "y"}, t) end)
    end
  end

  describe "error cases" do
    test "returns error for unrecognized characters" do
      assert {:error, "Lexer error:" <> _} = Lexer.tokenize("`")
    end
  end

  describe "prefixed numeric literals" do
    test "hex literals" do
      assert {:ok, [{:integer, 1, 255}]} = Lexer.tokenize("0xFF")
      assert {:ok, [{:integer, 1, 255}]} = Lexer.tokenize("0xff")
      assert {:ok, [{:integer, 1, 0}]} = Lexer.tokenize("0x0")
      assert {:ok, [{:integer, 1, 26}]} = Lexer.tokenize("0x1a")
    end

    test "octal literals" do
      assert {:ok, [{:integer, 1, 8}]} = Lexer.tokenize("0o10")
      assert {:ok, [{:integer, 1, 0}]} = Lexer.tokenize("0o0")
      assert {:ok, [{:integer, 1, 63}]} = Lexer.tokenize("0o77")
    end

    test "binary literals" do
      assert {:ok, [{:integer, 1, 10}]} = Lexer.tokenize("0b1010")
      assert {:ok, [{:integer, 1, 0}]} = Lexer.tokenize("0b0")
      assert {:ok, [{:integer, 1, 7}]} = Lexer.tokenize("0b111")
    end

    test "underscore separators in integers" do
      assert {:ok, [{:integer, 1, 1_000_000}]} = Lexer.tokenize("1_000_000")
      assert {:ok, [{:integer, 1, 42}]} = Lexer.tokenize("4_2")
    end

    test "underscore separators in floats" do
      assert {:ok, [{:float, 1, 1_000.5}]} = Lexer.tokenize("1_000.5")
    end

    test "underscore separators in hex" do
      assert {:ok, [{:integer, 1, 0xFFFF}]} = Lexer.tokenize("0xFF_FF")
    end

    test "underscore separators in binary" do
      assert {:ok, [{:integer, 1, 0b11110000}]} = Lexer.tokenize("0b1111_0000")
    end
  end

  describe "line continuation" do
    test "backslash joins lines" do
      {:ok, tokens} = Lexer.tokenize("x = 1 +\\\n2")
      names = for {:name, _, n} <- tokens, do: n
      assert "x" in names
    end

    test "backslash in expression" do
      assert Pyex.run!("x = 1 +\\\n2\nx") == 3
    end

    test "backslash in assignment" do
      result =
        Pyex.run!("""
        long_name =\
          42
        long_name
        """)

      assert result == 42
    end
  end

  describe "raw strings" do
    test "raw double-quoted string preserves backslashes" do
      assert {:ok, [{:string, 1, "\\n\\t"}]} = Lexer.tokenize(~S|r"\n\t"|)
    end

    test "raw single-quoted string preserves backslashes" do
      assert {:ok, [{:string, 1, "\\n\\t"}]} = Lexer.tokenize(~S|r'\n\t'|)
    end

    test "raw string with regex pattern" do
      assert {:ok, [{:string, 1, "\\d+\\.\\d+"}]} = Lexer.tokenize(~S|r"\d+\.\d+"|)
    end

    test "raw string with backslash-quote" do
      assert {:ok, [{:string, 1, "it\\'s"}]} = Lexer.tokenize(~S|r"it\'s"|)
    end

    test "raw string end-to-end" do
      assert Pyex.run!(~S|len(r"\n")|) == 2
    end

    test "raw string used for regex" do
      result =
        Pyex.run!("""
        import re
        pattern = r"\\d+"
        m = re.findall(pattern, "abc123def456")
        m
        """)

      assert result == ["123", "456"]
    end
  end

  describe "escape sequences" do
    test "carriage return \\r" do
      assert {:ok, [{:string, 1, "\r"}]} = Lexer.tokenize(~S|"\r"|)
    end

    test "null \\0" do
      assert {:ok, [{:string, 1, <<0>>}]} = Lexer.tokenize(~S|"\0"|)
    end

    test "bell \\a" do
      assert {:ok, [{:string, 1, "\a"}]} = Lexer.tokenize(~S|"\a"|)
    end

    test "backspace \\b" do
      assert {:ok, [{:string, 1, "\b"}]} = Lexer.tokenize(~S|"\b"|)
    end

    test "form feed \\f" do
      assert {:ok, [{:string, 1, "\f"}]} = Lexer.tokenize(~S|"\f"|)
    end

    test "vertical tab \\v" do
      assert {:ok, [{:string, 1, "\v"}]} = Lexer.tokenize(~S|"\v"|)
    end

    test "hex escape \\xNN" do
      assert {:ok, [{:string, 1, "A"}]} = Lexer.tokenize(~S|"\x41"|)
      {:ok, [{:string, 1, result}]} = Lexer.tokenize(~S|"\xff"|)
      assert result == <<0xFF::utf8>>
    end

    test "unicode escape \\uNNNN" do
      assert {:ok, [{:string, 1, "€"}]} = Lexer.tokenize(~S|"\u20AC"|)
      assert {:ok, [{:string, 1, "A"}]} = Lexer.tokenize(~S|"\u0041"|)
    end

    test "unicode escape \\UNNNNNNNN" do
      assert {:ok, [{:string, 1, "😀"}]} = Lexer.tokenize(~S|"\U0001F600"|)
    end

    test "unknown escape passes through" do
      assert {:ok, [{:string, 1, "\\d"}]} = Lexer.tokenize(~S|"\d"|)
      assert {:ok, [{:string, 1, "\\w"}]} = Lexer.tokenize(~S|"\w"|)
    end

    test "escape sequences in single-quoted strings" do
      assert {:ok, [{:string, 1, "\r"}]} = Lexer.tokenize(~S|'\r'|)
      assert {:ok, [{:string, 1, "A"}]} = Lexer.tokenize(~S|'\x41'|)
    end

    test "escape sequences in triple-quoted strings" do
      assert {:ok, [{:string, 1, "\r"}]} = Lexer.tokenize(~s|""\"\\r\"""|)
    end

    test "mixed escapes in one string" do
      assert {:ok, [{:string, 1, "a\tb\nc"}]} = Lexer.tokenize(~S|"a\tb\nc"|)
    end

    test "escape sequences work end-to-end" do
      assert Pyex.run!(~S|len("\r\n")|) == 2
      assert Pyex.run!(~S|"\x48\x65\x6c\x6c\x6f"|) == "Hello"
    end
  end
end
