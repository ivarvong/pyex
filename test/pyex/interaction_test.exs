defmodule Pyex.InteractionTest do
  use ExUnit.Case, async: true

  describe "generator inside try/except" do
    test "try/except wrapping generator iteration" do
      code = """
      def count_gen(n):
          for i in range(n):
              yield i

      results = []
      try:
          for x in count_gen(3):
              results.append(x)
      except StopIteration:
          results.append("stopped")
      results
      """

      assert Pyex.run!(code) == [0, 1, 2]
    end

    test "try/except inside a generator function" do
      code = """
      def safe_divide_gen(pairs):
          for a, b in pairs:
              try:
                  yield a // b
              except ZeroDivisionError:
                  yield -1

      list(safe_divide_gen([(10, 2), (6, 3), (5, 0), (8, 4)]))
      """

      assert Pyex.run!(code) == [5, 2, -1, 2]
    end
  end

  describe "decorator on generator" do
    test "decorator wraps a generator function" do
      code = """
      def collect(func):
          def wrapper(*args):
              return list(func(*args))
          return wrapper

      @collect
      def numbers(n):
          for i in range(n):
              yield i * 2

      numbers(5)
      """

      assert Pyex.run!(code) == [0, 2, 4, 6, 8]
    end
  end

  describe "class with generator" do
    test "class method returns filtered data" do
      code = """
      class NumberSource:
          def __init__(self, data):
              self.data = data

          def evens(self):
              result = []
              for item in self.data:
                  if item % 2 == 0:
                      result.append(item)
              return result

      src = NumberSource([1, 2, 3, 4, 5, 6, 7, 8])
      src.evens()
      """

      assert Pyex.run!(code) == [2, 4, 6, 8]
    end

    test "standalone generator consumed by class method" do
      code = """
      def fib_gen(n):
          a, b = 0, 1
          for _ in range(n):
              yield a
              a, b = b, a + b

      class Stats:
          def __init__(self, data):
              self.data = list(data)

          def mean(self):
              return sum(self.data) / len(self.data)

      s = Stats(fib_gen(8))
      (s.data, s.mean())
      """

      assert Pyex.run!(code) == {:tuple, [[0, 1, 1, 2, 3, 5, 8, 13], 4.125]}
    end
  end

  describe "walrus operator in comprehension" do
    test "walrus in list comprehension filter" do
      code = """
      data = ["hello", "", "world", "", "foo"]
      result = [upper for s in data if (upper := s.upper()) != ""]
      result
      """

      assert Pyex.run!(code) == ["HELLO", "WORLD", "FOO"]
    end

    test "walrus in generator expression" do
      code = """
      nums = [1, 4, 2, 8, 3, 7]
      result = list(y for x in nums if (y := x * 2) > 5)
      result
      """

      assert Pyex.run!(code) == [8, 16, 6, 14]
    end
  end

  describe "class with decorator" do
    test "method decorator" do
      code = """
      def log_call(func):
          def wrapper(*args, **kwargs):
              return ("logged", func(*args, **kwargs))
          return wrapper

      class Calculator:
          def __init__(self, value):
              self.value = value

          @log_call
          def double(self):
              return self.value * 2

      c = Calculator(21)
      c.double()
      """

      result = Pyex.run!(code)
      assert result == {:tuple, ["logged", 42]}
    end
  end

  describe "nested comprehension with class" do
    test "comprehension creates class instances" do
      code = """
      class Point:
          def __init__(self, x, y):
              self.x = x
              self.y = y

      points = [Point(x, y) for x in range(3) for y in range(3) if x != y]
      [(p.x, p.y) for p in points]
      """

      result = Pyex.run!(code)

      assert result == [
               {:tuple, [0, 1]},
               {:tuple, [0, 2]},
               {:tuple, [1, 0]},
               {:tuple, [1, 2]},
               {:tuple, [2, 0]},
               {:tuple, [2, 1]}
             ]
    end
  end

  describe "try/except inside comprehension" do
    test "function with try/except used in list comprehension" do
      code = """
      def safe_int(x):
          try:
              return int(x)
          except ValueError:
              return None

      data = ["1", "abc", "3", "def", "5"]
      [safe_int(x) for x in data if safe_int(x) is not None]
      """

      assert Pyex.run!(code) == [1, 3, 5]
    end
  end

  describe "match/case with classes" do
    test "match on class instance attributes" do
      code = """
      class Point:
          def __init__(self, x, y):
              self.x = x
              self.y = y

      def describe(point):
          match point:
              case Point(x=0, y=0):
                  return "origin"
              case Point(x=0, y=y):
                  return f"on y-axis at {y}"
              case Point(x=x, y=0):
                  return f"on x-axis at {x}"
              case Point(x=x, y=y):
                  return f"at ({x}, {y})"

      [describe(Point(0, 0)), describe(Point(0, 5)), describe(Point(3, 0)), describe(Point(1, 2))]
      """

      assert Pyex.run!(code) == [
               "origin",
               "on y-axis at 5",
               "on x-axis at 3",
               "at (1, 2)"
             ]
    end
  end

  describe "generator pipeline" do
    test "chained generators with map and filter semantics" do
      code = """
      def squares(n):
          for i in range(n):
              yield i * i

      def evens(gen):
          for x in gen:
              if x % 2 == 0:
                  yield x

      def take(gen, n):
          count = 0
          for x in gen:
              if count >= n:
                  return
              yield x
              count += 1

      list(take(evens(squares(20)), 5))
      """

      assert Pyex.run!(code) == [0, 4, 16, 36, 64]
    end
  end

  describe "context manager with class" do
    test "with statement calls __enter__ and binds as-var" do
      code = """
      class Resource:
          def __init__(self):
              self.state = "init"

          def __enter__(self):
              self.state = "opened"
              return self

          def __exit__(self, *args):
              pass

      r = Resource()
      with r as res:
          result = res.state
      result
      """

      assert Pyex.run!(code) == "opened"
    end

    test "with statement works without as clause" do
      code = """
      class NullContext:
          def __enter__(self):
              return 42

          def __exit__(self, *args):
              pass

      result = None
      with NullContext():
          result = "executed"
      result
      """

      assert Pyex.run!(code) == "executed"
    end
  end

  describe "inheritance chain with super" do
    test "three-level inheritance with super()" do
      code = """
      class A:
          def greet(self):
              return "A"

      class B(A):
          def greet(self):
              return "B+" + super().greet()

      class C(B):
          def greet(self):
              return "C+" + super().greet()

      C().greet()
      """

      assert Pyex.run!(code) == "C+B+A"
    end
  end

  describe "class with dunder methods used in comprehensions" do
    test "instances with __len__ and __getitem__ in for loop" do
      code = """
      class Row:
          def __init__(self, *values):
              self._data = list(values)

          def __len__(self):
              return len(self._data)

          def __getitem__(self, i):
              return self._data[i]

      rows = [Row(1, 2, 3), Row(4, 5, 6), Row(7, 8, 9)]
      [row[1] for row in rows]
      """

      assert Pyex.run!(code) == [2, 5, 8]
    end
  end

  describe "unpacking in various contexts" do
    test "tuple unpacking from function return" do
      code = """
      def min_max(items):
          return min(items), max(items)

      lo, hi = min_max([5, 2, 8, 1, 9])
      (lo, hi)
      """

      assert Pyex.run!(code) == {:tuple, [1, 9]}
    end

    test "unpacking in for loop from dict items" do
      code = """
      scores = {"alice": 90, "bob": 85, "carol": 95}
      names = []
      for name, score in scores.items():
          if score >= 90:
              names.append(name)
      sorted(names)
      """

      assert Pyex.run!(code) == ["alice", "carol"]
    end

    test "multiple assignment with expressions" do
      code = """
      a, b, c = 1 + 1, 2 * 3, 4 ** 2
      (a, b, c)
      """

      assert Pyex.run!(code) == {:tuple, [2, 6, 16]}
    end
  end

  describe "lambda with closures" do
    test "lambda captures enclosing scope variable" do
      code = """
      def make_adder(n):
          return lambda x: x + n

      add5 = make_adder(5)
      add10 = make_adder(10)
      (add5(3), add10(3))
      """

      assert Pyex.run!(code) == {:tuple, [8, 13]}
    end

    test "lambda used in map" do
      code = """
      result = list(map(lambda x: x ** 2, [1, 2, 3, 4, 5]))
      result
      """

      assert Pyex.run!(code) == [1, 4, 9, 16, 25]
    end

    test "lambda as sort key" do
      code = """
      data = [("b", 2), ("a", 1), ("c", 3)]
      sorted_data = sorted(data, key=lambda x: x[1])
      sorted_data
      """

      assert Pyex.run!(code) == [{:tuple, ["a", 1]}, {:tuple, ["b", 2]}, {:tuple, ["c", 3]}]
    end
  end

  describe "exception handling with classes" do
    test "custom exception class caught by name" do
      code = """
      class AppError(Exception):
          pass

      result = "not caught"
      try:
          raise AppError("not found")
      except AppError:
          result = "caught AppError"
      result
      """

      assert Pyex.run!(code) == "caught AppError"
    end

    test "exception caught as string message" do
      code = """
      class ValidationError(Exception):
          pass

      try:
          raise ValidationError("invalid input")
      except ValidationError as e:
          str(e)
      """

      result = Pyex.run!(code)
      assert result =~ "invalid input"
    end
  end

  describe "global and nonlocal across features" do
    test "nonlocal in nested function inside class" do
      code = """
      class Counter:
          def __init__(self):
              self.count = 0

          def make_incrementer(self):
              count = self.count
              def increment():
                  nonlocal count
                  count += 1
                  return count
              return increment

      c = Counter()
      inc = c.make_incrementer()
      [inc(), inc(), inc()]
      """

      assert Pyex.run!(code) == [1, 2, 3]
    end
  end
end
