defmodule Pyex.Test.GeneratorOracle do
  @moduledoc """
  Trace-level differential testing for the generator engine.

  The plain differential fuzzer compares the *final stdout* of a whole
  program. That is blind to the bugs that live in generators: side-effect
  *ordering* (code before the first `yield` running at creation vs. first
  `next()`) and protocol *boundaries* (`throw` at the last `yield` in a
  `try`, `send` routed through `yield from`). Those mostly produce the same
  final output, which is exactly why an eager, non-lazy engine passed
  thousands of value-level tests while being subtly wrong.

  This module raises the observable from "final value" to "trace": it
  generates a random generator **body** *and* a random **driver** (a
  sequence of `next`/`send`/`throw`/`close` ops), renders a self-contained
  Python program that prints an interleaved trace of every side effect and
  every op result, and asserts CPython and Pyex emit the identical trace.

  It also exposes:

    * `gen_body/0`, `gen_driver/0`, `gen_pure_body/0` — StreamData generators
      biased toward the continuation frames that interact (`try`/`finally`,
      `for`, nested `yield from`, send-receiving yields).
    * metamorphic rendering (`render_metamorphic/2`) — `list(g)` ≡
      `[x for x in g]` ≡ a manual `next`-until-`StopIteration` loop, which
      pins the engine to itself without an oracle.

  All generated programs terminate (bounded `for range(n)`, bounded driver
  length, no `while True`) so a runaway is a bug, not an expected timeout.
  """

  use ExUnitProperties

  @python3 System.find_executable("python3")

  @exceptions ["ValueError", "KeyError", "RuntimeError"]

  @doc "True if `python3` is on PATH at suite-start time."
  @spec python3_available?() :: boolean()
  def python3_available?, do: @python3 != nil

  # ── StreamData generators ───────────────────────────────────────────

  @doc "A generator-function body: a non-empty block of statements."
  def gen_body, do: block(2)

  @doc """
  A body with no send/throw-sensitive constructs (only plain yields, logs,
  `for`, `try`, `yield from`) — safe to drive with `list()`, a comprehension,
  and a manual loop and expect identical results. Used for metamorphic checks.
  """
  def gen_pure_body, do: block(2, pure: true)

  @doc "A driver: a bounded sequence of protocol operations."
  def gen_driver do
    list_of(
      one_of([
        constant(:next),
        constant(:next),
        map(small_int(), &{:send, &1}),
        map(member_of(@exceptions), &{:throw, &1}),
        constant(:close)
      ]),
      min_length: 1,
      max_length: 6
    )
  end

  defp small_int, do: integer(-9..9)
  defp count, do: integer(0..3)

  # Cleanup-only statements for `finally` bodies: side effects, never control
  # flow that could interact with GeneratorExit.
  defp tame_block(depth) do
    list_of(tame_stmt(depth), min_length: 1, max_length: 2)
  end

  defp tame_stmt(0), do: map(small_int(), &{:log, &1})

  defp tame_stmt(depth) do
    one_of([
      map(small_int(), &{:log, &1}),
      bind({count(), tame_block(depth - 1)}, fn {n, b} -> constant({:for, n, b}) end)
    ])
  end

  # A block is a list of 1..3 statements at the given recursion budget.
  defp block(depth, opts \\ []) do
    list_of(stmt(depth, opts), min_length: 1, max_length: 3)
  end

  defp stmt(0, _opts) do
    one_of([
      map(small_int(), &{:log, &1}),
      map(small_int(), &{:yield, &1}),
      map(small_int(), &{:recv, &1}),
      map(small_int(), &{:return, &1})
    ])
  end

  defp stmt(depth, opts) do
    leaves =
      if opts[:pure] do
        [map(small_int(), &{:log, &1}), map(small_int(), &{:yield, &1})]
      else
        [
          map(small_int(), &{:log, &1}),
          map(small_int(), &{:yield, &1}),
          map(small_int(), &{:recv, &1}),
          map(small_int(), &{:return, &1})
        ]
      end

    nested = [
      bind({count(), block(depth - 1, opts)}, fn {n, b} -> constant({:for, n, b}) end),
      # `finally` is restricted to cleanup-only statements (logs / bounded
      # for-of-logs). `yield`/`return` inside a `finally` are a deprecated
      # SyntaxWarning construct and let a generator swallow GeneratorExit
      # ("generator ignored GeneratorExit"), whose only observable is a
      # nondeterministic GC-time message on stderr — out of scope for this
      # generator. The lazy-`finally`-on-close behavior itself is still
      # exercised (the try body yields; the finally cleans up).
      bind({block(depth - 1, opts), tame_block(depth - 1)}, fn {b, f} ->
        constant({:try_finally, b, f})
      end),
      bind({block(depth - 1, opts), small_int()}, fn {b, r} ->
        constant({:yield_from, b, r})
      end)
    ]

    nested =
      if opts[:pure] do
        nested
      else
        [
          bind({member_of(@exceptions), block(depth - 1, opts), block(depth - 1, opts)}, fn
            {e, b, h} -> constant({:try_except, e, b, h})
          end)
          | nested
        ]
      end

    one_of(leaves ++ nested)
  end

  # ── Rendering: (body, driver) → self-contained Python source ─────────

  @doc """
  Render a program that defines a generator from `body`, runs `driver`
  against it, and prints an interleaved trace: each side effect (`log`) and
  each op result on its own line. Running this under CPython and Pyex and
  comparing stdout is the trace-level conformance check.
  """
  @spec render(term(), [term()]) :: String.t()
  def render(body, driver) do
    {body_lines, _next} = render_block(body, 1, 0)

    """
    def log(x):
        print("L", x)
    def g():
    #{Enum.join(body_lines, "\n")}
    it = g()
    #{driver |> Enum.map(&render_op/1) |> Enum.join("\n")}
    # Deterministically finalize a still-suspended generator via the protocol
    # (close runs its finally). CPython would otherwise run that finally only
    # when GC reclaims the abandoned generator at interpreter shutdown — a
    # nondeterministic, separate concern from generator protocol semantics.
    try:
        it.close()
    except Exception:
        pass
    """
  end

  @doc """
  Render the same generator consumed three equivalent ways (`mode`):

    * `:listing`     — `list(g())`
    * `:comprehension` — `[x for x in g()]`
    * `:manual`      — a `while True: next(...)` loop until `StopIteration`

  All three must print the identical yielded sequence. `body` should come
  from `gen_pure_body/0`.
  """
  @spec render_metamorphic(term(), :listing | :comprehension | :manual) :: String.t()
  def render_metamorphic(body, mode) do
    {body_lines, _next} = render_block(body, 1, 0)

    drive =
      case mode do
        :listing ->
          "print(list(g()))"

        :comprehension ->
          "print([x for x in g()])"

        :manual ->
          """
          acc = []
          it = g()
          while True:
              try:
                  acc.append(next(it))
              except StopIteration:
                  break
          print(acc)
          """
      end

    """
    def log(x):
        print("L", x)
    def g():
    #{Enum.join(body_lines, "\n")}
    #{drive}
    """
  end

  # Render a driver op into a self-tracing snippet (caught, never escapes).
  defp render_op(:next), do: op_wrap("next(it)", "next")
  defp render_op({:send, v}), do: op_wrap("it.send(#{v})", "send(#{v})")
  defp render_op({:throw, e}), do: op_wrap("it.throw(#{e})", "throw(#{e})")

  defp render_op(:close) do
    """
    try:
        it.close()
        print("close ->", "ok")
    except Exception as _e:
        print("close ->", type(_e).__name__)
    """
    |> String.trim_trailing()
  end

  defp op_wrap(call, label) do
    """
    try:
        print("#{label} ->", #{call})
    except StopIteration as _e:
        print("#{label} -> stop", _e.value)
    except Exception as _e:
        print("#{label} -> exc", type(_e).__name__)
    """
    |> String.trim_trailing()
  end

  # ── AST → Python lines (indent-aware, sub-generators inlined) ────────
  #
  # Returns {lines, next_subgen_id}. `indent` is a 0-based nesting level;
  # every line is prefixed with 4 spaces per level.

  defp render_block(stmts, indent, sub_id) do
    {rev_lines, next_id} =
      Enum.reduce(stmts, {[], sub_id}, fn s, {acc, id} ->
        {lines, id2} = render_stmt(s, indent, id)
        {Enum.reverse(lines, acc), id2}
      end)

    {Enum.reverse(rev_lines), next_id}
  end

  defp pad(indent), do: String.duplicate("    ", indent)

  defp render_stmt({:log, n}, indent, id), do: {["#{pad(indent)}log(#{n})"], id}
  defp render_stmt({:yield, n}, indent, id), do: {["#{pad(indent)}yield #{n}"], id}
  defp render_stmt({:recv, n}, indent, id), do: {["#{pad(indent)}log((yield #{n}))"], id}
  defp render_stmt({:return, n}, indent, id), do: {["#{pad(indent)}return #{n}"], id}

  defp render_stmt({:for, n, block}, indent, id) do
    {inner, id2} = render_block_or_pass(block, indent + 1, id)
    {["#{pad(indent)}for _i in range(#{n}):" | inner], id2}
  end

  defp render_stmt({:try_finally, block, fin}, indent, id) do
    {b, id2} = render_block_or_pass(block, indent + 1, id)
    {f, id3} = render_block_or_pass(fin, indent + 1, id2)
    {["#{pad(indent)}try:" | b] ++ ["#{pad(indent)}finally:" | f], id3}
  end

  defp render_stmt({:try_except, exc, block, handler}, indent, id) do
    {b, id2} = render_block_or_pass(block, indent + 1, id)
    {h, id3} = render_block_or_pass(handler, indent + 1, id2)
    {["#{pad(indent)}try:" | b] ++ ["#{pad(indent)}except #{exc}:" | h], id3}
  end

  defp render_stmt({:yield_from, sub_block, ret}, indent, id) do
    name = "_sub#{id}"
    {sub_lines, id2} = render_block_or_pass(sub_block, indent + 1, id + 1)

    lines =
      ["#{pad(indent)}def #{name}():" | sub_lines] ++
        ["#{pad(indent + 1)}return #{ret}"] ++
        ["#{pad(indent)}yield from #{name}()"]

    {lines, id2}
  end

  defp render_block_or_pass([], indent, id), do: {["#{pad(indent)}pass"], id}
  defp render_block_or_pass(stmts, indent, id), do: render_block(stmts, indent, id)

  # ── Running + comparison ─────────────────────────────────────────────

  @doc """
  Run `source` through CPython and Pyex; assert identical stdout (the
  interleaved trace). Skips silently if CPython itself rejects the program
  (a generation bug, not a Pyex bug).
  """
  @spec assert_trace_conforms(String.t()) :: :ok
  def assert_trace_conforms(source) do
    import ExUnit.Assertions

    case run_cpython(source) do
      {:ok, cpython} ->
        pyex = run_pyex(source)

        assert pyex == {:ok, cpython},
               """
               Generator trace mismatch.

               source:
               #{indent(source)}

               CPython trace:
               #{indent(cpython)}

               Pyex result:
               #{indent(inspect(pyex))}
               """

        :ok

      {:error, _} ->
        # Generated program CPython itself rejects — skip (not a Pyex bug).
        :ok
    end
  end

  @doc """
  Metamorphic check for a side-effect-free `body`: `list(g())`,
  `[x for x in g()]`, and a manual `next`-until-`StopIteration` loop must all
  produce the identical result — in Pyex *and* in CPython (so the relation is
  verified both as an oracle-free engine invariant and against the spec).
  Skips if CPython rejects the generated program.
  """
  @spec assert_metamorphic(term()) :: :ok
  def assert_metamorphic(body) do
    import ExUnit.Assertions

    modes = [:listing, :comprehension, :manual]
    sources = Map.new(modes, &{&1, render_metamorphic(body, &1)})

    case run_cpython(sources[:listing]) do
      {:error, _} ->
        :ok

      {:ok, _} ->
        results =
          Enum.flat_map(modes, fn mode ->
            src = sources[mode]
            [{:cpython, mode, run_cpython(src)}, {:pyex, mode, run_pyex(src)}]
          end)

        outputs = Enum.map(results, fn {_engine, _mode, r} -> r end)

        assert outputs |> Enum.uniq() |> length() == 1,
               """
               Metamorphic mismatch: list / comprehension / manual-next diverged.

               body:
               #{indent(inspect(body))}

               results (engine, mode, output):
               #{Enum.map_join(results, "\n", fn {e, m, r} -> "    #{e}/#{m}: #{inspect(r)}" end)}
               """

        :ok
    end
  end

  @doc "Total `ctx.steps` to fully drain `source` (run with a high finite step cap so the counter advances)."
  @spec drain_steps(String.t()) :: non_neg_integer()
  def drain_steps(source) do
    {:ok, _v, ctx} = Pyex.run(source, limits: [max_steps: 100_000_000, timeout: 30_000])
    ctx.steps
  end

  defp run_cpython(source) do
    # Capture stdout only: CPython emits SyntaxWarnings and GC-time
    # ("Exception ignored while closing generator") noise on stderr that is
    # nondeterministic and not part of the trace we compare.
    case System.cmd(@python3, ["-W", "ignore", "-c", source], stderr_to_stdout: false) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, _} -> {:error, String.trim_trailing(output)}
    end
  end

  defp run_pyex(source) do
    case Pyex.run(source, Pyex.Ctx.new(timeout: 5_000)) do
      {:ok, _, ctx} ->
        {:ok, ctx |> Pyex.output() |> IO.iodata_to_binary() |> String.trim_trailing()}

      {:error, err} ->
        {:error, err.exception_type || err.message}
    end
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end
end
