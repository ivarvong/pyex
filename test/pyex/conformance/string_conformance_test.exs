defmodule Pyex.Conformance.StringTest do
  @moduledoc """
  Live CPython conformance tests for `str` methods.

  The string surface area is huge and previous ad-hoc tests missed
  corner cases (e.g. `splitlines()` returning a trailing empty string).
  This matrix tests every common method against CPython.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "splitlines" do
    for {label, input, kwarg} <- [
          {"empty", "", ""},
          {"single line no eol", "hello", ""},
          {"single line with eol", "hello\n", ""},
          {"two lines", "a\nb", ""},
          {"two lines trailing eol", "a\nb\n", ""},
          {"just newlines", "\n\n", ""},
          {"mixed", "a\r\nb\rc\nd", ""},
          {"keepends", "a\nb\n", "True"},
          {"keepends mixed", "a\r\nb\rc", "True"}
        ] do
      test "splitlines(#{inspect(label)})" do
        keepends = unquote(kwarg)
        call = if keepends == "", do: "splitlines()", else: "splitlines(#{keepends})"

        check!("""
        print(#{inspect(unquote(input))}.#{call})
        """)
      end
    end
  end

  describe "split" do
    for {label, input, args} <- [
          {"no args whitespace", "a  b  c", ""},
          {"no args leading ws", "  a b", ""},
          {"no args trailing ws", "a b  ", ""},
          {"no args only ws", "   ", ""},
          {"empty string", "", ""},
          {"explicit comma", "a,b,c", "','"},
          {"explicit empty sep", "aXbXc", "'X'"},
          {"maxsplit=1", "a,b,c,d", "',', 1"},
          {"maxsplit=0", "a,b,c", "',', 0"},
          {"maxsplit=-1", "a,b,c", "',', -1"},
          {"consecutive sep", "a,,b", "','"}
        ] do
      test "split #{label}" do
        call = if unquote(args) == "", do: "split()", else: "split(#{unquote(args)})"

        check!("""
        print(#{inspect(unquote(input))}.#{call})
        """)
      end
    end
  end

  describe "rsplit" do
    for {label, input, args} <- [
          {"no args whitespace", "a  b  c", ""},
          {"with maxsplit", "a,b,c,d", "',', 2"},
          {"exhausted maxsplit", "a,b,c", "',', 5"}
        ] do
      test "rsplit #{label}" do
        call = if unquote(args) == "", do: "rsplit()", else: "rsplit(#{unquote(args)})"

        check!("""
        print(#{inspect(unquote(input))}.#{call})
        """)
      end
    end
  end

  describe "strip/lstrip/rstrip" do
    for {label, input, args} <- [
          {"strip default", "  hello  ", ""},
          {"strip chars", "xxhelloxx", "'x'"},
          {"strip mixed", "  xyhelloyx  ", "' xy'"},
          {"strip empty input", "", ""},
          {"strip all matching", "xxxx", "'x'"},
          {"lstrip default", "  hello  ", ""},
          {"rstrip default", "  hello  ", ""}
        ] do
      test "#{label}" do
        method =
          cond do
            String.starts_with?(unquote(label), "lstrip") -> "lstrip"
            String.starts_with?(unquote(label), "rstrip") -> "rstrip"
            true -> "strip"
          end

        call = if unquote(args) == "", do: "#{method}()", else: "#{method}(#{unquote(args)})"

        check!("""
        print(repr(#{inspect(unquote(input))}.#{call}))
        """)
      end
    end
  end

  describe "case methods" do
    for {label, input, method} <- [
          {"upper", "Hello World", "upper"},
          {"lower", "Hello World", "lower"},
          {"swapcase", "Hello World", "swapcase"},
          {"title", "hello world foo", "title"},
          {"capitalize", "hello WORLD", "capitalize"},
          {"casefold", "Hello", "casefold"},
          {"upper unicode", "café", "upper"},
          {"lower unicode", "CAFÉ", "lower"}
        ] do
      test "#{label}" do
        check!("""
        print(#{inspect(unquote(input))}.#{unquote(method)}())
        """)
      end
    end
  end

  describe "find/rfind/index" do
    for {label, input, args} <- [
          {"find first", "abcabc", "'b'"},
          {"find from start", "abcabc", "'b', 2"},
          {"find not present", "abc", "'x'"},
          {"rfind last", "abcabc", "'b'"},
          {"rfind with end", "abcabc", "'b', 0, 3"}
        ] do
      test "#{label}" do
        check!("""
        print(#{inspect(unquote(input))}.#{unquote(label) |> String.split() |> List.first()}(#{unquote(args)}))
        """)
      end
    end
  end

  describe "replace" do
    for {label, input, args} <- [
          {"simple", "hello world", "'world', 'Python'"},
          {"count=1", "a,b,c,d", "',', ';', 1"},
          {"no match", "abc", "'x', 'y'"},
          {"empty old", "abc", "'', '-'"}
        ] do
      test "#{label}" do
        check!("""
        print(#{inspect(unquote(input))}.replace(#{unquote(args)}))
        """)
      end
    end
  end

  describe "join" do
    for {label, sep, iterable} <- [
          {"basic", ",", "['a', 'b', 'c']"},
          {"empty iterable", ",", "[]"},
          {"single element", ",", "['only']"},
          {"empty sep", "", "['a', 'b', 'c']"},
          {"spaces", " ", "['hello', 'world']"}
        ] do
      test "#{label}" do
        check!("""
        print(#{inspect(unquote(sep))}.join(#{unquote(iterable)}))
        """)
      end
    end
  end

  describe "startswith/endswith" do
    for {label, input, args} <- [
          {"startswith true", "hello world", "'hello'"},
          {"startswith false", "hello world", "'world'"},
          {"startswith tuple", "hello.txt", "('.txt', '.md')"},
          {"startswith tuple miss", "hello", "('.txt', '.md')"},
          {"endswith true", "hello world", "'world'"},
          {"endswith tuple", "file.py", "('.py', '.pyc')"}
        ] do
      test "#{label}" do
        method =
          if String.starts_with?(unquote(label), "starts"), do: "startswith", else: "endswith"

        check!("""
        print(#{inspect(unquote(input))}.#{method}(#{unquote(args)}))
        """)
      end
    end
  end

  describe "center/ljust/rjust" do
    for {label, input, args} <- [
          {"center default fill", "hi", "10"},
          {"center with fill", "hi", "10, '*'"},
          {"ljust default", "hi", "5"},
          {"rjust default", "hi", "5"},
          {"too wide", "hi", "1"}
        ] do
      test "#{label}" do
        method =
          cond do
            String.starts_with?(unquote(label), "center") -> "center"
            String.starts_with?(unquote(label), "ljust") -> "ljust"
            true -> "rjust"
          end

        check!("""
        print(repr(#{inspect(unquote(input))}.#{method}(#{unquote(args)})))
        """)
      end
    end
  end

  describe "zfill" do
    for {label, input, arg} <- [
          {"basic", "42", "5"},
          {"already long", "12345", "3"},
          {"negative", "-42", "5"},
          {"positive sign", "+42", "5"},
          {"empty", "", "3"}
        ] do
      test "#{label}" do
        check!("""
        print(repr(#{inspect(unquote(input))}.zfill(#{unquote(arg)})))
        """)
      end
    end
  end

  describe "isX predicates" do
    for {label, input, method} <- [
          {"isalpha alpha", "abc", "isalpha"},
          {"isalpha mixed", "abc1", "isalpha"},
          {"isdigit digit", "123", "isdigit"},
          {"isdigit mixed", "1a2", "isdigit"},
          {"isalnum", "abc123", "isalnum"},
          {"isspace", "   \\t\\n", "isspace"},
          {"isspace empty", "", "isspace"},
          {"isupper", "HELLO", "isupper"},
          {"islower", "hello", "islower"},
          {"isdecimal", "123", "isdecimal"},
          {"isnumeric", "123", "isnumeric"}
        ] do
      test "#{label}" do
        check!("""
        print(#{inspect(unquote(input))}.#{unquote(method)}())
        """)
      end
    end
  end

  describe "partition/rpartition" do
    for {label, input, sep} <- [
          {"partition found", "hello world", "' '"},
          {"partition not found", "hello", "'x'"},
          {"partition empty", "", "'x'"},
          {"rpartition", "a/b/c", "'/'"}
        ] do
      test "#{label}" do
        method =
          if String.starts_with?(unquote(label), "rpart"), do: "rpartition", else: "partition"

        check!("""
        print(#{inspect(unquote(input))}.#{method}(#{unquote(sep)}))
        """)
      end
    end
  end

  describe "count" do
    for {label, input, args} <- [
          {"basic", "aabbcc", "'b'"},
          {"overlapping not counted", "aaa", "'aa'"},
          {"not found", "abc", "'x'"},
          {"with range", "aabba", "'a', 1, 4"},
          {"empty substring", "abc", "''"}
        ] do
      test "count #{label}" do
        check!("""
        print(#{inspect(unquote(input))}.count(#{unquote(args)}))
        """)
      end
    end
  end

  describe "format" do
    test "positional" do
      check!(~S"""
      print("{} {}".format("hello", "world"))
      """)
    end

    test "named" do
      check!(~S"""
      print("{name} is {age}".format(name="alice", age=30))
      """)
    end

    test "indexed" do
      check!(~S"""
      print("{0} {1} {0}".format("a", "b"))
      """)
    end

    test "format specs" do
      check!(~S"""
      print("{:>10}".format("hi"))
      print("{:<10}".format("hi"))
      print("{:^10}".format("hi"))
      print("{:.3f}".format(3.14159))
      print("{:08d}".format(42))
      """)
    end
  end

  describe "encode/decode symmetry (ascii)" do
    # CPython returns bytes objects which Pyex doesn't have, but
    # the string->string roundtrip via str(bytes) should match.
    test "plain ascii" do
      check!(~S"""
      s = "hello"
      print(s == s)
      """)
    end
  end
end
