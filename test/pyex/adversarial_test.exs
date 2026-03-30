defmodule Pyex.AdversarialTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :adversarial

  # Shared tight limits for most tests
  @tight_limits [max_steps: 5_000, max_memory_bytes: 1_000_000, max_output_bytes: 100_000]

  # Every adversarial test must produce {:error, %Pyex.Error{}} — never
  # a raised Elixir exception, never a hang, never a crash.
  defp assert_contained(code, opts \\ []) do
    limits = Keyword.get(opts, :limits, @tight_limits)

    case Pyex.run(code, limits: limits) do
      {:ok, _val, _ctx} -> :ok
      {:error, %Pyex.Error{}} -> :ok
      other -> flunk("Expected {:ok, ...} or {:error, %Pyex.Error{}}, got: #{inspect(other)}")
    end
  end

  defp assert_stopped(code, opts \\ []) do
    limits = Keyword.get(opts, :limits, @tight_limits)

    case Pyex.run(code, limits: limits) do
      {:error, %Pyex.Error{kind: kind}} when kind in [:limit, :timeout, :python] -> :ok
      {:error, %Pyex.Error{} = err} -> flunk("Unexpected error kind: #{inspect(err)}")
      {:ok, val, _ctx} -> flunk("Expected limit error, program completed with: #{inspect(val)}")
    end
  end

  # ── Step limits ──────────────────────────────────────────────

  describe "step limits" do
    test "infinite while loop" do
      assert_stopped("while True: pass", limits: [max_steps: 1_000])
    end

    test "recursive call bomb" do
      assert_stopped("""
      def f(n): return f(n+1)
      f(0)
      """)
    end

    test "comprehension over huge range" do
      assert_stopped("[x for x in range(1000000)]")
    end

    test "nested generator chain" do
      assert_stopped("""
      def g(n):
          if n > 0: yield from g(n-1)
          yield n
      list(g(1000000))
      """)
    end

    test "for loop over huge range" do
      assert_stopped("""
      s = 0
      for i in range(1000000):
          s += i
      """)
    end

    test "nested for loops" do
      assert_stopped("""
      s = 0
      for i in range(1000):
          for j in range(1000):
              for k in range(1000):
                  s += 1
      """)
    end

    test "while True with nested function calls" do
      assert_stopped("""
      def noop(): pass
      while True:
          noop()
      """)
    end

    test "itertools.product explosion" do
      assert_stopped("""
      import itertools
      list(itertools.product(range(100), repeat=5))
      """)
    end

    test "normal program within budget" do
      assert {:ok, 45, _ctx} =
               Pyex.run(
                 "total = 0\nfor i in range(10):\n    total += i\ntotal",
                 limits: [max_steps: 1_000]
               )
    end
  end

  # ── Memory limits ────────────────────────────────────────────

  describe "memory limits" do
    test "exponential string doubling" do
      assert_stopped("""
      s = 'a'
      while True:
          s = s + s
      """)
    end

    test "list multiplication bomb" do
      assert_stopped("""
      x = [0] * 1000
      x = x * 1000
      x = x * 1000
      """)
    end

    test "dict growth bomb" do
      assert_stopped("""
      d = {}
      for i in range(100000):
          d[i] = i
      """)
    end

    test "set growth bomb" do
      assert_stopped("""
      s = set()
      for i in range(100000):
          s.add(i)
      """)
    end

    test "list append bomb" do
      assert_stopped("""
      items = []
      for i in range(100000):
          items.append(i)
      """)
    end

    test "nested list creation" do
      assert_stopped("""
      x = []
      for i in range(1000):
          x.append([0] * 1000)
      """)
    end

    test "string concatenation in loop" do
      assert_stopped("""
      s = ""
      for i in range(100000):
          s += "x" * 100
      """)
    end

    test "dict comprehension bomb" do
      assert_stopped("{i: str(i) * 100 for i in range(100000)}")
    end

    test "small program within memory budget" do
      assert {:ok, 9900, _ctx} =
               Pyex.run(
                 "data = [i * 2 for i in range(100)]\nsum(data)",
                 limits: [max_memory_bytes: 1_000_000]
               )
    end
  end

  # ── Output limits ────────────────────────────────────────────

  describe "output limits" do
    test "print flood" do
      assert_stopped(
        "while True:\n    print('x' * 10000)",
        limits: [max_output_bytes: 50_000, max_steps: 100_000]
      )
    end

    test "single massive print" do
      assert_stopped(
        "print('x' * 10000000)",
        limits: [max_output_bytes: 50_000, max_steps: 100_000]
      )
    end

    test "many small prints" do
      assert_stopped(
        "for i in range(100000):\n    print(i)",
        limits: [max_output_bytes: 10_000, max_steps: 1_000_000]
      )
    end

    test "print in recursive function" do
      assert_stopped("""
      def spam(n):
          print("spam" * 100)
          if n > 0:
              spam(n - 1)
      spam(10000)
      """)
    end

    test "normal print within budget" do
      assert {:ok, _, _ctx} =
               Pyex.run(
                 "for i in range(10):\n    print(i)",
                 limits: [max_output_bytes: 1_000]
               )
    end
  end

  # ── Format string bombs ──────────────────────────────────────

  describe "format string bombs" do
    test "percent format with huge width" do
      assert_contained("'%999999999d' % 1")
    end

    test "format method with huge width" do
      assert_contained("'{:>999999999}'.format('x')")
    end

    test "f-string with huge width" do
      assert_contained("x = 1\nf'{x:>999999999}'")
    end

    test "repeated format in loop" do
      assert_stopped("""
      s = ""
      for i in range(100000):
          s += "{:>100}".format(str(i))
      """)
    end

    test "format with huge precision" do
      assert_contained("'%.999999f' % 3.14")
    end
  end

  # ── String operation bombs ───────────────────────────────────

  describe "string operation bombs" do
    test "join with huge list" do
      assert_stopped("""
      items = [str(i) for i in range(100000)]
      result = ",".join(items)
      """)
    end

    test "replace explosion" do
      assert_stopped("""
      s = "a" * 100000
      for i in range(100):
          s = s.replace("a", "aa")
      """)
    end

    test "split and rejoin repeatedly" do
      assert_stopped("""
      s = " ".join(["word"] * 10000)
      for i in range(1000):
          parts = s.split(" ")
          s = " ".join(parts) + " extra"
      """)
    end
  end

  # ── Class and dunder bombs ──────────────────────────────────

  describe "class and dunder bombs" do
    test "recursive __repr__" do
      assert_stopped("""
      class Evil:
          def __repr__(self):
              return repr(self) + "x"
      repr(Evil())
      """)
    end

    test "recursive __str__" do
      assert_stopped("""
      class Evil:
          def __str__(self):
              return str(self) + "x"
      str(Evil())
      """)
    end

    test "__init__ that spawns more instances" do
      assert_stopped("""
      instances = []
      class Spawner:
          def __init__(self):
              instances.append(self)
              if len(instances) < 100000:
                  Spawner()
      Spawner()
      """)
    end

    test "__add__ infinite chain" do
      assert_stopped("""
      class Sticky:
          def __add__(self, other):
              return Sticky() + other
      Sticky() + Sticky()
      """)
    end

    test "deep inheritance chain lookup" do
      # Build a chain of 200 classes and instantiate the deepest one
      lines =
        ["class C0:\n    def method(self): return 0"] ++
          for i <- 1..200, do: "class C#{i}(C#{i - 1}): pass"

      code = Enum.join(lines, "\n") <> "\nC200().method()"
      assert_contained(code)
    end
  end

  # ── Exception handling bombs ─────────────────────────────────

  describe "exception handling bombs" do
    test "infinite retry loop" do
      assert_stopped("""
      while True:
          try:
              x = 1 / 0
          except:
              pass
      """)
    end

    test "exception in except handler" do
      assert_stopped("""
      def bomb():
          try:
              bomb()
          except:
              bomb()
      bomb()
      """)
    end
  end

  # ── Timeout integration ─────────────────────────────────────

  describe "timeout integration" do
    test "timeout inside limits supersedes top-level" do
      result = Pyex.run("while True: pass", timeout: 10_000, limits: [timeout: 50])
      assert {:error, %Pyex.Error{kind: :timeout}} = result
    end

    test "top-level timeout still works without limits" do
      result = Pyex.run("while True: pass", timeout: 50)
      assert {:error, %Pyex.Error{kind: :timeout}} = result
    end
  end

  # ── Combined limits ─────────────────────────────────────────

  describe "combined limits" do
    test "whichever limit triggers first wins" do
      assert_stopped("""
      s = ""
      for i in range(1000000):
          s += str(i)
      """)
    end

    test "Pyex.Limits struct works directly" do
      limits = %Pyex.Limits{max_steps: 100}

      assert {:error, %Pyex.Error{kind: :limit, limit: :steps}} =
               Pyex.run("while True: pass", limits: limits)
    end
  end

  # ── Error structure ─────────────────────────────────────────

  describe "error structure" do
    test "limit errors have correct kind and limit fields" do
      {:error, err} = Pyex.run("while True: pass", limits: [max_steps: 100])

      assert %Pyex.Error{
               kind: :limit,
               limit: :steps,
               message: "LimitError: step limit exceeded" <> _
             } = err
    end

    test "limit errors are never Elixir exceptions" do
      result = Pyex.run("while True: pass", limits: [max_steps: 100])
      assert {:error, %Pyex.Error{}} = result
    end

    test "output limit error has correct limit field" do
      {:error, err} =
        Pyex.run("print('x' * 100000)", limits: [max_output_bytes: 100, max_steps: 100_000])

      assert %Pyex.Error{kind: :limit, limit: :output} = err
    end
  end

  # ── Property-based adversarial tests ─────────────────────────

  describe "property: random programs always terminate cleanly" do
    @tag timeout: 120_000
    property "random loop programs terminate with limits" do
      check all(
              iterations <- integer(1..10_000_000),
              body <-
                one_of([
                  constant("x += 1"),
                  constant("x = str(x)"),
                  constant("x = [x]"),
                  constant("pass")
                ]),
              max_runs: 50
            ) do
        code = "x = 0\nfor i in range(#{iterations}):\n    #{body}"
        result = Pyex.run(code, limits: @tight_limits)

        assert match?({:ok, _, _}, result) or match?({:error, %Pyex.Error{}}, result),
               "Unexpected result: #{inspect(result)}"
      end
    end

    @tag timeout: 120_000
    property "random while loops terminate with limits" do
      check all(
              condition <-
                one_of([
                  constant("True"),
                  constant("x < 1000000"),
                  constant("len(items) < 1000000")
                ]),
              body <-
                one_of([
                  constant("x += 1"),
                  constant("items.append(x)\n    x += 1"),
                  constant("pass")
                ]),
              max_runs: 30
            ) do
        code = "x = 0\nitems = []\nwhile #{condition}:\n    #{body}"
        result = Pyex.run(code, limits: @tight_limits)

        assert match?({:ok, _, _}, result) or match?({:error, %Pyex.Error{}}, result),
               "Unexpected result: #{inspect(result)}"
      end
    end

    @tag timeout: 120_000
    property "nested comprehensions terminate with limits" do
      check all(
              outer <- integer(1..10_000),
              inner <- integer(1..10_000),
              max_runs: 30
            ) do
        code = "[i + j for i in range(#{outer}) for j in range(#{inner})]"
        result = Pyex.run(code, limits: @tight_limits)

        assert match?({:ok, _, _}, result) or match?({:error, %Pyex.Error{}}, result),
               "Unexpected result: #{inspect(result)}"
      end
    end

    @tag timeout: 120_000
    property "recursive functions terminate with limits" do
      check all(
              depth <- integer(1..100_000),
              max_runs: 20
            ) do
        code = "def f(n):\n    if n <= 0: return 0\n    return f(n-1) + 1\nf(#{depth})"
        result = Pyex.run(code, limits: @tight_limits)

        assert match?({:ok, _, _}, result) or match?({:error, %Pyex.Error{}}, result),
               "Unexpected result: #{inspect(result)}"
      end
    end

    @tag timeout: 120_000
    property "string operations terminate with limits" do
      check all(
              repeat <- integer(1..10_000_000),
              max_runs: 30
            ) do
        code = "s = 'x' * #{repeat}"
        result = Pyex.run(code, limits: @tight_limits)

        assert match?({:ok, _, _}, result) or match?({:error, %Pyex.Error{}}, result),
               "Unexpected result: #{inspect(result)}"
      end
    end
  end
end
