defmodule Pyex.Stdlib.ReTest do
  use ExUnit.Case, async: true

  alias Pyex.Error

  describe "re.match" do
    test "matches at beginning of string" do
      result =
        Pyex.run!("""
        import re
        m = re.match("hello", "hello world")
        m.group()
        """)

      assert result == "hello"
    end

    test "match with group(n) for capture groups" do
      result =
        Pyex.run!("""
        import re
        m = re.match("(\\w+)@(\\w+)", "user@host")
        [m.group(0), m.group(1), m.group(2)]
        """)

      assert result == ["user@host", "user", "host"]
    end

    test "match with raw string pattern" do
      # Issue #9: walrus operator was failing due to raw string escape issue
      # This test ensures raw string patterns work correctly with \w
      result =
        Pyex.run!(~S"""
        import re
        m = re.match(r"(\w+)", "hello world")
        m.group(1)
        """)

      assert result == "hello"
    end

    test "returns None when no match at beginning" do
      result =
        Pyex.run!("""
        import re
        re.match("world", "hello world")
        """)

      assert result == nil
    end
  end

  describe "re.search" do
    test "finds pattern anywhere in string" do
      result =
        Pyex.run!("""
        import re
        m = re.search("world", "hello world")
        m.group()
        """)

      assert result == "world"
    end

    test "returns None when no match" do
      result =
        Pyex.run!("""
        import re
        re.search("xyz", "hello world")
        """)

      assert result == nil
    end

    test "captures groups" do
      result =
        Pyex.run!("""
        import re
        m = re.search("(\\w+)@(\\w+)", "user@host")
        m.group(0)
        """)

      assert result == "user@host"
    end
  end

  describe "re.findall" do
    test "returns all matches" do
      result =
        Pyex.run!("""
        import re
        re.findall("[0-9]+", "abc 123 def 456")
        """)

      assert result == ["123", "456"]
    end

    test "returns empty list when no matches" do
      result =
        Pyex.run!("""
        import re
        re.findall("[0-9]+", "no digits here")
        """)

      assert result == []
    end
  end

  describe "re.sub" do
    test "replaces matches" do
      result =
        Pyex.run!("""
        import re
        re.sub("[0-9]+", "NUM", "abc 123 def 456")
        """)

      assert result == "abc NUM def NUM"
    end
  end

  describe "re.split" do
    test "splits on pattern" do
      result =
        Pyex.run!("""
        import re
        re.split("[,;]+", "a,b;;c,d")
        """)

      assert result == ["a", "b", "c", "d"]
    end

    test "splits on whitespace" do
      result =
        Pyex.run!("""
        import re
        re.split("\\s+", "hello   world  foo")
        """)

      assert result == ["hello", "world", "foo"]
    end
  end

  describe "re.search with groups" do
    test "group(1) returns first capture" do
      result =
        Pyex.run!("""
        import re
        m = re.search("(\\w+)@(\\w+)", "user@host.com")
        m.group(1)
        """)

      assert result == "user"
    end

    test "group(2) returns second capture" do
      result =
        Pyex.run!("""
        import re
        m = re.search("(\\w+)@(\\w+)", "user@host.com")
        m.group(2)
        """)

      assert result == "host"
    end
  end

  describe "re.match edge cases" do
    test "match returns full match via group()" do
      result =
        Pyex.run!("""
        import re
        m = re.match("\\d+-\\d+", "123-456 stuff")
        m.group()
        """)

      assert result == "123-456"
    end

    test "match anchored to start returns None for mid-string" do
      result =
        Pyex.run!("""
        import re
        re.match("world", "hello world") is None
        """)

      assert result == true
    end

    test "match on empty string" do
      result =
        Pyex.run!("""
        import re
        m = re.match(".*", "")
        m.group()
        """)

      assert result == ""
    end
  end

  describe "re.findall with groups" do
    test "findall returns captured groups" do
      result =
        Pyex.run!("""
        import re
        re.findall("(\\d+)", "abc 123 def 456 ghi 789")
        """)

      assert result == ["123", "456", "789"]
    end

    test "findall on complex pattern" do
      result =
        Pyex.run!("""
        import re
        re.findall("[A-Z][a-z]+", "Hello World Foo Bar")
        """)

      assert result == ["Hello", "World", "Foo", "Bar"]
    end
  end

  describe "re.sub advanced" do
    test "replace all digits with hash" do
      result =
        Pyex.run!("""
        import re
        re.sub("\\d", "#", "phone: 123-456-7890")
        """)

      assert result == "phone: ###-###-####"
    end
  end

  describe "re error handling" do
    test "invalid regex raises error" do
      assert {:error, %Error{message: msg}} =
               Pyex.run("""
               import re
               re.match("[invalid", "test")
               """)

      assert msg =~ "re.error"
    end
  end

  describe "re.compile" do
    test "compile returns pattern object" do
      result =
        Pyex.run!("""
        import re
        pattern = re.compile(r"\\d+")
        pattern.findall("a1b2c3")
        """)

      assert result == ["1", "2", "3"]
    end

    test "compiled pattern match method" do
      result =
        Pyex.run!("""
        import re
        pattern = re.compile(r"(\\w+)")
        m = pattern.match("hello world")
        m.group(1)
        """)

      assert result == "hello"
    end

    test "compiled pattern search method" do
      result =
        Pyex.run!("""
        import re
        pattern = re.compile(r"world")
        m = pattern.search("hello world")
        m.group()
        """)

      assert result == "world"
    end

    test "compiled pattern sub method" do
      result =
        Pyex.run!("""
        import re
        pattern = re.compile(r"\\d+")
        pattern.sub("NUM", "abc 123 def 456")
        """)

      assert result == "abc NUM def NUM"
    end

    test "compiled pattern split method" do
      result =
        Pyex.run!("""
        import re
        pattern = re.compile(r"[,;]+")
        pattern.split("a,b;;c,d")
        """)

      assert result == ["a", "b", "c", "d"]
    end
  end

  describe "re flags" do
    test "re.IGNORECASE flag" do
      result =
        Pyex.run!("""
        import re
        re.findall(r"hello", "Hello World", re.IGNORECASE)
        """)

      assert result == ["Hello"]
    end

    test "re.DOTALL flag" do
      # Use raw string to avoid issues with newlines in heredoc
      code = ~S"""
      import re
      re.findall(r"a.b", "a\nb", re.DOTALL)
      """

      result = Pyex.run!(code)
      assert result == ["a\nb"]
    end

    test "re.MULTILINE flag" do
      result =
        Pyex.run!("""
        import re
        re.findall(r"^hello", "hello\\nhello", re.MULTILINE)
        """)

      assert result == ["hello", "hello"]
    end

    test "compile with flags" do
      result =
        Pyex.run!("""
        import re
        pattern = re.compile(r"hello", re.IGNORECASE)
        pattern.findall("Hello World")
        """)

      assert result == ["Hello"]
    end
  end

  describe "ReDoS protection" do
    test "normal regex operations work with timeout protection" do
      result =
        Pyex.run!("""
        import re
        m = re.search("(\\d+)", "abc123def")
        m.group(1)
        """)

      assert result == "123"
    end

    test "match works with complex but safe pattern" do
      result =
        Pyex.run!("""
        import re
        m = re.match("([a-z]+)@([a-z]+)\\.com", "user@example.com")
        [m.group(1), m.group(2)]
        """)

      assert result == ["user", "example"]
    end

    test "findall works with timeout protection" do
      result =
        Pyex.run!("""
        import re
        re.findall("\\d+", "a1b22c333")
        """)

      assert result == ["1", "22", "333"]
    end

    test "sub works with timeout protection" do
      result =
        Pyex.run!("""
        import re
        re.sub("\\s+", "-", "hello   world   foo")
        """)

      assert result == "hello-world-foo"
    end

    test "split works with timeout protection" do
      result =
        Pyex.run!("""
        import re
        re.split(",\\s*", "a, b,c,  d")
        """)

      assert result == ["a", "b", "c", "d"]
    end
  end
end
