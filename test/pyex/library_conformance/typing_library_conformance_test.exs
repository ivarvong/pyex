defmodule Pyex.LibraryConformance.TypingTest do
  @moduledoc """
  Conformance tests for the `typing` surface against the pinned reference
  CPython. Each snippet runs through pyex and through the reference
  interpreter, asserting byte-equal output.

  Tagged `:library_conformance` so they're excluded by default. Run with:

      mix test --include library_conformance
  """

  use ExUnit.Case, async: true

  @moduletag :library_conformance

  import Pyex.Test.LibraryConformance

  unless uv_available?() do
    @moduletag skip: "uv not found on PATH"
  end

  describe "Generic / parameterized base classes" do
    test "Generic[T] base class with a type variable" do
      assert_matches_library("""
      from typing import TypeVar, Generic

      T = TypeVar("T")

      class Box(Generic[T]):
          def __init__(self, value: T):
              self.value = value

          def get(self) -> T:
              return self.value

      b = Box(42)
      print(b.get())
      """)
    end

    test "Generic base mixed with a concrete base" do
      assert_matches_library("""
      from typing import TypeVar, Generic

      T = TypeVar("T")

      class Base:
          kind = "base"

      class Holder(Base, Generic[T]):
          def __init__(self, v: T):
              self.v = v

      h = Holder("x")
      print(h.v, h.kind)
      """)
    end

    test "multiple type parameters" do
      assert_matches_library("""
      from typing import TypeVar, Generic

      K = TypeVar("K")
      V = TypeVar("V")

      class Pair(Generic[K, V]):
          def __init__(self, k: K, v: V):
              self.k = k
              self.v = v

      p = Pair("a", 1)
      print(p.k, p.v)
      """)
    end

    test "annotated methods and fields on a generic class" do
      assert_matches_library("""
      from typing import TypeVar, Generic, List

      T = TypeVar("T")

      class Stack(Generic[T]):
          def __init__(self) -> None:
              self._items = []

          def push(self, item: T) -> None:
              self._items.append(item)

          def pop(self) -> T:
              return self._items.pop()

      s = Stack()
      s.push(1)
      s.push(2)
      print(s.pop(), s.pop())
      """)
    end
  end

  describe "typing constructs that erase at runtime" do
    test "Optional / Union / List / Dict annotations don't affect execution" do
      assert_matches_library("""
      from typing import Optional, Union, List, Dict

      def f(a: Optional[int], b: Union[int, str], c: List[int]) -> Dict[str, int]:
          return {"n": (a or 0) + len(c)}

      print(f(None, "x", [1, 2, 3]))
      """)
    end
  end
end
