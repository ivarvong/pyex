defmodule Pyex.GeneratorsTest do
  use ExUnit.Case, async: true

  describe "generators" do
    test "basic generator with yield" do
      code = """
      def gen():
          yield 1
          yield 2
          yield 3

      list(gen())
      """

      assert Pyex.run!(code) == [1, 2, 3]
    end

    test "generator with for loop" do
      code = """
      def squares(n):
          for i in range(n):
              yield i * i

      list(squares(5))
      """

      assert Pyex.run!(code) == [0, 1, 4, 9, 16]
    end

    test "generator with while loop" do
      code = """
      def count_up(n):
          i = 0
          while i < n:
              yield i
              i += 1

      list(count_up(4))
      """

      assert Pyex.run!(code) == [0, 1, 2, 3]
    end

    test "generator with conditional yield" do
      code = """
      def evens(n):
          for i in range(n):
              if i % 2 == 0:
                  yield i

      list(evens(10))
      """

      assert Pyex.run!(code) == [0, 2, 4, 6, 8]
    end

    test "generator in for loop" do
      code = """
      def gen():
          yield 10
          yield 20
          yield 30

      total = 0
      for x in gen():
          total += x
      total
      """

      assert Pyex.run!(code) == 60
    end

    test "yield from iterable" do
      code = """
      def flatten(lists):
          for lst in lists:
              yield from lst

      list(flatten([[1, 2], [3, 4], [5]]))
      """

      assert Pyex.run!(code) == [1, 2, 3, 4, 5]
    end

    test "yield from another generator" do
      code = """
      def inner():
          yield 1
          yield 2

      def outer():
          yield 0
          yield from inner()
          yield 3

      list(outer())
      """

      assert Pyex.run!(code) == [0, 1, 2, 3]
    end

    test "generator with sum()" do
      code = """
      def gen():
          yield 1
          yield 2
          yield 3

      sum(gen())
      """

      assert Pyex.run!(code) == 6
    end

    test "generator with any() and all()" do
      code = """
      def gen():
          yield 1
          yield 2
          yield 3

      def gen_true():
          yield True
          yield True

      [any(gen()), all(gen_true())]
      """

      assert Pyex.run!(code) == [true, true]
    end

    test "generator with tuple() and set()" do
      code = """
      def gen():
          yield 1
          yield 2
          yield 3

      [tuple(gen()), len(set(gen()))]
      """

      assert Pyex.run!(code) == [{:tuple, [1, 2, 3]}, 3]
    end

    test "generator with sorted()" do
      code = """
      def gen():
          yield 3
          yield 1
          yield 2

      sorted(gen())
      """

      assert Pyex.run!(code) == [1, 2, 3]
    end

    test "bare yield returns None" do
      code = """
      def gen():
          yield
          yield 42

      list(gen())
      """

      assert Pyex.run!(code) == [nil, 42]
    end

    test "generator with return terminates" do
      code = """
      def gen():
          yield 1
          yield 2
          return
          yield 3

      list(gen())
      """

      assert Pyex.run!(code) == [1, 2]
    end

    test "fibonacci generator" do
      code = """
      def fib(limit):
          a, b = 0, 1
          while a < limit:
              yield a
              a, b = b, a + b

      list(fib(50))
      """

      assert Pyex.run!(code) == [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
    end

    test "generator with enumerate" do
      code = """
      def gen():
          yield "a"
          yield "b"
          yield "c"

      result = []
      for i, v in enumerate(gen()):
          result.append(f"{i}:{v}")
      result
      """

      assert Pyex.run!(code) == ["0:a", "1:b", "2:c"]
    end

    test "nested generators" do
      code = """
      def outer():
          for i in range(3):
              yield from inner(i)

      def inner(n):
          for j in range(2):
              yield n * 10 + j

      list(outer())
      """

      assert Pyex.run!(code) == [0, 1, 10, 11, 20, 21]
    end

    test "generator with min() and max()" do
      code = """
      def gen():
          yield 5
          yield 2
          yield 8

      [min(gen()), max(gen())]
      """

      assert Pyex.run!(code) == [2, 8]
    end

    test "generator with reversed()" do
      code = """
      def gen():
          yield 1
          yield 2
          yield 3

      list(reversed(gen()))
      """

      assert Pyex.run!(code) == [3, 2, 1]
    end

    test "generator expression as function argument" do
      assert Pyex.run!("sum(x * x for x in range(5))") == 30
    end

    test "generator expression with filter" do
      assert Pyex.run!("sum(x for x in range(10) if x % 2 == 0)") == 20
    end

    test "generator expression with list()" do
      assert Pyex.run!("list(x * 2 for x in [1, 2, 3])") == [2, 4, 6]
    end

    test "generator expression with any()" do
      assert Pyex.run!("any(x > 3 for x in [1, 2, 3, 4, 5])") == true
      assert Pyex.run!("any(x > 10 for x in [1, 2, 3])") == false
    end

    test "generator expression with all()" do
      assert Pyex.run!("all(x > 0 for x in [1, 2, 3])") == true
      assert Pyex.run!("all(x > 1 for x in [1, 2, 3])") == false
    end

    test "parenthesized generator expression" do
      code = """
      g = (x * x for x in range(4))
      list(g)
      """

      assert Pyex.run!(code) == [0, 1, 4, 9]
    end

    test "generator expression with tuple unpacking" do
      code = """
      pairs = [(1, 2), (3, 4), (5, 6)]
      sum(a + b for a, b in pairs)
      """

      assert Pyex.run!(code) == 21
    end

    test "generator expression with max()" do
      assert Pyex.run!("max(len(s) for s in [\"hi\", \"hello\", \"hey\"])") == 5
    end

    test "generator expression with sorted()" do
      assert Pyex.run!("sorted(x % 3 for x in range(6))") == [0, 0, 1, 1, 2, 2]
    end
  end
end
