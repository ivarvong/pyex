defmodule Pyex.SuspendTest do
  use ExUnit.Case, async: true

  alias Pyex.{Builtins, Ctx, Interpreter, Lexer, Parser}

  defp parse!(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)
    ast
  end

  describe "event logging" do
    test "simple assignment records events" do
      ast = parse!("x = 1")
      {:ok, _val, _env, ctx} = Interpreter.run_with_ctx(ast, Builtins.env(), Ctx.new())
      events = Ctx.events(ctx)
      assert length(events) > 0

      types = Enum.map(events, fn {type, _step, _data} -> type end)
      assert :assign in types
    end

    test "if/else records branch events" do
      ast = parse!("x = 1\nif x == 1:\n    y = 2\nelse:\n    y = 3\ny")
      {:ok, 2, _env, ctx} = Interpreter.run_with_ctx(ast, Builtins.env(), Ctx.new())

      branch_events =
        Ctx.events(ctx)
        |> Enum.filter(fn {type, _, _} -> type == :branch end)

      assert length(branch_events) >= 1
    end

    test "for loop records loop_iter events" do
      ast = parse!("total = 0\nfor i in range(3):\n    total = total + i\ntotal")
      {:ok, 3, _env, ctx} = Interpreter.run_with_ctx(ast, Builtins.env(), Ctx.new())

      loop_events =
        Ctx.events(ctx)
        |> Enum.filter(fn {type, _, _} -> type == :loop_iter end)

      assert length(loop_events) == 3
    end

    test "function call records call_enter and call_exit" do
      code = """
      def add(a, b):
          return a + b
      add(1, 2)
      """

      ast = parse!(code)
      {:ok, 3, _env, ctx} = Interpreter.run_with_ctx(ast, Builtins.env(), Ctx.new())

      types = Enum.map(Ctx.events(ctx), fn {type, _, _} -> type end)
      assert :call_enter in types
      assert :call_exit in types
    end
  end

  describe "suspend" do
    test "suspend() stops execution and returns :suspended" do
      code = """
      x = 1
      suspend()
      x = 2
      x
      """

      ast = parse!(code)
      result = Interpreter.run_with_ctx(ast, Builtins.env(), Ctx.new())
      assert {:suspended, env, ctx} = result
      assert {:ok, 1} = Pyex.Env.get(env, "x")
      assert length(Ctx.events(ctx)) > 0
    end

    test "suspend mid-loop stops at that iteration" do
      code = """
      total = 0
      for i in range(10):
          if i == 3:
              suspend()
          total = total + i
      total
      """

      ast = parse!(code)
      {:suspended, env, _ctx} = Interpreter.run_with_ctx(ast, Builtins.env(), Ctx.new())
      assert {:ok, total} = Pyex.Env.get(env, "total")
      assert total == 0 + 1 + 2
    end

    test "suspend inside function" do
      code = """
      def work():
          x = 10
          suspend()
          return x + 1
      work()
      """

      ast = parse!(code)
      result = Interpreter.run_with_ctx(ast, Builtins.env(), Ctx.new())
      assert {:suspended, _env, _ctx} = result
    end
  end

  describe "for_resume round-trip" do
    test "ctx round-trips through for_resume" do
      code = """
      x = 42
      suspend()
      x
      """

      ast = parse!(code)
      {:suspended, _env, ctx} = Interpreter.run_with_ctx(ast, Builtins.env(), Ctx.new())

      restored = Ctx.for_resume(ctx)
      assert restored.mode == :replay
      assert restored.remaining == Ctx.events(ctx)
    end
  end

  describe "event log inspection" do
    test "log captures full execution trace" do
      code = """
      x = 0
      for i in range(3):
          if i > 0:
              x = x + i
      x
      """

      ast = parse!(code)
      {:ok, 3, _env, ctx} = Interpreter.run_with_ctx(ast, Builtins.env(), Ctx.new())

      events = Ctx.events(ctx)
      types = Enum.map(events, fn {type, _, _} -> type end)

      assert :assign in types
      assert :loop_iter in types
      assert :branch in types
      assert Enum.count(types, &(&1 == :loop_iter)) == 3
    end

    test "steps are monotonically increasing" do
      code = """
      x = 1
      y = 2
      z = x + y
      """

      ast = parse!(code)
      {:ok, _val, _env, ctx} = Interpreter.run_with_ctx(ast, Builtins.env(), Ctx.new())

      steps = Enum.map(Ctx.events(ctx), fn {_, step, _} -> step end)
      assert steps == Enum.sort(steps)
      assert steps == Enum.uniq(steps)
    end
  end

  describe "resume end-to-end" do
    test "suspend captures state for resume" do
      source = """
      x = 10
      suspend()
      x = x + 5
      x
      """

      ast = parse!(source)
      {:suspended, env, ctx} = Interpreter.run_with_ctx(ast, Builtins.env(), Ctx.new())
      assert {:ok, 10} = Pyex.Env.get(env, "x")

      restored = Ctx.for_resume(ctx)
      assert restored.mode == :replay
      assert restored.remaining == Ctx.events(ctx)
    end

    test "resume replays events from ctx and continues" do
      source = """
      x = 10
      suspend()
      x = x + 5
      x
      """

      {:suspended, ctx} = Pyex.run(source, Ctx.new())

      result = Pyex.resume(source, ctx)
      assert {:ok, 15, _ctx} = result
    end

    test "resume with for_resume creates replay context" do
      source = """
      x = 42
      y = x * 2
      suspend()
      z = x + y
      """

      {:suspended, ctx} = Pyex.run(source, Ctx.new())
      resume_ctx = Ctx.for_resume(ctx)
      assert resume_ctx.mode == :replay
      assert length(resume_ctx.remaining) > 0
    end

    test "suspend in loop captures iteration state" do
      source = """
      total = 0
      for i in range(5):
          if i == 2:
              suspend()
          total = total + i
      total
      """

      ast = parse!(source)
      {:suspended, env, ctx} = Interpreter.run_with_ctx(ast, Builtins.env(), Ctx.new())
      assert {:ok, total} = Pyex.Env.get(env, "total")
      assert total == 0 + 1

      events = Ctx.events(ctx)
      assert length(events) > 0
      types = Enum.map(events, fn {type, _, _} -> type end)
      assert :loop_iter in types
      assert :suspend in types
    end
  end

  describe "branch_at" do
    test "creates a truncated context for branching" do
      code = """
      x = 1
      y = 2
      z = 3
      """

      ast = parse!(code)
      {:ok, _val, _env, ctx} = Interpreter.run_with_ctx(ast, Builtins.env(), Ctx.new())

      all_events = Ctx.events(ctx)
      assert length(all_events) == 3

      branched = Ctx.branch_at(ctx, 2)
      assert length(Ctx.events(branched)) == 2
      assert branched.mode == :replay
    end
  end

  describe "resume skips suspend" do
    test "resume after suspend continues execution" do
      source = """
      x = 1
      suspend()
      x = x + 10
      x
      """

      {:suspended, ctx} = Pyex.run(source, Ctx.new())
      {:ok, result, _ctx} = Pyex.resume(source, ctx)
      assert result == 11
    end

    test "resume in loop continues from suspend point" do
      source = """
      total = 0
      for i in range(5):
          total += i
          if i == 2:
              suspend()
      total
      """

      {:suspended, ctx} = Pyex.run(source, Ctx.new())
      {:ok, result, _ctx} = Pyex.resume(source, ctx)
      assert result == 10
    end
  end
end
