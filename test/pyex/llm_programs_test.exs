defmodule Pyex.LlmProgramsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests that simulate realistic Python programs an LLM would generate.
  Each test is a complete program that exercises multiple features together.
  """

  describe "program 1: FizzBuzz" do
    test "classic fizzbuzz" do
      code = """
      def fizzbuzz(n):
          result = []
          for i in range(1, n + 1):
              if i % 15 == 0:
                  result.append("FizzBuzz")
              elif i % 3 == 0:
                  result.append("Fizz")
              elif i % 5 == 0:
                  result.append("Buzz")
              else:
                  result.append(str(i))
          return result

      fizzbuzz(16)
      """

      result = Pyex.run!(code)

      assert result == [
               "1",
               "2",
               "Fizz",
               "4",
               "Buzz",
               "Fizz",
               "7",
               "8",
               "Fizz",
               "Buzz",
               "11",
               "Fizz",
               "13",
               "14",
               "FizzBuzz",
               "16"
             ]
    end
  end

  describe "program 2: linked list class" do
    test "build and traverse linked list" do
      code = """
      class Node:
          def __init__(self, val, next_node):
              self.val = val
              self.next = next_node

      class LinkedList:
          def __init__(self):
              self.head = None

          def push(self, val):
              self.head = Node(val, self.head)

          def to_list(self):
              result = []
              current = self.head
              while current is not None:
                  result.append(current.val)
                  current = current.next
              return result

      ll = LinkedList()
      ll.push(3)
      ll.push(2)
      ll.push(1)
      ll.to_list()
      """

      assert Pyex.run!(code) == [1, 2, 3]
    end
  end

  describe "program 3: fibonacci with memoization" do
    test "memoized fibonacci" do
      code = """
      memo = {}

      def fib(n):
          if n in memo:
              return memo[n]
          if n <= 1:
              return n
          result = fib(n - 1) + fib(n - 2)
          memo[n] = result
          return result

      [fib(i) for i in range(10)]
      """

      assert Pyex.run!(code) == [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
    end
  end

  describe "program 4: text processing pipeline" do
    test "word frequency counter" do
      code = """
      def word_count(text):
          words = text.lower().split()
          counts = {}
          for word in words:
              word = word.strip(".,!?")
              if word == "":
                  continue
              if word in counts:
                  counts[word] = counts[word] + 1
              else:
                  counts[word] = 1
          return counts

      text = "the cat sat on the mat the cat"
      result = word_count(text)
      result["the"]
      """

      assert Pyex.run!(code) == 3
    end
  end

  describe "program 5: matrix operations" do
    test "matrix transpose and multiply" do
      code = """
      def transpose(matrix):
          rows = len(matrix)
          cols = len(matrix[0])
          result = []
          for j in range(cols):
              row = []
              for i in range(rows):
                  row.append(matrix[i][j])
              result.append(row)
          return result

      def dot_product(a, b):
          total = 0
          for i in range(len(a)):
              total = total + a[i] * b[i]
          return total

      def mat_mul(a, b):
          bt = transpose(b)
          result = []
          for row in a:
              new_row = []
              for col in bt:
                  new_row.append(dot_product(row, col))
              result.append(new_row)
          return result

      a = [[1, 2], [3, 4]]
      b = [[5, 6], [7, 8]]
      mat_mul(a, b)
      """

      assert Pyex.run!(code) == [[19, 22], [43, 50]]
    end
  end

  describe "program 6: class hierarchy with polymorphism" do
    test "shape area calculation" do
      code = """
      class Shape:
          def __init__(self, name):
              self.name = name
          def area(self):
              return 0
          def describe(self):
              return self.name + ": area=" + str(self.area())

      class Circle(Shape):
          def __init__(self, radius):
              self.name = "Circle"
              self.radius = radius
          def area(self):
              return 3.14159 * self.radius * self.radius

      class Rectangle(Shape):
          def __init__(self, w, h):
              self.name = "Rectangle"
              self.w = w
              self.h = h
          def area(self):
              return self.w * self.h

      shapes = [Circle(5), Rectangle(3, 4)]
      areas = [s.area() for s in shapes]
      areas
      """

      result = Pyex.run!(code)
      [circle_area, rect_area] = result
      assert abs(circle_area - 78.53975) < 0.001
      assert rect_area == 12
    end
  end

  describe "program 7: sorting algorithms" do
    test "quicksort implementation" do
      code = """
      def quicksort(arr):
          if len(arr) <= 1:
              return arr
          pivot = arr[0]
          left = [x for x in arr[1:] if x <= pivot]
          right = [x for x in arr[1:] if x > pivot]
          return quicksort(left) + [pivot] + quicksort(right)

      quicksort([3, 6, 8, 10, 1, 2, 1])
      """

      assert Pyex.run!(code) == [1, 1, 2, 3, 6, 8, 10]
    end
  end

  describe "program 8: JSON-like data processing" do
    test "nested data extraction" do
      code = """
      data = {
          "users": [
              {"name": "Alice", "age": 30, "active": True},
              {"name": "Bob", "age": 25, "active": False},
              {"name": "Charlie", "age": 35, "active": True}
          ]
      }

      active_users = [u["name"] for u in data["users"] if u["active"]]
      ages = [u["age"] for u in data["users"]]
      avg_age = sum(ages) / len(ages)

      result = {
          "active": active_users,
          "avg_age": avg_age,
          "count": len(data["users"])
      }
      result["active"]
      """

      assert Pyex.run!(code) == ["Alice", "Charlie"]
    end
  end

  describe "program 9: exception handling" do
    test "try/except with custom logic" do
      code = """
      def safe_divide(a, b):
          try:
              if b == 0:
                  raise ValueError("division by zero")
              return a / b
          except ValueError as e:
              return -1

      results = []
      results.append(safe_divide(10, 2))
      results.append(safe_divide(10, 0))
      results.append(safe_divide(9, 3))
      results
      """

      assert Pyex.run!(code) == [5.0, -1, 3.0]
    end
  end

  describe "program 10: iterator patterns and data pipeline" do
    test "functional-style data pipeline" do
      code = """
      def pipeline(data, *funcs):
          result = data
          for func in funcs:
              result = func(result)
          return result

      def double_all(lst):
          return [x * 2 for x in lst]

      def filter_even(lst):
          return [x for x in lst if x % 2 == 0]

      def sum_list(lst):
          total = 0
          for x in lst:
              total = total + x
          return total

      numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      pipeline(numbers, double_all, filter_even, sum_list)
      """

      assert Pyex.run!(code) == 110
    end
  end

  describe "program 11: command processor with match/case" do
    test "processes commands via pattern matching" do
      code = """
      def process_command(cmd):
          match cmd:
              case ["quit"]:
                  return "Goodbye!"
              case ["greet", name]:
                  return f"Hello, {name}!"
              case ["add", x, y]:
                  return str(int(x) + int(y))
              case ["echo", *words]:
                  return " ".join(words)
              case _:
                  return "Unknown command"

      results = []
      commands = [
          ["greet", "Alice"],
          ["add", "3", "4"],
          ["echo", "hello", "world"],
          ["quit"],
          ["unknown"]
      ]
      for cmd in commands:
          results.append(process_command(cmd))
      results
      """

      assert Pyex.run!(code) == [
               "Hello, Alice!",
               "7",
               "hello world",
               "Goodbye!",
               "Unknown command"
             ]
    end
  end

  describe "program 12: fibonacci generator with data processing" do
    test "generates fibonacci sequence and processes it" do
      code = """
      def fibonacci(limit):
          a, b = 0, 1
          while a <= limit:
              yield a
              a, b = b, a + b

      def is_even(n):
          return n % 2 == 0

      fibs = list(fibonacci(100))
      even_fibs = [f for f in fibs if is_even(f)]
      result = {
          "count": len(fibs),
          "sum": sum(fibs),
          "even_count": len(even_fibs),
          "even_sum": sum(even_fibs),
          "max": max(fibs)
      }
      result
      """

      assert Pyex.run!(code) == %{
               "count" => 12,
               "sum" => 232,
               "even_count" => 4,
               "even_sum" => 44,
               "max" => 89
             }
    end
  end

  describe "program 13: config parser using classes and match" do
    test "parses config lines into typed values" do
      code = """
      class Config:
          def __init__(self):
              self.data = {}

          def set(self, key, value):
              self.data[key] = value

          def get(self, key):
              return self.data.get(key)

          def parse_value(self, raw):
              match raw:
                  case "true" | "True" | "yes":
                      return True
                  case "false" | "False" | "no":
                      return False
                  case "none" | "None" | "null":
                      return None
                  case _:
                      try:
                          return int(raw)
                      except:
                          return raw

      config = Config()
      lines = [
          "debug=true",
          "port=8080",
          "host=localhost",
          "verbose=false",
          "timeout=none"
      ]
      for line in lines:
          key, value = line.split("=")
          config.set(key, config.parse_value(value))

      [config.get("debug"), config.get("port"), config.get("host"),
       config.get("verbose"), config.get("timeout")]
      """

      assert Pyex.run!(code) == [true, 8080, "localhost", false, nil]
    end
  end

  describe "program 14: pipeline with generators and yield from" do
    test "chains data processing generators" do
      code = """
      def read_data():
          yield {"name": "Alice", "age": 30, "dept": "eng"}
          yield {"name": "Bob", "age": 25, "dept": "sales"}
          yield {"name": "Carol", "age": 35, "dept": "eng"}
          yield {"name": "Dave", "age": 28, "dept": "eng"}
          yield {"name": "Eve", "age": 32, "dept": "sales"}

      def filter_dept(records, dept):
          for r in records:
              if r["dept"] == dept:
                  yield r

      def extract_names(records):
          for r in records:
              yield r["name"]

      eng_names = sorted(list(extract_names(filter_dept(read_data(), "eng"))))
      eng_names
      """

      assert Pyex.run!(code) == ["Alice", "Carol", "Dave"]
    end
  end

  describe "program 15: state machine with match/case and classes" do
    test "simple traffic light state machine" do
      code = """
      class TrafficLight:
          def __init__(self):
              self.state = "red"
              self.history = []

          def next(self):
              self.history.append(self.state)
              match self.state:
                  case "red":
                      self.state = "green"
                  case "green":
                      self.state = "yellow"
                  case "yellow":
                      self.state = "red"

          def get_history(self):
              return self.history + [self.state]

      light = TrafficLight()
      for _ in range(6):
          light.next()

      light.get_history()
      """

      assert Pyex.run!(code) == ["red", "green", "yellow", "red", "green", "yellow", "red"]
    end
  end

  describe "program 16: vector math with dunder methods" do
    test "vector operations using operator overloading" do
      code = """
      class Vector:
          def __init__(self, x, y):
              self.x = x
              self.y = y

          def __add__(self, other):
              return Vector(self.x + other.x, self.y + other.y)

          def __sub__(self, other):
              return Vector(self.x - other.x, self.y - other.y)

          def __mul__(self, scalar):
              return Vector(self.x * scalar, self.y * scalar)

          def __eq__(self, other):
              return self.x == other.x and self.y == other.y

          def __neg__(self):
              return Vector(-self.x, -self.y)

          def magnitude(self):
              return (self.x ** 2 + self.y ** 2) ** 0.5

          def __repr__(self):
              return "Vector(" + str(self.x) + ", " + str(self.y) + ")"

      v1 = Vector(3, 4)
      v2 = Vector(1, 2)

      v3 = v1 + v2
      v4 = v1 - v2
      v5 = v1 * 2
      v6 = -v1

      results = {
          "add": (v3.x, v3.y),
          "sub": (v4.x, v4.y),
          "mul": (v5.x, v5.y),
          "neg": (v6.x, v6.y),
          "eq": v1 == Vector(3, 4),
          "neq": v1 == v2,
          "mag": round(v1.magnitude(), 1),
          "repr": repr(v1)
      }
      results
      """

      result = Pyex.run!(code)
      assert result["add"] == {:tuple, [4, 6]}
      assert result["sub"] == {:tuple, [2, 2]}
      assert result["mul"] == {:tuple, [6, 8]}
      assert result["neg"] == {:tuple, [-3, -4]}
      assert result["eq"] == true
      assert result["neq"] == false
      assert result["mag"] == 5.0
      assert result["repr"] == "Vector(3, 4)"
    end
  end

  describe "program 17: inheritance hierarchy with super()" do
    test "animal hierarchy with polymorphism" do
      code = """
      class Animal:
          def __init__(self, name, sound):
              self.name = name
              self.sound = sound

          def speak(self):
              return self.name + " says " + self.sound

      class Pet(Animal):
          def __init__(self, name, sound, owner):
              super().__init__(name, sound)
              self.owner = owner

          def info(self):
              return self.speak() + " (owner: " + self.owner + ")"

      class Dog(Pet):
          def __init__(self, name, owner, breed):
              super().__init__(name, "Woof", owner)
              self.breed = breed

          def fetch(self):
              return self.name + " fetches the ball"

      class Cat(Pet):
          def __init__(self, name, owner):
              super().__init__(name, "Meow", owner)

      rex = Dog("Rex", "Alice", "Labrador")
      whiskers = Cat("Whiskers", "Bob")

      results = [
          rex.speak(),
          rex.info(),
          rex.fetch(),
          rex.breed,
          whiskers.speak(),
          whiskers.info(),
          isinstance(rex, Dog),
          isinstance(rex, Pet),
          isinstance(rex, Animal)
      ]
      results
      """

      assert Pyex.run!(code) == [
               "Rex says Woof",
               "Rex says Woof (owner: Alice)",
               "Rex fetches the ball",
               "Labrador",
               "Whiskers says Meow",
               "Whiskers says Meow (owner: Bob)",
               true,
               true,
               true
             ]
    end
  end

  describe "program 18: nested comprehensions for matrix operations" do
    test "matrix transpose and flatten" do
      code = """
      matrix = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

      flat = [x for row in matrix for x in row]

      transpose = [[row[i] for row in matrix] for i in range(len(matrix[0]))]

      even_flat = [x for row in matrix for x in row if x % 2 == 0]

      pairs = [(i, j) for i in range(3) for j in range(3) if i != j]

      diag = [matrix[i][i] for i in range(len(matrix))]

      {
          "flat": flat,
          "transpose": transpose,
          "evens": even_flat,
          "pairs": len(pairs),
          "diagonal": diag
      }
      """

      result = Pyex.run!(code)
      assert result["flat"] == [1, 2, 3, 4, 5, 6, 7, 8, 9]
      assert result["transpose"] == [[1, 4, 7], [2, 5, 8], [3, 6, 9]]
      assert result["evens"] == [2, 4, 6, 8]
      assert result["pairs"] == 6
      assert result["diagonal"] == [1, 5, 9]
    end
  end

  describe "program 19: callable class with isinstance" do
    test "function-like objects and type checking" do
      code = """
      class Validator:
          def __init__(self, validator_fn, name):
              self.validator_fn = validator_fn
              self.name = name
              self.errors = []

          def __call__(self, value):
              if self.validator_fn(value):
                  return True
              self.errors.append(self.name + " failed for " + str(value))
              return False

          def __bool__(self):
              return len(self.errors) == 0

          def __len__(self):
              return len(self.errors)

      def is_positive(x):
          return isinstance(x, int) and x > 0

      def is_short_str(x):
          return isinstance(x, str) and len(x) < 10

      pos_check = Validator(is_positive, "positive")
      str_check = Validator(is_short_str, "short_string")

      results = []
      results.append(pos_check(5))
      results.append(pos_check(-1))
      results.append(str_check("hi"))
      results.append(str_check("this is way too long"))

      results.append(callable(pos_check))
      results.append(not pos_check)
      results.append(not str_check)
      results.append(len(pos_check))
      results.append(len(str_check))

      results
      """

      assert Pyex.run!(code) == [true, false, true, false, true, true, true, 1, 1]
    end
  end

  describe "program 20: data pipeline with generators and comprehensions" do
    test "student grade processing pipeline" do
      code = """
      class Student:
          def __init__(self, name, scores):
              self.name = name
              self.scores = scores

          def average(self):
              return sum(self.scores) / len(self.scores)

          def __lt__(self, other):
              return self.average() < other.average()

          def __eq__(self, other):
              return self.name == other.name

          def grade(self):
              avg = self.average()
              if avg >= 90:
                  return "A"
              elif avg >= 80:
                  return "B"
              elif avg >= 70:
                  return "C"
              else:
                  return "F"

      students = [
          Student("Alice", [95, 87, 92]),
          Student("Bob", [78, 85, 72]),
          Student("Carol", [90, 95, 88]),
          Student("Dave", [65, 70, 68])
      ]

      grades = {s.name: s.grade() for s in students}

      passing = [s.name for s in students if s.average() >= 70]

      top_scores = sorted([s.average() for s in students], reverse=True)

      best = sorted(students, reverse=True)[0]

      {
          "grades": grades,
          "passing": passing,
          "top_avg": round(top_scores[0], 1),
          "best": best.name
      }
      """

      result = Pyex.run!(code)
      assert result["grades"] == %{"Alice" => "A", "Bob" => "C", "Carol" => "A", "Dave" => "F"}
      assert result["passing"] == ["Alice", "Bob", "Carol"]
      assert result["top_avg"] == 91.3
      assert result["best"] == "Alice"
    end
  end
end
