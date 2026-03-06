defmodule Pyex.LlmConformanceTest do
  @moduledoc """
  Conformance tests using realistic LLM-generated Python programs.

  Each test runs the same code through CPython and Pyex, comparing
  `print(repr(...))` output. These programs simulate what LLMs actually
  produce: data processing, string manipulation, statistics, classes,
  error handling, regex, datetime, and common algorithmic patterns.

  Requires `python3` on PATH.
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
      {:ok, _, ctx} -> ctx |> Pyex.output() |> IO.iodata_to_binary() |> String.trim()
      {:error, err} -> "PYEX_ERROR: #{err.message}"
    end
  end

  defp indent(code) do
    code |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))
  end

  # ── Data processing ───────────────────────────────────────────

  describe "data processing" do
    test "group by and aggregate" do
      assert_conforms("""
      records = [
          {"name": "Alice", "dept": "eng", "salary": 100},
          {"name": "Bob", "dept": "sales", "salary": 80},
          {"name": "Carol", "dept": "eng", "salary": 120},
          {"name": "Dave", "dept": "sales", "salary": 90},
          {"name": "Eve", "dept": "eng", "salary": 110},
      ]

      dept_totals = {}
      dept_counts = {}
      for r in records:
          d = r["dept"]
          dept_totals[d] = dept_totals.get(d, 0) + r["salary"]
          dept_counts[d] = dept_counts.get(d, 0) + 1

      dept_avg = {d: dept_totals[d] / dept_counts[d] for d in dept_totals}
      print(repr(sorted(dept_avg.items())))
      """)
    end

    test "flatten nested structure" do
      assert_conforms("""
      def flatten(lst):
          result = []
          for item in lst:
              if isinstance(item, list):
                  result.extend(flatten(item))
              else:
                  result.append(item)
          return result

      print(repr(flatten([1, [2, [3, 4], 5], [6, 7]])))
      """)
    end

    test "deduplicate preserving order" do
      assert_conforms("""
      def dedupe(lst):
          seen = set()
          result = []
          for item in lst:
              if item not in seen:
                  seen.add(item)
                  result.append(item)
          return result

      print(repr(dedupe([3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5])))
      """)
    end

    test "csv-style parsing" do
      assert_conforms(~S"""
      lines = [
          "name,age,city",
          "Alice,30,NYC",
          "Bob,25,LA",
          "Carol,35,Chicago"
      ]
      headers = lines[0].split(",")
      rows = []
      for line in lines[1:]:
          values = line.split(",")
          row = {}
          for i in range(len(headers)):
              row[headers[i]] = values[i]
          rows.append(row)

      names = [r["name"] for r in rows]
      print(repr(names))
      """)
    end

    test "running total" do
      assert_conforms("""
      def running_total(nums):
          result = []
          total = 0
          for n in nums:
              total += n
              result.append(total)
          return result

      print(repr(running_total([1, 2, 3, 4, 5])))
      """)
    end

    test "top N items" do
      assert_conforms("""
      scores = {"Alice": 95, "Bob": 72, "Carol": 88, "Dave": 91, "Eve": 67}
      top3 = sorted(scores.items(), key=lambda x: x[1], reverse=True)[:3]
      print(repr([(name, score) for name, score in top3]))
      """)
    end
  end

  # ── Statistics / math ───────────────────────────────────────

  describe "statistics and math" do
    test "mean median mode" do
      assert_conforms("""
      def mean(nums):
          return sum(nums) / len(nums)

      def median(nums):
          s = sorted(nums)
          n = len(s)
          if n % 2 == 1:
              return s[n // 2]
          return (s[n // 2 - 1] + s[n // 2]) / 2

      def mode(nums):
          counts = {}
          for n in nums:
              counts[n] = counts.get(n, 0) + 1
          max_count = max(counts.values())
          return [k for k, v in sorted(counts.items()) if v == max_count][0]

      data = [4, 1, 2, 2, 3, 4, 4, 5]
      print(repr((mean(data), median(data), mode(data))))
      """)
    end

    test "standard deviation" do
      assert_conforms("""
      import math

      def stdev(nums):
          avg = sum(nums) / len(nums)
          variance = sum((x - avg) ** 2 for x in nums) / len(nums)
          return math.sqrt(variance)

      print(repr(round(stdev([2, 4, 4, 4, 5, 5, 7, 9]), 4)))
      """)
    end

    test "prime sieve" do
      assert_conforms("""
      def sieve(n):
          is_prime = [True] * (n + 1)
          is_prime[0] = is_prime[1] = False
          for i in range(2, int(n**0.5) + 1):
              if is_prime[i]:
                  for j in range(i*i, n + 1, i):
                      is_prime[j] = False
          return [i for i in range(n + 1) if is_prime[i]]

      print(repr(sieve(50)))
      """)
    end

    test "gcd and lcm" do
      assert_conforms("""
      def gcd(a, b):
          while b:
              a, b = b, a % b
          return a

      def lcm(a, b):
          return a * b // gcd(a, b)

      print(repr((gcd(48, 18), lcm(12, 15))))
      """)
    end

    test "binary search" do
      assert_conforms("""
      def bisect(arr, target):
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

      arr = [2, 5, 8, 12, 16, 23, 38, 56, 72, 91]
      print(repr((bisect(arr, 23), bisect(arr, 50))))
      """)
    end
  end

  # ── String manipulation ───────────────────────────────────────

  describe "string manipulation" do
    test "palindrome check" do
      assert_conforms("""
      def is_palindrome(s):
          s = s.lower().replace(" ", "")
          return s == s[::-1]

      tests = ["racecar", "hello", "A man a plan a canal Panama".replace(" ", "").lower()]
      print(repr([is_palindrome(t) for t in tests]))
      """)
    end

    test "caesar cipher" do
      assert_conforms(~S"""
      def caesar(text, shift):
          result = []
          for c in text:
              if c.isalpha():
                  base = ord('a') if c.islower() else ord('A')
                  result.append(chr((ord(c) - base + shift) % 26 + base))
              else:
                  result.append(c)
          return "".join(result)

      encrypted = caesar("Hello, World!", 13)
      decrypted = caesar(encrypted, 13)
      print(repr((encrypted, decrypted)))
      """)
    end

    test "word wrap" do
      assert_conforms(~S"""
      def wrap(text, width):
          words = text.split()
          lines = []
          current = []
          current_len = 0
          for word in words:
              if current_len + len(word) + len(current) > width:
                  lines.append(" ".join(current))
                  current = [word]
                  current_len = len(word)
              else:
                  current.append(word)
                  current_len += len(word)
          if current:
              lines.append(" ".join(current))
          return lines

      print(repr(wrap("the quick brown fox jumps over the lazy dog", 15)))
      """)
    end

    test "count vowels and consonants" do
      assert_conforms(~S"""
      def analyze(text):
          text = text.lower()
          vowels = sum(1 for c in text if c in "aeiou")
          consonants = sum(1 for c in text if c.isalpha() and c not in "aeiou")
          return {"vowels": vowels, "consonants": consonants}

      r = analyze("Hello World")
      print(repr(sorted(r.items())))
      """)
    end

    test "title case with exceptions" do
      assert_conforms("""
      def title_case(text, exceptions=None):
          if exceptions is None:
              exceptions = {"a", "an", "the", "in", "on", "at", "to", "for", "of"}
          words = text.lower().split()
          result = []
          for i, word in enumerate(words):
              if i == 0 or word not in exceptions:
                  result.append(word.capitalize())
              else:
                  result.append(word)
          return " ".join(result)

      print(repr(title_case("the lord of the rings")))
      """)
    end

    test "string template interpolation" do
      assert_conforms(~S"""
      def render(template, context):
          result = template
          for key, val in context.items():
              result = result.replace("{{" + key + "}}", str(val))
          return result

      t = "Hello, {{name}}! You have {{count}} messages."
      print(repr(render(t, {"name": "Alice", "count": 5})))
      """)
    end
  end

  # ── Regex ───────────────────────────────────────────────────

  describe "regex patterns" do
    test "extract emails" do
      assert_conforms(~S"""
      import re
      text = "Contact alice@example.com or bob@test.org for info"
      emails = re.findall(r'[\w.]+@[\w.]+\.\w+', text)
      print(repr(sorted(emails)))
      """)
    end

    test "parse key-value pairs" do
      assert_conforms(~S"""
      import re
      config = "host=localhost port=8080 debug=true"
      pairs = re.findall(r'(\w+)=(\w+)', config)
      d = {k: v for k, v in pairs}
      print(repr(sorted(d.items())))
      """)
    end

    test "validate and extract" do
      assert_conforms(~S"""
      import re

      def parse_date(s):
          m = re.match(r'^(\d{4})-(\d{2})-(\d{2})$', s)
          if m:
              return (int(m.group(1)), int(m.group(2)), int(m.group(3)))
          return None

      print(repr(parse_date("2024-01-15")))
      print(repr(parse_date("not-a-date")))
      """)
    end

    test "replace with pattern" do
      assert_conforms(~S"""
      import re
      text = "Hello   World   Foo   Bar"
      print(repr(re.sub(r'\s+', ' ', text)))
      """)
    end
  end

  # ── Datetime ───────────────────────────────────────────────

  describe "datetime processing" do
    test "days between dates" do
      assert_conforms("""
      from datetime import date
      d1 = date(2024, 1, 1)
      d2 = date(2024, 3, 1)
      delta = d2 - d1
      print(repr(delta.days))
      """)
    end

    test "add days to date" do
      assert_conforms("""
      from datetime import date, timedelta
      start = date(2024, 1, 15)
      end = start + timedelta(days=30)
      print(repr(str(end)))
      """)
    end

    test "weekday name" do
      assert_conforms("""
      from datetime import date
      days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
      d = date(2024, 1, 1)
      print(repr(days[d.weekday()]))
      """)
    end

    test "date comparison and sorting" do
      assert_conforms("""
      from datetime import date
      dates = [date(2024, 3, 1), date(2024, 1, 15), date(2024, 2, 28)]
      sorted_dates = sorted(dates)
      print(repr([str(d) for d in sorted_dates]))
      """)
    end
  end

  # ── Error handling ────────────────────────────────────────

  describe "error handling patterns" do
    test "retry pattern" do
      assert_conforms("""
      def unreliable(attempt):
          if attempt < 3:
              raise ValueError(f"fail on attempt {attempt}")
          return "success"

      def retry(func, max_attempts=5):
          errors = []
          for i in range(max_attempts):
              try:
                  return func(i)
              except ValueError as e:
                  errors.append(str(e))
          return errors

      print(repr(retry(unreliable)))
      """)
    end

    test "multiple except clauses" do
      assert_conforms("""
      def safe_convert(val):
          try:
              return int(val)
          except ValueError:
              try:
                  return float(val)
              except ValueError:
                  return None

      results = [safe_convert("42"), safe_convert("3.14"), safe_convert("abc")]
      print(repr(results))
      """)
    end

    test "try except else finally" do
      assert_conforms("""
      results = []

      def process(x):
          try:
              val = 100 / x
          except ZeroDivisionError:
              results.append("error")
              val = 0
          else:
              results.append("ok")
          finally:
              results.append("done")
          return val

      process(5)
      process(0)
      print(repr(results))
      """)
    end

    test "exception with args" do
      assert_conforms("""
      try:
          raise ValueError("bad value", 42)
      except ValueError as e:
          print(repr(e.args))
      """)
    end
  end

  # ── Closures and higher-order functions ──────────────────

  describe "closures and higher order" do
    test "make multiplier" do
      assert_conforms("""
      def make_multiplier(n):
          def multiply(x):
              return x * n
          return multiply

      double = make_multiplier(2)
      triple = make_multiplier(3)
      print(repr([double(5), triple(5), double(triple(4))])  )
      """)
    end

    test "compose functions" do
      assert_conforms("""
      def compose(f, g):
          def composed(x):
              return f(g(x))
          return composed

      add1 = lambda x: x + 1
      double = lambda x: x * 2

      add1_then_double = compose(double, add1)
      double_then_add1 = compose(add1, double)
      print(repr((add1_then_double(3), double_then_add1(3))))
      """)
    end

    test "accumulator closure" do
      assert_conforms("""
      def make_counter(start=0):
          count = [start]
          def increment(n=1):
              count[0] += n
              return count[0]
          return increment

      c = make_counter()
      results = [c(), c(), c(5), c()]
      print(repr(results))
      """)
    end

    test "filter map reduce pipeline" do
      assert_conforms("""
      nums = list(range(1, 11))
      evens = list(filter(lambda x: x % 2 == 0, nums))
      squared = list(map(lambda x: x ** 2, evens))
      total = sum(squared)
      print(repr((evens, squared, total)))
      """)
    end
  end

  # ── Dict patterns ──────────────────────────────────────────

  describe "dict patterns" do
    test "invert dict" do
      assert_conforms("""
      d = {"a": 1, "b": 2, "c": 3}
      inverted = {v: k for k, v in d.items()}
      print(repr(sorted(inverted.items())))
      """)
    end

    test "merge dicts" do
      assert_conforms("""
      defaults = {"color": "blue", "size": 10, "visible": True}
      overrides = {"color": "red", "size": 20}
      merged = dict(defaults)
      merged.update(overrides)
      print(repr(sorted(merged.items())))
      """)
    end

    test "nested dict access" do
      assert_conforms("""
      config = {
          "database": {
              "host": "localhost",
              "port": 5432,
              "credentials": {"user": "admin", "password": "secret"}
          },
          "cache": {"ttl": 300}
      }

      def get_nested(d, *keys):
          for key in keys:
              d = d[key]
          return d

      print(repr(get_nested(config, "database", "credentials", "user")))
      print(repr(get_nested(config, "cache", "ttl")))
      """)
    end

    test "counter from scratch" do
      assert_conforms("""
      def count_chars(s):
          counts = {}
          for c in s:
              counts[c] = counts.get(c, 0) + 1
          return counts

      c = count_chars("abracadabra")
      print(repr(sorted(c.items())))
      """)
    end

    test "dict comprehension with condition" do
      assert_conforms("""
      scores = {"Alice": 85, "Bob": 62, "Carol": 91, "Dave": 45, "Eve": 78}
      passing = {k: v for k, v in scores.items() if v >= 70}
      print(repr(sorted(passing.items())))
      """)
    end
  end

  # ── Classes and OOP ───────────────────────────────────────

  describe "class patterns" do
    test "stack implementation" do
      assert_conforms("""
      class Stack:
          def __init__(self):
              self.items = []

          def push(self, item):
              self.items.append(item)

          def pop(self):
              if not self.items:
                  raise IndexError("pop from empty stack")
              return self.items.pop()

          def peek(self):
              return self.items[-1] if self.items else None

          def __len__(self):
              return len(self.items)

          def __bool__(self):
              return len(self.items) > 0

      s = Stack()
      s.push(1)
      s.push(2)
      s.push(3)
      print(repr((s.pop(), s.peek(), len(s), bool(s))))
      s.pop()
      s.pop()
      print(repr((len(s), bool(s))))
      """)
    end

    test "linked list with iteration" do
      assert_conforms("""
      class Node:
          def __init__(self, val, next=None):
              self.val = val
              self.next = next

      def make_list(items):
          head = None
          for item in reversed(items):
              head = Node(item, head)
          return head

      def to_list(node):
          result = []
          while node is not None:
              result.append(node.val)
              node = node.next
          return result

      head = make_list([1, 2, 3, 4, 5])
      print(repr(to_list(head)))
      """)
    end

    test "binary tree" do
      assert_conforms("""
      class TreeNode:
          def __init__(self, val, left=None, right=None):
              self.val = val
              self.left = left
              self.right = right

      def insert(root, val):
          if root is None:
              return TreeNode(val)
          if val < root.val:
              root.left = insert(root.left, val)
          else:
              root.right = insert(root.right, val)
          return root

      def inorder(root):
          if root is None:
              return []
          return inorder(root.left) + [root.val] + inorder(root.right)

      root = None
      for v in [5, 3, 7, 1, 4, 6, 8]:
          root = insert(root, v)

      print(repr(inorder(root)))
      """)
    end

    test "class with __str__ and __repr__" do
      assert_conforms(~S"""
      class Point:
          def __init__(self, x, y):
              self.x = x
              self.y = y

          def __repr__(self):
              return f"Point({self.x}, {self.y})"

          def distance_to(self, other):
              return ((self.x - other.x) ** 2 + (self.y - other.y) ** 2) ** 0.5

      p1 = Point(0, 0)
      p2 = Point(3, 4)
      print(repr(p1))
      print(repr(round(p1.distance_to(p2), 1)))
      """)
    end
  end

  # ── Generator patterns ─────────────────────────────────────

  describe "generator patterns" do
    test "chunked iteration" do
      assert_conforms("""
      def chunks(lst, n):
          for i in range(0, len(lst), n):
              yield lst[i:i+n]

      print(repr(list(chunks([1,2,3,4,5,6,7,8,9], 3))))
      """)
    end

    test "sliding window" do
      assert_conforms("""
      def sliding_window(lst, size):
          for i in range(len(lst) - size + 1):
              yield lst[i:i+size]

      print(repr(list(sliding_window([1,2,3,4,5], 3))))
      """)
    end

    test "chained generators" do
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

    test "enumerate simulation" do
      assert_conforms("""
      def my_enumerate(iterable, start=0):
          i = start
          for item in iterable:
              yield (i, item)
              i += 1

      print(repr(list(my_enumerate(["a", "b", "c"], start=1))))
      """)
    end
  end

  # ── Decorator patterns ────────────────────────────────────

  describe "decorator patterns" do
    test "memoize decorator" do
      assert_conforms("""
      def memoize(func):
          cache = {}
          def wrapper(*args):
              if args not in cache:
                  cache[args] = func(*args)
              return cache[args]
          return wrapper

      @memoize
      def fib(n):
          if n <= 1:
              return n
          return fib(n - 1) + fib(n - 2)

      print(repr([fib(i) for i in range(10)]))
      """)
    end

    # Skip: wrapper.call_count = calls sets attr on function — requires reference semantics
    @tag :skip
    test "call counter decorator" do
      assert_conforms("""
      def count_calls(func):
          calls = [0]
          def wrapper(*args):
              calls[0] += 1
              return func(*args)
          wrapper.call_count = calls
          return wrapper

      @count_calls
      def add(a, b):
          return a + b

      results = [add(1, 2), add(3, 4), add(5, 6)]
      print(repr(results))
      """)
    end
  end

  # ── Algorithms ────────────────────────────────────────────

  describe "algorithms" do
    test "BFS shortest path" do
      assert_conforms("""
      def bfs(graph, start, end):
          queue = [(start, [start])]
          visited = set()
          while queue:
              node, path = queue.pop(0)
              if node == end:
                  return path
              if node in visited:
                  continue
              visited.add(node)
              for neighbor in graph.get(node, []):
                  if neighbor not in visited:
                      queue.append((neighbor, path + [neighbor]))
          return None

      graph = {
          "A": ["B", "C"],
          "B": ["A", "D", "E"],
          "C": ["A", "F"],
          "D": ["B"],
          "E": ["B", "F"],
          "F": ["C", "E"]
      }

      print(repr(bfs(graph, "A", "F")))
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
          return merge(left, right)

      def merge(left, right):
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

    test "topological sort" do
      assert_conforms("""
      def topo_sort(graph):
          in_degree = {n: 0 for n in graph}
          for node in graph:
              for neighbor in graph[node]:
                  in_degree[neighbor] = in_degree.get(neighbor, 0) + 1

          queue = sorted([n for n in in_degree if in_degree[n] == 0])
          result = []
          while queue:
              node = queue.pop(0)
              result.append(node)
              for neighbor in sorted(graph.get(node, [])):
                  in_degree[neighbor] -= 1
                  if in_degree[neighbor] == 0:
                      queue.append(neighbor)
              queue.sort()

          return result

      deps = {
          "A": ["C"],
          "B": ["C", "D"],
          "C": ["E"],
          "D": ["E"],
          "E": []
      }
      print(repr(topo_sort(deps)))
      """)
    end

    test "knapsack 0/1" do
      assert_conforms("""
      def knapsack(weights, values, capacity):
          n = len(weights)
          dp = [[0] * (capacity + 1) for _ in range(n + 1)]
          for i in range(1, n + 1):
              for w in range(capacity + 1):
                  dp[i][w] = dp[i-1][w]
                  if weights[i-1] <= w:
                      val = dp[i-1][w - weights[i-1]] + values[i-1]
                      if val > dp[i][w]:
                          dp[i][w] = val
          return dp[n][capacity]

      print(repr(knapsack([2, 3, 4, 5], [3, 4, 5, 6], 8)))
      """)
    end
  end

  # ── Mixed realistic programs ──────────────────────────────

  describe "realistic programs" do
    test "student gradebook" do
      assert_conforms("""
      students = {
          "Alice": [90, 85, 92, 88],
          "Bob": [78, 82, 75, 80],
          "Carol": [95, 98, 92, 96],
          "Dave": [60, 65, 70, 55],
      }

      def letter_grade(avg):
          if avg >= 90: return "A"
          if avg >= 80: return "B"
          if avg >= 70: return "C"
          if avg >= 60: return "D"
          return "F"

      report = []
      for name in sorted(students.keys()):
          scores = students[name]
          avg = sum(scores) / len(scores)
          grade = letter_grade(avg)
          report.append((name, round(avg, 1), grade))

      print(repr(report))
      """)
    end

    test "roman numeral converter" do
      assert_conforms("""
      def to_roman(num):
          vals = [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),
                  (100,"C"),(90,"XC"),(50,"L"),(40,"XL"),
                  (10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")]
          result = ""
          for val, sym in vals:
              while num >= val:
                  result += sym
                  num -= val
          return result

      tests = [1, 4, 9, 14, 42, 99, 399, 1994, 3999]
      print(repr([to_roman(n) for n in tests]))
      """)
    end

    test "json processing pipeline" do
      assert_conforms("""
      import json

      data = json.loads('[{"id": 1, "name": "Alice", "active": true}, '
                        '{"id": 2, "name": "Bob", "active": false}, '
                        '{"id": 3, "name": "Carol", "active": true}]')

      active = [d["name"] for d in data if d["active"]]
      ids = {d["name"]: d["id"] for d in data}
      print(repr(active))
      print(repr(sorted(ids.items())))
      """)
    end

    # Skip: self.listeners[event].append(callback) requires reference semantics
    @tag :skip
    test "event system" do
      assert_conforms("""
      class EventEmitter:
          def __init__(self):
              self.listeners = {}

          def on(self, event, callback):
              if event not in self.listeners:
                  self.listeners[event] = []
              self.listeners[event].append(callback)

          def emit(self, event, *args):
              results = []
              for cb in self.listeners.get(event, []):
                  results.append(cb(*args))
              return results

      log = []
      emitter = EventEmitter()
      emitter.on("greet", lambda name: f"Hello, {name}!")
      emitter.on("greet", lambda name: f"Hi, {name}!")
      emitter.on("add", lambda a, b: a + b)

      log.extend(emitter.emit("greet", "World"))
      log.extend(emitter.emit("add", 3, 4))
      log.extend(emitter.emit("unknown"))
      print(repr(log))
      """)
    end

    test "simple state machine" do
      assert_conforms("""
      class StateMachine:
          def __init__(self, initial):
              self.state = initial
              self.transitions = {}

          def add_transition(self, from_state, event, to_state):
              self.transitions[(from_state, event)] = to_state

          def handle(self, event):
              key = (self.state, event)
              if key in self.transitions:
                  self.state = self.transitions[key]
                  return True
              return False

      sm = StateMachine("idle")
      sm.add_transition("idle", "start", "running")
      sm.add_transition("running", "pause", "paused")
      sm.add_transition("paused", "resume", "running")
      sm.add_transition("running", "stop", "idle")

      events = ["start", "pause", "resume", "stop", "invalid"]
      results = []
      for e in events:
          ok = sm.handle(e)
          results.append((e, sm.state, ok))
      print(repr(results))
      """)
    end

    test "RLE encoding and decoding" do
      assert_conforms(~S"""
      def rle_encode(s):
          if not s:
              return []
          result = []
          count = 1
          for i in range(1, len(s)):
              if s[i] == s[i-1]:
                  count += 1
              else:
                  result.append((s[i-1], count))
                  count = 1
          result.append((s[-1], count))
          return result

      def rle_decode(encoded):
          return "".join(c * n for c, n in encoded)

      original = "aaabbbccddddee"
      encoded = rle_encode(original)
      decoded = rle_decode(encoded)
      print(repr(encoded))
      print(repr(decoded == original))
      """)
    end
  end

  # ── Edge cases that catch silent divergences ────────────

  describe "edge cases" do
    test "negative indexing" do
      assert_conforms("""
      lst = [1, 2, 3, 4, 5]
      print(repr((lst[-1], lst[-2], lst[-3])))
      """)
    end

    test "chained comparisons" do
      assert_conforms("""
      x = 5
      print(repr((1 < x < 10, 1 < x > 10, 0 < x == 5 < 10)))
      """)
    end

    test "truthy and falsy" do
      assert_conforms("""
      vals = [0, 1, -1, 0.0, 0.1, "", "x", [], [0], {}, {"a": 1}, None, True, False]
      print(repr([bool(v) for v in vals]))
      """)
    end

    test "unpacking variations" do
      assert_conforms("""
      a, b, c = [1, 2, 3]
      x, *rest = [10, 20, 30, 40]
      *init, last = [10, 20, 30, 40]
      print(repr((a, b, c, x, rest, init, last)))
      """)
    end

    test "nested comprehension scoping" do
      assert_conforms("""
      matrix = [[1, 2], [3, 4], [5, 6]]
      flat = [x for row in matrix for x in row]
      print(repr(flat))
      """)
    end

    test "string methods chain" do
      assert_conforms("""
      s = "  Hello, World!  "
      print(repr(s.strip().lower().replace(",", "").split()))
      """)
    end

    test "dict update and pop" do
      assert_conforms("""
      d = {"a": 1, "b": 2, "c": 3}
      d.update({"b": 20, "d": 4})
      removed = d.pop("a")
      print(repr((sorted(d.items()), removed)))
      """)
    end

    test "enumerate with start" do
      assert_conforms("""
      items = ["a", "b", "c"]
      print(repr(list(enumerate(items, start=1))))
      """)
    end

    test "all and any with generators" do
      assert_conforms("""
      nums = [2, 4, 6, 8]
      print(repr((all(x % 2 == 0 for x in nums), any(x > 7 for x in nums))))
      """)
    end

    test "multiple return values" do
      assert_conforms("""
      def divmod_custom(a, b):
          return a // b, a % b

      q, r = divmod_custom(17, 5)
      print(repr((q, r)))
      """)
    end

    test "walrus operator" do
      assert_conforms("""
      data = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      filtered = [y for x in data if (y := x * 2) > 10]
      print(repr(filtered))
      """)
    end

    test "ternary in various positions" do
      assert_conforms("""
      x = 5
      a = "yes" if x > 3 else "no"
      b = [("even" if i % 2 == 0 else "odd") for i in range(5)]
      print(repr((a, b)))
      """)
    end

    test "set operations" do
      assert_conforms("""
      a = {1, 2, 3, 4}
      b = {3, 4, 5, 6}
      print(repr(sorted(a & b)))
      print(repr(sorted(a | b)))
      print(repr(sorted(a - b)))
      print(repr(sorted(a ^ b)))
      """)
    end

    test "tuple as dict key" do
      assert_conforms("""
      grid = {}
      for i in range(3):
          for j in range(3):
              grid[(i, j)] = i * 3 + j
      print(repr(grid[(1, 2)]))
      print(repr(sorted(grid.keys())))
      """)
    end
  end
end
