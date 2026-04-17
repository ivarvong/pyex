defmodule Pyex.Conformance.ReTest do
  @moduledoc """
  Live CPython conformance tests for the `re` module.

  Covers basic match/search/findall/sub, anchors, character classes,
  quantifiers, groups, flags, and common real-world patterns.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "match" do
    for {label, pattern, string} <- [
          {"simple match at start", "hello", "hello world"},
          {"no match (not at start)", "world", "hello world"},
          {"digit class", ~S|\d+|, "abc123def"},
          {"anchor start", ~S|^hello|, "hello world"},
          {"word boundary", ~S|\bfoo\b|, "foo bar"},
          {"dot any", ~S|a.c|, "abc"},
          {"dot not newline", ~S|a.c|, "a\nc"}
        ] do
      test "match #{label}" do
        check!("""
        import re
        m = re.match(#{inspect(unquote(pattern))}, #{inspect(unquote(string))})
        if m:
            print("MATCH", m.group(), m.start(), m.end())
        else:
            print("NONE")
        """)
      end
    end
  end

  describe "search" do
    for {label, pattern, string} <- [
          {"digit anywhere", ~S|\d+|, "abc123def"},
          {"word in middle", "world", "hello world"},
          {"nothing", ~S|xyz|, "hello"},
          {"multiple possibilities", ~S|\d+|, "a1 b22 c333"}
        ] do
      test "search #{label}" do
        check!("""
        import re
        m = re.search(#{inspect(unquote(pattern))}, #{inspect(unquote(string))})
        if m:
            print("FOUND", m.group(), m.start(), m.end())
        else:
            print("NONE")
        """)
      end
    end
  end

  describe "findall" do
    for {label, pattern, string} <- [
          {"all digits", ~S|\d+|, "a1 b22 c333"},
          {"words", ~S|\w+|, "hello world foo"},
          {"empty result", ~S|xyz|, "abc"},
          {"overlapping not counted", "aa", "aaaa"}
        ] do
      test "findall #{label}" do
        check!("""
        import re
        print(re.findall(#{inspect(unquote(pattern))}, #{inspect(unquote(string))}))
        """)
      end
    end

    test "findall with groups returns tuples" do
      check!("""
      import re
      print(re.findall(r"(\\w+)=(\\d+)", "a=1 b=2 c=3"))
      """)
    end

    test "findall with single group returns strings" do
      check!("""
      import re
      print(re.findall(r"(\\w+)", "hello world"))
      """)
    end
  end

  describe "sub" do
    for {label, pattern, repl, string} <- [
          {"simple replace", ~S|foo|, "bar", "foo and foo"},
          {"digits to X", ~S|\d+|, "X", "a1 b22 c333"},
          {"empty match replace", ~S|^|, ">", "abc"},
          {"word to upper via \\1", ~S|\w+|, ~S|[\g<0>]|, "a b c"}
        ] do
      test "sub #{label}" do
        check!("""
        import re
        print(re.sub(#{inspect(unquote(pattern))}, #{inspect(unquote(repl))}, #{inspect(unquote(string))}))
        """)
      end
    end

    test "sub with count limit" do
      check!("""
      import re
      print(re.sub(r"\\d+", "X", "1 2 3 4 5", count=3))
      """)
    end

    test "sub with backreferences" do
      check!("""
      import re
      print(re.sub(r"(\\w+)=(\\d+)", r"\\2:\\1", "a=1 b=2"))
      """)
    end
  end

  describe "split" do
    for {label, pattern, string} <- [
          {"whitespace", ~S|\s+|, "hello   world   foo"},
          {"commas", ",", "a,b,c,d"},
          {"empty result", "x", "abc"},
          {"digit splits", ~S|\d+|, "a1b2c3d"}
        ] do
      test "split #{label}" do
        check!("""
        import re
        print(re.split(#{inspect(unquote(pattern))}, #{inspect(unquote(string))}))
        """)
      end
    end

    test "split with maxsplit" do
      check!("""
      import re
      print(re.split(",", "a,b,c,d,e", maxsplit=2))
      """)
    end
  end

  describe "groups and named groups" do
    test "numeric groups" do
      check!("""
      import re
      m = re.match(r"(\\w+) (\\w+)", "hello world")
      print(m.group(0))
      print(m.group(1))
      print(m.group(2))
      print(m.groups())
      """)
    end

    test "named groups" do
      check!("""
      import re
      m = re.match(r"(?P<first>\\w+) (?P<second>\\w+)", "hello world")
      print(m.group("first"))
      print(m.group("second"))
      print(m.groupdict())
      """)
    end
  end

  describe "flags" do
    test "IGNORECASE" do
      check!("""
      import re
      m = re.match(r"hello", "HELLO", re.IGNORECASE)
      print(bool(m))
      """)
    end

    test "MULTILINE affects ^" do
      check!("""
      import re
      print(re.findall(r"^\\w+", "abc\\ndef\\nghi", re.MULTILINE))
      """)
    end

    test "DOTALL makes . match newline" do
      check!("""
      import re
      m = re.match(r"a.b", "a\\nb", re.DOTALL)
      print(bool(m))
      """)
    end
  end

  describe "compile" do
    test "compiled pattern reused" do
      check!("""
      import re
      p = re.compile(r"\\d+")
      print(p.findall("a1 b22 c333"))
      print(p.search("hello 99 world").group())
      """)
    end
  end

  describe "character classes" do
    for {label, pattern, string} <- [
          {"[abc]", "[abc]", "xyzcab"},
          {"[^abc]", "[^abc]", "abcxyz"},
          {"[a-z]+", "[a-z]+", "Hello World"},
          {"[0-9]{3}", "[0-9]{3}", "abc123def4567"}
        ] do
      test "findall #{label}" do
        check!("""
        import re
        print(re.findall(#{inspect(unquote(pattern))}, #{inspect(unquote(string))}))
        """)
      end
    end
  end

  describe "quantifiers" do
    for {label, pattern, string} <- [
          {"a*", "a*", "aaabbb"},
          {"a+", "a+", "aaabbb"},
          {"a?b", "a?b", "bab"},
          {"a{2,4}", "a{2,4}", "aaaaa"},
          {"a{2}", "a{2}", "aaa"},
          {"lazy *?", "a.*?b", "a123b456b"}
        ] do
      test "findall #{label}" do
        check!("""
        import re
        print(re.findall(#{inspect(unquote(pattern))}, #{inspect(unquote(string))}))
        """)
      end
    end
  end

  describe "real-world patterns" do
    test "email-like extraction" do
      check!("""
      import re
      text = "contact: foo@bar.com or baz@quux.org"
      print(re.findall(r"[\\w.]+@[\\w.]+", text))
      """)
    end

    test "ISO date extraction" do
      check!("""
      import re
      s = "start 2026-04-15 end 2026-05-20"
      print(re.findall(r"\\d{4}-\\d{2}-\\d{2}", s))
      """)
    end

    test "whitespace normalization" do
      check!("""
      import re
      print(re.sub(r"\\s+", " ", "hello    world\\t\\tfoo"))
      """)
    end
  end
end
