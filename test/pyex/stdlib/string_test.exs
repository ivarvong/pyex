defmodule Pyex.Stdlib.StringTest do
  use ExUnit.Case, async: true

  describe "string constants" do
    test "ascii_lowercase returns the lowercase alphabet" do
      assert Pyex.run!("import string\nstring.ascii_lowercase") == "abcdefghijklmnopqrstuvwxyz"
    end

    test "ascii_uppercase returns the uppercase alphabet" do
      assert Pyex.run!("import string\nstring.ascii_uppercase") == "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    end

    test "ascii_letters returns both lowercase and uppercase" do
      result = Pyex.run!("import string\nstring.ascii_letters")
      assert result == "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    end

    test "digits returns 0123456789" do
      assert Pyex.run!("import string\nstring.digits") == "0123456789"
    end

    test "hexdigits contains 0123456789abcdefABCDEF" do
      assert Pyex.run!("import string\nstring.hexdigits") == "0123456789abcdefABCDEF"
    end

    test "punctuation contains common punctuation" do
      result = Pyex.run!("import string\nstring.punctuation")
      assert String.contains?(result, "!")
      assert String.contains?(result, "@")
      assert String.contains?(result, "#")
    end

    test "len(string.printable) should be 100" do
      assert Pyex.run!("import string\nlen(string.printable)") == 100
    end

    test "whitespace contains space, tab, newline" do
      result = Pyex.run!("import string\nstring.whitespace")
      assert String.contains?(result, " ")
      assert String.contains?(result, "\t")
      assert String.contains?(result, "\n")
    end

    test "usage in real code: filtering ascii_letters" do
      result =
        Pyex.run!("""
        import string
        ''.join(c for c in 'Hello World 123!' if c in string.ascii_letters)
        """)

      assert result == "HelloWorld"
    end

    test "from string import ascii_letters, digits" do
      result =
        Pyex.run!("""
        from string import ascii_letters, digits
        ascii_letters + digits
        """)

      assert result == "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    end
  end
end
