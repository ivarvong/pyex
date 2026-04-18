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
  end
end
