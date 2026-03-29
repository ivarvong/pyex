defmodule Pyex.AdversarialTest do
  use ExUnit.Case, async: true

  @moduletag :adversarial

  describe "step limits" do
    test "infinite while loop is stopped" do
      assert {:error, %Pyex.Error{kind: :limit, limit: :steps}} =
               Pyex.run("while True: pass", limits: [max_steps: 1_000])
    end

    test "recursive call bomb is stopped" do
      code = """
      def f(n): return f(n+1)
      f(0)
      """

      assert {:error, %Pyex.Error{kind: kind}} = Pyex.run(code, limits: [max_steps: 1_000])
      assert kind in [:limit, :python]
    end

    test "comprehension bomb is stopped" do
      code = "[x for x in range(1000000)]"

      assert {:error, %Pyex.Error{kind: :limit, limit: :steps}} =
               Pyex.run(code, limits: [max_steps: 5_000])
    end

    test "nested generator chain is stopped" do
      code = """
      def g(n):
          if n > 0: yield from g(n-1)
          yield n
      list(g(1000000))
      """

      assert {:error, %Pyex.Error{kind: kind}} = Pyex.run(code, limits: [max_steps: 5_000])
      assert kind in [:limit, :python]
    end

    test "for loop with huge range is stopped" do
      code = """
      s = 0
      for i in range(1000000):
          s += i
      """

      assert {:error, %Pyex.Error{kind: :limit, limit: :steps}} =
               Pyex.run(code, limits: [max_steps: 1_000])
    end

    test "normal program completes within step budget" do
      code = """
      total = 0
      for i in range(10):
          total += i
      total
      """

      assert {:ok, 45, _ctx} = Pyex.run(code, limits: [max_steps: 1_000])
    end
  end

  describe "memory limits" do
    test "exponential string growth is stopped" do
      code = """
      s = 'a'
      while True:
          s = s + s
      """

      assert {:error, %Pyex.Error{kind: kind}} =
               Pyex.run(code, limits: [max_memory_bytes: 100_000, max_steps: 100_000])

      assert kind in [:limit, :python]
    end

    test "list multiplication bomb is stopped" do
      code = """
      x = [0] * 1000
      x = x * 1000
      x = x * 1000
      """

      assert {:error, %Pyex.Error{kind: kind}} =
               Pyex.run(code, limits: [max_memory_bytes: 1_000_000, max_steps: 100_000])

      assert kind in [:limit, :python]
    end

    test "dict merge bomb is stopped" do
      code = """
      d = {}
      for i in range(100000):
          d[i] = i
      """

      assert {:error, %Pyex.Error{kind: kind}} =
               Pyex.run(code, limits: [max_memory_bytes: 500_000, max_steps: 500_000])

      assert kind in [:limit, :python]
    end

    test "small program completes within memory budget" do
      code = """
      data = [i * 2 for i in range(100)]
      sum(data)
      """

      assert {:ok, 9900, _ctx} = Pyex.run(code, limits: [max_memory_bytes: 1_000_000])
    end
  end

  describe "output limits" do
    test "print flood is stopped" do
      code = """
      while True:
          print('x' * 10000)
      """

      result = Pyex.run(code, limits: [max_output_bytes: 50_000, max_steps: 100_000])

      case result do
        {:error, %Pyex.Error{kind: :limit, limit: :output}} -> :ok
        {:error, %Pyex.Error{kind: :limit, limit: :steps}} -> :ok
        other -> flunk("Expected limit error, got: #{inspect(other)}")
      end
    end

    test "normal print completes within output budget" do
      code = """
      for i in range(10):
          print(i)
      """

      assert {:ok, _, _ctx} = Pyex.run(code, limits: [max_output_bytes: 1_000])
    end
  end

  describe "timeout integration" do
    test "timeout inside limits supersedes top-level" do
      code = "while True: pass"

      # limits timeout of 50ms should take effect, not the 10_000ms top-level
      result = Pyex.run(code, timeout: 10_000, limits: [timeout: 50])

      assert {:error, %Pyex.Error{kind: :timeout}} = result
    end

    test "top-level timeout still works without limits" do
      code = "while True: pass"

      result = Pyex.run(code, timeout: 50)

      assert {:error, %Pyex.Error{kind: :timeout}} = result
    end
  end

  describe "combined limits" do
    test "multiple limits — whichever triggers first wins" do
      code = """
      s = ""
      for i in range(1000000):
          s += str(i)
      """

      assert {:error, %Pyex.Error{kind: :limit}} =
               Pyex.run(code,
                 limits: [
                   max_steps: 10_000,
                   max_memory_bytes: 1_000_000,
                   max_output_bytes: 1_000_000
                 ]
               )
    end

    test "Pyex.Limits struct works directly" do
      limits = %Pyex.Limits{max_steps: 100}

      assert {:error, %Pyex.Error{kind: :limit, limit: :steps}} =
               Pyex.run("while True: pass", limits: limits)
    end
  end

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
      # This should return {:error, _}, never raise
      result = Pyex.run("while True: pass", limits: [max_steps: 100])
      assert {:error, %Pyex.Error{}} = result
    end
  end
end
