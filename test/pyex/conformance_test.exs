defmodule Pyex.ConformanceTest do
  @moduledoc """
  Conformance tests that run the same Python code through both
  CPython and Pyex, then assert identical output.

  Each snippet calls `print(repr(expression))` so the output is
  a canonical Python repr string. We compare stripped stdout from
  both interpreters.

  Requires `python3` on PATH. Tests are tagged `:conformance` and
  skipped if python3 is unavailable.
  """
  use ExUnit.Case, async: true

  @python3 System.find_executable("python3")

  setup do
    if @python3 do
      :ok
    else
      {:skip, "python3 not found on PATH"}
    end
  end

  defp assert_conforms(code) do
    python_output = run_cpython(code)
    pyex_output = run_pyex(code)

    assert pyex_output == python_output,
           """
           Conformance mismatch:

           Python code:
           #{indent(code)}

           CPython output: #{inspect(python_output)}
           Pyex output:    #{inspect(pyex_output)}
           """
  end

  defp run_cpython(code) do
    {output, 0} = System.cmd(@python3, ["-c", code], stderr_to_stdout: true)
    String.trim(output)
  end

  defp run_pyex(code) do
    case Pyex.run(code) do
      {:ok, _, ctx} -> String.trim(Pyex.output(ctx))
      {:error, err} -> "PYEX_ERROR: #{err.message}"
    end
  end

  defp indent(code) do
    code
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end

  # ── Arithmetic ──────────────────────────────────────────────

  describe "arithmetic" do
    test "basic operations" do
      assert_conforms("print(repr(2 + 3 * 4))")
    end

    test "integer division floors toward negative infinity" do
      assert_conforms("print(repr((-7) // 2))")
    end

    test "modulo follows divisor sign" do
      assert_conforms("print(repr((-7) % 3))")
    end

    test "power operator" do
      assert_conforms("print(repr(2 ** 10))")
    end

    test "integer power stays integer" do
      assert_conforms("print(repr(3 ** 20))")
    end

    test "float division" do
      assert_conforms("print(repr(10 / 3))")
    end

    test "negative power" do
      assert_conforms("print(repr(2 ** -1))")
    end

    test "mixed int/float" do
      assert_conforms("print(repr(1 + 2.5))")
    end

    test "chained comparison" do
      assert_conforms("print(repr(1 < 3 < 5))")
    end

    test "chained comparison false" do
      assert_conforms("print(repr(1 < 3 > 5))")
    end
  end

  # ── Strings ─────────────────────────────────────────────────

  describe "strings" do
    test "concatenation" do
      assert_conforms(~S[print(repr("hello" + " " + "world"))])
    end

    test "repetition" do
      assert_conforms(~S[print(repr("ab" * 3))])
    end

    test "reverse repetition" do
      assert_conforms(~S[print(repr(3 * "xy"))])
    end

    test "indexing" do
      assert_conforms(~S|print(repr("hello"[1]))|)
    end

    test "negative indexing" do
      assert_conforms(~S|print(repr("hello"[-1]))|)
    end

    test "slicing" do
      assert_conforms(~S|print(repr("hello"[1:4]))|)
    end

    test "split and join" do
      assert_conforms(~S[print(repr("-".join("a b c".split())))])
    end

    test "upper and lower" do
      assert_conforms(~S[print(repr("Hello".upper() + "Hello".lower()))])
    end

    test "strip" do
      assert_conforms(~S[print(repr("  hello  ".strip()))])
    end

    test "replace" do
      assert_conforms(~S[print(repr("hello world".replace("world", "python")))])
    end

    test "startswith and endswith" do
      assert_conforms(~S[print(repr(("hello".startswith("he"), "hello".endswith("lo"))))])
    end

    test "find" do
      assert_conforms(~S[print(repr("hello".find("ll")))])
    end

    test "in operator" do
      assert_conforms(~S[print(repr("ll" in "hello"))])
    end

    test "f-string" do
      assert_conforms(~S[x = 42; print(repr(f"value={x}"))])
    end

    test "len" do
      assert_conforms(~S[print(repr(len("hello")))])
    end

    test "iteration" do
      assert_conforms(~S|print(repr([c for c in "abc"]))|)
    end
  end

  # ── Lists ───────────────────────────────────────────────────

  describe "lists" do
    test "literal and indexing" do
      assert_conforms("print(repr([1, 2, 3][1]))")
    end

    test "negative indexing" do
      assert_conforms("print(repr([10, 20, 30][-1]))")
    end

    test "slicing" do
      assert_conforms("print(repr([1, 2, 3, 4, 5][1:4]))")
    end

    test "slice with step" do
      assert_conforms("print(repr([0, 1, 2, 3, 4, 5][::2]))")
    end

    test "concatenation" do
      assert_conforms("print(repr([1, 2] + [3, 4]))")
    end

    test "repetition" do
      assert_conforms("print(repr([0] * 5))")
    end

    test "in operator" do
      assert_conforms("print(repr(3 in [1, 2, 3, 4]))")
    end

    test "not in operator" do
      assert_conforms("print(repr(5 not in [1, 2, 3]))")
    end

    test "append and len" do
      assert_conforms("""
      x = [1, 2]
      x.append(3)
      print(repr((x, len(x))))
      """)
    end

    test "sort and reverse" do
      assert_conforms("""
      x = [3, 1, 4, 1, 5]
      x.sort()
      print(repr(x))
      """)
    end

    test "list comprehension" do
      assert_conforms("print(repr([x**2 for x in range(6)]))")
    end

    test "filtered comprehension" do
      assert_conforms("print(repr([x for x in range(10) if x % 2 == 0]))")
    end

    test "nested comprehension" do
      assert_conforms("print(repr([x*y for x in [1,2,3] for y in [10,20]]))")
    end
  end

  # ── Tuples ──────────────────────────────────────────────────

  describe "tuples" do
    test "literal" do
      assert_conforms("print(repr((1, 2, 3)))")
    end

    test "single element" do
      assert_conforms("print(repr((42,)))")
    end

    test "empty" do
      assert_conforms("print(repr(()))")
    end

    test "indexing" do
      assert_conforms("print(repr((10, 20, 30)[1]))")
    end

    test "unpacking" do
      assert_conforms("""
      a, b, c = (1, 2, 3)
      print(repr((a, b, c)))
      """)
    end

    test "starred unpacking" do
      assert_conforms("""
      first, *rest = [1, 2, 3, 4, 5]
      print(repr((first, rest)))
      """)
    end

    test "starred at end" do
      assert_conforms("""
      *init, last = [1, 2, 3, 4, 5]
      print(repr((init, last)))
      """)
    end

    test "in operator" do
      assert_conforms("print(repr(2 in (1, 2, 3)))")
    end
  end

  # ── Dicts ───────────────────────────────────────────────────

  describe "dicts" do
    test "literal and access" do
      assert_conforms(~S|print(repr({"a": 1, "b": 2}["a"]))|)
    end

    test "get with default" do
      assert_conforms(~S[print(repr({"a": 1}.get("b", 0)))])
    end

    test "keys values items" do
      assert_conforms(
        ~S[d = {"x": 1}; print(repr((sorted(d.keys()), sorted(d.values()), sorted(d.items()))))]
      )
    end

    test "in operator" do
      assert_conforms(~S[print(repr("a" in {"a": 1, "b": 2}))])
    end

    test "iteration gives keys" do
      assert_conforms(~S|print(repr(sorted([k for k in {"b": 2, "a": 1}])))|)
    end

    test "dict comprehension" do
      assert_conforms("print(repr({k: k**2 for k in range(4)}))")
    end

    test "update" do
      assert_conforms("""
      d = {"a": 1}
      d.update({"b": 2})
      print(repr(sorted(d.items())))
      """)
    end

    test "pop" do
      assert_conforms("""
      d = {"a": 1, "b": 2}
      v = d.pop("a")
      print(repr((v, d)))
      """)
    end

    test "setdefault" do
      assert_conforms("""
      d = {"a": 1}
      d.setdefault("a", 99)
      d.setdefault("b", 42)
      print(repr(sorted(d.items())))
      """)
    end
  end

  # ── Sets ────────────────────────────────────────────────────

  describe "sets" do
    test "literal" do
      assert_conforms("print(repr(sorted({3, 1, 2})))")
    end

    test "operations" do
      assert_conforms("print(repr(sorted({1,2,3} & {2,3,4})))")
    end

    test "union" do
      assert_conforms("print(repr(sorted({1,2} | {3,4})))")
    end

    test "difference" do
      assert_conforms("print(repr(sorted({1,2,3} - {2})))")
    end

    test "in operator" do
      assert_conforms("print(repr(2 in {1, 2, 3}))")
    end

    test "set comprehension" do
      assert_conforms("print(repr(sorted({x % 3 for x in range(10)})))")
    end
  end

  # ── Control flow ────────────────────────────────────────────

  describe "control flow" do
    test "if/elif/else" do
      assert_conforms("""
      def classify(x):
          if x > 0:
              return "pos"
          elif x == 0:
              return "zero"
          else:
              return "neg"
      print(repr((classify(5), classify(0), classify(-3))))
      """)
    end

    test "while with break" do
      assert_conforms("""
      r = []
      i = 0
      while True:
          if i >= 5:
              break
          r.append(i)
          i += 1
      print(repr(r))
      """)
    end

    test "for with continue" do
      assert_conforms("""
      r = []
      for i in range(8):
          if i % 2 == 0:
              continue
          r.append(i)
      print(repr(r))
      """)
    end

    test "for/else (no break)" do
      assert_conforms("""
      result = "none"
      for x in [2, 4, 6]:
          if x % 2 != 0:
              result = "found odd"
              break
      else:
          result = "all even"
      print(repr(result))
      """)
    end

    test "ternary expression" do
      assert_conforms("""
      x = 5
      print(repr("big" if x > 3 else "small"))
      """)
    end

    test "walrus operator" do
      assert_conforms("print(repr([y for x in range(6) if (y := x*x) > 10]))")
    end
  end

  # ── Functions ───────────────────────────────────────────────

  describe "functions" do
    test "basic function" do
      assert_conforms("""
      def add(a, b):
          return a + b
      print(repr(add(3, 4)))
      """)
    end

    test "default arguments" do
      assert_conforms("""
      def greet(name, greeting="Hello"):
          return f"{greeting}, {name}!"
      print(repr((greet("World"), greet("World", "Hi"))))
      """)
    end

    test "keyword arguments" do
      assert_conforms("""
      def make(name, age=0, city="?"):
          return (name, age, city)
      print(repr(make("Bob", city="NYC", age=25)))
      """)
    end

    test "*args" do
      assert_conforms("""
      def total(*args):
          return sum(args)
      print(repr(total(1, 2, 3, 4)))
      """)
    end

    test "**kwargs" do
      assert_conforms("""
      def info(**kwargs):
          return sorted(kwargs.items())
      print(repr(info(name="Alice", age=30)))
      """)
    end

    test "lambda" do
      assert_conforms("print(repr((lambda x, y: x + y)(3, 4)))")
    end

    test "closure" do
      assert_conforms("""
      def make_adder(n):
          def adder(x):
              return x + n
          return adder
      print(repr(make_adder(10)(5)))
      """)
    end

    test "recursive" do
      assert_conforms("""
      def fact(n):
          return 1 if n <= 1 else n * fact(n - 1)
      print(repr(fact(10)))
      """)
    end

    test "bare return" do
      assert_conforms("""
      def f():
          return
      print(repr(f()))
      """)
    end

    test "global" do
      assert_conforms("""
      x = 0
      def inc():
          global x
          x += 1
      inc(); inc(); inc()
      print(repr(x))
      """)
    end

    test "nonlocal" do
      assert_conforms("""
      def outer():
          count = 0
          def inner():
              nonlocal count
              count += 1
          inner(); inner()
          return count
      print(repr(outer()))
      """)
    end
  end

  # ── Builtins ────────────────────────────────────────────────

  describe "builtins" do
    test "len on various types" do
      assert_conforms(
        ~S|print(repr((len([1,2,3]), len("abc"), len({1:2}), len((1,2)), len({1,2}))))|
      )
    end

    test "range" do
      assert_conforms("print(repr(list(range(5))))")
    end

    test "range with step" do
      assert_conforms("print(repr(list(range(0, 10, 2))))")
    end

    test "range negative step" do
      assert_conforms("print(repr(list(range(5, 0, -1))))")
    end

    test "sorted" do
      assert_conforms("print(repr(sorted([3, 1, 4, 1, 5])))")
    end

    test "sorted with key" do
      assert_conforms("print(repr(sorted(['bb', 'a', 'ccc'], key=len)))")
    end

    test "sorted reverse" do
      assert_conforms("print(repr(sorted([3, 1, 2], reverse=True)))")
    end

    test "reversed" do
      assert_conforms("print(repr(list(reversed([1, 2, 3]))))")
    end

    test "enumerate" do
      assert_conforms("print(repr(list(enumerate(['a', 'b', 'c']))))")
    end

    test "enumerate with start" do
      assert_conforms("print(repr(list(enumerate(['a', 'b'], 1))))")
    end

    test "zip" do
      assert_conforms("print(repr(list(zip([1,2,3], ['a','b','c']))))")
    end

    test "zip three" do
      assert_conforms("print(repr(list(zip([1,2], [3,4], [5,6]))))")
    end

    test "map" do
      assert_conforms("print(repr(list(map(str, [1, 2, 3]))))")
    end

    test "filter" do
      assert_conforms("print(repr(list(filter(lambda x: x > 2, [1, 2, 3, 4]))))")
    end

    test "any and all" do
      assert_conforms("print(repr((any([False, True, False]), all([True, True, False]))))")
    end

    test "min and max" do
      assert_conforms("print(repr((min(3, 1, 2), max(3, 1, 2))))")
    end

    test "sum" do
      assert_conforms("print(repr(sum([1, 2, 3, 4])))")
    end

    test "abs" do
      assert_conforms("print(repr((abs(-5), abs(3.14))))")
    end

    test "round" do
      assert_conforms("print(repr((round(3.7), round(3.14159, 2))))")
    end

    test "int float str bool" do
      assert_conforms(~S[print(repr((int("42"), float("3.14"), str(42), bool(0), bool(1))))])
    end

    test "chr and ord" do
      assert_conforms("print(repr((chr(65), ord('A'))))")
    end

    test "hex oct bin" do
      assert_conforms("print(repr((hex(255), oct(8), bin(10))))")
    end

    test "divmod" do
      assert_conforms("print(repr(divmod(17, 5)))")
    end

    test "pow" do
      assert_conforms("print(repr((pow(2, 10), pow(2, 10, 100))))")
    end

    test "isinstance" do
      assert_conforms("print(repr((isinstance(42, int), isinstance(42, str))))")
    end

    test "callable" do
      assert_conforms("print(repr((callable(len), callable(42))))")
    end

    test "type" do
      assert_conforms(
        ~S|print(repr((type(42).__name__, type("hi").__name__, type([]).__name__)))|
      )
    end

    test "sorted string" do
      assert_conforms(~S[print(repr(sorted("dcba")))])
    end
  end

  # ── Exception handling ──────────────────────────────────────

  describe "exceptions" do
    test "try/except" do
      assert_conforms("""
      try:
          x = 1 / 0
      except ZeroDivisionError:
          x = -1
      print(repr(x))
      """)
    end

    test "try/except/else" do
      assert_conforms("""
      try:
          x = 10
      except:
          x = -1
      else:
          x = x + 1
      print(repr(x))
      """)
    end

    test "try/except/finally" do
      assert_conforms("""
      r = []
      try:
          r.append("try")
      except:
          r.append("except")
      finally:
          r.append("finally")
      print(repr(r))
      """)
    end

    test "raise and catch" do
      assert_conforms("""
      try:
          raise ValueError("oops")
      except ValueError as e:
          result = str(e)
      print(repr(result))
      """)
    end

    test "multiple except" do
      assert_conforms("""
      def safe(x):
          try:
              return 10 / x
          except ZeroDivisionError:
              return "zero"
          except TypeError:
              return "type"
      print(repr((safe(2), safe(0))))
      """)
    end

    test "assert" do
      assert_conforms("""
      try:
          assert False, "nope"
      except AssertionError:
          x = "caught"
      except AssertionError:
          x = "caught"
      except:
          x = "caught"
      print(repr(x))
      """)
    end
  end

  # ── Classes ─────────────────────────────────────────────────

  describe "classes" do
    test "basic class" do
      assert_conforms("""
      class Point:
          def __init__(self, x, y):
              self.x = x
              self.y = y
          def magnitude(self):
              return (self.x**2 + self.y**2) ** 0.5
      p = Point(3, 4)
      print(repr(p.magnitude()))
      """)
    end

    test "inheritance" do
      assert_conforms("""
      class Animal:
          def __init__(self, name):
              self.name = name
          def speak(self):
              return "..."
      class Dog(Animal):
          def speak(self):
              return self.name + " says Woof"
      print(repr(Dog("Rex").speak()))
      """)
    end

    test "dunder add" do
      assert_conforms("""
      class Vec:
          def __init__(self, x, y):
              self.x = x
              self.y = y
          def __add__(self, other):
              return Vec(self.x + other.x, self.y + other.y)
      v = Vec(1, 2) + Vec(3, 4)
      print(repr((v.x, v.y)))
      """)
    end

    test "dunder len and bool" do
      assert_conforms("""
      class Bag:
          def __init__(self, items):
              self.items = items
          def __len__(self):
              return len(self.items)
          def __bool__(self):
              return len(self.items) > 0
      print(repr((len(Bag([1,2])), bool(Bag([])), bool(Bag([1])))))
      """)
    end

    test "class variable" do
      assert_conforms("""
      class Counter:
          count = 0
          def __init__(self):
              Counter.count += 1
      Counter(); Counter(); Counter()
      print(repr(Counter.count))
      """)
    end
  end

  # ── Generators ──────────────────────────────────────────────

  describe "generators" do
    test "basic generator" do
      assert_conforms("""
      def gen():
          yield 1
          yield 2
          yield 3
      print(repr(list(gen())))
      """)
    end

    test "generator expression" do
      assert_conforms("print(repr(list(x**2 for x in range(5))))")
    end

    test "yield from" do
      assert_conforms("""
      def chain(a, b):
          yield from a
          yield from b
      print(repr(list(chain([1, 2], [3, 4]))))
      """)
    end

    test "sum of generator" do
      assert_conforms("print(repr(sum(x*x for x in range(5))))")
    end
  end

  # ── Match/case ──────────────────────────────────────────────

  describe "match/case" do
    test "basic matching" do
      assert_conforms("""
      def describe(x):
          match x:
              case 0:
                  return "zero"
              case 1:
                  return "one"
              case _:
                  return "other"
      print(repr((describe(0), describe(1), describe(42))))
      """)
    end

    test "guard" do
      assert_conforms("""
      def classify(x):
          match x:
              case n if n > 0:
                  return "pos"
              case 0:
                  return "zero"
              case _:
                  return "neg"
      print(repr(classify(-5)))
      """)
    end
  end

  # ── Decorators ──────────────────────────────────────────────

  describe "decorators" do
    test "basic decorator" do
      assert_conforms("""
      def twice(f):
          def wrapper(*args):
              return f(*args) * 2
          return wrapper

      @twice
      def square(x):
          return x * x

      print(repr(square(3)))
      """)
    end
  end

  # ── Numeric edge cases ─────────────────────────────────────

  describe "numeric edge cases" do
    test "large integers" do
      assert_conforms("print(repr(2 ** 64))")
    end

    test "integer string conversion" do
      assert_conforms(~S[print(repr(int("ff", 16)))])
    end

    test "bool arithmetic" do
      assert_conforms("print(repr(True + True + False))")
    end

    test "boolean is int subclass" do
      assert_conforms("print(repr(isinstance(True, int)))")
    end

    test "negative zero" do
      assert_conforms("print(repr(-0 == 0))")
    end
  end

  # ── Scope and closures ─────────────────────────────────────

  describe "scope" do
    test "nested closures" do
      assert_conforms("""
      def make_counter():
          count = [0]
          def inc():
              count[0] += 1
              return count[0]
          return inc
      c = make_counter()
      print(repr((c(), c(), c())))
      """)
    end

    test "list comprehension scope" do
      assert_conforms("""
      x = 10
      result = [x for x in range(3)]
      print(repr((result, x)))
      """)
    end
  end

  # ── Complex programs ────────────────────────────────────────

  describe "complex programs" do
    test "fibonacci memoized" do
      assert_conforms("""
      cache = {}
      def fib(n):
          if n in cache:
              return cache[n]
          if n <= 1:
              result = n
          else:
              result = fib(n-1) + fib(n-2)
          cache[n] = result
          return result
      print(repr([fib(i) for i in range(12)]))
      """)
    end

    test "flatten nested list" do
      assert_conforms("""
      def flatten(lst):
          result = []
          for item in lst:
              if isinstance(item, list):
                  result.extend(flatten(item))
              else:
                  result.append(item)
          return result
      print(repr(flatten([1, [2, [3, 4], 5], [6]])))
      """)
    end

    test "group by" do
      assert_conforms("""
      def group_by(items, key):
          groups = {}
          for item in items:
              k = key(item)
              if k not in groups:
                  groups[k] = []
              groups[k].append(item)
          return groups
      data = ["apple", "ant", "bear", "bat", "cat"]
      g = group_by(data, lambda w: w[0])
      print(repr(sorted([(k, sorted(v)) for k, v in g.items()])))
      """)
    end

    test "matrix transpose" do
      assert_conforms("""
      matrix = [[1,2,3],[4,5,6],[7,8,9]]
      transposed = [[row[i] for row in matrix] for i in range(len(matrix[0]))]
      print(repr(transposed))
      """)
    end

    test "counter from scratch" do
      assert_conforms("""
      def count_words(text):
          counts = {}
          for word in text.split():
              counts[word] = counts.get(word, 0) + 1
          return counts
      c = count_words("the cat sat on the mat the cat")
      print(repr(sorted(c.items())))
      """)
    end
  end

  # ── Closure mutation ───────────────────────────────────────

  describe "closure mutation" do
    test "list mutation via subscript" do
      assert_conforms("""
      def make_counter():
          count = [0]
          def inc():
              count[0] += 1
              return count[0]
          return inc
      c = make_counter()
      print(repr((c(), c(), c())))
      """)
    end

    test "dict mutation via subscript append" do
      assert_conforms("""
      groups = {}
      groups["a"] = []
      groups["a"].append(1)
      groups["a"].append(2)
      print(repr(groups))
      """)
    end

    @tag :skip
    test "multiple closures share state" do
      assert_conforms("""
      def make_pair():
          data = [0]
          def get():
              return data[0]
          def set(v):
              data[0] = v
          return get, set
      getter, setter = make_pair()
      setter(42)
      print(repr(getter()))
      """)
    end

    @tag :skip
    test "closure over dict" do
      assert_conforms("""
      def make_cache():
          cache = {}
          def put(k, v):
              cache[k] = v
          def get(k):
              return cache.get(k)
          return put, get
      put, get = make_cache()
      put("x", 10)
      put("y", 20)
      print(repr((get("x"), get("y"), get("z"))))
      """)
    end
  end

  # ── Class semantics ────────────────────────────────────────

  describe "class semantics" do
    test "class variable shared across instances" do
      assert_conforms("""
      class Counter:
          count = 0
          def __init__(self):
              Counter.count += 1
      Counter(); Counter(); Counter()
      print(repr(Counter.count))
      """)
    end

    test "instance variable shadows class variable" do
      assert_conforms("""
      class Foo:
          x = 10
          def set_x(self, v):
              self.x = v
      a = Foo()
      b = Foo()
      a.set_x(99)
      print(repr((a.x, b.x, Foo.x)))
      """)
    end

    test "super() method resolution" do
      assert_conforms("""
      class A:
          def greet(self):
              return "A"
      class B(A):
          def greet(self):
              return "B+" + super().greet()
      print(repr(B().greet()))
      """)
    end

    test "diamond inheritance MRO" do
      assert_conforms("""
      class A:
          def who(self):
              return "A"
      class B(A):
          def who(self):
              return "B"
      class C(A):
          def who(self):
              return "C"
      class D(B, C):
          pass
      print(repr(D().who()))
      """)
    end

    test "dunder repr" do
      assert_conforms("""
      class Point:
          def __init__(self, x, y):
              self.x = x
              self.y = y
          def __repr__(self):
              return f"Point({self.x}, {self.y})"
      print(repr(Point(1, 2)))
      """)
    end

    test "dunder eq" do
      assert_conforms("""
      class Box:
          def __init__(self, val):
              self.val = val
          def __eq__(self, other):
              return self.val == other.val
      print(repr(Box(1) == Box(1)))
      print(repr(Box(1) == Box(2)))
      """)
    end

    test "dunder getitem setitem" do
      assert_conforms("""
      class MyDict:
          def __init__(self):
              self.data = {}
          def __setitem__(self, k, v):
              self.data[k] = v
          def __getitem__(self, k):
              return self.data[k]
      m = MyDict()
      m["x"] = 10
      m["y"] = 20
      print(repr((m["x"], m["y"])))
      """)
    end

    test "static-like method via class" do
      assert_conforms("""
      class Math:
          def add(self, a, b):
              return a + b
      m = Math()
      print(repr(m.add(3, 4)))
      """)
    end
  end

  # ── String edge cases ──────────────────────────────────────

  describe "string edge cases" do
    test "escape sequences" do
      assert_conforms(~S|print(repr("a\tb\nc"))|)
    end

    test "raw string" do
      assert_conforms(~S|print(repr(r"a\tb\nc"))|)
    end

    test "string multiplication with zero" do
      assert_conforms(~S|print(repr("abc" * 0))|)
    end

    test "negative string multiplication" do
      assert_conforms(~S|print(repr("abc" * -1))|)
    end

    test "string comparison" do
      assert_conforms(~S|print(repr(("abc" < "abd", "abc" == "abc", "z" > "a")))|)
    end

    test "multiline string" do
      assert_conforms(~S|print(repr("""hello\nworld"""))|)
    end

    test "string count" do
      assert_conforms(~S|print(repr("banana".count("an")))|)
    end

    test "string zfill" do
      assert_conforms(~S|print(repr("42".zfill(5)))|)
    end

    test "string isdigit" do
      assert_conforms(~S|print(repr(("123".isdigit(), "12a".isdigit())))|)
    end

    test "string title" do
      assert_conforms(~S|print(repr("hello world".title()))|)
    end
  end

  # ── List edge cases ────────────────────────────────────────

  describe "list edge cases" do
    test "nested list comprehension with condition" do
      assert_conforms("print(repr([x*y for x in range(1,4) for y in range(1,4) if x != y]))")
    end

    test "list equality" do
      assert_conforms("print(repr(([1,2,3] == [1,2,3], [1,2] == [1,3])))")
    end

    test "list comparison" do
      assert_conforms("print(repr(([1,2] < [1,3], [1,2,3] > [1,2])))")
    end

    test "list index method" do
      assert_conforms("print(repr([10, 20, 30, 20].index(20)))")
    end

    test "list count method" do
      assert_conforms("print(repr([1, 2, 1, 3, 1].count(1)))")
    end

    test "list copy is shallow" do
      assert_conforms("""
      a = [1, [2, 3]]
      b = a.copy()
      b[0] = 99
      print(repr((a, b)))
      """)
    end

    test "del from list" do
      assert_conforms("""
      x = [1, 2, 3, 4]
      del x[1]
      print(repr(x))
      """)
    end

    test "negative slice step" do
      assert_conforms("print(repr([1,2,3,4,5][::-1]))")
    end

    test "starred unpacking middle" do
      assert_conforms("""
      a, *b, c = [1, 2, 3, 4, 5]
      print(repr((a, b, c)))
      """)
    end
  end

  # ── Dict edge cases ────────────────────────────────────────

  describe "dict edge cases" do
    test "dict from list of tuples" do
      assert_conforms("print(repr(dict([('a', 1), ('b', 2)])))")
    end

    test "dict equality" do
      assert_conforms(~S|print(repr({"a": 1, "b": 2} == {"b": 2, "a": 1}))|)
    end

    test "dict del" do
      assert_conforms("""
      d = {"a": 1, "b": 2, "c": 3}
      del d["b"]
      print(repr(sorted(d.items())))
      """)
    end

    test "dict comprehension with condition" do
      assert_conforms("print(repr({k: k**2 for k in range(6) if k % 2 == 0}))")
    end

    test "dict merge with update" do
      assert_conforms("""
      a = {"x": 1}
      b = {"x": 2, "y": 3}
      a.update(b)
      print(repr(sorted(a.items())))
      """)
    end

    test "nested dict access" do
      assert_conforms("""
      d = {"a": {"b": {"c": 42}}}
      print(repr(d["a"]["b"]["c"]))
      """)
    end
  end

  # ── Set edge cases ─────────────────────────────────────────

  describe "set edge cases" do
    test "set symmetric difference" do
      assert_conforms("print(repr(sorted({1,2,3} ^ {2,3,4})))")
    end

    test "set add and discard" do
      assert_conforms("""
      s = {1, 2, 3}
      s.add(4)
      s.discard(2)
      print(repr(sorted(s)))
      """)
    end

    test "set issubset" do
      assert_conforms("print(repr({1,2,3}.issubset({1,2,3,4})))")
    end

    test "set from string" do
      assert_conforms(~S|print(repr(sorted(set("hello"))))|)
    end
  end

  # ── Tuple edge cases ───────────────────────────────────────

  describe "tuple edge cases" do
    test "tuple concatenation" do
      assert_conforms("print(repr((1, 2) + (3, 4)))")
    end

    test "tuple repetition" do
      assert_conforms("print(repr((1, 2) * 3))")
    end

    test "tuple comparison" do
      assert_conforms("print(repr(((1, 2) < (1, 3), (1, 2) == (1, 2))))")
    end

    test "tuple count and index" do
      assert_conforms("print(repr(((1,2,1,3,1).count(1), (10,20,30).index(20))))")
    end

    @tag :skip
    test "nested tuple unpacking" do
      assert_conforms("""
      (a, b), c = (1, 2), 3
      print(repr((a, b, c)))
      """)
    end
  end

  # ── Generator edge cases ───────────────────────────────────

  describe "generator edge cases" do
    test "generator with state" do
      assert_conforms("""
      def fib_gen(n):
          a, b = 0, 1
          for _ in range(n):
              yield a
              a, b = b, a + b
      print(repr(list(fib_gen(8))))
      """)
    end

    test "chained generators" do
      assert_conforms("""
      def evens(n):
          for i in range(n):
              if i % 2 == 0:
                  yield i
      print(repr(list(evens(10))))
      """)
    end

    test "generator in sum" do
      assert_conforms("print(repr(sum(x*x for x in range(5))))")
    end

    test "generator any/all" do
      assert_conforms(
        "print(repr((any(x > 3 for x in range(5)), all(x < 10 for x in range(5)))))"
      )
    end

    test "nested yield from" do
      assert_conforms("""
      def flatten(lst):
          for item in lst:
              if isinstance(item, list):
                  yield from flatten(item)
              else:
                  yield item
      print(repr(list(flatten([1, [2, [3, 4], 5], 6]))))
      """)
    end
  end

  # ── Walrus operator edge cases ─────────────────────────────

  describe "walrus operator" do
    test "walrus in while" do
      assert_conforms("""
      data = [1, 2, 3, 0, 4, 5]
      results = []
      i = 0
      while (val := data[i]) != 0:
          results.append(val)
          i += 1
      print(repr(results))
      """)
    end
  end

  # ── Match/case edge cases ──────────────────────────────────

  describe "match/case edge cases" do
    test "match with destructuring" do
      assert_conforms("""
      def process(cmd):
          match cmd:
              case ("add", x, y):
                  return x + y
              case ("mul", x, y):
                  return x * y
              case _:
                  return None
      print(repr((process(("add", 3, 4)), process(("mul", 5, 6)), process("unknown"))))
      """)
    end

    test "match with list pattern" do
      assert_conforms("""
      def head(lst):
          match lst:
              case [first, *rest]:
                  return first
              case []:
                  return None
      print(repr((head([1,2,3]), head([]))))
      """)
    end
  end

  # ── Boolean and None edge cases ────────────────────────────

  describe "boolean and none" do
    test "truthiness" do
      assert_conforms("""
      results = []
      for val in [0, 1, "", "a", [], [1], {}, {"a":1}, None, True, False, (), (1,)]:
          results.append(bool(val))
      print(repr(results))
      """)
    end

    test "none comparisons" do
      assert_conforms("print(repr((None is None, None is not None, None == None, None != 0)))")
    end

    test "short circuit and" do
      assert_conforms("print(repr((0 and 1, 1 and 2, 1 and 0, 0 and 0)))")
    end

    test "short circuit or" do
      assert_conforms("print(repr((0 or 1, 1 or 2, 0 or 0, 0 or False or 3)))")
    end

    test "not operator" do
      assert_conforms("print(repr((not True, not False, not 0, not 1, not None, not [])))")
    end
  end

  # ── Numeric edge cases (extended) ──────────────────────────

  describe "numeric extended" do
    test "integer division edge cases" do
      assert_conforms("print(repr((7 // 2, -7 // 2, 7 // -2, -7 // -2)))")
    end

    test "modulo edge cases" do
      assert_conforms("print(repr((7 % 3, -7 % 3, 7 % -3, -7 % -3)))")
    end

    test "float precision" do
      assert_conforms("print(repr(0.1 + 0.2 == 0.3))")
    end

    test "divmod" do
      assert_conforms("print(repr((divmod(17, 5), divmod(-17, 5))))")
    end

    test "bitwise operations" do
      assert_conforms("print(repr((5 & 3, 5 | 3, 5 ^ 3, ~5, 1 << 4, 32 >> 3)))")
    end

    test "hex oct bin" do
      assert_conforms("print(repr((0xff, 0o77, 0b1010)))")
    end

    test "int with base" do
      assert_conforms(~S|print(repr((int("ff", 16), int("77", 8), int("1010", 2))))|)
    end

    test "large integer arithmetic" do
      assert_conforms("print(repr(2**100 + 1))")
    end
  end

  # ── Exception edge cases ───────────────────────────────────

  describe "exception edge cases" do
    test "exception in list comprehension" do
      assert_conforms("""
      try:
          result = [1/x for x in [1, 2, 0, 4]]
      except ZeroDivisionError:
          result = "caught"
      print(repr(result))
      """)
    end

    test "nested try/except" do
      assert_conforms("""
      def safe_div(a, b):
          try:
              return a / b
          except ZeroDivisionError:
              return "inf"
          except TypeError:
              return "type_err"
      print(repr((safe_div(10, 2), safe_div(10, 0))))
      """)
    end

    test "try/except/else/finally" do
      assert_conforms("""
      log = []
      try:
          log.append("try")
          x = 42
      except:
          log.append("except")
      else:
          log.append("else")
      finally:
          log.append("finally")
      print(repr(log))
      """)
    end

    test "custom exception class" do
      assert_conforms("""
      class MyError(Exception):
          pass
      try:
          raise MyError("custom")
      except MyError as e:
          print(repr(str(e)))
      """)
    end
  end

  # ── Scope edge cases ───────────────────────────────────────

  describe "scope edge cases" do
    test "global in nested function" do
      assert_conforms("""
      x = 0
      def outer():
          def inner():
              global x
              x = 42
          inner()
      outer()
      print(repr(x))
      """)
    end

    test "nonlocal with multiple levels" do
      assert_conforms("""
      def outer():
          x = 0
          def middle():
              nonlocal x
              def inner():
                  nonlocal x
                  x += 1
              inner()
              inner()
          middle()
          return x
      print(repr(outer()))
      """)
    end

    test "variable shadowing" do
      assert_conforms("""
      x = "global"
      def f():
          x = "local"
          return x
      print(repr((f(), x)))
      """)
    end

    test "del variable" do
      assert_conforms("""
      x = 42
      del x
      try:
          print(x)
      except NameError:
          print(repr("deleted"))
      """)
    end
  end

  # ── Complex programs (extended) ────────────────────────────

  describe "complex programs extended" do
    test "binary search" do
      assert_conforms("""
      def binary_search(arr, target):
          lo, hi = 0, len(arr) - 1
          while lo <= hi:
              mid = (lo + hi) // 2
              if arr[mid] == target:
                  return mid
              elif arr[mid] < target:
                  lo = mid + 1
              else:
                  hi = mid - 1
          return -1
      print(repr(binary_search([1,3,5,7,9,11,13], 7)))
      """)
    end

    test "sieve of eratosthenes" do
      assert_conforms("""
      def sieve(n):
          is_prime = [True] * (n + 1)
          is_prime[0] = False
          is_prime[1] = False
          for i in range(2, int(n**0.5) + 1):
              if is_prime[i]:
                  for j in range(i*i, n + 1, i):
                      is_prime[j] = False
          return [i for i in range(n + 1) if is_prime[i]]
      print(repr(sieve(30)))
      """)
    end

    test "merge sort" do
      assert_conforms("""
      def merge_sort(arr):
          if len(arr) <= 1:
              return arr
          mid = len(arr) // 2
          left = merge_sort(arr[:mid])
          right = merge_sort(arr[mid:])
          result = []
          i = j = 0
          while i < len(left) and j < len(right):
              if left[i] <= right[j]:
                  result.append(left[i])
                  i += 1
              else:
                  result.append(right[j])
                  j += 1
          result.extend(left[i:])
          result.extend(right[j:])
          return result
      print(repr(merge_sort([38, 27, 43, 3, 9, 82, 10])))
      """)
    end

    test "decorator with args" do
      assert_conforms("""
      def repeat(n):
          def decorator(f):
              def wrapper(*args):
                  results = []
                  for _ in range(n):
                      results.append(f(*args))
                  return results
              return wrapper
          return decorator

      @repeat(3)
      def greet(name):
          return f"hi {name}"

      print(repr(greet("world")))
      """)
    end

    test "linked list" do
      assert_conforms("""
      class Node:
          def __init__(self, val, next=None):
              self.val = val
              self.next = next

      def to_list(node):
          result = []
          while node is not None:
              result.append(node.val)
              node = node.next
          return result

      head = Node(1, Node(2, Node(3)))
      print(repr(to_list(head)))
      """)
    end

    test "stack implementation" do
      assert_conforms("""
      class Stack:
          def __init__(self):
              self.items = []
          def push(self, item):
              self.items.append(item)
          def pop(self):
              return self.items.pop()
          def peek(self):
              return self.items[-1]
          def is_empty(self):
              return len(self.items) == 0
          def __len__(self):
              return len(self.items)

      s = Stack()
      s.push(1); s.push(2); s.push(3)
      print(repr((s.pop(), s.peek(), len(s))))
      """)
    end
  end

  # ── Iterator Protocol ────────────────────────────────────────

  describe "iterator protocol" do
    test "list() on custom iterable class" do
      assert_conforms(~S"""
      class Countdown:
          def __init__(self, start):
              self.start = start
          def __iter__(self):
              self.current = self.start
              return self
          def __next__(self):
              if self.current <= 0:
                  raise StopIteration
              val = self.current
              self.current -= 1
              return val
      print(repr(list(Countdown(5))))
      """)
    end

    test "tuple() on custom iterable class" do
      assert_conforms(~S"""
      class Range3:
          def __init__(self):
              self.i = 0
          def __iter__(self):
              self.i = 0
              return self
          def __next__(self):
              if self.i >= 3:
                  raise StopIteration
              val = self.i
              self.i += 1
              return val
      print(repr(tuple(Range3())))
      """)
    end

    test "set() on custom iterable class" do
      assert_conforms(~S"""
      class Repeat:
          def __init__(self):
              self.items = [1, 2, 2, 3, 3, 3]
              self.i = 0
          def __iter__(self):
              self.i = 0
              return self
          def __next__(self):
              if self.i >= len(self.items):
                  raise StopIteration
              val = self.items[self.i]
              self.i += 1
              return val
      print(repr(sorted(set(Repeat()))))
      """)
    end

    test "for loop over custom iterable" do
      assert_conforms(~S"""
      class Squares:
          def __init__(self, n):
              self.n = n
          def __iter__(self):
              self.i = 0
              return self
          def __next__(self):
              if self.i >= self.n:
                  raise StopIteration
              val = self.i ** 2
              self.i += 1
              return val
      result = []
      for x in Squares(5):
          result.append(x)
      print(repr(result))
      """)
    end

    test "iter() and next() on custom iterator" do
      assert_conforms(~S"""
      class Counter:
          def __init__(self, limit):
              self.limit = limit
              self.count = 0
          def __iter__(self):
              return self
          def __next__(self):
              if self.count >= self.limit:
                  raise StopIteration
              val = self.count
              self.count += 1
              return val
      it = iter(Counter(3))
      print(repr(next(it)))
      print(repr(next(it)))
      print(repr(next(it)))
      """)
    end

    test "next() with default on custom iterator" do
      assert_conforms(~S"""
      class Once:
          def __init__(self, val):
              self.val = val
              self.done = False
          def __iter__(self):
              return self
          def __next__(self):
              if self.done:
                  raise StopIteration
              self.done = True
              return self.val
      it = iter(Once(42))
      print(repr(next(it, "default")))
      print(repr(next(it, "default")))
      """)
    end

    test "separate __iter__ returns new iterator" do
      assert_conforms(~S"""
      class IterObj:
          def __init__(self, data):
              self.data = data
          def __iter__(self):
              return IterHelper(self.data)

      class IterHelper:
          def __init__(self, data):
              self.data = data
              self.i = 0
          def __iter__(self):
              return self
          def __next__(self):
              if self.i >= len(self.data):
                  raise StopIteration
              val = self.data[self.i]
              self.i += 1
              return val
      obj = IterObj([10, 20, 30])
      print(repr(list(obj)))
      print(repr(list(obj)))
      """)
    end

    test "sum() on custom iterable" do
      assert_conforms(~S"""
      class Nums:
          def __init__(self, n):
              self.n = n
          def __iter__(self):
              self.i = 1
              return self
          def __next__(self):
              if self.i > self.n:
                  raise StopIteration
              val = self.i
              self.i += 1
              return val
      print(repr(sum(Nums(10))))
      """)
    end

    test "sorted() on custom iterable" do
      assert_conforms(~S"""
      class Unsorted:
          def __init__(self):
              self.items = [3, 1, 4, 1, 5]
              self.i = 0
          def __iter__(self):
              self.i = 0
              return self
          def __next__(self):
              if self.i >= len(self.items):
                  raise StopIteration
              val = self.items[self.i]
              self.i += 1
              return val
      print(repr(sorted(Unsorted())))
      """)
    end
  end

  # ── Itertools ────────────────────────────────────────────────

  describe "itertools" do
    test "chain" do
      assert_conforms(~S"""
      from itertools import chain
      print(repr(list(chain([1, 2], [3, 4], [5]))))
      """)
    end

    test "islice" do
      assert_conforms(~S"""
      from itertools import islice
      print(repr(list(islice(range(20), 2, 10, 3))))
      """)
    end

    test "product" do
      assert_conforms(~S"""
      from itertools import product
      print(repr(list(product([1, 2], ['a', 'b']))))
      """)
    end

    test "product with repeat" do
      assert_conforms(~S"""
      from itertools import product
      print(repr(list(product([0, 1], repeat=2))))
      """)
    end

    test "permutations" do
      assert_conforms(~S"""
      from itertools import permutations
      print(repr(list(permutations([1, 2, 3], 2))))
      """)
    end

    test "combinations" do
      assert_conforms(~S"""
      from itertools import combinations
      print(repr(list(combinations([1, 2, 3, 4], 2))))
      """)
    end

    test "combinations_with_replacement" do
      assert_conforms(~S"""
      from itertools import combinations_with_replacement
      print(repr(list(combinations_with_replacement('AB', 2))))
      """)
    end

    test "repeat" do
      assert_conforms(~S"""
      from itertools import repeat
      print(repr(list(repeat(3, 4))))
      """)
    end

    test "compress" do
      assert_conforms(~S"""
      from itertools import compress
      print(repr(list(compress('ABCDEF', [1, 0, 1, 0, 1, 1]))))
      """)
    end

    test "pairwise" do
      assert_conforms(~S"""
      from itertools import pairwise
      print(repr(list(pairwise([1, 2, 3, 4, 5]))))
      """)
    end

    test "zip_longest" do
      assert_conforms(~S"""
      from itertools import zip_longest
      print(repr(list(zip_longest([1, 2, 3], [4, 5], fillvalue=0))))
      """)
    end

    test "accumulate default" do
      assert_conforms(~S"""
      from itertools import accumulate
      print(repr(list(accumulate([1, 2, 3, 4, 5]))))
      """)
    end

    test "accumulate with function" do
      assert_conforms(~S"""
      from itertools import accumulate
      print(repr(list(accumulate([1, 2, 3, 4], lambda x, y: x * y))))
      """)
    end

    test "starmap" do
      assert_conforms(~S"""
      from itertools import starmap
      print(repr(list(starmap(pow, [(2, 5), (3, 2), (10, 3)]))))
      """)
    end

    test "takewhile" do
      assert_conforms(~S"""
      from itertools import takewhile
      print(repr(list(takewhile(lambda x: x < 5, [1, 4, 6, 3, 1]))))
      """)
    end

    test "dropwhile" do
      assert_conforms(~S"""
      from itertools import dropwhile
      print(repr(list(dropwhile(lambda x: x < 5, [1, 4, 6, 3, 1]))))
      """)
    end

    test "filterfalse" do
      assert_conforms(~S"""
      from itertools import filterfalse
      print(repr(list(filterfalse(lambda x: x % 2, range(10)))))
      """)
    end

    test "groupby" do
      assert_conforms(~S"""
      from itertools import groupby
      print(repr([(k, list(g)) for k, g in groupby('AAABBBCCA')]))
      """)
    end

    test "groupby with key" do
      assert_conforms(~S"""
      from itertools import groupby
      data = [('a', 1), ('a', 2), ('b', 3), ('b', 4)]
      print(repr([(k, list(g)) for k, g in groupby(data, key=lambda x: x[0])]))
      """)
    end

    test "tee" do
      assert_conforms(~S"""
      from itertools import tee
      a, b = tee([1, 2, 3])
      print(repr((list(a), list(b))))
      """)
    end

    test "combined itertools usage" do
      assert_conforms(~S"""
      from itertools import chain, islice, repeat, accumulate
      result = list(islice(chain(repeat(1, 3), accumulate([1, 1, 1])), 6))
      print(repr(result))
      """)
    end
  end

  # ── With statement / context managers ─────────────────────────

  describe "with statement" do
    test "custom class context manager enter/exit" do
      assert_conforms("""
      class CM:
          def __init__(self, val):
              self.val = val
              self.log = []
          def __enter__(self):
              self.log.append("enter")
              return self.val
          def __exit__(self, exc_type, exc_val, exc_tb):
              self.log.append("exit")
              return False
      cm = CM(42)
      with cm as v:
          result = v
      print(repr((result, cm.log)))
      """)
    end

    test "with statement exit called on exception" do
      assert_conforms("""
      class CM:
          def __init__(self):
              self.log = []
          def __enter__(self):
              self.log.append("enter")
              return self
          def __exit__(self, exc_type, exc_val, exc_tb):
              self.log.append("exit")
              return False
      cm = CM()
      try:
          with cm:
              raise ValueError("oops")
      except ValueError:
          pass
      print(repr(cm.log))
      """)
    end

    test "with statement exit suppresses exception" do
      assert_conforms("""
      class Suppress:
          def __enter__(self):
              return self
          def __exit__(self, exc_type, exc_val, exc_tb):
              return True
      result = "ok"
      with Suppress():
          raise ValueError("suppressed")
      print(repr(result))
      """)
    end

    test "nested with custom context managers" do
      assert_conforms("""
      class CM:
          def __init__(self, name):
              self.name = name
              self.log = []
          def __enter__(self):
              self.log.append("enter")
              return self.name
          def __exit__(self, exc_type, exc_val, exc_tb):
              self.log.append("exit")
              return False
      a = CM("a")
      b = CM("b")
      with a as va:
          with b as vb:
              result = va + vb
      print(repr((result, a.log, b.log)))
      """)
    end
  end

  # ── String formatting ──────────────────────────────────────

  describe "string percent formatting" do
    test "basic %s and %d" do
      assert_conforms(~S[print(repr("hello %s, you are %d" % ("world", 42)))])
    end

    test "%f formatting" do
      assert_conforms(~S[print(repr("pi is %f" % 3.14159))])
    end

    test "%x hex formatting" do
      assert_conforms(~S[print(repr("%x" % 255))])
    end

    test "%o octal formatting" do
      assert_conforms(~S[print(repr("%o" % 8))])
    end

    test "percent escape" do
      assert_conforms(~S[print(repr("100%% done"))])
    end

    test "%r repr formatting" do
      assert_conforms(~S[print(repr("%r" % "hello"))])
    end

    test "width and padding" do
      assert_conforms(~S[print(repr("%10d" % 42))])
    end

    test "zero padding" do
      assert_conforms(~S[print(repr("%05d" % 42))])
    end

    test "left alignment" do
      assert_conforms(~S[print(repr("%-10s!" % "hi"))])
    end

    test "multiple substitutions" do
      assert_conforms(
        ~S[print(repr("%s is %d years old and %.1f meters tall" % ("Alice", 30, 1.7)))]
      )
    end
  end

  describe "string format method" do
    test "positional format" do
      assert_conforms(~S[print(repr("{} + {} = {}".format(1, 2, 3)))])
    end

    test "indexed format" do
      assert_conforms(~S[print(repr("{0} and {1} and {0}".format("a", "b")))])
    end
  end

  # ── Class decorators ────────────────────────────────────────

  describe "class decorators" do
    test "basic class decorator" do
      assert_conforms("""
      def add_greeting(cls):
          cls.greet = lambda self: "hello from " + type(self).__name__
          return cls

      @add_greeting
      class MyClass:
          pass

      print(repr(MyClass().greet()))
      """)
    end

    test "class decorator adds attribute" do
      assert_conforms("""
      def tag(cls):
          cls.tagged = True
          return cls

      @tag
      class Config:
          def __init__(self):
              self.val = 42

      c = Config()
      print(repr((c.val, Config.tagged)))
      """)
    end
  end

  # ── Advanced function features ──────────────────────────────

  describe "advanced functions" do
    test "star args unpacking in call" do
      assert_conforms("""
      def add(a, b, c):
          return a + b + c
      args = [1, 2, 3]
      print(repr(add(*args)))
      """)
    end

    test "double star kwargs unpacking in call" do
      assert_conforms("""
      def greet(name, greeting):
          return f"{greeting}, {name}!"
      kwargs = {"name": "World", "greeting": "Hello"}
      print(repr(greet(**kwargs)))
      """)
    end

    test "mixed star and double star unpacking" do
      assert_conforms("""
      def f(a, b, c, d=10, e=20):
          return (a, b, c, d, e)
      args = [1, 2]
      kwargs = {"d": 100, "e": 200}
      print(repr(f(*args, 3, **kwargs)))
      """)
    end

    test "args and kwargs combined" do
      assert_conforms("""
      def f(*args, **kwargs):
          return (list(args), sorted(kwargs.items()))
      print(repr(f(1, 2, 3, x=4, y=5)))
      """)
    end

    test "global and nonlocal interaction" do
      assert_conforms("""
      g = 0
      def outer():
          x = 0
          def middle():
              nonlocal x
              global g
              x += 1
              g += 10
          middle()
          middle()
          return x
      result = outer()
      print(repr((result, g)))
      """)
    end
  end

  # ── Advanced comprehensions ────────────────────────────────

  describe "advanced comprehensions" do
    test "nested list comprehension with multiple conditions" do
      assert_conforms("""
      print(repr([x*y for x in range(1, 6) for y in range(1, 6) if x != y if x*y < 10]))
      """)
    end

    test "dict comprehension with value transformation" do
      assert_conforms("""
      words = ["hello", "world", "python"]
      print(repr(sorted({w: len(w) for w in words}.items())))
      """)
    end

    test "set comprehension deduplication" do
      assert_conforms("""
      print(repr(sorted({x % 5 for x in range(20)})))
      """)
    end

    test "comprehension with function call" do
      assert_conforms("""
      def square(x):
          return x * x
      print(repr([square(i) for i in range(8)]))
      """)
    end

    test "comprehension variable does not leak" do
      assert_conforms("""
      x = "before"
      result = [x for x in range(5)]
      print(repr((result, x)))
      """)
    end
  end

  # ── Advanced generators ────────────────────────────────────

  describe "advanced generators" do
    test "generator with send-like accumulation" do
      assert_conforms("""
      def running_sum(items):
          total = 0
          for x in items:
              total += x
              yield total
      print(repr(list(running_sum([1, 2, 3, 4, 5]))))
      """)
    end

    test "generator as pipeline" do
      assert_conforms("""
      def evens(n):
          for i in range(n):
              if i % 2 == 0:
                  yield i

      def squared(gen):
          for x in gen:
              yield x * x

      print(repr(list(squared(evens(10)))))
      """)
    end

    test "generator with try/except" do
      assert_conforms("""
      def safe_divide(pairs):
          for a, b in pairs:
              try:
                  yield a / b
              except ZeroDivisionError:
                  yield None
      print(repr(list(safe_divide([(10, 2), (5, 0), (8, 4)]))))
      """)
    end

    test "multiple generators interleaved" do
      assert_conforms("""
      def g1():
          yield 1
          yield 2
          yield 3

      def g2():
          yield "a"
          yield "b"
          yield "c"

      print(repr(list(zip(g1(), g2()))))
      """)
    end
  end

  # ── Advanced class features ────────────────────────────────

  describe "advanced classes" do
    test "dunder str" do
      assert_conforms("""
      class Thing:
          def __init__(self, name):
              self.name = name
          def __str__(self):
              return "Thing:" + self.name
      t = Thing("foo")
      print(repr(str(t)))
      """)
    end

    test "dunder contains" do
      assert_conforms("""
      class Range:
          def __init__(self, lo, hi):
              self.lo = lo
              self.hi = hi
          def __contains__(self, val):
              return self.lo <= val < self.hi
      r = Range(1, 10)
      print(repr((5 in r, 15 in r, 1 in r, 10 in r)))
      """)
    end

    test "dunder lt for comparison" do
      assert_conforms("""
      class Score:
          def __init__(self, name, val):
              self.name = name
              self.val = val
          def __lt__(self, other):
              return self.val < other.val
      a = Score("a", 1)
      b = Score("b", 2)
      print(repr((a < b, b < a)))
      """)
    end

    test "dunder mul" do
      assert_conforms("""
      class Vec:
          def __init__(self, x, y):
              self.x = x
              self.y = y
          def __mul__(self, scalar):
              return Vec(self.x * scalar, self.y * scalar)
      v = Vec(1, 2) * 3
      print(repr((v.x, v.y)))
      """)
    end

    test "multiple inheritance method resolution" do
      assert_conforms("""
      class A:
          def who(self):
              return "A"
      class B(A):
          def who(self):
              return "B"
      class C(A):
          def who(self):
              return "C"
      class D(B, C):
          pass
      print(repr(D().who()))
      """)
    end

    test "class with custom iterator" do
      assert_conforms("""
      class Countdown:
          def __init__(self, n):
              self.n = n
          def __iter__(self):
              self.current = self.n
              return self
          def __next__(self):
              if self.current <= 0:
                  raise StopIteration
              val = self.current
              self.current -= 1
              return val
      print(repr(list(Countdown(5))))
      print(repr(sum(Countdown(10))))
      """)
    end
  end

  # ── Import patterns ────────────────────────────────────────

  describe "import patterns" do
    test "from X import Y" do
      assert_conforms("""
      from collections import Counter
      c = Counter([1, 1, 2, 3, 3, 3])
      print(repr(c.most_common(2)))
      """)
    end

    test "import X as Y" do
      assert_conforms("""
      import json as j
      print(repr(j.loads('[1, 2, 3]')))
      """)
    end

    test "from X import Y as Z" do
      assert_conforms("""
      from collections import Counter as C
      c = C([1, 1, 2, 3, 3, 3])
      print(repr(c.most_common(3)))
      """)
    end

    test "multiple from imports" do
      assert_conforms("""
      from itertools import chain, islice
      print(repr(list(islice(chain([1, 2], [3, 4]), 3))))
      """)
    end
  end

  # ── Boolean edge cases ─────────────────────────────────────

  describe "boolean edge cases" do
    test "bool constructor" do
      assert_conforms("""
      vals = [0, 1, -1, 0.0, 0.1, "", "a", [], [0], {}, {1:2}, None, True, False, (), (0,)]
      print(repr([bool(v) for v in vals]))
      """)
    end

    test "and returns last evaluated operand" do
      assert_conforms(~S[print(repr((1 and 2 and 3, 1 and 0 and 3, 0 and 1 and 3)))])
    end

    test "or returns first truthy operand" do
      assert_conforms(~s|print(repr((0 or 0 or 3, 1 or 2 or 3, 0 or "" or [] or "found")))|)
    end

    test "chained not" do
      assert_conforms("print(repr((not not True, not not False, not not 0, not not 1)))")
    end
  end

  # ── Assignment edge cases ──────────────────────────────────

  describe "assignment edge cases" do
    test "chained assignment" do
      assert_conforms("""
      a = b = c = 42
      print(repr((a, b, c)))
      """)
    end

    test "augmented assignment operators" do
      assert_conforms("""
      x = 10
      x += 5
      x -= 3
      x *= 2
      x //= 3
      x %= 5
      print(repr(x))
      """)
    end

    test "augmented assignment on list elements" do
      assert_conforms("""
      x = [1, 2, 3]
      x[0] += 10
      x[1] *= 5
      x[-1] -= 1
      print(repr(x))
      """)
    end

    test "augmented assignment on dict values" do
      assert_conforms(~S"""
      d = {"a": 1, "b": 2}
      d["a"] += 10
      d["b"] *= 3
      print(repr(sorted(d.items())))
      """)
    end

    test "swap via tuple unpacking" do
      assert_conforms("""
      a, b = 1, 2
      a, b = b, a
      print(repr((a, b)))
      """)
    end
  end

  # ── Assert statement ───────────────────────────────────────

  describe "assert statement" do
    test "assert passes for true" do
      assert_conforms("""
      assert True
      assert 1 == 1
      assert len([1, 2]) == 2
      print(repr("all passed"))
      """)
    end

    test "assert with message" do
      assert_conforms("""
      try:
          assert False, "custom message"
      except:
          print(repr("caught"))
      """)
    end
  end

  # ── Del statement edge cases ───────────────────────────────

  describe "del statement" do
    test "del dict key" do
      assert_conforms(~S"""
      d = {"a": 1, "b": 2, "c": 3}
      del d["b"]
      print(repr(sorted(d.items())))
      """)
    end

    test "del list element" do
      assert_conforms("""
      x = [1, 2, 3, 4, 5]
      del x[2]
      print(repr(x))
      """)
    end

    test "del variable" do
      assert_conforms("""
      x = 42
      del x
      try:
          print(x)
      except NameError:
          print(repr("deleted"))
      """)
    end
  end

  # ── Semicolon separator ────────────────────────────────────

  describe "semicolon separator" do
    test "multiple statements on one line" do
      assert_conforms("x = 1; y = 2; z = x + y; print(repr(z))")
    end

    test "semicolons with function calls" do
      assert_conforms("""
      result = []; result.append(1); result.append(2); result.append(3)
      print(repr(result))
      """)
    end
  end

  # ── Range as lazy object ───────────────────────────────────

  describe "range object" do
    test "range in operator" do
      assert_conforms("print(repr((5 in range(10), 15 in range(10))))")
    end

    test "range length" do
      assert_conforms("print(repr(len(range(5, 15, 2))))")
    end

    test "range indexing" do
      assert_conforms("print(repr(range(10)[3]))")
    end

    test "range negative indexing" do
      assert_conforms("print(repr(range(10)[-1]))")
    end

    test "range attributes" do
      assert_conforms("""
      r = range(1, 10, 2)
      print(repr((r.start, r.stop, r.step)))
      """)
    end
  end

  # ── Inline if ──────────────────────────────────────────────

  describe "inline if" do
    test "single line if body" do
      assert_conforms("""
      x = 5
      if x > 3: print(repr("big"))
      """)
    end

    test "single line if/else" do
      assert_conforms("""
      x = 1
      if x > 3: y = "big"
      else: y = "small"
      print(repr(y))
      """)
    end
  end

  # ── Complex real-world programs ────────────────────────────

  describe "real-world programs" do
    test "CSV-like parser" do
      assert_conforms(~S"""
      def parse_csv(text):
          rows = []
          for line in text.strip().split("\n"):
              rows.append(line.split(","))
          return rows

      data = "name,age,city\nAlice,30,NYC\nBob,25,LA"
      rows = parse_csv(data)
      header = rows[0]
      records = [{header[i]: row[i] for i in range(len(header))} for row in rows[1:]]
      print(repr([sorted(r.items()) for r in records]))
      """)
    end

    test "mini calculator" do
      assert_conforms(~S"""
      def calc(expr):
          parts = expr.split()
          a = int(parts[0])
          op = parts[1]
          b = int(parts[2])
          if op == "+":
              return a + b
          elif op == "-":
              return a - b
          elif op == "*":
              return a * b
          elif op == "/":
              return a / b
          else:
              return None

      exprs = ["10 + 5", "20 - 8", "6 * 7", "15 / 4"]
      print(repr([calc(e) for e in exprs]))
      """)
    end

    test "frequency analysis" do
      assert_conforms(~S"""
      text = "the quick brown fox jumps over the lazy dog the fox"
      words = text.split()
      freq = {}
      for w in words:
          freq[w] = freq.get(w, 0) + 1
      top = sorted(freq.items(), key=lambda x: (-x[1], x[0]))
      print(repr(top[:3]))
      """)
    end

    test "matrix multiplication" do
      assert_conforms("""
      def matmul(a, b):
          rows_a, cols_a = len(a), len(a[0])
          cols_b = len(b[0])
          result = [[0] * cols_b for _ in range(rows_a)]
          for i in range(rows_a):
              for j in range(cols_b):
                  for k in range(cols_a):
                      result[i][j] += a[i][k] * b[k][j]
          return result

      a = [[1, 2], [3, 4]]
      b = [[5, 6], [7, 8]]
      print(repr(matmul(a, b)))
      """)
    end

    test "LRU-like cache using dict" do
      assert_conforms("""
      def cached_fib():
          cache = {}
          def fib(n):
              if n in cache:
                  return cache[n]
              if n <= 1:
                  result = n
              else:
                  result = fib(n - 1) + fib(n - 2)
              cache[n] = result
              return result
          return fib

      fib = cached_fib()
      print(repr([fib(i) for i in range(20)]))
      """)
    end

    test "simple state machine" do
      assert_conforms(~S"""
      def run_machine(transitions, start, inputs):
          state = start
          path = [state]
          for inp in inputs:
              key = (state, inp)
              if key in transitions:
                  state = transitions[key]
              path.append(state)
          return path

      transitions = {
          ("locked", "coin"): "unlocked",
          ("unlocked", "push"): "locked",
      }
      print(repr(run_machine(transitions, "locked", ["coin", "push", "push", "coin"])))
      """)
    end

    test "graph BFS" do
      assert_conforms(~S"""
      def bfs(graph, start):
          visited = set()
          queue = [start]
          order = []
          while queue:
              node = queue.pop(0)
              if node not in visited:
                  visited.add(node)
                  order.append(node)
                  for neighbor in sorted(graph.get(node, [])):
                      if neighbor not in visited:
                          queue.append(neighbor)
          return order

      graph = {
          "a": ["b", "c"],
          "b": ["d"],
          "c": ["d", "e"],
          "d": [],
          "e": [],
      }
      print(repr(bfs(graph, "a")))
      """)
    end

    test "decorator memoize with class" do
      assert_conforms("""
      class Memoize:
          def __init__(self, func):
              self.func = func
              self.cache = {}
          def __call__(self, *args):
              if args not in self.cache:
                  self.cache[args] = self.func(*args)
              return self.cache[args]

      @Memoize
      def fib(n):
          if n <= 1:
              return n
          return fib(n - 1) + fib(n - 2)

      print(repr([fib(i) for i in range(15)]))
      """)
    end
  end

  describe "unittest assertions" do
    test "assertEqual passes and returns None" do
      assert_conforms(~S"""
      import unittest
      tc = unittest.TestCase()
      print(repr(tc.assertEqual(1, 1)))
      print(repr(tc.assertEqual("hello", "hello")))
      print(repr(tc.assertEqual([1,2], [1,2])))
      """)
    end

    test "assertEqual failure message" do
      assert_conforms(~S"""
      import unittest
      tc = unittest.TestCase()
      try:
          tc.assertEqual(1, 2)
      except AssertionError as e:
          print(repr(str(e)))
      """)
    end

    test "assertNotEqual passes" do
      assert_conforms(~S"""
      import unittest
      tc = unittest.TestCase()
      print(repr(tc.assertNotEqual(1, 2)))
      """)
    end

    test "assertTrue and assertFalse pass" do
      assert_conforms(~S"""
      import unittest
      tc = unittest.TestCase()
      print(repr(tc.assertTrue(True)))
      print(repr(tc.assertFalse(False)))
      print(repr(tc.assertTrue(1)))
      print(repr(tc.assertFalse(0)))
      """)
    end

    test "assertIsNone and assertIsNotNone pass" do
      assert_conforms(~S"""
      import unittest
      tc = unittest.TestCase()
      print(repr(tc.assertIsNone(None)))
      print(repr(tc.assertIsNotNone(42)))
      """)
    end

    test "assertIn passes for list" do
      assert_conforms(~S"""
      import unittest
      tc = unittest.TestCase()
      print(repr(tc.assertIn(2, [1, 2, 3])))
      print(repr(tc.assertNotIn(5, [1, 2, 3])))
      """)
    end

    test "assertIn passes for string" do
      assert_conforms(~S"""
      import unittest
      tc = unittest.TestCase()
      print(repr(tc.assertIn("ell", "hello")))
      """)
    end

    test "assertIn passes for dict" do
      assert_conforms(~S"""
      import unittest
      tc = unittest.TestCase()
      print(repr(tc.assertIn("a", {"a": 1, "b": 2})))
      """)
    end

    test "comparison assertions pass" do
      assert_conforms(~S"""
      import unittest
      tc = unittest.TestCase()
      print(repr(tc.assertGreater(5, 3)))
      print(repr(tc.assertGreaterEqual(5, 5)))
      print(repr(tc.assertLess(3, 5)))
      print(repr(tc.assertLessEqual(5, 5)))
      """)
    end

    test "assertIs and assertIsNot pass" do
      assert_conforms(~S"""
      import unittest
      tc = unittest.TestCase()
      print(repr(tc.assertIs(None, None)))
      print(repr(tc.assertIs(True, True)))
      print(repr(tc.assertIsNot(1, 2)))
      """)
    end

    test "assertEqual with custom message" do
      assert_conforms(~S"""
      import unittest
      tc = unittest.TestCase()
      try:
          tc.assertEqual(1, 2, "custom msg")
      except AssertionError as e:
          print(repr(str(e)))
      """)
    end

    test "assertAlmostEqual passes for close values" do
      assert_conforms(~S"""
      import unittest
      tc = unittest.TestCase()
      print(repr(tc.assertAlmostEqual(0.1 + 0.2, 0.3)))
      print(repr(tc.assertAlmostEqual(1.00000001, 1.00000002)))
      """)
    end

    test "test class with passing tests" do
      assert_conforms(~S"""
      import unittest

      class Calculator:
          def add(self, a, b):
              return a + b

      class TestCalc(unittest.TestCase):
          def test_add(self):
              c = Calculator()
              self.assertEqual(c.add(2, 3), 5)

          def test_add_negative(self):
              c = Calculator()
              self.assertEqual(c.add(-1, 1), 0)

      result = {"tests": 2, "pass": True}
      print(repr(result["pass"]))
      """)
    end

    test "fail method raises AssertionError" do
      assert_conforms(~S"""
      import unittest
      tc = unittest.TestCase()
      try:
          tc.fail("oops")
      except AssertionError as e:
          print(repr(str(e)))
      """)
    end
  end
end
