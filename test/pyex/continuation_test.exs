defmodule Pyex.ContinuationTest do
  @moduledoc """
  Stress tests for the continuation-based generator system.

  Every test runs the generator both eagerly (via Pyex.run) and
  lazily through Lambda.handle_stream to verify that continuations
  produce identical results to eager execution.
  """
  use ExUnit.Case, async: true

  alias Pyex.Lambda

  defp run!(source) do
    {:ok, result, _ctx} = Pyex.run(source)
    result
  end

  defp stream_chunks!(source) do
    app_source =
      """
      import fastapi
      from fastapi.responses import StreamingResponse

      app = fastapi.FastAPI()

      @app.get("/test")
      def test_handler():
      """ <>
        indent(source) <>
        """
            return StreamingResponse(gen(), media_type="text/plain")
        """

    {:ok, app} = Lambda.boot(app_source)
    {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/test"})
    Enum.to_list(resp.chunks)
  end

  defp indent(source) do
    source
    |> String.split("\n")
    |> Enum.map(fn line ->
      if String.trim(line) == "", do: "", else: "    " <> line
    end)
    |> Enum.join("\n")
  end

  defp assert_both(python_gen_body, expected) do
    eager_source = """
    #{python_gen_body}
    list(gen())
    """

    eager_result = run!(eager_source)
    assert eager_result == expected, "eager mismatch: #{inspect(eager_result)}"

    stream_result = stream_chunks!(python_gen_body)
    stream_expected = Enum.map(expected, &to_string/1)
    assert stream_result == stream_expected, "stream mismatch: #{inspect(stream_result)}"
  end

  describe "nested for loops" do
    test "2D grid yield" do
      assert_both(
        """
        def gen():
            for i in range(3):
                for j in range(4):
                    yield i * 10 + j
        """,
        for(i <- 0..2, j <- 0..3, do: i * 10 + j)
      )
    end

    test "3D nested for loops" do
      assert_both(
        """
        def gen():
            for i in range(2):
                for j in range(3):
                    for k in range(2):
                        yield i * 100 + j * 10 + k
        """,
        for(i <- 0..1, j <- 0..2, k <- 0..1, do: i * 100 + j * 10 + k)
      )
    end

    test "nested for with work between yields" do
      assert_both(
        """
        def gen():
            for i in range(3):
                total = 0
                for j in range(i + 1):
                    total += j
                yield total
                for j in range(i + 1):
                    yield i * 10 + j
        """,
        [0, 0, 1, 10, 11, 3, 20, 21, 22]
      )
    end

    test "yield before, inside, and after nested for" do
      assert_both(
        """
        def gen():
            yield "start"
            for i in range(2):
                yield "outer-" + str(i)
                for j in range(2):
                    yield "inner-" + str(i) + "-" + str(j)
                yield "end-outer-" + str(i)
            yield "done"
        """,
        [
          "start",
          "outer-0",
          "inner-0-0",
          "inner-0-1",
          "end-outer-0",
          "outer-1",
          "inner-1-0",
          "inner-1-1",
          "end-outer-1",
          "done"
        ]
      )
    end
  end

  describe "while loops" do
    test "while with break" do
      assert_both(
        """
        def gen():
            i = 0
            while True:
                if i >= 5:
                    break
                yield i
                i += 1
        """,
        [0, 1, 2, 3, 4]
      )
    end

    test "while with continue" do
      assert_both(
        """
        def gen():
            i = 0
            while i < 10:
                i += 1
                if i % 3 == 0:
                    continue
                yield i
        """,
        [1, 2, 4, 5, 7, 8, 10]
      )
    end

    test "while with break and continue combined" do
      assert_both(
        """
        def gen():
            i = 0
            while True:
                i += 1
                if i > 8:
                    break
                if i % 2 == 0:
                    continue
                yield i
        """,
        [1, 3, 5, 7]
      )
    end

    test "nested while loops" do
      assert_both(
        """
        def gen():
            i = 0
            while i < 3:
                j = 0
                while j < 3:
                    yield i * 10 + j
                    j += 1
                i += 1
        """,
        [0, 1, 2, 10, 11, 12, 20, 21, 22]
      )
    end
  end

  describe "for with break and continue" do
    test "for with break" do
      assert_both(
        """
        def gen():
            for i in range(100):
                if i >= 5:
                    break
                yield i
        """,
        [0, 1, 2, 3, 4]
      )
    end

    test "for with continue" do
      assert_both(
        """
        def gen():
            for i in range(10):
                if i % 2 == 0:
                    continue
                yield i
        """,
        [1, 3, 5, 7, 9]
      )
    end

    test "nested for with inner break" do
      assert_both(
        """
        def gen():
            for i in range(3):
                for j in range(10):
                    if j >= 2:
                        break
                    yield i * 10 + j
        """,
        [0, 1, 10, 11, 20, 21]
      )
    end
  end

  describe "yield in conditionals" do
    test "yield in both if and else branches" do
      assert_both(
        """
        def gen():
            for i in range(6):
                if i % 2 == 0:
                    yield "even-" + str(i)
                else:
                    yield "odd-" + str(i)
        """,
        ["even-0", "odd-1", "even-2", "odd-3", "even-4", "odd-5"]
      )
    end

    test "yield in if/elif/else" do
      assert_both(
        """
        def gen():
            for i in range(9):
                if i % 3 == 0:
                    yield "fizz"
                elif i % 3 == 1:
                    yield "one"
                else:
                    yield "two"
        """,
        ["fizz", "one", "two", "fizz", "one", "two", "fizz", "one", "two"]
      )
    end

    test "conditional yield (some iterations skip)" do
      assert_both(
        """
        def gen():
            for i in range(10):
                if i * i > 20:
                    yield i
        """,
        [5, 6, 7, 8, 9]
      )
    end

    test "multiple yields in one branch" do
      assert_both(
        """
        def gen():
            for i in range(3):
                if i % 2 == 0:
                    yield i
                    yield i * 10
                else:
                    yield -i
        """,
        [0, 0, -1, 2, 20]
      )
    end
  end

  describe "mutation between yields" do
    test "accumulator pattern" do
      assert_both(
        """
        def gen():
            total = 0
            for i in range(5):
                total += i * i
                yield total
        """,
        [0, 1, 5, 14, 30]
      )
    end

    test "list building between yields" do
      assert_both(
        """
        def gen():
            items = []
            for i in range(4):
                items.append(i)
                yield len(items)
        """,
        [1, 2, 3, 4]
      )
    end

    test "dict mutation between yields" do
      assert_both(
        """
        def gen():
            counts = {}
            words = ["a", "b", "a", "c", "b", "a"]
            for w in words:
                counts[w] = counts.get(w, 0) + 1
                yield counts[w]
        """,
        [1, 1, 2, 1, 2, 3]
      )
    end

    test "string accumulation" do
      assert_both(
        """
        def gen():
            s = ""
            for c in "hello":
                s += c
                yield s
        """,
        ["h", "he", "hel", "hell", "hello"]
      )
    end

    test "fibonacci via augmented assignment" do
      assert_both(
        """
        def gen():
            a, b = 0, 1
            for i in range(10):
                yield a
                a, b = b, a + b
        """,
        [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
      )
    end
  end

  describe "generator calling generator" do
    test "manual iteration via for loop" do
      assert_both(
        """
        def inner(n):
            for i in range(n):
                yield i * i

        def gen():
            for x in inner(3):
                yield x + 100
            for x in inner(2):
                yield x + 200
        """,
        [100, 101, 104, 200, 201]
      )
    end

    test "nested generator delegation" do
      assert_both(
        """
        def numbers(start, end):
            for i in range(start, end):
                yield i

        def gen():
            for n in numbers(0, 3):
                for m in numbers(10, 13):
                    yield n * 100 + m
        """,
        [10, 11, 12, 110, 111, 112, 210, 211, 212]
      )
    end

    test "generator consuming generator with filter" do
      assert_both(
        """
        def all_numbers():
            for i in range(20):
                yield i

        def gen():
            for n in all_numbers():
                if n > 3 and n < 8:
                    yield n
        """,
        [4, 5, 6, 7]
      )
    end
  end

  describe "yield from" do
    test "yield from string" do
      assert_both(
        """
        def gen():
            yield from "abcde"
        """,
        ["a", "b", "c", "d", "e"]
      )
    end

    test "yield from multiple sources in sequence" do
      assert_both(
        """
        def gen():
            yield from [1, 2, 3]
            yield from [4, 5, 6]
            yield from [7, 8, 9]
        """,
        [1, 2, 3, 4, 5, 6, 7, 8, 9]
      )
    end

    test "yield from another generator" do
      assert_both(
        """
        def inner():
            yield 10
            yield 20
            yield 30

        def gen():
            yield 1
            yield from inner()
            yield 2
        """,
        [1, 10, 20, 30, 2]
      )
    end

    test "yield from chained generators" do
      assert_both(
        """
        def a():
            yield 1
            yield 2

        def b():
            yield 3
            yield 4

        def gen():
            yield from a()
            yield 99
            yield from b()
        """,
        [1, 2, 99, 3, 4]
      )
    end

    test "yield from in a loop" do
      assert_both(
        """
        def chunk(start):
            for i in range(start, start + 3):
                yield i

        def gen():
            for s in [0, 10, 20]:
                yield from chunk(s)
        """,
        [0, 1, 2, 10, 11, 12, 20, 21, 22]
      )
    end

    test "deeply nested yield from (3 levels)" do
      assert_both(
        """
        def level3():
            yield "c1"
            yield "c2"

        def level2():
            yield "b1"
            yield from level3()
            yield "b2"

        def gen():
            yield "a1"
            yield from level2()
            yield "a2"
        """,
        ["a1", "b1", "c1", "c2", "b2", "a2"]
      )
    end

    test "yield from dict yields keys" do
      result =
        run!("""
        def gen():
            yield from {"x": 1, "y": 2, "z": 3}
        sorted(list(gen()))
        """)

      assert result == ["x", "y", "z"]
    end

    test "yield from generator expression" do
      assert_both(
        """
        def gen():
            yield from (x * x for x in range(5))
        """,
        [0, 1, 4, 9, 16]
      )
    end
  end

  describe "exception mid-stream" do
    test "exception after some yields propagates" do
      source = """
      def gen():
          yield 1
          yield 2
          raise ValueError("boom")
          yield 3

      results = []
      try:
          for x in gen():
              results.append(x)
      except ValueError as e:
          results.append(str(e))
      results
      """

      assert run!(source) == [1, 2, "boom"]
    end

    test "exception in nested generator" do
      source = """
      def inner():
          yield "a"
          raise RuntimeError("fail")
          yield "b"

      def outer():
          yield "start"
          yield from inner()
          yield "end"

      results = []
      try:
          for x in outer():
              results.append(x)
      except RuntimeError as e:
          results.append("caught: " + str(e))
      results
      """

      assert run!(source) == ["start", "a", "caught: fail"]
    end

    test "streaming exception returns 500 detail" do
      source = """
      import fastapi
      from fastapi.responses import StreamingResponse

      app = fastapi.FastAPI()

      @app.get("/test")
      def test_handler():
          def gen():
              yield "ok"
              raise ValueError("exploded")
          return StreamingResponse(gen(), media_type="text/plain")
      """

      {:ok, app} = Lambda.boot(source)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/test"})

      chunks = Enum.to_list(resp.chunks)
      assert hd(chunks) == "ok"
      assert length(chunks) == 2
      error_chunk = Jason.decode!(Enum.at(chunks, 1))
      assert error_chunk["detail"] =~ "ValueError"
    end
  end

  describe "try/except inside generator" do
    test "yield inside try" do
      assert_both(
        """
        def gen():
            for i in range(5):
                try:
                    if i == 3:
                        raise ValueError("skip")
                    yield i
                except ValueError:
                    yield -1
        """,
        [0, 1, 2, -1, 4]
      )
    end

    test "yield inside both try and except" do
      assert_both(
        """
        def gen():
            for x in [1, 0, 2, 0, 3]:
                try:
                    yield 100 // x
                except ZeroDivisionError:
                    yield -1
        """,
        [100, -1, 50, -1, 33]
      )
    end
  end

  describe "closures and scope" do
    test "generator closes over outer variable" do
      assert_both(
        """
        def make_gen(multiplier):
            def gen():
                for i in range(5):
                    yield i * multiplier
            return gen

        g = make_gen(7)
        def gen():
            yield from g()
        """,
        [0, 7, 14, 21, 28]
      )
    end

    test "generator closes over list from outer scope" do
      assert_both(
        """
        def make_gen():
            items = [10, 20, 30, 40, 50]
            def gen():
                for item in items:
                    yield item + 1
            return gen

        g = make_gen()
        def gen():
            yield from g()
        """,
        [11, 21, 31, 41, 51]
      )
    end
  end

  describe "interleaved generators" do
    test "two generators consumed alternately" do
      result =
        run!("""
        def evens():
            n = 0
            while n < 10:
                yield n
                n += 2

        def odds():
            n = 1
            while n < 10:
                yield n
                n += 2

        e = iter(evens())
        o = iter(odds())
        results = []
        for i in range(5):
            results.append(next(e))
            results.append(next(o))
        results
        """)

      assert result == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    end

    test "three generators round-robin" do
      result =
        run!("""
        def counter(start, step, count):
            n = start
            for _ in range(count):
                yield n
                n += step

        a = iter(counter(0, 3, 6))
        b = iter(counter(1, 3, 6))
        c = iter(counter(2, 3, 6))
        results = []
        for i in range(6):
            results.append(next(a))
            results.append(next(b))
            results.append(next(c))
        results
        """)

      assert result == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]
    end
  end

  describe "large and complex generators" do
    test "100 chunks through streaming" do
      source = """
      def gen():
          for i in range(100):
              yield str(i)
      """

      chunks = stream_chunks!(source)
      assert length(chunks) == 100
      assert hd(chunks) == "0"
      assert List.last(chunks) == "99"
    end

    test "500 chunks through streaming" do
      source = """
      def gen():
          for i in range(500):
              yield str(i)
      """

      chunks = stream_chunks!(source)
      assert length(chunks) == 500
      assert List.last(chunks) == "499"
    end

    test "complex pipeline: nested loops, conditionals, mutation" do
      assert_both(
        """
        def gen():
            matrix = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
            running = 0
            for row in matrix:
                for val in row:
                    running += val
                    if val % 2 == 0:
                        yield running
        """,
        [3, 10, 21, 36]
      )
    end

    test "sieve-like generator" do
      assert_both(
        """
        def gen():
            for n in range(2, 30):
                is_prime = True
                for d in range(2, n):
                    if n % d == 0:
                        is_prime = False
                        break
                if is_prime:
                    yield n
        """,
        [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
      )
    end

    test "flattening nested lists via yield from" do
      assert_both(
        """
        def gen():
            data = [[1, 2], [3], [4, 5, 6], [], [7]]
            for sublist in data:
                yield from sublist
        """,
        [1, 2, 3, 4, 5, 6, 7]
      )
    end

    test "generator producing structured data" do
      result =
        run!("""
        def gen():
            for i in range(4):
                yield {"id": i, "value": i * i}

        list(gen())
        """)

      assert result == [
               %{"id" => 0, "value" => 0},
               %{"id" => 1, "value" => 1},
               %{"id" => 2, "value" => 4},
               %{"id" => 3, "value" => 9}
             ]
    end
  end

  describe "edge cases" do
    test "generator that yields None" do
      result =
        run!("""
        def gen():
            yield None
            yield None
            yield None
        list(gen())
        """)

      assert result == [nil, nil, nil]
    end

    test "generator that yields empty strings" do
      assert_both(
        """
        def gen():
            yield ""
            yield ""
            yield "x"
        """,
        ["", "", "x"]
      )
    end

    test "generator with single yield" do
      assert_both(
        """
        def gen():
            yield 42
        """,
        [42]
      )
    end

    test "generator that conditionally never yields" do
      assert_both(
        """
        def gen():
            for i in range(10):
                if i > 100:
                    yield i
        """,
        []
      )
    end

    test "yield inside deeply nested if" do
      assert_both(
        """
        def gen():
            for i in range(20):
                if i > 5:
                    if i < 15:
                        if i % 2 == 0:
                            yield i
        """,
        [6, 8, 10, 12, 14]
      )
    end

    test "generator with return after some yields" do
      assert_both(
        """
        def gen():
            yield 1
            yield 2
            return
            yield 3
        """,
        [1, 2]
      )
    end

    test "generator with conditional return" do
      assert_both(
        """
        def gen():
            for i in range(100):
                yield i
                if i >= 4:
                    return
        """,
        [0, 1, 2, 3, 4]
      )
    end

    test "tuple unpacking in for loop inside generator" do
      assert_both(
        """
        def gen():
            pairs = [(1, 2), (3, 4), (5, 6)]
            for a, b in pairs:
                yield a + b
        """,
        [3, 7, 11]
      )
    end

    test "enumerate in generator" do
      assert_both(
        """
        def gen():
            for i, c in enumerate("abc"):
                yield str(i) + c
        """,
        ["0a", "1b", "2c"]
      )
    end
  end

  describe "streaming-specific continuation stress" do
    test "early halt after 1 of many chunks" do
      source = """
      import fastapi
      from fastapi.responses import StreamingResponse

      app = fastapi.FastAPI()

      @app.get("/test")
      def handler():
          def gen():
              for i in range(1000):
                  yield str(i) + "\\n"
          return StreamingResponse(gen(), media_type="text/plain")
      """

      {:ok, app} = Lambda.boot(source)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/test"})

      taken = Enum.take(resp.chunks, 3)
      assert taken == ["0\n", "1\n", "2\n"]
    end

    test "reduce_while stops mid-stream" do
      source = """
      import fastapi
      from fastapi.responses import StreamingResponse

      app = fastapi.FastAPI()

      @app.get("/test")
      def handler():
          def gen():
              for i in range(1000):
                  yield str(i)
          return StreamingResponse(gen(), media_type="text/plain")
      """

      {:ok, app} = Lambda.boot(source)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/test"})

      result =
        Enum.reduce_while(resp.chunks, [], fn chunk, acc ->
          n = String.to_integer(chunk)
          if n >= 10, do: {:halt, acc}, else: {:cont, acc ++ [n]}
        end)

      assert result == Enum.to_list(0..9)
    end

    test "multiple streaming requests reuse app" do
      source = """
      import fastapi
      from fastapi.responses import StreamingResponse

      app = fastapi.FastAPI()

      counter = [0]

      @app.get("/test")
      def handler():
          counter[0] += 1
          c = counter[0]
          def gen():
              for i in range(3):
                  yield str(c) + "-" + str(i)
          return StreamingResponse(gen(), media_type="text/plain")
      """

      {:ok, app} = Lambda.boot(source)

      {:ok, r1, app} = Lambda.handle_stream(app, %{method: "GET", path: "/test"})
      assert Enum.to_list(r1.chunks) == ["1-0", "1-1", "1-2"]

      {:ok, r2, app} = Lambda.handle_stream(app, %{method: "GET", path: "/test"})
      assert Enum.to_list(r2.chunks) == ["2-0", "2-1", "2-2"]

      {:ok, r3, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/test"})
      assert Enum.to_list(r3.chunks) == ["3-0", "3-1", "3-2"]
    end

    test "nested for loops through streaming" do
      source = """
      import fastapi
      from fastapi.responses import StreamingResponse

      app = fastapi.FastAPI()

      @app.get("/test")
      def handler():
          def gen():
              yield "<table>"
              for row in range(3):
                  yield "<tr>"
                  for col in range(4):
                      yield "<td>" + str(row) + "," + str(col) + "</td>"
                  yield "</tr>"
              yield "</table>"
          return StreamingResponse(gen(), media_type="text/html")
      """

      {:ok, app} = Lambda.boot(source)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/test"})

      chunks = Enum.to_list(resp.chunks)
      assert hd(chunks) == "<table>"
      assert List.last(chunks) == "</table>"

      html = Enum.join(chunks)
      assert html =~ "<tr><td>0,0</td><td>0,1</td><td>0,2</td><td>0,3</td></tr>"
      assert html =~ "<tr><td>2,0</td><td>2,1</td><td>2,2</td><td>2,3</td></tr>"
      assert String.starts_with?(html, "<table>")
      assert String.ends_with?(html, "</table>")
    end

    test "SSE events from generator" do
      source = """
      import fastapi
      from fastapi.responses import StreamingResponse
      import json

      app = fastapi.FastAPI()

      @app.get("/events")
      def events():
          def gen():
              for i in range(5):
                  data = json.dumps({"id": i, "msg": "event-" + str(i)})
                  yield "data: " + data + "\\n\\n"
          return StreamingResponse(gen(), media_type="text/event-stream")
      """

      {:ok, app} = Lambda.boot(source)
      {:ok, resp, _app} = Lambda.handle_stream(app, %{method: "GET", path: "/events"})

      assert resp.headers["content-type"] == "text/event-stream"
      chunks = Enum.to_list(resp.chunks)
      assert length(chunks) == 5

      Enum.each(Enum.with_index(chunks), fn {chunk, i} ->
        assert String.starts_with?(chunk, "data: ")
        json_str = chunk |> String.trim_leading("data: ") |> String.trim()
        parsed = Jason.decode!(json_str)
        assert parsed["id"] == i
        assert parsed["msg"] == "event-#{i}"
      end)
    end
  end
end
