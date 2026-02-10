defmodule Pyex.PropertyTest do
  @moduledoc """
  Property-based tests for the Pyex interpreter.

  Ensures the entire pipeline (lexer, parser, interpreter) never crashes
  on arbitrary input. The contract: every call returns {:ok, _} or
  {:error, _}, never raises.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pyex.{Lexer, Parser, Builtins, Interpreter, Ctx}

  @timeout_ctx Ctx.new(timeout_ms: 200)

  defp fresh_ctx do
    %{@timeout_ctx | compute_ns: 0, compute_started_at: System.monotonic_time(:nanosecond)}
  end

  defp assert_no_crash(result) do
    assert match?({:ok, _, _}, result) or
             match?({:suspended, _}, result) or
             match?({:error, _}, result)
  end

  describe "lexer robustness" do
    property "never crashes on arbitrary binary input" do
      check all(source <- string(:printable, max_length: 500), max_runs: 1000) do
        result = Lexer.tokenize(source)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    property "never crashes on binary with control characters" do
      check all(source <- binary(max_length: 300), max_runs: 1000) do
        result = Lexer.tokenize(source)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    property "never crashes on strings with Python-like tokens" do
      check all(source <- python_like_source(), max_runs: 1000) do
        result = Lexer.tokenize(source)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end

  describe "full pipeline robustness" do
    property "never crashes on arbitrary printable strings" do
      check all(source <- string(:printable, max_length: 500), max_runs: 1000) do
        result = Pyex.run(source)
        assert match?({:ok, _, _}, result) or match?({:error, _}, result)
      end
    end

    property "never crashes on Python-like source" do
      check all(source <- python_like_source(), max_runs: 1000) do
        result = Pyex.run(source)
        assert match?({:ok, _, _}, result) or match?({:error, _}, result)
      end
    end

    property "never crashes on generated expressions" do
      check all(source <- python_expression(), max_runs: 1000) do
        assert_no_crash(Pyex.run(source, fresh_ctx()))
      end
    end
  end

  describe "generated valid programs" do
    property "arithmetic programs always return a value or error cleanly" do
      check all(program <- arithmetic_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "assignment + expression programs never crash" do
      check all(program <- assignment_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "list/dict programs never crash" do
      check all(program <- collection_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "control flow programs never crash" do
      check all(program <- control_flow_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "function definition programs never crash" do
      check all(program <- function_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "string operation programs never crash" do
      check all(program <- string_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "class programs never crash" do
      check all(program <- class_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "try/except programs never crash" do
      check all(program <- try_except_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "comprehension programs never crash" do
      check all(program <- comprehension_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "generator/yield programs never crash" do
      check all(program <- generator_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "with statement programs never crash" do
      check all(program <- with_program(), max_runs: 500) do
        ctx = fresh_ctx()

        ctx = %{
          ctx
          | filesystem: Pyex.Filesystem.Memory.new(),
            fs_module: Pyex.Filesystem.Memory
        }

        assert_no_crash(Pyex.run(program, ctx))
      end
    end

    property "decorator programs never crash" do
      check all(program <- decorator_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "unpacking programs never crash" do
      check all(program <- unpacking_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "walrus operator programs never crash" do
      check all(program <- walrus_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "stdlib math programs never crash" do
      check all(program <- math_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "stdlib json programs never crash" do
      check all(program <- json_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "stdlib re programs never crash" do
      check all(program <- regex_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "stdlib collections programs never crash" do
      check all(program <- collections_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "method chaining programs never crash" do
      check all(program <- method_chain_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "match/case programs never crash" do
      check all(program <- match_case_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end

    property "mixed feature programs never crash" do
      check all(program <- mixed_feature_program(), max_runs: 500) do
        assert_no_crash(Pyex.run(program, fresh_ctx()))
      end
    end
  end

  describe "pathological inputs" do
    property "deeply nested parentheses don't crash" do
      check all(depth <- integer(1..50), max_runs: 50) do
        source = String.duplicate("(", depth) <> "1" <> String.duplicate(")", depth)
        result = Pyex.run(source)
        assert match?({:ok, _, _}, result) or match?({:error, _}, result)
      end
    end

    property "deeply nested list literals don't crash" do
      check all(depth <- integer(1..30), max_runs: 30) do
        source = String.duplicate("[", depth) <> "1" <> String.duplicate("]", depth)
        result = Pyex.run(source)
        assert match?({:ok, _, _}, result) or match?({:error, _}, result)
      end
    end

    property "long chains of binary operators don't crash" do
      check all(count <- integer(1..100), max_runs: 50) do
        source = Enum.map_join(1..count, " + ", &to_string/1)
        result = Pyex.run(source)
        assert match?({:ok, _, _}, result) or match?({:error, _}, result)
      end
    end

    property "long chains of comparisons don't crash" do
      check all(count <- integer(2..30), max_runs: 30) do
        source = Enum.map_join(1..count, " < ", &to_string/1)
        result = Pyex.run(source)
        assert match?({:ok, _, _}, result) or match?({:error, _}, result)
      end
    end

    property "strings with all escape sequences don't crash" do
      check all(s <- escape_heavy_string(), max_runs: 200) do
        source = "\"#{s}\""
        result = Pyex.run(source)
        assert match?({:ok, _, _}, result) or match?({:error, _}, result)
      end
    end

    property "large integer literals don't crash" do
      check all(n <- integer(-999_999_999..999_999_999), max_runs: 200) do
        result = Pyex.run(to_string(n))
        assert match?({:ok, _, _}, result) or match?({:error, _}, result)
      end
    end

    property "float edge cases don't crash" do
      check all(
              f <- one_of([float(min: -1.0e100, max: 1.0e100), constant(0.0)]),
              max_runs: 200
            ) do
        result = Pyex.run(to_string(f))
        assert match?({:ok, _, _}, result) or match?({:error, _}, result)
      end
    end

    property "many sequential statements don't crash" do
      check all(count <- integer(1..50), max_runs: 30) do
        lines = Enum.map(1..count, fn i -> "x_#{i} = #{i}" end)
        source = Enum.join(lines, "\n")
        result = Pyex.run(source)
        assert match?({:ok, _, _}, result) or match?({:error, _}, result)
      end
    end

    property "unicode identifiers don't crash" do
      check all(name <- unicode_identifier(), max_runs: 200) do
        source = "#{name} = 1\n#{name}"
        result = Pyex.run(source)
        assert match?({:ok, _, _}, result) or match?({:error, _}, result)
      end
    end

    property "mixed indentation doesn't crash" do
      check all(program <- mixed_indent_program(), max_runs: 200) do
        result = Pyex.run(program)
        assert match?({:ok, _, _}, result) or match?({:error, _}, result)
      end
    end
  end

  describe "parser robustness with lexer output" do
    property "parser never crashes on successfully lexed tokens" do
      check all(source <- python_like_source(), max_runs: 500) do
        case Lexer.tokenize(source) do
          {:ok, tokens} ->
            result = Parser.parse(tokens)
            assert match?({:ok, _}, result) or match?({:error, _}, result)

          {:error, _} ->
            :ok
        end
      end
    end
  end

  describe "interpreter robustness with parsed AST" do
    property "interpreter never crashes on successfully parsed AST" do
      check all(source <- python_like_source(), max_runs: 500) do
        with {:ok, tokens} <- Lexer.tokenize(source),
             {:ok, ast} <- Parser.parse(tokens) do
          ctx = %{
            @timeout_ctx
            | compute_ns: 0,
              compute_started_at: System.monotonic_time(:nanosecond)
          }

          result = Interpreter.run_with_ctx(ast, Builtins.env(), ctx)

          assert match?({:ok, _, _, _}, result) or
                   match?({:suspended, _, _}, result) or
                   match?({:error, _}, result)
        end
      end
    end
  end

  defp python_like_source do
    gen all(fragments <- list_of(python_fragment(), min_length: 1, max_length: 10)) do
      Enum.join(fragments, " ")
    end
  end

  defp python_fragment do
    one_of([
      python_keyword(),
      python_identifier(),
      python_number(),
      python_string_literal(),
      python_operator(),
      constant("\n"),
      constant("    "),
      constant("("),
      constant(")"),
      constant("["),
      constant("]"),
      constant("{"),
      constant("}"),
      constant(","),
      constant(":"),
      constant(".")
    ])
  end

  defp python_keyword do
    member_of([
      "if",
      "else",
      "elif",
      "while",
      "for",
      "in",
      "def",
      "return",
      "class",
      "try",
      "except",
      "finally",
      "raise",
      "import",
      "from",
      "as",
      "pass",
      "break",
      "continue",
      "and",
      "or",
      "not",
      "is",
      "True",
      "False",
      "None",
      "lambda",
      "with",
      "yield",
      "global",
      "nonlocal",
      "del",
      "assert",
      "match",
      "case"
    ])
  end

  defp python_identifier do
    gen all(
          first <- member_of(~w(a b c d x y z foo bar baz result items data val tmp)),
          suffix <- one_of([constant(""), integer(0..9) |> map(&to_string/1)])
        ) do
      first <> suffix
    end
  end

  defp python_number do
    one_of([
      integer(-1000..1000) |> map(&to_string/1),
      float(min: -100.0, max: 100.0) |> map(&to_string/1),
      constant("0"),
      constant("0x1f"),
      constant("0b1010"),
      constant("0o77")
    ])
  end

  defp python_string_literal do
    one_of([
      gen(all(s <- string(:alphanumeric, max_length: 20), do: "\"#{s}\"")),
      gen(all(s <- string(:alphanumeric, max_length: 20), do: "'#{s}'")),
      constant("\"\""),
      constant("''"),
      gen(all(s <- string(:alphanumeric, max_length: 10), do: "f\"#{s}\"")),
      gen(all(s <- string(:alphanumeric, max_length: 10), do: "f\"{x}#{s}\""))
    ])
  end

  defp python_operator do
    member_of([
      "+",
      "-",
      "*",
      "/",
      "//",
      "%",
      "**",
      "==",
      "!=",
      "<",
      ">",
      "<=",
      ">=",
      "=",
      "+=",
      "-=",
      "*=",
      "/=",
      ":",
      ".",
      ",",
      ";",
      "(",
      ")",
      "[",
      "]",
      "{",
      "}"
    ])
  end

  defp python_expression do
    gen all(expr <- sized_expression(3)) do
      expr
    end
  end

  defp sized_expression(0) do
    one_of([
      integer(-100..100) |> map(&to_string/1),
      float(min: -100.0, max: 100.0) |> map(&to_string/1),
      constant("True"),
      constant("False"),
      constant("None"),
      gen(all(s <- string(:alphanumeric, max_length: 10), do: "\"#{s}\"")),
      member_of(~w(x y z a b c))
    ])
  end

  defp sized_expression(n) do
    smaller = sized_expression(n - 1)

    one_of([
      sized_expression(0),
      gen(
        all left <- smaller,
            op <- member_of(["+", "-", "*", "/", "//", "%", "**"]),
            right <- smaller do
          "#{left} #{op} #{right}"
        end
      ),
      gen(all(val <- smaller, do: "(#{val})")),
      gen(all(val <- smaller, do: "-#{val}")),
      gen(all(val <- smaller, do: "not #{val}")),
      gen(
        all left <- smaller, right <- smaller do
          "[#{left}, #{right}]"
        end
      ),
      gen(
        all cond_expr <- smaller,
            then_expr <- smaller,
            else_expr <- smaller do
          "#{then_expr} if #{cond_expr} else #{else_expr}"
        end
      ),
      gen(
        all func <- member_of(~w(len str int float bool type abs round)),
            arg <- smaller do
          "#{func}(#{arg})"
        end
      ),
      gen(
        all left <- smaller,
            op <- member_of(["==", "!=", "<", ">", "<=", ">="]),
            right <- smaller do
          "#{left} #{op} #{right}"
        end
      ),
      gen(
        all left <- smaller, right <- smaller do
          "#{left} and #{right}"
        end
      ),
      gen(
        all left <- smaller, right <- smaller do
          "#{left} or #{right}"
        end
      )
    ])
  end

  defp arithmetic_program do
    gen all(
          assignments <- list_of(arithmetic_assignment(), min_length: 1, max_length: 5),
          expr <- arithmetic_expr()
        ) do
      Enum.join(assignments, "\n") <> "\n" <> expr
    end
  end

  defp arithmetic_assignment do
    gen all(
          var <- member_of(~w(a b c x y z)),
          expr <- arithmetic_expr()
        ) do
      "#{var} = #{expr}"
    end
  end

  defp arithmetic_expr do
    one_of([
      integer(-1000..1000) |> map(&to_string/1),
      gen(
        all left <- integer(-100..100),
            op <- member_of(["+", "-", "*"]),
            right <- integer(-100..100) do
          "#{left} #{op} #{right}"
        end
      ),
      gen(
        all left <- integer(1..100),
            right <- integer(1..100) do
          "#{left} / #{right}"
        end
      ),
      gen(
        all left <- integer(1..100),
            right <- integer(1..100) do
          "#{left} // #{right}"
        end
      ),
      gen(
        all left <- integer(0..100),
            right <- integer(1..20) do
          "#{left} % #{right}"
        end
      ),
      gen(
        all base <- integer(0..10),
            exp <- integer(0..5) do
          "#{base} ** #{exp}"
        end
      )
    ])
  end

  defp assignment_program do
    gen all(
          vars <-
            uniq_list_of(
              member_of(~w(a b c d e f g h i j k l m n o p q r s t u v w x y z)),
              min_length: 1,
              max_length: 8
            ),
          vals <-
            list_of(
              one_of([
                integer(-100..100) |> map(&to_string/1),
                constant("True"),
                constant("False"),
                constant("None"),
                gen(all(s <- string(:alphanumeric, max_length: 8), do: "\"#{s}\""))
              ]),
              length: length(vars)
            )
        ) do
      assignments =
        Enum.zip(vars, vals)
        |> Enum.map(fn {v, val} -> "#{v} = #{val}" end)
        |> Enum.join("\n")

      last_var = List.last(vars)
      assignments <> "\n" <> last_var
    end
  end

  defp collection_program do
    one_of([
      gen(
        all items <- list_of(integer(-50..50) |> map(&to_string/1), min_length: 0, max_length: 10),
            method <-
              member_of([
                "len(xs)",
                "xs[0]",
                "xs[-1]",
                "sorted(xs)",
                "sum(xs)",
                "min(xs)",
                "max(xs)",
                "xs"
              ]) do
          "xs = [#{Enum.join(items, ", ")}]\n#{method}"
        end
      ),
      gen(
        all keys <-
              uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 5),
                min_length: 1,
                max_length: 5
              ),
            vals <-
              list_of(integer(0..100) |> map(&to_string/1),
                min_length: length(keys),
                max_length: length(keys)
              ) do
          pairs =
            Enum.zip(keys, vals)
            |> Enum.map(fn {k, v} -> "\"#{k}\": #{v}" end)
            |> Enum.join(", ")

          first_key = hd(keys)
          "d = {#{pairs}}\nd[\"#{first_key}\"]"
        end
      ),
      gen(
        all items <- list_of(integer(0..20) |> map(&to_string/1), min_length: 0, max_length: 8) do
          "s = {#{Enum.join(items, ", ")}}\nlen(s)"
        end
      ),
      gen(
        all items <- list_of(integer(0..20) |> map(&to_string/1), min_length: 0, max_length: 8) do
          "t = (#{Enum.join(items, ", ")}#{if length(items) == 1, do: ",", else: ""})\nlen(t)"
        end
      )
    ])
  end

  defp control_flow_program do
    one_of([
      gen(
        all n <- integer(0..20) do
          """
          total = 0
          for i in range(#{n}):
              total += i
          total
          """
        end
      ),
      gen(
        all n <- integer(1..10),
            cond_val <- member_of(["i > 0", "i % 2 == 0", "i < 5", "True"]) do
          """
          result = []
          for i in range(#{n}):
              if #{cond_val}:
                  result.append(i)
          result
          """
        end
      ),
      gen(
        all limit <- integer(1..15) do
          """
          x = 0
          while x < #{limit}:
              x += 1
          x
          """
        end
      ),
      gen(
        all n <- integer(0..10) do
          """
          total = 0
          for i in range(#{n}):
              if i % 2 == 0:
                  continue
              total += i
          total
          """
        end
      ),
      gen(
        all n <- integer(1..20),
            target <- integer(0..20) do
          """
          found = False
          for i in range(#{n}):
              if i == #{target}:
                  found = True
                  break
          found
          """
        end
      ),
      gen(
        all val <- integer(-50..50) do
          cond do
            val > 0 ->
              """
              x = #{val}
              if x > 10:
                  result = "big"
              elif x > 0:
                  result = "small"
              else:
                  result = "zero"
              result
              """

            true ->
              """
              x = #{val}
              if x > 0:
                  result = "positive"
              else:
                  result = "non-positive"
              result
              """
          end
        end
      )
    ])
  end

  defp function_program do
    one_of([
      gen(
        all body_val <- integer(0..100) do
          """
          def f():
              return #{body_val}
          f()
          """
        end
      ),
      gen(
        all op <- member_of(["+", "-", "*"]) do
          """
          def calc(a, b):
              return a #{op} b
          calc(3, 4)
          """
        end
      ),
      gen(
        all default <- integer(0..10) do
          """
          def greet(name, times=#{default}):
              return name * times
          greet("hi", 2)
          """
        end
      ),
      constant("""
      def fib(n):
          if n <= 1:
              return n
          return fib(n - 1) + fib(n - 2)
      fib(10)
      """),
      gen(
        all n <- integer(0..5) do
          """
          def make_adder(n):
              def adder(x):
                  return x + n
              return adder
          add = make_adder(#{n})
          add(10)
          """
        end
      ),
      gen(
        all op <- member_of(["+", "-", "*"]) do
          """
          fn = lambda a, b: a #{op} b
          fn(5, 3)
          """
        end
      ),
      constant("""
      def variadic(*args, **kwargs):
          return (args, kwargs)
      variadic(1, 2, 3, x=4, y=5)
      """)
    ])
  end

  defp string_program do
    one_of([
      gen(
        all s <- string(:alphanumeric, min_length: 1, max_length: 20),
            method <-
              member_of([
                "upper()",
                "lower()",
                "strip()",
                "split()",
                "replace(\"a\", \"b\")",
                "startswith(\"a\")",
                "endswith(\"z\")",
                "find(\"a\")",
                "count(\"a\")"
              ]) do
          "\"#{s}\".#{method}"
        end
      ),
      gen(
        all s <- string(:alphanumeric, min_length: 1, max_length: 10),
            i <- integer(0..5) do
          "\"#{s}\"[#{i}]"
        end
      ),
      gen(
        all s <- string(:alphanumeric, min_length: 3, max_length: 15),
            start <- integer(0..2),
            stop <- integer(3..5) do
          "\"#{s}\"[#{start}:#{stop}]"
        end
      ),
      gen(
        all name <- member_of(~w(world elixir python test)),
            n <- integer(0..10) do
          "f\"hello {\"#{name}\"} number {#{n}}\""
        end
      ),
      gen(
        all sep <- member_of([" ", ", ", "-", ""]),
            items <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 5),
                min_length: 1,
                max_length: 5
              ) do
          list_str = Enum.map_join(items, ", ", &"\"#{&1}\"")
          "\"#{sep}\".join([#{list_str}])"
        end
      )
    ])
  end

  defp class_program do
    one_of([
      constant("""
      class Point:
          def __init__(self, x, y):
              self.x = x
              self.y = y
          def magnitude(self):
              return (self.x ** 2 + self.y ** 2) ** 0.5
      p = Point(3, 4)
      p.magnitude()
      """),
      gen(
        all val <- integer(0..100) do
          """
          class Box:
              def __init__(self, value):
                  self.value = value
              def get(self):
                  return self.value
          b = Box(#{val})
          b.get()
          """
        end
      ),
      constant("""
      class Animal:
          def __init__(self, name):
              self.name = name
          def speak(self):
              return self.name + " speaks"
      class Dog(Animal):
          def speak(self):
              return self.name + " barks"
      d = Dog("Rex")
      d.speak()
      """),
      constant("""
      class Counter:
          def __init__(self):
              self.count = 0
          def __str__(self):
              return "Counter(" + str(self.count) + ")"
          def __repr__(self):
              return "Counter()"
          def inc(self):
              self.count += 1
              return self
      c = Counter()
      c.inc().inc()
      c.count
      """)
    ])
  end

  defp try_except_program do
    one_of([
      constant("""
      try:
          x = 1 / 0
      except ZeroDivisionError:
          x = -1
      x
      """),
      constant("""
      try:
          x = int("not a number")
      except ValueError as e:
          x = str(e)
      x
      """),
      constant("""
      result = []
      for i in range(5):
          try:
              result.append(10 // i)
          except ZeroDivisionError:
              result.append(0)
      result
      """),
      constant("""
      def safe_divide(a, b):
          try:
              return a / b
          except ZeroDivisionError:
              return None
          finally:
              pass
      safe_divide(10, 0)
      """),
      constant("""
      try:
          raise ValueError("test error")
      except ValueError as e:
          msg = str(e)
      msg
      """),
      constant("""
      try:
          x = 42
      except:
          x = -1
      else:
          x = x + 1
      x
      """)
    ])
  end

  defp comprehension_program do
    one_of([
      gen(
        all n <- integer(1..15),
            expr <- member_of(["i", "i * 2", "i ** 2", "str(i)", "i + 1"]) do
          "[#{expr} for i in range(#{n})]"
        end
      ),
      gen(
        all n <- integer(1..15),
            cond_expr <- member_of(["i > 0", "i % 2 == 0", "i < 5"]) do
          "[i for i in range(#{n}) if #{cond_expr}]"
        end
      ),
      gen(
        all n <- integer(1..8) do
          "{i: i ** 2 for i in range(#{n})}"
        end
      ),
      gen(
        all n <- integer(1..10) do
          "{i for i in range(#{n})}"
        end
      ),
      gen(
        all n <- integer(1..5), m <- integer(1..5) do
          "[(i, j) for i in range(#{n}) for j in range(#{m})]"
        end
      ),
      gen(
        all n <- integer(1..10),
            cond_expr <- member_of(["i % 2 == 0", "i > 3", "i != 5"]) do
          "[i * 10 for i in range(#{n}) if #{cond_expr}]"
        end
      )
    ])
  end

  defp escape_heavy_string do
    gen all(
          parts <-
            list_of(
              one_of([
                string(:alphanumeric, min_length: 1, max_length: 5),
                constant("\\n"),
                constant("\\t"),
                constant("\\\\"),
                constant("\\'"),
                constant("\\\""),
                constant("\\r"),
                constant("\\0"),
                constant("\\x41"),
                constant("\\u0041")
              ]),
              min_length: 1,
              max_length: 8
            )
        ) do
      Enum.join(parts)
    end
  end

  defp unicode_identifier do
    gen all(
          first <- member_of(~w(a b c x y z _ α β γ δ)),
          rest <- string(:alphanumeric, max_length: 5)
        ) do
      first <> rest
    end
  end

  defp mixed_indent_program do
    one_of([
      gen(
        all indent <- member_of(["  ", "    ", "\t", "      "]),
            val <- integer(0..10) do
          "if True:\n#{indent}x = #{val}\nx"
        end
      ),
      gen(
        all val <- integer(0..10) do
          "x = #{val}\n\n\nx"
        end
      ),
      gen(
        all val <- integer(0..10) do
          "\n\nx = #{val}\nx"
        end
      )
    ])
  end

  defp generator_program do
    one_of([
      gen(
        all n <- integer(1..10) do
          """
          def gen_range(n):
              i = 0
              while i < n:
                  yield i
                  i += 1
          list(gen_range(#{n}))
          """
        end
      ),
      gen(
        all n <- integer(1..8) do
          """
          def squares(n):
              for i in range(n):
                  yield i * i
          list(squares(#{n}))
          """
        end
      ),
      gen(
        all n <- integer(3..10) do
          """
          def fibonacci(n):
              a, b = 0, 1
              for _ in range(n):
                  yield a
                  a, b = b, a + b
          list(fibonacci(#{n}))
          """
        end
      ),
      gen(
        all n <- integer(1..5) do
          """
          def chain(*iterables):
              for it in iterables:
                  yield from it
          list(chain(range(#{n}), range(#{n})))
          """
        end
      ),
      gen(
        all n <- integer(1..10),
            pred <- member_of(["x % 2 == 0", "x > 3", "x < 7"]) do
          """
          def filtered(n):
              for x in range(n):
                  if #{pred}:
                      yield x
          list(filtered(#{n}))
          """
        end
      )
    ])
  end

  defp with_program do
    one_of([
      constant("""
      with open("test.txt", "w") as f:
          f.write("hello world")
      with open("test.txt", "r") as f:
          data = f.read()
      data
      """),
      gen(
        all content <- string(:alphanumeric, min_length: 1, max_length: 20) do
          """
          with open("out.txt", "w") as f:
              f.write("#{content}")
          with open("out.txt", "r") as f:
              result = f.read()
          len(result)
          """
        end
      )
    ])
  end

  defp decorator_program do
    one_of([
      constant("""
      def logger(func):
          def wrapper(*args, **kwargs):
              result = func(*args, **kwargs)
              return result
          return wrapper

      @logger
      def add(a, b):
          return a + b
      add(3, 4)
      """),
      gen(
        all n <- integer(1..10) do
          """
          def double_result(func):
              def wrapper(*args):
                  return func(*args) * 2
              return wrapper

          @double_result
          def compute(x):
              return x + #{n}
          compute(5)
          """
        end
      ),
      constant("""
      def repeat(n):
          def decorator(func):
              def wrapper(*args):
                  result = []
                  for i in range(n):
                      result.append(func(*args))
                  return result
              return wrapper
          return decorator

      @repeat(3)
      def greet(name):
          return "hi " + name
      greet("world")
      """)
    ])
  end

  defp unpacking_program do
    one_of([
      gen(
        all a <- integer(-50..50), b <- integer(-50..50) do
          """
          x, y = #{a}, #{b}
          x + y
          """
        end
      ),
      gen(
        all n <- integer(2..6) do
          vars = Enum.map_join(1..n, ", ", fn i -> "v#{i}" end)
          vals = Enum.map_join(1..n, ", ", &to_string/1)

          """
          #{vars} = #{vals}
          #{vars}
          """
        end
      ),
      constant("""
      data = [(1, "a"), (2, "b"), (3, "c")]
      nums = []
      for num, letter in data:
          nums.append(num)
      nums
      """),
      constant("""
      d = {"x": 1, "y": 2, "z": 3}
      pairs = []
      for k, v in d.items():
          pairs.append(k + "=" + str(v))
      pairs
      """),
      gen(
        all a <- integer(0..10), b <- integer(0..10) do
          """
          a, b = #{a}, #{b}
          a, b = b, a
          (a, b)
          """
        end
      )
    ])
  end

  defp walrus_program do
    one_of([
      gen(
        all n <- integer(0..20) do
          """
          results = []
          data = list(range(#{n}))
          if (n := len(data)) > 5:
              results.append(n)
          else:
              results.append(0)
          results
          """
        end
      ),
      gen(
        all threshold <- integer(1..10) do
          """
          values = [1, 5, 3, 8, 2, 9, 4]
          big = [y for x in values if (y := x * 2) > #{threshold}]
          big
          """
        end
      )
    ])
  end

  defp math_program do
    one_of([
      gen(
        all func <- member_of(["sin", "cos", "tan", "sqrt", "log", "exp", "floor", "ceil"]),
            val <- float(min: 0.1, max: 10.0) do
          """
          import math
          math.#{func}(#{val})
          """
        end
      ),
      gen(
        all val <- float(min: -100.0, max: 100.0) do
          """
          import math
          math.fabs(#{val})
          """
        end
      ),
      constant("""
      import math
      math.pi
      """),
      constant("""
      import math
      math.e
      """),
      gen(
        all base <- float(min: 0.1, max: 10.0), exp <- float(min: 0.1, max: 5.0) do
          """
          import math
          math.pow(#{base}, #{exp})
          """
        end
      )
    ])
  end

  defp json_program do
    one_of([
      gen(
        all key <- string(:alphanumeric, min_length: 1, max_length: 8),
            val <- integer(-100..100) do
          """
          import json
          data = {"#{key}": #{val}}
          s = json.dumps(data)
          json.loads(s)
          """
        end
      ),
      gen(
        all items <- list_of(integer(-50..50) |> map(&to_string/1), min_length: 0, max_length: 5) do
          """
          import json
          data = [#{Enum.join(items, ", ")}]
          s = json.dumps(data)
          json.loads(s)
          """
        end
      ),
      constant("""
      import json
      json.loads("null")
      """),
      constant("""
      import json
      json.dumps({"nested": {"a": [1, 2, 3]}, "b": True, "c": None})
      """),
      constant("""
      import json
      try:
          json.loads("not valid json")
      except:
          result = "caught"
      result
      """)
    ])
  end

  defp regex_program do
    one_of([
      gen(
        all pattern <- member_of(["\\d+", "\\w+", "[a-z]+", "\\s+", "."]),
            text <- string(:alphanumeric, min_length: 1, max_length: 20) do
          """
          import re
          re.findall("#{pattern}", "#{text}")
          """
        end
      ),
      gen(
        all text <- string(:alphanumeric, min_length: 1, max_length: 20) do
          """
          import re
          m = re.search("(\\w+)", "#{text}")
          m.group(0) if m else None
          """
        end
      ),
      gen(
        all text <- string(:alphanumeric, min_length: 1, max_length: 15) do
          """
          import re
          re.sub("\\d", "X", "#{text}123abc")
          """
        end
      ),
      constant("""
      import re
      re.split("[,;]", "a,b;c,d")
      """)
    ])
  end

  defp collections_program do
    one_of([
      gen(
        all items <- list_of(member_of(~w(a b c d e f)), min_length: 1, max_length: 10) do
          list_str = Enum.map_join(items, ", ", &"\"#{&1}\"")

          """
          from collections import Counter
          c = Counter([#{list_str}])
          c.most_common(3)
          """
        end
      ),
      gen(
        all items <- list_of(integer(0..10) |> map(&to_string/1), min_length: 0, max_length: 8) do
          """
          from collections import Counter
          c = Counter([#{Enum.join(items, ", ")}])
          dict(c)
          """
        end
      ),
      constant("""
      from collections import OrderedDict
      d = OrderedDict()
      d["b"] = 2
      d["a"] = 1
      d["c"] = 3
      list(d.keys())
      """),
      constant("""
      from collections import defaultdict
      d = defaultdict(int)
      d["a"] += 1
      d["b"] += 2
      d["a"] += 3
      dict(d)
      """)
    ])
  end

  defp method_chain_program do
    one_of([
      gen(
        all s <- string(:alphanumeric, min_length: 1, max_length: 15),
            methods <-
              list_of(
                member_of([
                  "upper()",
                  "lower()",
                  "strip()",
                  "title()",
                  "swapcase()",
                  "capitalize()"
                ]),
                min_length: 1,
                max_length: 4
              ) do
          chain = Enum.join(methods, ".")
          "\"#{s}\".#{chain}"
        end
      ),
      gen(
        all n <- integer(1..10) do
          """
          result = list(range(#{n}))
          result.sort()
          result.reverse()
          result
          """
        end
      ),
      gen(
        all items <- list_of(integer(0..20) |> map(&to_string/1), min_length: 1, max_length: 5),
            method <-
              member_of([
                "keys()",
                "values()",
                "items()",
                "copy()"
              ]) do
          pairs =
            Enum.with_index(items) |> Enum.map_join(", ", fn {v, i} -> "\"k#{i}\": #{v}" end)

          """
          d = {#{pairs}}
          list(d.#{method})
          """
        end
      )
    ])
  end

  defp match_case_program do
    one_of([
      gen(
        all val <- integer(-10..10) do
          """
          match #{val}:
              case 0:
                  result = "zero"
              case n if n > 0:
                  result = "positive"
              case _:
                  result = "negative"
          result
          """
        end
      ),
      gen(
        all cmd <- member_of(["quit", "help", "save", "unknown"]) do
          """
          command = "#{cmd}"
          match command:
              case "quit":
                  result = 0
              case "help":
                  result = 1
              case _:
                  result = -1
          result
          """
        end
      ),
      constant("""
      point = (3, 4)
      match point:
          case (0, 0):
              result = "origin"
          case (x, 0):
              result = "x-axis"
          case (0, y):
              result = "y-axis"
          case (x, y):
              result = "point"
      result
      """)
    ])
  end

  defp mixed_feature_program do
    one_of([
      gen(
        all n <- integer(1..8) do
          """
          data = {i: i ** 2 for i in range(#{n})}
          total = sum(v for v in data.values())
          filtered = {k: v for k, v in data.items() if v > 5}
          (total, filtered)
          """
        end
      ),
      gen(
        all n <- integer(1..10) do
          """
          class Stack:
              def __init__(self):
                  self.items = []
              def push(self, x):
                  self.items.append(x)
              def pop(self):
                  return self.items.pop()
              def __len__(self):
                  return len(self.items)
          s = Stack()
          for i in range(#{n}):
              s.push(i)
          results = []
          while len(s) > 0:
              results.append(s.pop())
          results
          """
        end
      ),
      constant("""
      import math
      import json

      data = [math.sqrt(i) for i in range(1, 6)]
      rounded = [round(x, 2) for x in data]
      json.dumps(rounded)
      """),
      gen(
        all n <- integer(2..8) do
          """
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
          fib(#{n})
          """
        end
      ),
      gen(
        all n <- integer(1..6) do
          """
          def flatten(lst):
              result = []
              for item in lst:
                  if type(item) == type([]):
                      result.extend(flatten(item))
                  else:
                      result.append(item)
              return result
          nested = [[i, [i + 1]] for i in range(#{n})]
          flatten(nested)
          """
        end
      ),
      constant("""
      from collections import Counter
      words = "the cat sat on the mat the cat".split()
      counts = Counter(words)
      most = counts.most_common(2)
      most
      """),
      gen(
        all n <- integer(1..5) do
          """
          def pipe(*funcs):
              def apply(x):
                  for f in funcs:
                      x = f(x)
                  return x
              return apply

          transform = pipe(
              lambda x: x * 2,
              lambda x: x + 1,
              lambda x: x ** 2
          )
          [transform(i) for i in range(#{n})]
          """
        end
      )
    ])
  end
end
