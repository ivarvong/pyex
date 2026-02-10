defmodule Pyex.ClassesTest do
  use ExUnit.Case, async: true

  alias Pyex.Error

  describe "class definitions" do
    test "basic class with __init__ and method" do
      code = """
      class Dog:
          def __init__(self, name):
              self.name = name
          def speak(self):
              return self.name + " barks"

      d = Dog("Rex")
      d.speak()
      """

      assert Pyex.run!(code) == "Rex barks"
    end

    test "class with no __init__" do
      code = """
      class Empty:
          pass

      e = Empty()
      type(e)
      """

      {:instance, _, %{"__name__" => name}} = Pyex.run!(code)
      assert name == "Empty"
    end

    test "class with class-level attribute" do
      code = """
      class Circle:
          pi = 3.14
          def __init__(self, r):
              self.radius = r
          def area(self):
              return Circle.pi * self.radius * self.radius

      c = Circle(10)
      c.area()
      """

      assert Pyex.run!(code) == 314.0
    end

    test "instance attribute mutation persists" do
      code = """
      class Counter:
          def __init__(self):
              self.count = 0
          def inc(self):
              self.count = self.count + 1
          def get(self):
              return self.count

      c = Counter()
      c.inc()
      c.inc()
      c.inc()
      c.get()
      """

      assert Pyex.run!(code) == 3
    end

    test "inheritance with method override" do
      code = """
      class Animal:
          def __init__(self, name):
              self.name = name
          def speak(self):
              return self.name + " makes a sound"

      class Dog(Animal):
          def speak(self):
              return self.name + " barks"

      d = Dog("Rex")
      d.speak()
      """

      assert Pyex.run!(code) == "Rex barks"
    end

    test "inheritance inherits __init__ from parent" do
      code = """
      class Animal:
          def __init__(self, name):
              self.name = name

      class Cat(Animal):
          def speak(self):
              return self.name + " meows"

      c = Cat("Whiskers")
      c.speak()
      """

      assert Pyex.run!(code) == "Whiskers meows"
    end

    test "isinstance with class" do
      code = """
      class Animal:
          pass

      class Dog(Animal):
          pass

      d = Dog()
      isinstance(d, Dog)
      """

      assert Pyex.run!(code) == true
    end

    test "isinstance with parent class" do
      code = """
      class Animal:
          pass

      class Dog(Animal):
          pass

      d = Dog()
      isinstance(d, Animal)
      """

      assert Pyex.run!(code) == true
    end

    test "isinstance returns false for unrelated class" do
      code = """
      class Cat:
          pass

      class Dog:
          pass

      d = Dog()
      isinstance(d, Cat)
      """

      assert Pyex.run!(code) == false
    end

    test "__str__ dunder method via str()" do
      code = """
      class Point:
          def __init__(self, x, y):
              self.x = x
              self.y = y
          def __str__(self):
              return "(" + str(self.x) + ", " + str(self.y) + ")"

      p = Point(3, 4)
      str(p)
      """

      assert Pyex.run!(code) == "(3, 4)"
    end

    test "__len__ dunder method via len()" do
      code = """
      class MyList:
          def __init__(self, items):
              self.items = items
          def __len__(self):
              return len(self.items)

      ml = MyList([1, 2, 3, 4, 5])
      len(ml)
      """

      assert Pyex.run!(code) == 5
    end

    test "__repr__ dunder method via repr()" do
      code = """
      class Foo:
          def __repr__(self):
              return "Foo()"

      f = Foo()
      repr(f)
      """

      assert Pyex.run!(code) == "Foo()"
    end

    test "multiple instances are independent" do
      code = """
      class Box:
          def __init__(self, val):
              self.val = val

      a = Box(10)
      b = Box(20)
      a.val + b.val
      """

      assert Pyex.run!(code) == 30
    end

    test "instance attribute access" do
      code = """
      class Person:
          def __init__(self, name, age):
              self.name = name
              self.age = age

      p = Person("Alice", 30)
      p.name + " is " + str(p.age)
      """

      assert Pyex.run!(code) == "Alice is 30"
    end

    test "method with arguments" do
      code = """
      class Calculator:
          def __init__(self):
              self.result = 0
          def add(self, n):
              self.result = self.result + n
          def get(self):
              return self.result

      c = Calculator()
      c.add(10)
      c.add(20)
      c.add(5)
      c.get()
      """

      assert Pyex.run!(code) == 35
    end

    test "attribute assignment outside __init__" do
      code = """
      class Obj:
          pass

      o = Obj()
      o.x = 42
      o.x
      """

      assert Pyex.run!(code) == 42
    end

    test "callable on class returns True" do
      code = """
      class Foo:
          pass

      callable(Foo)
      """

      assert Pyex.run!(code) == true
    end
  end

  describe "super()" do
    test "basic super().__init__" do
      code = """
      class Animal:
          def __init__(self, name):
              self.name = name

      class Dog(Animal):
          def __init__(self, name, breed):
              super().__init__(name)
              self.breed = breed

      d = Dog("Rex", "Labrador")
      [d.name, d.breed]
      """

      assert Pyex.run!(code) == ["Rex", "Labrador"]
    end

    test "super().method()" do
      code = """
      class Base:
          def greet(self):
              return "Hello from Base"

      class Child(Base):
          def greet(self):
              return super().greet() + " and Child"

      Child().greet()
      """

      assert Pyex.run!(code) == "Hello from Base and Child"
    end

    test "multi-level super chain" do
      code = """
      class A:
          def __init__(self):
              self.a = 1

      class B(A):
          def __init__(self):
              super().__init__()
              self.b = 2

      class C(B):
          def __init__(self):
              super().__init__()
              self.c = 3

      c = C()
      [c.a, c.b, c.c]
      """

      assert Pyex.run!(code) == [1, 2, 3]
    end

    test "super with arguments" do
      code = """
      class Shape:
          def __init__(self, color):
              self.color = color

      class Circle(Shape):
          def __init__(self, color, radius):
              super().__init__(color)
              self.radius = radius

      c = Circle("red", 5)
      [c.color, c.radius]
      """

      assert Pyex.run!(code) == ["red", 5]
    end

    test "super method with return value" do
      code = """
      class Base:
          def area(self):
              return 0

      class Rect(Base):
          def __init__(self, w, h):
              self.w = w
              self.h = h
          def area(self):
              return self.w * self.h

      class ColorRect(Rect):
          def __init__(self, w, h, color):
              super().__init__(w, h)
              self.color = color
          def describe(self):
              return self.color + " rect with area " + str(super().area())

      r = ColorRect(3, 4, "blue")
      r.describe()
      """

      assert Pyex.run!(code) == "blue rect with area 12"
    end
  end

  describe "MRO (C3 linearization)" do
    test "diamond inheritance resolves with C3 order" do
      code = """
      class A:
          def method(self):
              return "A"

      class B(A):
          pass

      class C(A):
          def method(self):
              return "C"

      class D(B, C):
          pass

      D().method()
      """

      assert Pyex.run!(code) == "C"
    end

    test "linear inheritance still works" do
      code = """
      class A:
          def method(self):
              return "A"

      class B(A):
          def method(self):
              return "B"

      class C(B):
          pass

      C().method()
      """

      assert Pyex.run!(code) == "B"
    end

    test "diamond with super()" do
      code = """
      class A:
          def __init__(self):
              self.log = ["A"]

      class B(A):
          def __init__(self):
              super().__init__()
              self.log.append("B")

      class C(A):
          def __init__(self):
              super().__init__()
              self.log.append("C")

      class D(B, C):
          def __init__(self):
              super().__init__()
              self.log.append("D")

      d = D()
      d.log
      """

      result = Pyex.run!(code)
      assert "D" in result
      assert "B" in result
    end
  end

  describe "dunder methods" do
    test "__add__ on instances" do
      code = """
      class Vec:
          def __init__(self, x, y):
              self.x = x
              self.y = y
          def __add__(self, other):
              return Vec(self.x + other.x, self.y + other.y)

      v = Vec(1, 2) + Vec(3, 4)
      (v.x, v.y)
      """

      assert Pyex.run!(code) == {:tuple, [4, 6]}
    end

    test "__sub__ on instances" do
      code = """
      class Vec:
          def __init__(self, x, y):
              self.x = x
              self.y = y
          def __sub__(self, other):
              return Vec(self.x - other.x, self.y - other.y)

      v = Vec(5, 7) - Vec(1, 2)
      (v.x, v.y)
      """

      assert Pyex.run!(code) == {:tuple, [4, 5]}
    end

    test "__mul__ on instances" do
      code = """
      class Vec:
          def __init__(self, x, y):
              self.x = x
              self.y = y
          def __mul__(self, scalar):
              return Vec(self.x * scalar, self.y * scalar)

      v = Vec(2, 3) * 4
      (v.x, v.y)
      """

      assert Pyex.run!(code) == {:tuple, [8, 12]}
    end

    test "__eq__ on instances" do
      code = """
      class Point:
          def __init__(self, x, y):
              self.x = x
              self.y = y
          def __eq__(self, other):
              return self.x == other.x and self.y == other.y

      Point(1, 2) == Point(1, 2)
      """

      assert Pyex.run!(code) == true
    end

    test "__ne__ on instances" do
      code = """
      class Point:
          def __init__(self, x, y):
              self.x = x
              self.y = y
          def __ne__(self, other):
              return self.x != other.x or self.y != other.y

      Point(1, 2) != Point(3, 4)
      """

      assert Pyex.run!(code) == true
    end

    test "__lt__ and __gt__ on instances" do
      code = """
      class Num:
          def __init__(self, val):
              self.val = val
          def __lt__(self, other):
              return self.val < other.val
          def __gt__(self, other):
              return self.val > other.val

      results = []
      results.append(Num(1) < Num(2))
      results.append(Num(3) > Num(1))
      results.append(Num(5) < Num(3))
      results
      """

      assert Pyex.run!(code) == [true, true, false]
    end

    test "__le__ and __ge__ on instances" do
      code = """
      class Num:
          def __init__(self, val):
              self.val = val
          def __le__(self, other):
              return self.val <= other.val
          def __ge__(self, other):
              return self.val >= other.val

      [Num(1) <= Num(1), Num(3) >= Num(2), Num(1) >= Num(5)]
      """

      assert Pyex.run!(code) == [true, true, false]
    end

    test "__neg__ on instance" do
      code = """
      class Num:
          def __init__(self, val):
              self.val = val
          def __neg__(self):
              return Num(-self.val)

      n = -Num(42)
      n.val
      """

      assert Pyex.run!(code) == -42
    end

    test "__bool__ on instance" do
      code = """
      class Bag:
          def __init__(self, items):
              self.items = items
          def __bool__(self):
              return len(self.items) > 0

      results = []
      results.append(not Bag([]))
      results.append(not Bag([1, 2]))
      results
      """

      assert Pyex.run!(code) == [true, false]
    end

    test "__len__ on instance used for truthiness" do
      code = """
      class MyList:
          def __init__(self):
              self.data = []
          def __len__(self):
              return len(self.data)
          def add(self, item):
              self.data.append(item)

      ml = MyList()
      r1 = not ml
      ml.add(1)
      r2 = not ml
      [r1, r2]
      """

      assert Pyex.run!(code) == [true, false]
    end

    test "__getitem__ on instance" do
      code = """
      class Grid:
          def __init__(self):
              self.data = {0: "a", 1: "b", 2: "c"}
          def __getitem__(self, key):
              return self.data[key]

      g = Grid()
      [g[0], g[1], g[2]]
      """

      assert Pyex.run!(code) == ["a", "b", "c"]
    end

    test "__contains__ on instance" do
      code = """
      class WordSet:
          def __init__(self, words):
              self.words = words
          def __contains__(self, item):
              for w in self.words:
                  if w == item:
                      return True
              return False

      ws = WordSet(["hello", "world"])
      ["hello" in ws, "foo" in ws, "world" not in ws]
      """

      assert Pyex.run!(code) == [true, false, false]
    end

    test "__call__ on instance" do
      code = """
      class Adder:
          def __init__(self, n):
              self.n = n
          def __call__(self, x):
              return self.n + x

      add5 = Adder(5)
      [add5(10), add5(20)]
      """

      assert Pyex.run!(code) == [15, 25]
    end

    test "__radd__ for right-hand dispatch" do
      code = """
      class Num:
          def __init__(self, val):
              self.val = val
          def __radd__(self, other):
              return Num(other + self.val)

      result = 10 + Num(5)
      result.val
      """

      assert Pyex.run!(code) == 15
    end

    test "chained comparison with __lt__" do
      code = """
      class Num:
          def __init__(self, val):
              self.val = val
          def __lt__(self, other):
              if isinstance(other, Num):
                  return self.val < other.val
              return self.val < other
          def __gt__(self, other):
              if isinstance(other, Num):
                  return self.val > other.val
              return self.val > other

      Num(1) < Num(5) < Num(10)
      """

      assert Pyex.run!(code) == true
    end

    test "__eq__ with None comparison" do
      code = """
      class Maybe:
          def __init__(self, val):
              self.val = val
          def __eq__(self, other):
              if other is None:
                  return self.val is None
              return self.val == other

      [Maybe(None) == None, Maybe(5) == None, Maybe(5) == 5]
      """

      assert Pyex.run!(code) == [true, false, true]
    end

    test "right-hand __eq__ dispatch (non-instance == instance)" do
      code = """
      class Tag:
          def __init__(self, name):
              self.name = name
          def __eq__(self, other):
              if isinstance(other, Tag):
                  return self.name == other.name
              return self.name == other

      "hello" == Tag("hello")
      """

      assert Pyex.run!(code) == true
    end
  end

  describe "__bool__/__len__ truthiness in control flow" do
    test "__bool__ in if statement" do
      code = """
      class Truthy:
          def __bool__(self):
              return True

      class Falsy:
          def __bool__(self):
              return False

      results = []
      if Truthy():
          results.append("truthy")
      if Falsy():
          results.append("falsy")
      results
      """

      assert Pyex.run!(code) == ["truthy"]
    end

    test "__len__ in if statement (empty = falsy)" do
      code = """
      class Container:
          def __init__(self, items):
              self.items = items
          def __len__(self):
              return len(self.items)

      results = []
      if Container([1, 2]):
          results.append("nonempty")
      if Container([]):
          results.append("empty")
      results
      """

      assert Pyex.run!(code) == ["nonempty"]
    end

    test "__bool__ in while loop" do
      code = """
      class Counter:
          def __init__(self, n):
              self.n = n
          def __bool__(self):
              return self.n > 0

      c = Counter(3)
      results = []
      while c:
          results.append(c.n)
          c.n = c.n - 1
      results
      """

      assert Pyex.run!(code) == [3, 2, 1]
    end

    test "__bool__ in ternary expression" do
      code = """
      class Flag:
          def __init__(self, on):
              self.on = on
          def __bool__(self):
              return self.on

      "yes" if Flag(True) else "no"
      """

      assert Pyex.run!(code) == "yes"
    end

    test "__bool__ with and/or operators" do
      code = """
      class Val:
          def __init__(self, v, truthy):
              self.v = v
              self.truthy = truthy
          def __bool__(self):
              return self.truthy

      a = Val("a", True)
      b = Val("b", False)
      r1 = (a and "yes")
      r2 = "yes" if (b and "yes") else "short-circuited"
      r3 = (b or "fallback")
      r4 = (a or "unused")
      [r1, r2, r3, r4.v]
      """

      assert Pyex.run!(code) == ["yes", "short-circuited", "fallback", "a"]
    end

    test "__bool__ in comprehension filter" do
      code = """
      class Item:
          def __init__(self, name, active):
              self.name = name
              self.active = active
          def __bool__(self):
              return self.active

      items = [Item("a", True), Item("b", False), Item("c", True)]
      [x.name for x in items if x]
      """

      assert Pyex.run!(code) == ["a", "c"]
    end

    test "__bool__ in assert" do
      code = """
      class Ok:
          def __bool__(self):
              return True

      assert Ok()
      "passed"
      """

      assert Pyex.run!(code) == "passed"
    end

    test "__call__ mutation propagates back" do
      code = """
      class Acc:
          def __init__(self):
              self.total = 0
          def __call__(self, n):
              self.total = self.total + n

      a = Acc()
      a(5)
      a(3)
      a.total
      """

      assert Pyex.run!(code) == 8
    end

    test "sorted with reverse=True" do
      assert Pyex.run!("sorted([3, 1, 2], reverse=True)") == [3, 2, 1]
    end

    test "sorted with key function" do
      code = """
      sorted(["banana", "apple", "cherry"], key=len)
      """

      assert Pyex.run!(code) == ["apple", "banana", "cherry"]
    end

    test "sorted instances by __lt__" do
      code = """
      class Num:
          def __init__(self, v):
              self.v = v
          def __lt__(self, other):
              return self.v < other.v

      nums = [Num(3), Num(1), Num(2)]
      [x.v for x in sorted(nums)]
      """

      assert Pyex.run!(code) == [1, 2, 3]
    end

    test "sorted instances with reverse=True" do
      code = """
      class Num:
          def __init__(self, v):
              self.v = v
          def __lt__(self, other):
              return self.v < other.v

      nums = [Num(3), Num(1), Num(2)]
      [x.v for x in sorted(nums, reverse=True)]
      """

      assert Pyex.run!(code) == [3, 2, 1]
    end
  end

  describe "__iter__ and __next__ protocol" do
    test "__iter__ returning list makes instance iterable in for loop" do
      code = """
      class Range3:
          def __iter__(self):
              return [0, 1, 2]

      results = []
      for x in Range3():
          results.append(x)
      results
      """

      assert Pyex.run!(code) == [0, 1, 2]
    end

    test "__iter__/__next__ iterator protocol with for loop" do
      code = """
      class Counter:
          def __init__(self, limit):
              self.limit = limit
              self.current = 0
          def __iter__(self):
              self.current = 0
              return self
          def __next__(self):
              if self.current >= self.limit:
                  raise StopIteration()
              val = self.current
              self.current += 1
              return val

      results = []
      for x in Counter(4):
          results.append(x)
      results
      """

      assert Pyex.run!(code) == [0, 1, 2, 3]
    end

    test "__iter__ in list comprehension" do
      code = """
      class Evens:
          def __init__(self, n):
              self.n = n
          def __iter__(self):
              return [i * 2 for i in range(self.n)]

      [x + 1 for x in Evens(5)]
      """

      assert Pyex.run!(code) == [1, 3, 5, 7, 9]
    end

    test "__iter__ with *args unpacking" do
      code = """
      class Args:
          def __iter__(self):
              return [10, 20, 30]

      def add(a, b, c):
          return a + b + c

      add(*Args())
      """

      assert Pyex.run!(code) == 60
    end

    test "non-iterable instance raises TypeError" do
      code = """
      class NotIterable:
          pass

      for x in NotIterable():
          pass
      """

      {:error, %Error{message: msg}} = Pyex.run(code)
      assert msg =~ "TypeError: 'NotIterable' object is not iterable"
    end

    test "__iter__ returning iterator instance that lacks __next__" do
      code = """
      class BadIter:
          pass

      class Container:
          def __iter__(self):
              return BadIter()

      for x in Container():
          pass
      """

      {:error, %Error{message: msg}} = Pyex.run(code)
      assert msg =~ "TypeError: 'BadIter' object is not an iterator"
    end
  end
end
