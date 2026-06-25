defmodule Pyex.Conformance.ClassIntrospectionTest do
  @moduledoc """
  Live CPython conformance tests for class introspection attributes
  (`__mro__`, `__bases__`, `__name__`) and `str.maketrans`/`translate`.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "__mro__" do
    test "simple inheritance" do
      check!("""
      class A: pass
      class B(A): pass
      class C(B): pass
      print([c.__name__ for c in C.__mro__])
      """)
    end

    test "ends with object" do
      check!("""
      class A: pass
      print(A.__mro__[-1].__name__)
      """)
    end
  end

  describe "__bases__" do
    test "single base" do
      check!("""
      class A: pass
      class B(A): pass
      print([c.__name__ for c in B.__bases__])
      """)
    end

    test "multiple bases" do
      check!("""
      class A: pass
      class B: pass
      class C(A, B): pass
      print([c.__name__ for c in C.__bases__])
      """)
    end
  end

  describe "__name__" do
    test "class name" do
      check!("""
      class MyClass: pass
      print(MyClass.__name__)
      """)
    end
  end

  describe "str.maketrans and translate" do
    test "simple mapping" do
      check!(~S|print("hello".translate(str.maketrans("el", "EL")))|)
    end

    test "delete characters" do
      check!(~S|print("hello world".translate(str.maketrans("", "", "lo")))|)
    end

    test "identity when no mapping matches" do
      check!(~S|print("abc".translate(str.maketrans("xyz", "XYZ")))|)
    end

    test "maketrans on a string instance matches the type staticmethod" do
      check!(~S|print("hello".translate("".maketrans("el", "EL")))|)
    end

    test "maketrans from a dict normalizes one-char keys to ordinals" do
      check!(~S|print("abc".translate(str.maketrans({"a": "X", "c": None})))|)
    end
  end

  describe "str predicate and mapping methods (isascii / isidentifier / isprintable / format_map)" do
    for {label, code} <- [
          {"isascii ascii", ~S|print("Hello".isascii())|},
          {"isascii non-ascii", ~S|print("café".isascii())|},
          {"isascii empty", ~S|print("".isascii())|},
          {"isidentifier valid", ~S|print("hello_world2".isidentifier())|},
          {"isidentifier leading digit", ~S|print("3x".isidentifier())|},
          {"isidentifier empty", ~S|print("".isidentifier())|},
          {"isidentifier unicode letter", ~S|print("café".isidentifier())|},
          {"isprintable plain", ~S|print("abc 123".isprintable())|},
          {"isprintable tab", ~S|print("a\tb".isprintable())|},
          {"isprintable empty", ~S|print("".isprintable())|},
          {"format_map basic",
           ~S|print("{greeting}, {name}".format_map({"greeting": "Hi", "name": "Bo"}))|},
          {"format_map missing key raises KeyError", ~S|
try:
    "{missing}".format_map({})
except KeyError as e:
    print(type(e).__name__)|}
        ] do
      test label do
        check!(unquote(code))
      end
    end
  end
end
