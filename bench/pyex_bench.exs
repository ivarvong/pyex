alias Pyex.{Lexer, Parser, Interpreter}

programs = %{
  "arithmetic" => "2 + 3 * 4 - 1",
  "string_ops" => ~s|"hello world".upper().split()|,
  "assignment" => """
  x = 1
  y = 2
  z = x + y
  z
  """,
  "function_call" => """
  def add(a, b):
      return a + b
  add(10, 20)
  """,
  "while_loop_100" => """
  i = 0
  total = 0
  while i < 100:
      total = total + i
      i = i + 1
  total
  """,
  "for_range_100" => """
  total = 0
  for i in range(100):
      total = total + i
  total
  """,
  "fibonacci_20" => """
  def fib(n):
      if n <= 1:
          return n
      a = 0
      b = 1
      i = 2
      while i <= n:
          temp = a + b
          a = b
          b = temp
          i = i + 1
      return b
  fib(20)
  """,
  "list_append_50" => """
  result = []
  for i in range(50):
      result.append(i)
  len(result)
  """,
  "nested_loops_10x10" => """
  total = 0
  for i in range(10):
      for j in range(10):
          total = total + i * j
  total
  """,
  "string_iteration" => """
  count = 0
  for ch in "the quick brown fox jumps over the lazy dog":
      if ch == "o":
          count = count + 1
  count
  """,
  "dict_build_and_read" => """
  d = {}
  for i in range(20):
      d[str(i)] = i * i
  total = 0
  for k in d:
      total = total + d[k]
  total
  """,
  "fizzbuzz_100" => """
  result = ""
  for i in range(1, 101):
      if i % 15 == 0:
          result = result + "FizzBuzz "
      elif i % 3 == 0:
          result = result + "Fizz "
      elif i % 5 == 0:
          result = result + "Buzz "
      else:
          result = result + str(i) + " "
  len(result)
  """,
  "recursive_factorial" => """
  def factorial(n):
      if n <= 1:
          return 1
      return n * factorial(n - 1)
  factorial(12)
  """,
  "try_except_loop" => """
  total = 0
  for i in range(20):
      try:
          total = total + 100 / (i - 10)
      except:
          total = total + 0
  round(total)
  """,
  "string_methods" => """
  s = "  Hello, World!  "
  s = s.strip()
  s = s.lower()
  s = s.replace("world", "python")
  words = s.split(", ")
  ", ".join(words).upper()
  """,
  "math_heavy" => """
  import math
  total = 0.0
  for i in range(1, 51):
      total = total + math.sin(i * 0.1) * math.cos(i * 0.1)
  round(total * 1000)
  """
}

pre_lexed =
  Map.new(programs, fn {name, source} ->
    {:ok, tokens} = Lexer.tokenize(source)
    {name, tokens}
  end)

pre_parsed =
  Map.new(pre_lexed, fn {name, tokens} ->
    {:ok, ast} = Parser.parse(tokens)
    {name, ast}
  end)

IO.puts("\n")

Benchee.run(
  %{
    "lex: arithmetic" => fn -> Lexer.tokenize(programs["arithmetic"]) end,
    "lex: fibonacci_20" => fn -> Lexer.tokenize(programs["fibonacci_20"]) end,
    "lex: fizzbuzz_100" => fn -> Lexer.tokenize(programs["fizzbuzz_100"]) end,
    "parse: arithmetic" => fn -> Parser.parse(pre_lexed["arithmetic"]) end,
    "parse: fibonacci_20" => fn -> Parser.parse(pre_lexed["fibonacci_20"]) end,
    "parse: fizzbuzz_100" => fn -> Parser.parse(pre_lexed["fizzbuzz_100"]) end,
    "eval: arithmetic" => fn -> Interpreter.run(pre_parsed["arithmetic"]) end,
    "eval: fibonacci_20" => fn -> Interpreter.run(pre_parsed["fibonacci_20"]) end,
    "eval: fizzbuzz_100" => fn -> Interpreter.run(pre_parsed["fizzbuzz_100"]) end,
    "e2e: arithmetic" => fn -> Pyex.run!(programs["arithmetic"]) end,
    "e2e: assignment" => fn -> Pyex.run!(programs["assignment"]) end,
    "e2e: function_call" => fn -> Pyex.run!(programs["function_call"]) end,
    "e2e: string_ops" => fn -> Pyex.run!(programs["string_ops"]) end,
    "e2e: while_loop_100" => fn -> Pyex.run!(programs["while_loop_100"]) end,
    "e2e: for_range_100" => fn -> Pyex.run!(programs["for_range_100"]) end,
    "e2e: fibonacci_20" => fn -> Pyex.run!(programs["fibonacci_20"]) end,
    "e2e: list_append_50" => fn -> Pyex.run!(programs["list_append_50"]) end,
    "e2e: nested_loops_10x10" => fn -> Pyex.run!(programs["nested_loops_10x10"]) end,
    "e2e: string_iteration" => fn -> Pyex.run!(programs["string_iteration"]) end,
    "e2e: dict_build_and_read" => fn -> Pyex.run!(programs["dict_build_and_read"]) end,
    "e2e: fizzbuzz_100" => fn -> Pyex.run!(programs["fizzbuzz_100"]) end,
    "e2e: recursive_factorial" => fn -> Pyex.run!(programs["recursive_factorial"]) end,
    "e2e: try_except_loop" => fn -> Pyex.run!(programs["try_except_loop"]) end,
    "e2e: string_methods" => fn -> Pyex.run!(programs["string_methods"]) end,
    "e2e: math_heavy" => fn -> Pyex.run!(programs["math_heavy"]) end
  },
  warmup: 1,
  time: 3,
  memory_time: 1,
  print: [configuration: false]
)
