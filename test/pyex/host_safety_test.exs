defmodule Pyex.HostSafetyTest do
  @moduledoc """
  The sandbox's load-bearing invariant: **no guest program can crash, hang, or
  unbound the host.** For *any* input — well-formed, malformed, adversarial, or
  randomly generated — `Pyex.run/2` must

    * return `{:ok, _, _}` or `{:error, %Pyex.Error{}}` (never let an
      Elixir-level exception/exit/throw escape the interpreter),
    * terminate within a wall-clock bound (so a step/memory/timeout ceiling
      that *fails* to stop a program is caught here as a test failure rather
      than freezing CI), and
    * stay within its resource ceilings.

  `Pyex.AdversarialTest` asserts this for a curated list of resource bombs; this
  module asserts it as a *universal property* over generated programs, plus a
  regression corpus of host-crash-class inputs (e.g. dynamic `type()` classes
  with builtin bases, which crashed the host before #131-era fixes).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :host_safety

  # Tight ceilings plus an internal wall-clock budget. Every run must terminate
  # well within @wall_ms; the outer Task is the backstop if the budget itself
  # has a bug (a hang the interpreter failed to stop is a host-safety failure).
  @limits [
    max_steps: 50_000,
    max_memory_bytes: 5_000_000,
    max_output_bytes: 200_000,
    timeout: 1_000
  ]
  @wall_ms 4_000

  # ── the invariant ──────────────────────────────────────────────────────────

  defp assert_host_safe(code) do
    task =
      Task.async(fn ->
        try do
          {:returned, Pyex.run(code, limits: @limits)}
        catch
          kind, reason -> {:host_crash, kind, reason, __STACKTRACE__}
        end
      end)

    case Task.yield(task, @wall_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:returned, {:ok, _v, _ctx}}} ->
        :ok

      {:ok, {:returned, {:error, %Pyex.Error{}}}} ->
        :ok

      {:ok, {:returned, other}} ->
        flunk(
          report(
            "non-conforming result (not {:ok,_,_} or {:error, %Pyex.Error{}})",
            code,
            inspect(other)
          )
        )

      {:ok, {:host_crash, kind, reason, stacktrace}} ->
        flunk(
          report(
            "Elixir-level host crash (#{kind})",
            code,
            Exception.format(kind, reason, stacktrace)
          )
        )

      nil ->
        flunk(
          report(
            "did not terminate within #{@wall_ms}ms — a resource ceiling failed to stop it",
            code,
            ""
          )
        )
    end
  end

  defp report(what, code, detail) do
    """
    HOST-SAFETY VIOLATION: #{what}
    ── offending program ──────────────────────────────
    #{code}
    ── detail ─────────────────────────────────────────
    #{detail}
    """
  end

  # ── regression corpus (each pinned by name) ────────────────────────────────

  @regressions [
    # Dynamic classes over builtin bases — the exact host-crash class fixed in
    # the C3-linearization / reify-base work. These must never regress.
    {"type() over a builtin base, instantiated", "type('T', (int,), {})()"},
    {"type() over multiple builtin bases", "type('T', (int, object), {})()"},
    {"isinstance against a dynamic int subclass",
     "t = type('T', (int,), {})\nprint(isinstance(t(), int))"},
    {"type() over str base used as a string",
     "s = type('S', (str,), {})('hi')\nprint(s.upper())"},

    # Self-referential structures (repr/print must not loop forever).
    {"self-referential list repr", "a = []\na.append(a)\nprint(a)"},
    {"self-referential dict repr", "d = {}\nd['self'] = d\nprint(repr(d))"},

    # Unbounded recursion must hit a ceiling, not blow the BEAM stack.
    {"infinite self-recursion", "def f(n):\n    return f(n + 1)\nf(0)"},
    {"mutual recursion", "def a(n):\n    return b(n)\ndef b(n):\n    return a(n)\na(0)"},

    # Misbehaving dunders.
    {"__getattr__ that recurses forever",
     "class C:\n    def __getattr__(self, name):\n        return self.missing\nC().x"},
    {"ZeroDivision inside __add__",
     "class C:\n    def __add__(self, o):\n        return 1 / 0\nC() + C()"},
    {"raise inside __exit__",
     "class X:\n    def __enter__(self):\n        return self\n    def __exit__(self, *a):\n        raise ValueError('boom')\nwith X():\n    pass"},
    {"__hash__ returning non-int",
     "class C:\n    def __hash__(self):\n        return 'nope'\nhash(C())"},

    # Metaclasses.
    {"custom metaclass instantiation",
     "class M(type):\n    pass\nclass A(metaclass=M):\n    pass\nprint(A())"},

    # Operator / slice edge cases.
    {"zero-step slice", "print([1, 2, 3][::0])"},
    {"unsupported binary operator", "print([] @ {})"},

    # Non-ASCII identifiers and strings.
    {"unicode identifier arithmetic", "日本 = 5\nprint(日本 * 2)"},

    # Generator / exception interplay.
    {"StopIteration raised inside a generator",
     "def g():\n    yield 1\n    raise StopIteration\nprint(list(g()))"},

    # Single-operation allocation / compute bombs: one native op whose size the
    # step/memory/timeout ceilings can't interrupt mid-flight. Each must fail
    # fast, not hang.
    {"factorial of a huge n", "import math\nmath.factorial(10**6)"},
    {"bytes() of a billion", "bytes(10**9)"},
    {"str.rjust to a billion", "'x'.rjust(10**9)"},
    {"str.center to a billion", "'x'.center(10**9)"},
    {"str.ljust to a billion", "'x'.ljust(10**9)"},
    {"str.zfill to a billion", "'1'.zfill(10**9)"},
    {"huge integer exponent", "2 ** (10**8)"},
    {"materialize a 10**12 range", "list(range(10**12))"},

    # Blocking the host: time.sleep must respect the run's timeout, and a
    # catastrophic regex must be budget-bounded — neither may hang.
    {"time.sleep beyond the timeout budget", "import time\ntime.sleep(10**9)"},
    {"catastrophic regex backtracking", "import re\nre.match('(a+)+$', 'a' * 50 + '!')"}
  ]

  for {name, code} <- @regressions do
    test "host-safe: #{name}" do
      assert_host_safe(unquote(code))
    end
  end

  # ── conformance of the fixes this harness drove ───────────────────────────

  describe "cycle-aware rendering and identity equality" do
    defp output(code) do
      {:ok, _v, ctx} = Pyex.run(code, limits: @limits)
      String.trim(Pyex.output(ctx))
    end

    test "a self-referential list renders the cycle instead of looping" do
      out = output("a = []\na.append(a)\nprint(a)")
      assert out =~ "[...]"
    end

    test "a self-referential dict renders the cycle instead of looping" do
      out = output("d = {}\nd['x'] = d\nprint(d)")
      assert out =~ "{...}"
    end

    test "a container is equal to itself by identity without materializing it" do
      assert output("a = []\na.append(a)\nprint(a == a)") == "True"
    end

    test "non-cyclic dict str is unchanged and matches repr" do
      assert output("print({'a': 1, 'b': 2})") == "{'a': 1, 'b': 2}"
      assert output("print(str({'x': 1}) == repr({'x': 1}))") == "True"
    end

    test "non-cyclic nested structures still render fully" do
      assert output("print([[1], [2, 3]])") == "[[1], [2, 3]]"
    end
  end

  # ── property: arbitrary spicy programs are host-safe ───────────────────────

  @tag timeout: 180_000
  property "randomly generated programs never crash, hang, or unbound the host" do
    check all(code <- program(), max_runs: 200) do
      assert_host_safe(code)
    end
  end

  # A small program is 1–5 "spicy" statements joined together — each one aimed
  # at machinery that historically hides host-crash bugs (dynamic classes,
  # dunder dispatch, recursion, self-reference, weird operators, unicode).
  defp program do
    gen all(stmts <- list_of(spicy_statement(), min_length: 1, max_length: 5)) do
      Enum.join(stmts, "\n")
    end
  end

  defp spicy_statement do
    one_of([
      dynamic_class_stmt(),
      dunder_abuse_stmt(),
      recursion_stmt(),
      self_reference_stmt(),
      operator_stmt(),
      unicode_stmt(),
      comprehension_stmt(),
      resource_bomb_stmt()
    ])
  end

  # A single operation handed a size from tiny to astronomical: small ones
  # succeed, huge ones must fail fast — never hang or unbound the host.
  defp resource_bomb_stmt do
    gen all(
          n <- member_of(["8", "1000", "10**6", "10**9", "10**12", "2 * 10**9"]),
          template <-
            member_of([
              "bytes(N)",
              "'ab' * (N)",
              "[0] * (N)",
              "'x'.rjust(N)",
              "'x'.center(N)",
              "'1'.zfill(N)",
              "list(range(N))",
              "2 ** (N)",
              "int('1' * (N))"
            ])
        ) do
      String.replace(template, "N", n)
    end
  end

  defp dynamic_class_stmt do
    gen all(
          base <- member_of(~w(int str float tuple list dict object bool bytes frozenset set)),
          arg <- member_of(["", "0", "1", "'x'", "[]", "()", "{}"])
        ) do
      "type('T', (#{base},), {})(#{arg})"
    end
  end

  defp dunder_abuse_stmt do
    gen all(
          {dunder, use_site} <-
            member_of([
              {"__add__", "C() + C()"},
              {"__getattr__", "C().whatever"},
              {"__call__", "C()()"},
              {"__iter__", "list(C())"},
              {"__eq__", "C() == C()"},
              {"__hash__", "hash(C())"},
              {"__repr__", "repr(C())"},
              {"__getitem__", "C()[0]"},
              {"__lt__", "C() < C()"}
            ]),
          body <-
            member_of([
              "return self",
              "return self.x",
              "raise ValueError('x')",
              "return 1 / 0",
              "return C()",
              "return [self]"
            ])
        ) do
      """
      class C:
          def #{dunder}(self, *a, **k):
              #{body}
      #{use_site}
      """
    end
  end

  defp recursion_stmt do
    gen all(kind <- member_of([:direct, :mutual, :via_property])) do
      case kind do
        :direct -> "def f(n):\n    return f(n + 1)\nf(0)"
        :mutual -> "def a(n):\n    return b(n)\ndef b(n):\n    return a(n)\na(0)"
        :via_property -> "class C:\n    @property\n    def x(self):\n        return self.x\nC().x"
      end
    end
  end

  defp self_reference_stmt do
    gen all(
          op <- member_of(["print(a)", "repr(a)", "str(a)", "len(a)", "a == a"]),
          kind <- member_of([:list, :dict])
        ) do
      case kind do
        :list -> "a = []\na.append(a)\n#{op}"
        :dict -> "a = {}\na['self'] = a\n#{op}"
      end
    end
  end

  defp operator_stmt do
    gen all(
          expr <-
            member_of([
              "[] @ {}",
              "~'x'",
              "[] < {}",
              "1 + 'x'",
              "[1, 2, 3][::0]",
              "(1).__class__.__bases__",
              "().__class__()",
              "{}.__setitem__([], 1)",
              "[].__iadd__(5)"
            ])
        ) do
      "print(#{expr})"
    end
  end

  defp unicode_stmt do
    gen all(
          n <- integer(0..50),
          text <- member_of(["日本語", "Ω≈ç√", "​́", "🦊🔥"])
        ) do
      "s = '#{text}' * #{n}\nprint(len(s))"
    end
  end

  defp comprehension_stmt do
    gen all(
          n <- integer(0..30),
          template <-
            member_of([
              "print([x * x for x in range(N)])",
              "print({x: x for x in range(N)})",
              "print(sum(x for x in range(N) if x % 2))",
              "print([[y for y in range(x)] for x in range(N)])"
            ])
        ) do
      String.replace(template, "N", Integer.to_string(n))
    end
  end
end
