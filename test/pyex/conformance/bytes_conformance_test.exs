defmodule Pyex.Conformance.BytesTest do
  @moduledoc """
  Live CPython conformance tests for `bytes` and `bytearray` types.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "bytes literal" do
    test "simple" do
      check!(~S|print(b"hello")|)
    end

    test "with hex escapes" do
      check!(~S|print(b"\x01\xff")|)
    end

    test "concatenation" do
      check!(~S|print(b"hello" + b" world")|)
    end

    test "len" do
      check!(~S|print(len(b"hello"))|)
    end

    test "type name" do
      check!(~S|print(type(b"hi").__name__)|)
    end
  end

  describe "bytes constructor" do
    test "empty" do
      check!("print(bytes())")
    end

    test "from integer" do
      check!("print(bytes(5))")
    end

    test "from list of ints" do
      check!("print(bytes([65, 66, 67]))")
    end

    test "from string with encoding" do
      check!(~S|print(bytes("hello", "utf-8"))|)
    end
  end

  describe "bytes methods" do
    test "hex" do
      check!(~S|print(b"\x01\xff".hex())|)
    end

    test "decode utf-8" do
      check!(~S|print(b"caf\xc3\xa9".decode("utf-8"))|)
    end

    test "startswith" do
      check!(~S|print(b"hello".startswith(b"he"))|)
    end

    test "endswith" do
      check!(~S|print(b"hello".endswith(b"lo"))|)
    end

    test "split" do
      check!(~S|print(b"a,b,c".split(b","))|)
    end

    test "strip" do
      check!(~S|print(b"  hello  ".strip())|)
    end

    test "upper" do
      check!(~S|print(b"hello".upper())|)
    end

    test "replace" do
      check!(~S|print(b"hello".replace(b"l", b"L"))|)
    end
  end

  describe "str.encode / bytes.decode roundtrip" do
    test "ascii" do
      check!(~S|print("hello".encode().decode())|)
    end

    test "unicode via utf-8" do
      check!(~S|print("café".encode("utf-8").decode("utf-8"))|)
    end
  end

  describe "bytes equality" do
    test "same bytes equal" do
      check!(~S|print(b"abc" == b"abc")|)
    end

    test "different bytes not equal" do
      check!(~S|print(b"abc" == b"xyz")|)
    end

    test "bytes != str" do
      check!(~S|print(b"abc" == "abc")|)
    end
  end

  describe "bool" do
    test "empty is falsy" do
      check!(~S|print(bool(b""))|)
    end

    test "non-empty is truthy" do
      check!(~S|print(bool(b"x"))|)
    end
  end
end
