defmodule Pyex.IntegrationTest do
  @moduledoc """
  Complex integration tests that exercise many features together.

  Each test runs a realistic Python program that combines multiple
  language features to verify correct interaction between subsystems.
  """
  use ExUnit.Case, async: true

  # -------------------------------------------------------------------
  # 1. Financial ledger: Decimal + defaultdict + f-string + classes + loops
  # -------------------------------------------------------------------
  describe "financial ledger" do
    test "category totals with precise Decimal arithmetic and formatted report" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        from collections import defaultdict

        class Transaction:
            def __init__(self, category, amount, description):
                self.category = category
                self.amount = Decimal(amount)
                self.description = description

        transactions = [
            Transaction("food", "19.99", "groceries"),
            Transaction("food", "4.99", "coffee"),
            Transaction("transport", "50.00", "gas"),
            Transaction("food", "3.49", "snack"),
            Transaction("transport", "2.50", "parking"),
            Transaction("utilities", "120.00", "electric"),
            Transaction("utilities", "45.99", "internet"),
        ]

        totals = defaultdict(lambda: Decimal("0"))
        counts = defaultdict(lambda: 0)

        for t in transactions:
            totals[t.category] += t.amount
            counts[t.category] += 1

        lines = []
        grand_total = Decimal("0")
        for cat in sorted(totals.keys()):
            total = totals[cat]
            avg = total / counts[cat]
            grand_total += total
            lines.append(f"{cat:<12} {counts[cat]:>3} items  total: {str(total):>8}  avg: {str(avg)}")

        lines.append(f"{'TOTAL':<12}            total: {str(grand_total):>8}")
        "\\n".join(lines)
        """)

      assert result =~ "food"
      assert result =~ "transport"
      assert result =~ "utilities"
      # Verify Decimal precision: 19.99 + 4.99 + 3.49 = 28.47 exactly
      assert result =~ "28.47"
      # transport: 50.00 + 2.50 = 52.50
      assert result =~ "52.50"
      # utilities: 120.00 + 45.99 = 165.99
      assert result =~ "165.99"
      # grand total: 28.47 + 52.50 + 165.99 = 246.96
      assert result =~ "246.96"
    end

    test "transaction filtering and balance computation" do
      result =
        Pyex.run!("""
        from decimal import Decimal

        class Account:
            def __init__(self, name):
                self.name = name
                self.balance = Decimal("0")
                self.history = []

            def deposit(self, amount):
                self.balance += Decimal(amount)
                self.history.append(("deposit", Decimal(amount)))

            def withdraw(self, amount):
                amt = Decimal(amount)
                if amt > self.balance:
                    return False
                self.balance -= amt
                self.history.append(("withdraw", amt))
                return True

        acct = Account("checking")
        acct.deposit("1000.00")
        acct.deposit("250.50")
        acct.withdraw("75.25")
        acct.withdraw("100.00")
        acct.deposit("30.00")

        deposits = [amt for typ, amt in acct.history if typ == "deposit"]
        withdrawals = [amt for typ, amt in acct.history if typ == "withdraw"]

        total_in = Decimal("0")
        for d in deposits:
            total_in += d

        total_out = Decimal("0")
        for w in withdrawals:
            total_out += w

        (str(acct.balance), str(total_in), str(total_out), len(acct.history))
        """)

      # balance = 1000.00 + 250.50 - 75.25 - 100.00 + 30.00 = 1105.25
      assert result == {:tuple, ["1105.25", "1280.50", "175.25", 5]}
    end
  end

  # -------------------------------------------------------------------
  # 2. Data pipeline: comprehensions + sorting + string methods +
  #    generators + dict operations + functional builtins
  # -------------------------------------------------------------------
  describe "data pipeline" do
    test "word frequency analysis with sorting and filtering" do
      result =
        Pyex.run!("""
        text = "the quick brown fox jumps over the lazy dog the fox the dog"
        words = text.lower().split()

        freq = {}
        for w in words:
            freq[w] = freq.get(w, 0) + 1

        # Sort by frequency descending, then alphabetically
        pairs = sorted(freq.items(), key=lambda p: (-p[1], p[0]))

        # Top words with count > 1
        top = [(w, c) for w, c in pairs if c > 1]

        # Format as "word(count)" strings
        formatted = [f"{w}({c})" for w, c in top]

        ", ".join(formatted)
        """)

      assert result == "the(4), dog(2), fox(2)"
    end

    test "nested data transformation with comprehensions and unpacking" do
      result =
        Pyex.run!("""
        students = [
            {"name": "Alice", "grades": [90, 85, 92, 88]},
            {"name": "Bob", "grades": [75, 80, 70, 85]},
            {"name": "Carol", "grades": [95, 98, 92, 97]},
            {"name": "Dave", "grades": [60, 65, 70, 55]},
        ]

        # Compute average, assign letter grade
        def letter_grade(avg):
            if avg >= 90:
                return "A"
            elif avg >= 80:
                return "B"
            elif avg >= 70:
                return "C"
            else:
                return "F"

        results = []
        for s in students:
            avg = sum(s["grades"]) / len(s["grades"])
            lg = letter_grade(avg)
            results.append((s["name"], avg, lg))

        # Sort by average descending using sorted (not in-place sort)
        results = sorted(results, key=lambda r: -r[1])

        # Get names of passing students (C or above)
        passing = [name for name, avg, lg in results if lg != "F"]

        # Build summary
        top_name, top_avg, top_grade = results[0]

        (passing, f"{top_name}: {top_avg:.1f} ({top_grade})")
        """)

      assert result == {:tuple, [["Carol", "Alice", "Bob"], "Carol: 95.5 (A)"]}
    end

    test "generator pipeline with chained transformations" do
      result =
        Pyex.run!("""
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
                    break
                yield x
                count += 1

        # Pipeline: generate squares -> filter evens -> take first 5
        pipeline = take(evens(squares(100)), 5)
        list(pipeline)
        """)

      # squares: 0,1,4,9,16,25,36,49,64,81,...
      # evens: 0,4,16,36,64,...
      assert result == [0, 4, 16, 36, 64]
    end
  end

  # -------------------------------------------------------------------
  # 3. CSV/File report: open() + csv module + defaultdict + f-strings
  # -------------------------------------------------------------------
  describe "CSV report processing" do
    test "read CSV, aggregate, and write formatted report" do
      csv_data =
        "name,department,salary\nAlice,Engineering,95000\nBob,Marketing,72000\nCarol,Engineering,105000\nDave,Marketing,68000\nEve,Engineering,88000\n"

      fs = Pyex.Filesystem.Memory.new(%{"employees.csv" => csv_data})

      result =
        Pyex.run!(
          """
          import csv
          from collections import defaultdict

          # Read CSV
          f = open("employees.csv", "r")
          reader = csv.DictReader(f)
          rows = list(reader)
          f.close()

          # Aggregate by department
          dept_salaries = defaultdict(lambda: [])
          for row in rows:
              dept_salaries[row["department"]].append(int(row["salary"]))

          # Build report
          lines = []
          for dept in sorted(dept_salaries.keys()):
              salaries = dept_salaries[dept]
              avg = sum(salaries) / len(salaries)
              lines.append(f"{dept}: {len(salaries)} employees, avg ${avg:,.0f}")

          # Write report
          report = "\\n".join(lines)
          out = open("report.txt", "w")
          out.write(report)
          out.close()

          report
          """,
          filesystem: fs
        )

      assert result =~ "Engineering: 3 employees, avg $96,000"
      assert result =~ "Marketing: 2 employees, avg $70,000"
    end

    test "parse and transform CSV data with list comprehensions" do
      csv_data = "product,price,quantity\nWidget,9.99,100\nGadget,24.99,50\nGizmo,4.99,200\n"
      fs = Pyex.Filesystem.Memory.new(%{"inventory.csv" => csv_data})

      result =
        Pyex.run!(
          """
          import csv

          f = open("inventory.csv", "r")
          reader = csv.DictReader(f)
          items = list(reader)
          f.close()

          # Compute total value per item
          valued = [(row["product"], float(row["price"]) * int(row["quantity"]))
                    for row in items]

          # Sort by value descending using sorted()
          valued = sorted(valued, key=lambda x: -x[1])

          # Format output
          total = sum(v for _, v in valued)
          top_product, top_value = valued[0]

          (top_product, len(items), total)
          """,
          filesystem: fs
        )

      # Gadget: 24.99*50=1249.5, Widget: 9.99*100=999, Gizmo: 4.99*200=998
      # Total: 3246.5, top = Gadget
      assert result == {:tuple, ["Gadget", 3, 3246.5]}
    end
  end

  # -------------------------------------------------------------------
  # 4. Class hierarchy: inheritance + super + dunder + exceptions +
  #    decorators
  # -------------------------------------------------------------------
  describe "class hierarchy" do
    test "shape hierarchy with polymorphism and dunder methods" do
      result =
        Pyex.run!("""
        import math

        class Shape:
            def __init__(self, name):
                self.name = name

            def area(self):
                return 0

            def __str__(self):
                return f"{self.name}: area={self.area():.2f}"

        class Circle(Shape):
            def __init__(self, radius):
                super().__init__("Circle")
                self.radius = radius

            def area(self):
                return math.pi * self.radius ** 2

        class Rectangle(Shape):
            def __init__(self, width, height):
                super().__init__("Rectangle")
                self.width = width
                self.height = height

            def area(self):
                return self.width * self.height

        class Square(Rectangle):
            def __init__(self, side):
                super().__init__(side, side)
                self.name = "Square"

        shapes = [Circle(5), Rectangle(4, 6), Square(3)]

        # Polymorphic area computation
        total_area = sum(s.area() for s in shapes)

        # String representations
        labels = [str(s) for s in shapes]

        # Type checking
        checks = (
            isinstance(shapes[2], Rectangle),
            isinstance(shapes[2], Shape),
            isinstance(shapes[0], Rectangle),
        )

        (labels, checks, total_area > 100)
        """)

      assert {:tuple, [labels, checks, area_check]} = result

      assert length(labels) == 3
      assert Enum.at(labels, 0) =~ "Circle: area="
      assert Enum.at(labels, 1) =~ "Rectangle: area=24.00"
      assert Enum.at(labels, 2) =~ "Square: area=9.00"
      assert checks == {:tuple, [true, true, false]}
      # pi*25 + 24 + 9 = ~111.54
      assert area_check == true
    end

    test "exception hierarchy with try/except and custom exceptions" do
      result =
        Pyex.run!("""
        class AppError(Exception):
            pass

        class ValidationError(AppError):
            pass

        class NotFoundError(AppError):
            pass

        def validate(value):
            if not isinstance(value, int):
                raise ValidationError("must be an integer")
            if value < 0:
                raise ValidationError("must be non-negative")
            if value > 100:
                raise NotFoundError("value out of range")
            return value * 2

        results = []
        test_inputs = [42, -1, "hello", 200, 0]

        for inp in test_inputs:
            try:
                r = validate(inp)
                results.append(("ok", r))
            except ValidationError as e:
                results.append(("validation", str(e)))
            except NotFoundError as e:
                results.append(("not_found", str(e)))

        results
        """)

      assert result == [
               {:tuple, ["ok", 84]},
               {:tuple, ["validation", "must be non-negative"]},
               {:tuple, ["validation", "must be an integer"]},
               {:tuple, ["not_found", "value out of range"]},
               {:tuple, ["ok", 0]}
             ]
    end

    test "decorator pattern with class-based call counting" do
      result =
        Pyex.run!("""
        class CallCounter:
            def __init__(self, func):
                self.func = func
                self.count = 0
                self.last_result = None

            def __call__(self, *args, **kwargs):
                self.count += 1
                self.last_result = self.func(*args, **kwargs)
                return self.last_result

        @CallCounter
        def add(a, b):
            return a + b

        @CallCounter
        def multiply(a, b):
            return a * b

        add(3, 4)
        add(10, 20)
        add(1, 1)
        multiply(5, 6)

        (add.count, add.last_result, multiply.count, multiply.last_result)
        """)

      assert result == {:tuple, [3, 2, 1, 30]}
    end
  end

  # -------------------------------------------------------------------
  # 5. Text processing: re + string methods + Counter + comprehensions
  # -------------------------------------------------------------------
  describe "text processing" do
    test "log parsing with regex and Counter" do
      result =
        Pyex.run!("""
        import re
        from collections import Counter

        logs = [
            "2024-01-15 INFO  User login: alice",
            "2024-01-15 ERROR Database connection failed",
            "2024-01-15 INFO  User login: bob",
            "2024-01-15 WARN  Disk usage at 85%",
            "2024-01-16 ERROR Timeout on API call",
            "2024-01-16 INFO  User login: alice",
            "2024-01-16 INFO  User logout: bob",
            "2024-01-16 ERROR Database connection failed",
        ]

        # Parse log levels
        levels = []
        for line in logs:
            match = re.search(r"(INFO|ERROR|WARN)", line)
            if match:
                levels.append(match.group(1))

        level_counts = Counter(levels)

        # Extract unique users
        users = set()
        for line in logs:
            match = re.search(r"User (?:login|logout): (\\w+)", line)
            if match:
                users.add(match.group(1))

        # Count errors per day using a plain dict
        error_days = {}
        for line in logs:
            if "ERROR" in line:
                date = line[:10]
                error_days[date] = error_days.get(date, 0) + 1

        (level_counts["INFO"], level_counts["ERROR"], level_counts["WARN"],
         sorted(list(users)), error_days)
        """)

      assert result ==
               {:tuple,
                [
                  4,
                  3,
                  1,
                  ["alice", "bob"],
                  %{"2024-01-15" => 1, "2024-01-16" => 2}
                ]}
    end

    test "text template rendering with string operations" do
      code = ~S"""
      def render_template(template, context):
          result = template
          for key, value in context.items():
              placeholder = "{{" + key + "}}"
              result = result.replace(placeholder, str(value))
          return result

      template = "Dear {{name}},\nYour order #{{order_id}} of {{quantity}} items totaling ${{total}} has shipped."

      context = {
          "name": "Alice",
          "order_id": 12345,
          "quantity": 3,
          "total": "29.97",
      }

      rendered = render_template(template, context)
      lines = rendered.split("\n")

      (lines[0], "shipped" in lines[1], lines[1].count("$"))
      """

      result = Pyex.run!(code)

      assert result == {:tuple, ["Dear Alice,", true, 1]}
    end
  end

  # -------------------------------------------------------------------
  # 6. Algorithm implementations: recursion + closures + data structures
  # -------------------------------------------------------------------
  describe "algorithms" do
    test "merge sort with recursion and list slicing" do
      result =
        Pyex.run!("""
        def merge_sort(arr):
            if len(arr) <= 1:
                return arr
            mid = len(arr) // 2
            left = merge_sort(arr[:mid])
            right = merge_sort(arr[mid:])
            return merge(left, right)

        def merge(left, right):
            result = []
            i = 0
            j = 0
            while i < len(left) and j < len(right):
                if left[i] <= right[j]:
                    result.append(left[i])
                    i += 1
                else:
                    result.append(right[j])
                    j += 1
            while i < len(left):
                result.append(left[i])
                i += 1
            while j < len(right):
                result.append(right[j])
                j += 1
            return result

        data = [38, 27, 43, 3, 9, 82, 10]
        merge_sort(data)
        """)

      assert result == [3, 9, 10, 27, 38, 43, 82]
    end

    test "binary search with while loop and edge cases" do
      result =
        Pyex.run!("""
        def binary_search(arr, target):
            lo = 0
            hi = len(arr) - 1
            while lo <= hi:
                mid = (lo + hi) // 2
                if arr[mid] == target:
                    return mid
                elif arr[mid] < target:
                    lo = mid + 1
                else:
                    hi = mid - 1
            return -1

        data = [2, 5, 8, 12, 16, 23, 38, 56, 72, 91]

        results = []
        for target in [23, 2, 91, 50, 8]:
            results.append(binary_search(data, target))

        results
        """)

      assert result == [5, 0, 9, -1, 2]
    end

    test "memoized fibonacci with closure and dict cache" do
      result =
        Pyex.run!("""
        def memoize(func):
            cache = {}
            def wrapper(n):
                if n not in cache:
                    cache[n] = func(n)
                return cache[n]
            return wrapper

        @memoize
        def fib(n):
            if n <= 1:
                return n
            return fib(n - 1) + fib(n - 2)

        # Compute several fibonacci numbers
        results = [fib(i) for i in range(15)]

        (results, fib(10), fib(0), fib(1))
        """)

      assert result ==
               {:tuple,
                [
                  [0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377],
                  55,
                  0,
                  1
                ]}
    end
  end

  # -------------------------------------------------------------------
  # 7. Stateful processing: classes + closures + itertools + generators
  # -------------------------------------------------------------------
  describe "stateful processing" do
    test "state machine with class and enum-like pattern" do
      result =
        Pyex.run!("""
        class StateMachine:
            def __init__(self):
                self.state = "idle"
                self.transitions = {
                    ("idle", "start"): "running",
                    ("running", "pause"): "paused",
                    ("paused", "resume"): "running",
                    ("running", "stop"): "stopped",
                    ("paused", "stop"): "stopped",
                }
                self.history = []

            def send(self, event):
                key = (self.state, event)
                if key in self.transitions:
                    old = self.state
                    self.state = self.transitions[key]
                    self.history.append((old, event, self.state))
                    return True
                return False

        sm = StateMachine()
        events = ["start", "pause", "stop", "resume", "stop"]
        outcomes = []

        for event in events:
            ok = sm.send(event)
            outcomes.append((event, ok, sm.state))

        final_state = sm.state
        valid_transitions = len([ok for _, ok, _ in outcomes if ok])
        history_len = len(sm.history)

        (final_state, valid_transitions, history_len, outcomes[-1])
        """)

      assert result ==
               {:tuple,
                [
                  "stopped",
                  3,
                  3,
                  {:tuple, ["stop", false, "stopped"]}
                ]}
    end

    test "pipeline builder with closures and chaining" do
      result =
        Pyex.run!("""
        def make_pipeline(*funcs):
            def run(data):
                result = data
                for f in funcs:
                    result = f(result)
                return result
            return run

        # Define transformation functions
        def double(x):
            return [item * 2 for item in x]

        def filter_big(x):
            return [item for item in x if item > 10]

        def sort_desc(x):
            return sorted(x, reverse=True)

        def take_three(x):
            return x[:3]

        pipeline = make_pipeline(double, filter_big, sort_desc, take_three)
        data = [1, 8, 3, 12, 5, 9, 7, 15, 2]
        pipeline(data)
        """)

      # double: [2, 16, 6, 24, 10, 18, 14, 30, 4]
      # filter_big: [16, 24, 18, 14, 30]
      # sort_desc: [30, 24, 18, 16, 14]
      # take_three: [30, 24, 18]
      assert result == [30, 24, 18]
    end
  end

  # -------------------------------------------------------------------
  # 8. JSON + data structures: json module + nested dicts + list ops
  # -------------------------------------------------------------------
  describe "JSON data processing" do
    test "parse JSON, transform, and serialize" do
      result =
        Pyex.run!("""
        import json

        raw = '{"users": [{"name": "Alice", "age": 30, "active": true}, {"name": "Bob", "age": 25, "active": false}, {"name": "Carol", "age": 35, "active": true}]}'

        data = json.loads(raw)

        # Filter active users and transform
        active = [
            {"name": u["name"].upper(), "age": u["age"]}
            for u in data["users"]
            if u["active"]
        ]

        # Add computed field
        avg_age = sum(u["age"] for u in active) / len(active)

        output = {
            "active_users": active,
            "count": len(active),
            "average_age": avg_age,
        }

        result_json = json.dumps(output)
        parsed_back = json.loads(result_json)

        (parsed_back["count"],
         parsed_back["average_age"],
         parsed_back["active_users"][0]["name"])
        """)

      assert result == {:tuple, [2, 32.5, "ALICE"]}
    end
  end

  # -------------------------------------------------------------------
  # 9. Math + itertools: combinations, permutations, functional patterns
  # -------------------------------------------------------------------
  describe "math and combinatorics" do
    test "itertools combinations with filtering and aggregation" do
      result =
        Pyex.run!("""
        from itertools import combinations, permutations

        # Find all pairs from a list that sum to a target
        numbers = [1, 3, 5, 7, 9, 11]
        target = 12

        pairs = [(a, b) for a, b in combinations(numbers, 2) if a + b == target]

        # Count permutations of length 2 from first 4 numbers
        perm_count = len(list(permutations(numbers[:4], 2)))

        (sorted(pairs), perm_count)
        """)

      # pairs summing to 12: (1,11), (3,9), (5,7)
      assert result ==
               {:tuple,
                [
                  [{:tuple, [1, 11]}, {:tuple, [3, 9]}, {:tuple, [5, 7]}],
                  12
                ]}
    end

    test "mathematical computations with math module" do
      result =
        Pyex.run!("""
        import math

        # Compute stats manually
        data = [2.5, 3.7, 1.2, 4.8, 3.3]

        mean = sum(data) / len(data)

        # Variance
        variance = sum((x - mean) ** 2 for x in data) / len(data)
        stddev = math.sqrt(variance)

        # Geometric mean via logs
        log_sum = sum(math.log(x) for x in data)
        geo_mean = math.exp(log_sum / len(data))

        # Round results
        (round(mean, 2), round(stddev, 2), round(geo_mean, 2))
        """)

      # Banker's rounding: stddev ~1.1489 rounds to 1.15 or 1.2 depending on rounding mode
      assert {:tuple, [mean, stddev, geo_mean]} = result
      assert mean == 3.1
      assert stddev >= 1.14 and stddev <= 1.2
      assert geo_mean == 2.81
    end
  end

  # -------------------------------------------------------------------
  # 10. Complex string + dict + set operations
  # -------------------------------------------------------------------
  describe "complex data operations" do
    test "set operations for data analysis" do
      result =
        Pyex.run!("""
        enrolled_math = {"Alice", "Bob", "Carol", "Dave", "Eve"}
        enrolled_science = {"Bob", "Carol", "Frank", "Grace"}
        enrolled_english = {"Alice", "Carol", "Dave", "Grace", "Heidi"}

        # Students in all three classes
        all_three = enrolled_math & enrolled_science & enrolled_english

        # Students in math OR science but NOT english
        math_or_sci_not_eng = (enrolled_math | enrolled_science) - enrolled_english

        # Students in exactly one class
        only_math = enrolled_math - enrolled_science - enrolled_english
        only_science = enrolled_science - enrolled_math - enrolled_english
        only_english = enrolled_english - enrolled_math - enrolled_science

        exactly_one = only_math | only_science | only_english

        (sorted(list(all_three)),
         sorted(list(math_or_sci_not_eng)),
         sorted(list(exactly_one)))
        """)

      assert result ==
               {:tuple,
                [
                  ["Carol"],
                  ["Bob", "Eve", "Frank"],
                  ["Eve", "Frank", "Heidi"]
                ]}
    end

    test "nested dict comprehension with complex transformation" do
      result =
        Pyex.run!("""
        raw_scores = {
            "team_a": [85, 90, 78, 92],
            "team_b": [70, 88, 95, 80],
            "team_c": [92, 88, 84, 96],
        }

        # Build summary dict with comprehension
        summary = {
            team: {
                "min": min(scores),
                "max": max(scores),
                "avg": sum(scores) / len(scores),
                "range": max(scores) - min(scores),
            }
            for team, scores in raw_scores.items()
        }

        # Find team with highest average
        best_team = max(summary.keys(), key=lambda t: summary[t]["avg"])

        # Get all teams with range < 15
        consistent = sorted([t for t in summary if summary[t]["range"] < 15])

        (best_team, summary[best_team]["avg"], consistent)
        """)

      assert result == {:tuple, ["team_c", 90.0, ["team_a", "team_c"]]}
    end
  end

  # -------------------------------------------------------------------
  # 11. Context managers + file I/O + with statement
  # -------------------------------------------------------------------
  describe "context managers" do
    test "with statement for file read and processing" do
      fs =
        Pyex.Filesystem.Memory.new(%{
          "data.txt" => "hello world\nfoo bar\nbaz qux\n"
        })

      result =
        Pyex.run!(
          """
          with open("data.txt", "r") as f:
              content = f.read()

          # Process outside the with block
          lines = content.strip().split("\\n")
          words = []
          for line in lines:
              words.extend(line.split())

          upper_words = [w.upper() for w in words if len(w) > 2]
          sorted(upper_words)
          """,
          filesystem: fs
        )

      assert result == ["BAR", "BAZ", "FOO", "HELLO", "QUX", "WORLD"]
    end

    test "write file in context manager and read it back" do
      fs = Pyex.Filesystem.Memory.new()

      result =
        Pyex.run!(
          """
          # Write data
          with open("output.txt", "w") as f:
              for i in range(5):
                  f.write(f"Line {i + 1}: value={i * 10}\\n")

          # Read it back
          with open("output.txt", "r") as f:
              content = f.read()

          lines = content.strip().split("\\n")
          (len(lines), lines[0], lines[-1])
          """,
          filesystem: fs
        )

      assert result == {:tuple, [5, "Line 1: value=0", "Line 5: value=40"]}
    end
  end

  # -------------------------------------------------------------------
  # 12. Hash + encoding: hashlib + base64 combined
  # -------------------------------------------------------------------
  describe "encoding and hashing" do
    test "hash computation and base64 encoding" do
      result =
        Pyex.run!("""
        import hashlib
        import base64

        message = "Hello, World!"

        # SHA-256 hash
        sha_hash = hashlib.sha256(message).hexdigest()

        # Base64 encode/decode roundtrip
        encoded = base64.b64encode(message)
        decoded = base64.b64decode(encoded)

        # MD5 for comparison
        md5_hash = hashlib.md5(message).hexdigest()

        (len(sha_hash) == 64,
         decoded == message,
         len(md5_hash) == 32,
         sha_hash[:8])
        """)

      assert result == {:tuple, [true, true, true, "dffd6021"]}
    end
  end

  # -------------------------------------------------------------------
  # 13. Walrus operator + complex conditionals
  # -------------------------------------------------------------------
  describe "walrus operator in complex contexts" do
    test "walrus in while loop for input processing simulation" do
      result =
        Pyex.run!("""
        data = [5, 12, 3, 18, 7, 25, 1, 9]
        idx = 0
        big_values = []

        while idx < len(data):
            if (val := data[idx]) > 10:
                big_values.append(val)
            idx += 1

        # Also use walrus in list comprehension filter
        doubled_big = [y for x in data if (y := x * 2) > 20]

        (big_values, doubled_big)
        """)

      assert result == {:tuple, [[12, 18, 25], [24, 36, 50]]}
    end
  end

  # -------------------------------------------------------------------
  # 14. Match/case with complex patterns
  # -------------------------------------------------------------------
  describe "match/case patterns" do
    test "match with literal, list, and wildcard patterns" do
      result =
        Pyex.run!("""
        def classify(value):
            match value:
                case 0:
                    return "zero"
                case 1:
                    return "one"
                case -1:
                    return "neg one"
                case "hello":
                    return "greeting"
                case "":
                    return "empty string"
                case [x]:
                    return f"single: {x}"
                case [x, y]:
                    return f"pair: {x}, {y}"
                case [x, y, z]:
                    return f"triple: {x}, {y}, {z}"
                case None:
                    return "none"
                case True:
                    return "true"
                case _:
                    return "other"

        results = [
            classify(0),
            classify(1),
            classify(-1),
            classify("hello"),
            classify(""),
            classify([99]),
            classify([1, 2]),
            classify([1, 2, 3]),
            classify(None),
            classify(42),
        ]
        results
        """)

      assert result == [
               "zero",
               "one",
               "neg one",
               "greeting",
               "empty string",
               "single: 99",
               "pair: 1, 2",
               "triple: 1, 2, 3",
               "none",
               "other"
             ]
    end
  end

  # -------------------------------------------------------------------
  # 15. Datetime + string formatting end-to-end
  # -------------------------------------------------------------------
  describe "datetime processing" do
    test "date parsing and arithmetic" do
      result =
        Pyex.run!("""
        from datetime import datetime, timedelta

        # Parse dates
        start = datetime.fromisoformat("2024-01-15")
        end = datetime.fromisoformat("2024-03-01")

        # Compute difference
        diff = end - start
        days = diff.days

        # Generate weekly checkpoints
        checkpoints = []
        current = start
        week = timedelta(days=7)
        while current < end:
            checkpoints.append(str(current)[:10])
            current = current + week

        (days, len(checkpoints), checkpoints[0], checkpoints[-1])
        """)

      assert {:tuple, [days, count, first, _last]} = result
      assert days == 46
      assert count > 0
      assert first == "2024-01-15"
    end
  end

  # -------------------------------------------------------------------
  # 16. Defaultdict + Decimal combined (single-level nesting)
  # -------------------------------------------------------------------
  describe "defaultdict with Decimal combined" do
    test "expense tracker with categories and precise totals" do
      result =
        Pyex.run!("""
        from decimal import Decimal
        from collections import defaultdict

        expenses = [
            ("2024-01", "rent", "1500.00"),
            ("2024-01", "food", "423.50"),
            ("2024-01", "food", "89.99"),
            ("2024-02", "rent", "1500.00"),
            ("2024-02", "food", "387.25"),
            ("2024-02", "transport", "150.00"),
            ("2024-01", "transport", "125.75"),
        ]

        # Track by category using compound keys "month:category"
        totals = defaultdict(lambda: Decimal("0"))

        for month, category, amount in expenses:
            key = month + ":" + category
            totals[key] += Decimal(amount)

        # Compute monthly totals
        jan_total = Decimal("0")
        feb_total = Decimal("0")
        for key in totals:
            month = key.split(":")[0]
            if month == "2024-01":
                jan_total += totals[key]
            elif month == "2024-02":
                feb_total += totals[key]

        jan_food = totals["2024-01:food"]

        (str(jan_total), str(feb_total), str(jan_food),
         str(jan_food == Decimal("513.49")))
        """)

      assert result ==
               {:tuple,
                [
                  "2139.24",
                  "2037.25",
                  "513.49",
                  "True"
                ]}
    end
  end
end
