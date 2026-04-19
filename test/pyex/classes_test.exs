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

      {:class, name, _, _} = Pyex.run!(code)
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

    test "class attribute set to None is accessible" do
      code = """
      class Config:
          debug = None
          name = "app"

      c = Config()
      (c.debug, c.name)
      """

      assert Pyex.run!(code) == {:tuple, [nil, "app"]}
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

    test "multiple local instance assignments remain accessible" do
      code = """
      class Box:
          def __init__(self, val):
              self.val = val

      def make_total():
          a = Box(10)
          b = Box(20)
          return a.val + b.val

      make_total()
      """

      assert Pyex.run!(code) == 30
    end

    test "local containers survive later instance assignments" do
      code = """
      class Box:
          def __init__(self, val):
              self.val = val

      def collect():
          first = Box(10)
          items = [first]
          second = Box(20)
          items.append(second)
          return items[0].val + items[1].val

      collect()
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

    test "diamond with super() — cooperative MRO" do
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

      # Python MRO for D: [D, B, C, A]
      # So D.__init__ → B.__init__ → C.__init__ → A.__init__
      assert Pyex.run!(code) == ["A", "C", "B", "D"]
    end

    test "diamond method resolution without super()" do
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

      # MRO: [D, B, C, A] — B has no method, so C's is found first
      assert Pyex.run!(code) == "C"
    end

    test "multiple inheritance with mixin" do
      code = """
      class JsonMixin:
          def to_json(self):
              return "{name: " + self.name + "}"

      class Animal:
          def __init__(self, name):
              self.name = name
          def speak(self):
              return self.name + " speaks"

      class Dog(JsonMixin, Animal):
          def speak(self):
              return self.name + " barks"

      d = Dog("Rex")
      (d.speak(), d.to_json())
      """

      assert Pyex.run!(code) == {:tuple, ["Rex barks", "{name: Rex}"]}
    end

    test "super() with cooperative methods beyond __init__" do
      code = """
      class Base:
          def greet(self):
              return "hello"

      class Loud(Base):
          def greet(self):
              return super().greet().upper()

      class Polite(Base):
          def greet(self):
              return super().greet() + ", please"

      class LoudPolite(Loud, Polite):
          pass

      LoudPolite().greet()
      """

      # MRO: [LoudPolite, Loud, Polite, Base]
      # Loud.greet → super().greet() calls Polite.greet
      # Polite.greet → super().greet() calls Base.greet → "hello"
      # Polite returns "hello, please"
      # Loud returns "hello, please".upper() → "HELLO, PLEASE"
      assert Pyex.run!(code) == "HELLO, PLEASE"
    end

    test "__mro__ via type()" do
      code = """
      class A:
          pass
      class B(A):
          pass
      class C(A):
          pass
      class D(B, C):
          pass

      bases = []
      for cls in [D, B, C, A]:
          bases.append(type(cls).__name__ if hasattr(cls, '__name__') else str(cls))

      # Just verify D inherits from both B and C
      d = D()
      isinstance(d, B) and isinstance(d, C) and isinstance(d, A)
      """

      assert Pyex.run!(code) == true
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

  # ── %s formatting with __str__ ─────────────────────────────────────────────

  describe "%s format with __str__" do
    test "%s calls __str__ on instance" do
      result =
        Pyex.run!("""
        class Tag:
            def __str__(self): return "my_tag"
        "%s" % Tag()
        """)

      assert result == "my_tag"
    end

    test "%s on exception instance returns message" do
      result =
        Pyex.run!("""
        try:
            raise ValueError("bad input")
        except ValueError as e:
            "%s" % e
        """)

      assert result == "bad input"
    end

    test "%s with width padding calls __str__" do
      result =
        Pyex.run!("""
        class Tag:
            def __str__(self): return "hi"
        "%-10s|" % Tag()
        """)

      assert result == "hi        |"
    end

    test "print uses __str__ on instance" do
      result =
        Pyex.run!("""
        class Greet:
            def __str__(self): return "hello"
        g = Greet()
        str(g)
        """)

      assert result == "hello"
    end

    test "__repr__ fallback when no __str__" do
      result =
        Pyex.run!("""
        class Thing:
            def __repr__(self): return "Thing()"
        str(Thing())
        """)

      assert result == "Thing()"
    end
  end

  # ── augmented assignment on instance attributes ───────────────────────────

  describe "augmented assignment on instance attributes" do
    test "self.n += x inside method" do
      result =
        Pyex.run!("""
        class Acc:
            def __init__(self): self.n = 0
            def add(self, x): self.n += x
        a = Acc()
        a.add(5)
        a.add(3)
        a.n
        """)

      assert result == 8
    end

    test "obj.attr += value from outside" do
      result =
        Pyex.run!("""
        class Box:
            def __init__(self, v): self.v = v
        b = Box(10)
        b.v += 5
        b.v
        """)

      assert result == 15
    end

    test "self.total += x across calls" do
      result =
        Pyex.run!("""
        class Acc:
            def __init__(self): self.total = 0
            def add(self, x): self.total += x
        a = Acc()
        a.add(10)
        a.add(20)
        a.add(5)
        a.total
        """)

      assert result == 35
    end
  end

  # ── exception hierarchy ────────────────────────────────────────────────────

  describe "exception hierarchy" do
    test "except Exception catches ValueError" do
      result =
        Pyex.run!("""
        try:
            raise ValueError("v")
        except Exception as e:
            str(e)
        """)

      assert result == "v"
    end

    test "except Exception catches TypeError" do
      result =
        Pyex.run!("""
        try:
            raise TypeError("t")
        except Exception as e:
            str(e)
        """)

      assert result == "t"
    end

    test "except Exception catches IndexError" do
      result =
        Pyex.run!("""
        try:
            [][0]
        except Exception as e:
            type(e).__name__
        """)

      assert result == "IndexError"
    end

    test "except Exception catches ZeroDivisionError" do
      result =
        Pyex.run!("""
        try:
            1 / 0
        except Exception:
            "caught"
        """)

      assert result == "caught"
    end

    test "custom exception caught by parent class" do
      result =
        Pyex.run!("""
        class AppError(Exception): pass
        class DBError(AppError): pass
        try:
            raise DBError("db down")
        except AppError as e:
            type(e).__name__ + ":" + str(e)
        """)

      assert result == "DBError:db down"
    end

    test "except tuple catches matching type" do
      result =
        Pyex.run!("""
        try:
            raise ValueError("v")
        except (TypeError, ValueError) as e:
            "caught:" + str(e)
        """)

      assert result == "caught:v"
    end

    test "inner except does not catch outer" do
      result =
        Pyex.run!("""
        try:
            try:
                raise ValueError("inner")
            except TypeError:
                "wrong"
        except ValueError as e:
            "right:" + str(e)
        """)

      assert result == "right:inner"
    end
  end

  # ── frozenset ─────────────────────────────────────────────────────────────

  describe "frozenset" do
    test "construction and equality" do
      assert Pyex.run!("frozenset([1, 2, 3]) == frozenset([3, 2, 1])")
    end

    test "usable as dict key" do
      result =
        Pyex.run!("""
        d = {frozenset([1, 2]): "val"}
        d[frozenset([2, 1])]
        """)

      assert result == "val"
    end

    test "intersection with set" do
      result = Pyex.run!("frozenset([1, 2, 3]) & {2, 3, 4}")
      assert result == {:frozenset, MapSet.new([2, 3])}
    end

    test "union with set" do
      result = Pyex.run!("frozenset([1, 2]) | {3, 4}")
      assert MapSet.equal?(elem(result, 1), MapSet.new([1, 2, 3, 4]))
    end

    test "is hashable (usable in set)" do
      result =
        Pyex.run!("""
        s = {frozenset([1, 2]), frozenset([1, 2]), frozenset([3])}
        len(s)
        """)

      assert result == 2
    end

    test ".add() raises AttributeError" do
      {:error, err} = Pyex.run("frozenset([1]).add(2)")
      assert err.message =~ "AttributeError"
    end
  end

  describe "type() and isinstance() matching CPython" do
    test "type(Foo) is type" do
      assert Pyex.run!("class Foo: pass\ntype(Foo) is type") == true
    end

    test "isinstance(Foo, type) is True" do
      assert Pyex.run!("class Foo: pass\nisinstance(Foo, type)") == true
    end

    test "type(Foo).__name__ is 'type'" do
      assert Pyex.run!("class Foo: pass\ntype(Foo).__name__") == "type"
    end

    test "isinstance(int, type) is True" do
      assert Pyex.run!("isinstance(int, type)") == true
    end

    test "type(42) is int" do
      assert Pyex.run!("type(42) is int") == true
    end

    test "type(\"x\") is str" do
      assert Pyex.run!("type(\"x\") is str") == true
    end

    test "type(True) is bool" do
      assert Pyex.run!("type(True) is bool") == true
    end

    test "bool.__mro__ is (bool, int, object)" do
      {:tuple, classes} = Pyex.run!("bool.__mro__")
      names = Enum.map(classes, fn {:class, n, _, _} -> n end)
      assert names == ["bool", "int", "object"]
    end
  end

  describe "subclassing stdlib classes" do
    test "subclass of datetime.datetime preserves subclass identity" do
      result =
        Pyex.run!("""
        import datetime

        class MyDT(datetime.datetime):
            def greet(self):
                return "hi"

        m = MyDT(2024, 1, 15, 10, 30)
        (type(m).__name__, isinstance(m, MyDT), isinstance(m, datetime.date), m.greet())
        """)

      assert result == {:tuple, ["MyDT", true, true, "hi"]}
    end

    test "subclass can override parent method with super()" do
      assert Pyex.run!("""
             import datetime

             class MyDT(datetime.datetime):
                 def isoformat(self):
                     return "X:" + super().isoformat()

             MyDT(2024, 1, 15).isoformat()
             """) == "X:2024-01-15T00:00:00"
    end

    test "subclass of list works" do
      result =
        Pyex.run!("""
        class MyList(list):
            def total(self):
                return sum(self)

        ml = MyList([1, 2, 3])
        (type(ml).__name__, ml.total(), len(ml), ml[0], isinstance(ml, list))
        """)

      assert result == {:tuple, ["MyList", 6, 3, 1, true]}
    end

    test "subclass of dict works" do
      result =
        Pyex.run!("""
        class MyDict(dict):
            def combined(self):
                return sum(self.values())

        md = MyDict(a=1, b=2)
        (type(md).__name__, md.combined(), len(md), md["a"], isinstance(md, dict))
        """)

      assert result == {:tuple, ["MyDict", 3, 2, 1, true]}
    end
  end

  describe "dict keys with __eq__/__hash__" do
    test "equal custom keys resolve to the same entry" do
      assert Pyex.run!("""
             class K:
                 def __init__(self, v): self.v = v
                 def __eq__(self, other): return isinstance(other, K) and self.v == other.v
                 def __hash__(self): return hash(self.v)

             d = {K(1): "first"}
             d[K(1)]
             """) == "first"
    end

    test "KeyError message doesn't leak ref internals" do
      {:error, err} = Pyex.run("d = {\"x\": 1}\nd[\"y\"]")
      # Should show 'y' with Python repr quoting, not {:ref, ...} or :y
      assert err.message =~ "KeyError: 'y'"
      refute err.message =~ "ref"
    end
  end

  describe "function dunders" do
    test "function exposes __name__, __doc__, __defaults__, __kwdefaults__" do
      assert Pyex.run!("""
             def f(x, y=10, *args, z=20, **kw):
                 "docstring"
                 return x

             (f.__name__, f.__doc__, f.__defaults__, f.__kwdefaults__["z"])
             """) == {:tuple, ["f", "docstring", {:tuple, [10]}, 20]}
    end

    test "lambda has __name__ '<lambda>'" do
      assert Pyex.run!("(lambda x: x).__name__") == "<lambda>"
    end

    test "hasattr works on functions" do
      assert Pyex.run!("""
             def f(): pass
             (hasattr(f, "__name__"), hasattr(f, "nope"))
             """) == {:tuple, [true, false]}
    end
  end

  describe "class __qualname__, __module__, __doc__, __dict__" do
    test "user class exposes qualname, module, doc, dict" do
      result =
        Pyex.run!("""
        class C:
            "the C class"
            x = 1

        (C.__qualname__, C.__module__, C.__doc__, "x" in C.__dict__)
        """)

      assert result == {:tuple, ["C", "__main__", "the C class", true]}
    end
  end

  describe "custom data descriptors" do
    test "__get__ and __set__ descriptors honored" do
      result =
        Pyex.run!("""
        class Prop:
            def __init__(self, v): self.v = v
            def __get__(self, obj, objtype=None): return self.v
            def __set__(self, obj, value): self.v = value

        class C:
            p = Prop(10)

        c = C()
        before = c.p
        c.p = 99
        after = c.p
        (before, after)
        """)

      assert result == {:tuple, [10, 99]}
    end
  end

  describe "__slots__ enforcement" do
    test "slotted class rejects undeclared attrs" do
      {:error, err} =
        Pyex.run("""
        class S:
            __slots__ = ("x", "y")
            def __init__(self, x, y):
                self.x = x
                self.y = y

        s = S(1, 2)
        s.z = 3
        """)

      assert err.message =~ "AttributeError"
      assert err.message =~ "'S'"
      assert err.message =~ "'z'"
    end

    test "regular class still allows arbitrary attrs" do
      assert Pyex.run!("""
             class C:
                 def __init__(self):
                     self.a = 1

             c = C()
             c.b = 2
             c.a + c.b
             """) == 3
    end
  end

  describe "typing generics" do
    test "List[int] returns a typing-generic without error" do
      assert match?(
               {:instance, {:class, "List", _, _}, _},
               Pyex.run!("from typing import List\nList[int]")
             )
    end

    test "Dict[str, int] works with multi-arg subscript" do
      assert match?(
               {:instance, {:class, "Dict", _, _}, _},
               Pyex.run!("from typing import Dict\nDict[str, int]")
             )
    end
  end
end
