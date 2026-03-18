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

  describe "match object .start() and .end()" do
    test "start and end on search match" do
      result =
        Pyex.run!("""
        import re
        m = re.search("world", "hello world")
        [m.start(), m.end()]
        """)

      assert result == [6, 11]
    end

    test "start and end default to group 0" do
      result =
        Pyex.run!("""
        import re
        m = re.search("(\\d+)", "abc123def")
        [m.start(0), m.end(0)]
        """)

      assert result == [3, 6]
    end

    test "start and end for capture group" do
      result =
        Pyex.run!("""
        import re
        m = re.search("(\\w+)@(\\w+)", "foo user@host bar")
        [m.start(1), m.end(1), m.start(2), m.end(2)]
        """)

      assert result == [4, 8, 9, 13]
    end

    test "span returns tuple of start and end" do
      result =
        Pyex.run!("""
        import re
        m = re.search("world", "hello world")
        m.span()
        """)

      assert result == {:tuple, [6, 11]}
    end
  end

  describe "match object .groups()" do
    test "groups returns tuple of all capture groups" do
      result =
        Pyex.run!("""
        import re
        m = re.search("(\\w+)@(\\w+)", "user@host")
        m.groups()
        """)

      assert result == {:tuple, ["user", "host"]}
    end
  end

  describe "match object .lastgroup" do
    test "lastgroup returns name of last matched named group" do
      result =
        Pyex.run!(~S"""
        import re
        m = re.search(r"(?P<first>\w+)\s+(?P<second>\w+)", "hello world")
        m.lastgroup
        """)

      assert result == "second"
    end

    test "lastgroup is None when no named groups" do
      result =
        Pyex.run!("""
        import re
        m = re.search("(\\w+)", "hello")
        m.lastgroup
        """)

      assert result == nil
    end

    test "group by name" do
      result =
        Pyex.run!(~S"""
        import re
        m = re.search(r"(?P<word>\w+)\s+(?P<num>\d+)", "hello 42")
        [m.group("word"), m.group("num")]
        """)

      assert result == ["hello", "42"]
    end
  end

  describe "re.finditer" do
    test "iterates over all matches" do
      result =
        Pyex.run!("""
        import re
        results = []
        for m in re.finditer("[0-9]+", "abc 123 def 456"):
            results.append(m.group())
        results
        """)

      assert result == ["123", "456"]
    end

    test "finditer with start and end positions" do
      result =
        Pyex.run!("""
        import re
        results = []
        for m in re.finditer("[0-9]+", "abc 123 def 456"):
            results.append([m.start(), m.end()])
        results
        """)

      assert result == [[4, 7], [12, 15]]
    end

    test "finditer with named groups and lastgroup" do
      result =
        Pyex.run!(~S"""
        import re
        pattern = r"(?P<word>[a-zA-Z]+)|(?P<num>\d+)"
        groups = []
        for m in re.finditer(pattern, "hello 42"):
            groups.append(m.lastgroup)
        groups
        """)

      assert result == ["word", "num"]
    end

    test "finditer on compiled pattern" do
      result =
        Pyex.run!("""
        import re
        pat = re.compile("[a-z]+")
        results = []
        for m in pat.finditer("abc 123 def"):
            results.append(m.group())
        results
        """)

      assert result == ["abc", "def"]
    end

    test "finditer returns empty iterator for no matches" do
      result =
        Pyex.run!("""
        import re
        results = []
        for m in re.finditer("[0-9]+", "no digits"):
            results.append(m.group())
        results
        """)

      assert result == []
    end

    test "finditer with list conversion" do
      result =
        Pyex.run!("""
        import re
        matches = list(re.finditer("\\w+", "hello world"))
        len(matches)
        """)

      assert result == 2
    end
  end
end
