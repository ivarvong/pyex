defmodule Pyex.DifferentialFuzzTest do
  @moduledoc """
  Differential fuzzing tests that generate random valid Python programs,
  run them through both CPython and Pyex, and assert identical output.

  Unlike `ConformanceTest` (hand-written snippets), these tests use
  StreamData generators to explore the input space automatically. Every
  generated program wraps its result in `print(repr(...))` so we get
  canonical, comparable output.

  Requires `python3` on PATH. Skipped otherwise.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @python3 System.find_executable("python3")

  setup do
    if @python3 do
      :ok
    else
      {:skip, "python3 not found on PATH"}
    end
  end

  defp assert_differential(code) do
    cpython_output = run_cpython(code)
    pyex_output = run_pyex(code)

    assert pyex_output == cpython_output,
           """
           Differential fuzz mismatch:

           Python code:
           #{indent(code)}

           CPython output: #{inspect(cpython_output)}
           Pyex output:    #{inspect(pyex_output)}
           """
  end

  defp run_cpython(code) do
    case System.cmd(@python3, ["-c", code], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, extract_exception_type(String.trim(output))}
    end
  end

  defp run_pyex(code) do
    case Pyex.run(code, Pyex.Ctx.new(timeout_ms: 2_000)) do
      {:ok, _, ctx} -> {:ok, String.trim(Pyex.output(ctx))}
      {:error, err} -> {:error, err.exception_type || err.kind}
    end
  end

  defp extract_exception_type(stderr) do
    case Regex.run(~r/(\w+Error|\w+Exception|StopIteration|KeyboardInterrupt)\b/, stderr) do
      [_, type] -> type
      _ -> :unknown
    end
  end

  defp indent(code) do
    code
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end

  # ── Generators ──────────────────────────────────────────────

  defp small_int, do: integer(-50..50)
  defp arith_op, do: member_of(["+", "-", "*"])

  defp comparison_op, do: member_of(["==", "!=", "<", ">", "<=", ">="])

  defp safe_string do
    gen all(s <- string(:alphanumeric, min_length: 0, max_length: 12)) do
      s
    end
  end

  # ── Arithmetic differential fuzzing ────────────────────────

  describe "arithmetic differential fuzzing" do
    property "addition and subtraction" do
      check all(
              a <- small_int(),
              b <- small_int(),
              op <- member_of(["+", "-"]),
              max_runs: 200
            ) do
        assert_differential("print(repr(#{a} #{op} #{b}))")
      end
    end

    property "multiplication" do
      check all(
              a <- integer(-100..100),
              b <- integer(-100..100),
              max_runs: 200
            ) do
        assert_differential("print(repr(#{a} * #{b}))")
      end
    end

    property "integer division" do
      check all(
              a <- integer(-100..100),
              b <- filter(integer(-100..100), &(&1 != 0)),
              max_runs: 200
            ) do
        assert_differential("print(repr(#{a} // #{b}))")
      end
    end

    property "modulo" do
      check all(
              a <- integer(-100..100),
              b <- filter(integer(-100..100), &(&1 != 0)),
              max_runs: 200
            ) do
        assert_differential("print(repr(#{a} % #{b}))")
      end
    end

    property "power" do
      check all(
              base <- integer(-10..10),
              exp <- integer(0..6),
              max_runs: 200
            ) do
        assert_differential("print(repr(#{base} ** #{exp}))")
      end
    end

    property "divmod" do
      check all(
              a <- integer(-100..100),
              b <- filter(integer(-100..100), &(&1 != 0)),
              max_runs: 200
            ) do
        assert_differential("print(repr(divmod(#{a}, #{b})))")
      end
    end

    property "chained comparisons" do
      check all(
              a <- small_int(),
              b <- small_int(),
              c <- small_int(),
              op1 <- comparison_op(),
              op2 <- comparison_op(),
              max_runs: 200
            ) do
        assert_differential("print(repr(#{a} #{op1} #{b} #{op2} #{c}))")
      end
    end

    property "bitwise operations" do
      check all(
              a <- integer(0..255),
              b <- integer(0..255),
              op <- member_of(["&", "|", "^"]),
              max_runs: 200
            ) do
        assert_differential("print(repr(#{a} #{op} #{b}))")
      end
    end

    property "shift operations" do
      check all(
              a <- integer(0..255),
              b <- integer(0..8),
              op <- member_of(["<<", ">>"]),
              max_runs: 200
            ) do
        assert_differential("print(repr(#{a} #{op} #{b}))")
      end
    end

    property "mixed arithmetic expressions" do
      check all(
              a <- small_int(),
              b <- filter(small_int(), &(&1 != 0)),
              c <- small_int(),
              op1 <- arith_op(),
              op2 <- arith_op(),
              max_runs: 200
            ) do
        assert_differential("print(repr((#{a} #{op1} #{b}) #{op2} #{c}))")
      end
    end
  end

  # ── String differential fuzzing ────────────────────────────

  describe "string differential fuzzing" do
    property "string repetition" do
      check all(
              s <- safe_string(),
              n <- integer(-2..5),
              max_runs: 200
            ) do
        assert_differential("print(repr(\"#{s}\" * #{n}))")
      end
    end

    property "string slicing" do
      check all(
              s <- string(:alphanumeric, min_length: 1, max_length: 10),
              start <- integer(-5..5),
              stop <- integer(-5..10),
              max_runs: 200
            ) do
        assert_differential("print(repr(\"#{s}\"[#{start}:#{stop}]))")
      end
    end

    property "string slicing with step" do
      check all(
              s <- string(:alphanumeric, min_length: 1, max_length: 10),
              start <- integer(0..3),
              stop <- integer(4..10),
              step <- filter(integer(-3..3), &(&1 != 0)),
              max_runs: 200
            ) do
        assert_differential("print(repr(\"#{s}\"[#{start}:#{stop}:#{step}]))")
      end
    end

    property "string methods" do
      check all(
              s <- string(:alphanumeric, min_length: 1, max_length: 15),
              method <-
                member_of([
                  "upper()",
                  "lower()",
                  "strip()",
                  "swapcase()",
                  "capitalize()",
                  "isdigit()",
                  "isalpha()",
                  "isalnum()",
                  "isupper()",
                  "islower()"
                ]),
              max_runs: 200
            ) do
        assert_differential("print(repr(\"#{s}\".#{method}))")
      end
    end

    property "string title method" do
      check all(
              s <- string(:alphanumeric, min_length: 1, max_length: 15),
              max_runs: 200
            ) do
        assert_differential("print(repr(\"#{s}\".title()))")
      end
    end

    property "string find and count" do
      check all(
              s <- string(:alphanumeric, min_length: 3, max_length: 15),
              sub <- string(:alphanumeric, min_length: 1, max_length: 3),
              max_runs: 200
            ) do
        code = """
        s = "#{s}"
        print(repr((s.find("#{sub}"), s.count("#{sub}"))))
        """

        assert_differential(code)
      end
    end

    property "string split and join" do
      check all(
              words <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 5),
                  min_length: 1,
                  max_length: 5
                ),
              sep <- member_of([" ", ",", "-", "."]),
              max_runs: 200
            ) do
        joined = Enum.join(words, sep)

        assert_differential(~s[print(repr("#{joined}".split("#{sep}")))])
      end
    end

    property "string in operator" do
      check all(
              haystack <- string(:alphanumeric, min_length: 2, max_length: 15),
              needle <- string(:alphanumeric, min_length: 1, max_length: 3),
              max_runs: 200
            ) do
        assert_differential(~s[print(repr("#{needle}" in "#{haystack}"))])
      end
    end

    property "string percent formatting" do
      check all(
              n <- small_int(),
              s <- string(:alphanumeric, min_length: 1, max_length: 8),
              max_runs: 200
            ) do
        assert_differential(~s[print(repr("int=%d str=%s" % (#{n}, "#{s}")))])
      end
    end
  end

  # ── Collection differential fuzzing ────────────────────────

  describe "list differential fuzzing" do
    property "list construction and indexing" do
      check all(
              items <- list_of(small_int(), min_length: 1, max_length: 8),
              idx <- integer(0..(length(items) - 1)),
              max_runs: 200
            ) do
        list_str = Enum.join(items, ", ")
        assert_differential("print(repr([#{list_str}][#{idx}]))")
      end
    end

    property "list slicing" do
      check all(
              items <- list_of(small_int(), min_length: 1, max_length: 10),
              start <- integer(0..3),
              stop <- integer(3..10),
              max_runs: 200
            ) do
        list_str = Enum.join(items, ", ")
        assert_differential("print(repr([#{list_str}][#{start}:#{stop}]))")
      end
    end

    property "list comprehension" do
      check all(
              n <- integer(1..15),
              expr <- member_of(["i", "i * 2", "i ** 2", "i + 1", "-i"]),
              max_runs: 200
            ) do
        assert_differential("print(repr([#{expr} for i in range(#{n})]))")
      end
    end

    property "filtered list comprehension" do
      check all(
              n <- integer(1..15),
              cond_expr <-
                member_of([
                  "i % 2 == 0",
                  "i % 3 == 0",
                  "i > 5",
                  "i < 3",
                  "i != 0"
                ]),
              max_runs: 200
            ) do
        assert_differential("print(repr([i for i in range(#{n}) if #{cond_expr}]))")
      end
    end

    property "nested list comprehension" do
      check all(
              n <- integer(1..5),
              m <- integer(1..5),
              max_runs: 100
            ) do
        assert_differential("print(repr([(i, j) for i in range(#{n}) for j in range(#{m})]))")
      end
    end

    property "list sorting" do
      check all(
              items <- list_of(small_int(), min_length: 0, max_length: 10),
              max_runs: 200
            ) do
        list_str = Enum.join(items, ", ")
        assert_differential("print(repr(sorted([#{list_str}])))")
      end
    end

    property "list concatenation and repetition" do
      check all(
              a <- list_of(small_int(), min_length: 0, max_length: 5),
              b <- list_of(small_int(), min_length: 0, max_length: 5),
              n <- integer(0..4),
              max_runs: 200
            ) do
        a_str = Enum.join(a, ", ")
        b_str = Enum.join(b, ", ")
        assert_differential("print(repr([#{a_str}] + [#{b_str}]))")
        assert_differential("print(repr([#{a_str}] * #{n}))")
      end
    end

    property "list methods" do
      check all(
              items <- list_of(small_int(), min_length: 1, max_length: 8),
              max_runs: 200
            ) do
        list_str = Enum.join(items, ", ")
        first = hd(items)

        code = """
        x = [#{list_str}]
        print(repr((x.index(#{first}), x.count(#{first}), len(x))))
        """

        assert_differential(code)
      end
    end
  end

  describe "dict differential fuzzing" do
    property "dict construction and access" do
      check all(
              n <- integer(1..6),
              vals <- list_of(small_int(), length: n),
              max_runs: 200
            ) do
        pairs =
          Enum.with_index(vals)
          |> Enum.map_join(", ", fn {v, i} -> "\"k#{i}\": #{v}" end)

        assert_differential("print(repr({#{pairs}}[\"k0\"]))")
      end
    end

    property "dict comprehension" do
      check all(
              n <- integer(1..10),
              max_runs: 200
            ) do
        assert_differential("print(repr({i: i ** 2 for i in range(#{n})}))")
      end
    end

    property "dict methods" do
      check all(
              n <- integer(1..5),
              vals <- list_of(small_int(), length: n),
              max_runs: 200
            ) do
        pairs =
          Enum.with_index(vals)
          |> Enum.map_join(", ", fn {v, i} -> "\"k#{i}\": #{v}" end)

        code = """
        d = {#{pairs}}
        print(repr(sorted(d.keys())))
        print(repr(sorted(d.values())))
        print(repr(sorted(d.items())))
        print(repr(d.get("k0")))
        print(repr(d.get("missing", -1)))
        """

        assert_differential(code)
      end
    end
  end

  describe "set differential fuzzing" do
    property "set operations" do
      check all(
              a <- list_of(integer(0..15), min_length: 0, max_length: 8),
              b <- list_of(integer(0..15), min_length: 0, max_length: 8),
              max_runs: 200
            ) do
        a_str = Enum.join(a, ", ")
        b_str = Enum.join(b, ", ")

        code = """
        a = {#{a_str}}
        b = {#{b_str}}
        print(repr(sorted(a & b)))
        print(repr(sorted(a | b)))
        print(repr(sorted(a - b)))
        print(repr(sorted(a ^ b)))
        """

        assert_differential(code)
      end
    end

    property "set comprehension" do
      check all(
              n <- integer(1..15),
              mod <- integer(2..5),
              max_runs: 200
            ) do
        assert_differential("print(repr(sorted({i % #{mod} for i in range(#{n})})))")
      end
    end
  end

  describe "tuple differential fuzzing" do
    property "tuple construction and indexing" do
      check all(
              items <- list_of(small_int(), min_length: 1, max_length: 8),
              idx <- integer(0..(length(items) - 1)),
              max_runs: 200
            ) do
        tuple_str =
          case items do
            [single] -> "#{single},"
            many -> Enum.join(many, ", ")
          end

        assert_differential("print(repr((#{tuple_str})[#{idx}]))")
      end
    end

    property "tuple unpacking" do
      check all(
              a <- small_int(),
              b <- small_int(),
              c <- small_int(),
              max_runs: 200
            ) do
        code = """
        x, y, z = #{a}, #{b}, #{c}
        print(repr((x, y, z)))
        """

        assert_differential(code)
      end
    end

    property "starred unpacking" do
      check all(
              items <- list_of(small_int(), min_length: 3, max_length: 8),
              max_runs: 200
            ) do
        list_str = Enum.join(items, ", ")

        code = """
        first, *middle, last = [#{list_str}]
        print(repr((first, middle, last)))
        """

        assert_differential(code)
      end
    end
  end

  # ── Control flow differential fuzzing ──────────────────────

  describe "control flow differential fuzzing" do
    property "for loop with range" do
      check all(
              start <- integer(0..5),
              stop <- integer(5..15),
              step <- filter(integer(1..3), &(&1 != 0)),
              max_runs: 200
            ) do
        code = """
        result = []
        for i in range(#{start}, #{stop}, #{step}):
            result.append(i)
        print(repr(result))
        """

        assert_differential(code)
      end
    end

    property "while loop with accumulator" do
      check all(
              limit <- integer(1..20),
              max_runs: 200
            ) do
        code = """
        total = 0
        i = 0
        while i < #{limit}:
            total += i
            i += 1
        print(repr(total))
        """

        assert_differential(code)
      end
    end

    property "for with break and else" do
      check all(
              n <- integer(1..15),
              target <- integer(0..20),
              max_runs: 200
            ) do
        code = """
        result = "not found"
        for i in range(#{n}):
            if i == #{target}:
                result = "found"
                break
        else:
            result = "exhausted"
        print(repr(result))
        """

        assert_differential(code)
      end
    end

    property "ternary expression" do
      check all(
              a <- small_int(),
              b <- small_int(),
              max_runs: 200
            ) do
        assert_differential("print(repr(#{a} if #{a} > #{b} else #{b}))")
      end
    end

    property "boolean short circuit" do
      check all(
              a <- small_int(),
              b <- small_int(),
              max_runs: 200
            ) do
        assert_differential("print(repr((#{a} and #{b}, #{a} or #{b})))")
      end
    end
  end

  # ── Function differential fuzzing ──────────────────────────

  describe "function differential fuzzing" do
    property "function with default args" do
      check all(
              default <- small_int(),
              arg <- small_int(),
              max_runs: 200
            ) do
        code = """
        def f(x, y=#{default}):
            return x + y
        print(repr((f(#{arg}), f(#{arg}, #{arg}))))
        """

        assert_differential(code)
      end
    end

    property "lambda expressions" do
      check all(
              a <- small_int(),
              b <- small_int(),
              op <- arith_op(),
              max_runs: 200
            ) do
        assert_differential("print(repr((lambda x, y: x #{op} y)(#{a}, #{b})))")
      end
    end

    property "recursive fibonacci" do
      check all(
              n <- integer(0..12),
              max_runs: 50
            ) do
        code = """
        def fib(n):
            if n <= 1:
                return n
            return fib(n - 1) + fib(n - 2)
        print(repr(fib(#{n})))
        """

        assert_differential(code)
      end
    end

    property "closure over variable" do
      check all(
              n <- small_int(),
              x <- small_int(),
              max_runs: 200
            ) do
        code = """
        def make_adder(n):
            def adder(x):
                return x + n
            return adder
        print(repr(make_adder(#{n})(#{x})))
        """

        assert_differential(code)
      end
    end

    property "variadic function" do
      check all(
              args <- list_of(small_int(), min_length: 0, max_length: 6),
              max_runs: 200
            ) do
        args_str = Enum.join(args, ", ")

        code = """
        def total(*args):
            return sum(args)
        print(repr(total(#{args_str})))
        """

        assert_differential(code)
      end
    end

    property "keyword arguments" do
      check all(
              a <- small_int(),
              b <- small_int(),
              max_runs: 200
            ) do
        code = """
        def f(x=0, y=0):
            return (x, y)
        print(repr(f(x=#{a}, y=#{b})))
        """

        assert_differential(code)
      end
    end
  end

  # ── Builtin differential fuzzing ───────────────────────────

  describe "builtin differential fuzzing" do
    property "sorted with various inputs" do
      check all(
              items <- list_of(small_int(), min_length: 0, max_length: 10),
              reverse <- boolean(),
              max_runs: 200
            ) do
        list_str = Enum.join(items, ", ")
        rev_str = if reverse, do: "True", else: "False"
        assert_differential("print(repr(sorted([#{list_str}], reverse=#{rev_str})))")
      end
    end

    property "min and max" do
      check all(
              items <- list_of(small_int(), min_length: 1, max_length: 8),
              max_runs: 200
            ) do
        list_str = Enum.join(items, ", ")
        assert_differential("print(repr((min([#{list_str}]), max([#{list_str}]))))")
      end
    end

    property "sum" do
      check all(
              items <- list_of(small_int(), min_length: 0, max_length: 10),
              max_runs: 200
            ) do
        list_str = Enum.join(items, ", ")
        assert_differential("print(repr(sum([#{list_str}])))")
      end
    end

    property "abs" do
      check all(
              n <- integer(-1000..1000),
              max_runs: 200
            ) do
        assert_differential("print(repr(abs(#{n})))")
      end
    end

    property "range" do
      check all(
              start <- integer(-5..5),
              stop <- integer(-5..15),
              step <- filter(integer(-3..3), &(&1 != 0)),
              max_runs: 200
            ) do
        assert_differential("print(repr(list(range(#{start}, #{stop}, #{step}))))")
      end
    end

    property "enumerate" do
      check all(
              items <- list_of(safe_string(), min_length: 0, max_length: 5),
              start <- integer(0..5),
              max_runs: 200
            ) do
        list_str = Enum.map_join(items, ", ", &"\"#{&1}\"")
        assert_differential("print(repr(list(enumerate([#{list_str}], #{start}))))")
      end
    end

    property "zip" do
      check all(
              a <- list_of(small_int(), min_length: 0, max_length: 5),
              b <- list_of(small_int(), min_length: 0, max_length: 5),
              max_runs: 200
            ) do
        a_str = Enum.join(a, ", ")
        b_str = Enum.join(b, ", ")
        assert_differential("print(repr(list(zip([#{a_str}], [#{b_str}]))))")
      end
    end

    property "map and filter" do
      check all(
              items <- list_of(small_int(), min_length: 0, max_length: 8),
              max_runs: 200
            ) do
        list_str = Enum.join(items, ", ")

        code = """
        nums = [#{list_str}]
        print(repr(list(map(abs, nums))))
        print(repr(list(filter(lambda x: x > 0, nums))))
        """

        assert_differential(code)
      end
    end

    property "any and all" do
      check all(
              items <- list_of(small_int(), min_length: 0, max_length: 8),
              max_runs: 200
            ) do
        list_str = Enum.join(items, ", ")
        assert_differential("print(repr((any([#{list_str}]), all([#{list_str}]))))")
      end
    end

    property "type conversions" do
      check all(
              n <- small_int(),
              max_runs: 200
            ) do
        assert_differential("print(repr((int(#{n}), float(#{n}), str(#{n}), bool(#{n}))))")
      end
    end

    property "chr and ord round-trip" do
      check all(
              n <- integer(32..126),
              max_runs: 100
            ) do
        assert_differential("print(repr((chr(#{n}), ord(chr(#{n})))))")
      end
    end

    property "hex oct bin" do
      check all(
              n <- integer(0..255),
              max_runs: 200
            ) do
        assert_differential("print(repr((hex(#{n}), oct(#{n}), bin(#{n}))))")
      end
    end

    property "int with base" do
      check all(
              n <- integer(0..255),
              max_runs: 200
            ) do
        hex_str = Integer.to_string(n, 16) |> String.downcase()
        oct_str = Integer.to_string(n, 8)
        bin_str = Integer.to_string(n, 2)

        code = """
        print(repr((int("#{hex_str}", 16), int("#{oct_str}", 8), int("#{bin_str}", 2))))
        """

        assert_differential(code)
      end
    end

    property "pow with modular exponentiation" do
      check all(
              base <- integer(2..10),
              exp <- integer(1..10),
              mod <- integer(2..20),
              max_runs: 200
            ) do
        assert_differential("print(repr(pow(#{base}, #{exp}, #{mod})))")
      end
    end

    property "isinstance checks" do
      check all(
              val <-
                one_of([
                  small_int() |> map(&to_string/1),
                  constant("\"hi\""),
                  constant("True"),
                  constant("[1]"),
                  constant("(1,)"),
                  constant("{1: 2}")
                ]),
              type <- member_of(["int", "str", "bool", "list", "tuple", "dict"]),
              max_runs: 200
            ) do
        assert_differential("print(repr(isinstance(#{val}, #{type})))")
      end
    end
  end

  # ── Generator differential fuzzing ─────────────────────────

  describe "generator differential fuzzing" do
    property "generator with yield" do
      check all(
              n <- integer(1..10),
              max_runs: 100
            ) do
        code = """
        def gen(n):
            for i in range(n):
                yield i * i
        print(repr(list(gen(#{n}))))
        """

        assert_differential(code)
      end
    end

    property "generator expression" do
      check all(
              n <- integer(1..15),
              expr <- member_of(["x", "x*2", "x**2", "x+1"]),
              max_runs: 200
            ) do
        assert_differential("print(repr(list(#{expr} for x in range(#{n}))))")
      end
    end

    property "generator with filter" do
      check all(
              n <- integer(1..15),
              pred <- member_of(["x % 2 == 0", "x > 3", "x < 8", "x != 5"]),
              max_runs: 200
            ) do
        assert_differential("print(repr(list(x for x in range(#{n}) if #{pred})))")
      end
    end

    property "sum of generator expression" do
      check all(
              n <- integer(1..15),
              max_runs: 200
            ) do
        assert_differential("print(repr(sum(x * x for x in range(#{n}))))")
      end
    end

    property "yield from" do
      check all(
              a <- integer(1..5),
              b <- integer(1..5),
              max_runs: 100
            ) do
        code = """
        def chain(a, b):
            yield from range(a)
            yield from range(b)
        print(repr(list(chain(#{a}, #{b}))))
        """

        assert_differential(code)
      end
    end
  end

  # ── Class differential fuzzing ─────────────────────────────

  describe "class differential fuzzing" do
    property "class with dunder methods" do
      check all(
              x <- small_int(),
              y <- small_int(),
              max_runs: 100
            ) do
        code = """
        class Vec:
            def __init__(self, x, y):
                self.x = x
                self.y = y
            def __add__(self, other):
                return Vec(self.x + other.x, self.y + other.y)
            def __repr__(self):
                return f"Vec({self.x}, {self.y})"
            def __eq__(self, other):
                return self.x == other.x and self.y == other.y
        v = Vec(#{x}, #{y}) + Vec(1, 2)
        print(repr((v.x, v.y)))
        """

        assert_differential(code)
      end
    end

    property "class with inheritance" do
      check all(
              val <- small_int(),
              max_runs: 100
            ) do
        code = """
        class Base:
            def __init__(self, val):
                self.val = val
            def double(self):
                return self.val * 2
        class Child(Base):
            def triple(self):
                return self.val * 3
        c = Child(#{val})
        print(repr((c.double(), c.triple())))
        """

        assert_differential(code)
      end
    end

    property "class variable vs instance variable" do
      check all(
              class_val <- small_int(),
              inst_val <- small_int(),
              max_runs: 100
            ) do
        code = """
        class Foo:
            x = #{class_val}
        a = Foo()
        b = Foo()
        a.x = #{inst_val}
        print(repr((a.x, b.x, Foo.x)))
        """

        assert_differential(code)
      end
    end
  end

  # ── Exception handling differential fuzzing ────────────────

  describe "exception handling differential fuzzing" do
    property "try/except with division" do
      check all(
              a <- small_int(),
              b <- small_int(),
              max_runs: 200
            ) do
        code = """
        try:
            result = #{a} / #{b}
        except ZeroDivisionError:
            result = "zero_div"
        print(repr(result))
        """

        assert_differential(code)
      end
    end

    property "try/except/else/finally ordering" do
      check all(
              should_error <- boolean(),
              max_runs: 100
            ) do
        divisor = if should_error, do: "0", else: "2"

        code = """
        log = []
        try:
            log.append("try")
            x = 10 / #{divisor}
        except ZeroDivisionError:
            log.append("except")
        else:
            log.append("else")
        finally:
            log.append("finally")
        print(repr(log))
        """

        assert_differential(code)
      end
    end

    property "raise and catch custom exceptions" do
      check all(
              exc_type <- member_of(["ValueError", "TypeError", "RuntimeError"]),
              msg <- safe_string(),
              max_runs: 100
            ) do
        code = """
        try:
            raise #{exc_type}("#{msg}")
        except #{exc_type} as e:
            print(repr(str(e)))
        """

        assert_differential(code)
      end
    end
  end

  # ── Complex program differential fuzzing ───────────────────

  describe "complex program differential fuzzing" do
    property "fibonacci sequence" do
      check all(
              n <- integer(1..15),
              max_runs: 50
            ) do
        code = """
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
        print(repr([fib(i) for i in range(#{n})]))
        """

        assert_differential(code)
      end
    end

    property "word counting" do
      check all(
              words <- list_of(member_of(~w(the cat sat on mat)), min_length: 1, max_length: 12),
              max_runs: 100
            ) do
        text = Enum.join(words, " ")

        code = """
        text = "#{text}"
        counts = {}
        for word in text.split():
            counts[word] = counts.get(word, 0) + 1
        print(repr(sorted(counts.items())))
        """

        assert_differential(code)
      end
    end

    property "nested data transformation" do
      check all(
              n <- integer(1..8),
              max_runs: 100
            ) do
        code = """
        data = {i: [j ** 2 for j in range(i)] for i in range(1, #{n + 1})}
        total = sum(sum(v) for v in data.values())
        keys = sorted(data.keys())
        print(repr((total, keys)))
        """

        assert_differential(code)
      end
    end

    property "decorator pattern" do
      check all(
              n <- integer(1..5),
              val <- small_int(),
              max_runs: 100
            ) do
        code = """
        def repeat(n):
            def decorator(f):
                def wrapper(*args):
                    return [f(*args) for _ in range(n)]
                return wrapper
            return decorator

        @repeat(#{n})
        def double(x):
            return x * 2

        print(repr(double(#{val})))
        """

        assert_differential(code)
      end
    end

    property "sorting with key function" do
      check all(
              words <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 8),
                  min_length: 1,
                  max_length: 8
                ),
              max_runs: 100
            ) do
        list_str = Enum.map_join(words, ", ", &"\"#{&1}\"")

        code = """
        words = [#{list_str}]
        print(repr(sorted(words)))
        print(repr(sorted(words, key=len)))
        print(repr(sorted(words, reverse=True)))
        """

        assert_differential(code)
      end
    end
  end

  # ── Match/case differential fuzzing ────────────────────────

  describe "match/case differential fuzzing" do
    property "match on integers" do
      check all(
              val <- integer(-5..5),
              max_runs: 100
            ) do
        code = """
        match #{val}:
            case 0:
                result = "zero"
            case n if n > 0:
                result = "positive"
            case _:
                result = "negative"
        print(repr(result))
        """

        assert_differential(code)
      end
    end

    property "match on tuples" do
      check all(
              x <- small_int(),
              y <- small_int(),
              max_runs: 100
            ) do
        code = """
        point = (#{x}, #{y})
        match point:
            case (0, 0):
                result = "origin"
            case (x, 0):
                result = f"x-axis at {x}"
            case (0, y):
                result = f"y-axis at {y}"
            case (x, y):
                result = f"({x}, {y})"
        print(repr(result))
        """

        assert_differential(code)
      end
    end
  end
end
