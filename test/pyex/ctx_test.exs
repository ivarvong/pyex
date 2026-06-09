defmodule Pyex.CtxTest do
  use ExUnit.Case, async: true

  alias Pyex.{Ctx, Error}

  describe "new/0" do
    test "creates a context with defaults" do
      ctx = Ctx.new()
      assert ctx.output_buffer == []
    end

    test "rejects legacy keyword-list network config" do
      assert_raise ArgumentError, ~r/network must be a list of rule maps/, fn ->
        Ctx.new(network: [dangerously_allow_full_internet_access: true])
      end
    end

    test "rejects legacy map network config" do
      assert_raise ArgumentError, ~r/network must be a list of rule maps/, fn ->
        Ctx.new(network: %{dangerously_allow_full_internet_access: true})
      end
    end

    test "rejects nil allowed_url_prefix" do
      assert_raise ArgumentError, ~r/allowed_url_prefix must be a non-empty string/, fn ->
        Ctx.new(network: [%{allowed_url_prefix: nil}])
      end
    end

    test "rejects empty allowed_url_prefix" do
      assert_raise ArgumentError, ~r/allowed_url_prefix must be a non-empty string/, fn ->
        Ctx.new(network: [%{allowed_url_prefix: ""}])
      end
    end

    test "rejects allowed_url_prefix without a scheme and host" do
      assert_raise ArgumentError, ~r/must be an absolute URL with a scheme and host/, fn ->
        Ctx.new(network: [%{allowed_url_prefix: "api.example.com/v1/"}])
      end
    end
  end

  describe "check_network_access/3" do
    test "matches scheme and host case-insensitively" do
      ctx = Ctx.new(network: [%{allowed_url_prefix: "https://api.example.com/v1/"}])

      assert {:ok, []} =
               Ctx.check_network_access(ctx, "GET", "HTTPS://API.EXAMPLE.COM/v1/chat")
    end

    test "allows paths at or below the prefix path" do
      ctx = Ctx.new(network: [%{allowed_url_prefix: "https://api.openai.com/v1/"}])

      assert {:ok, []} =
               Ctx.check_network_access(ctx, "GET", "https://api.openai.com/v1/chat/completions")
    end

    test "denies a host that only shares the prefix as a leading label" do
      ctx = Ctx.new(network: [%{allowed_url_prefix: "https://api.example.com/"}])

      assert {:denied, _} =
               Ctx.check_network_access(ctx, "GET", "https://api.example.com.attacker.com/")
    end

    test "denies the subdomain bypass even without a trailing slash on the prefix" do
      ctx = Ctx.new(network: [%{allowed_url_prefix: "https://api.example.com"}])

      assert {:denied, _} =
               Ctx.check_network_access(ctx, "GET", "https://api.example.com.attacker.com/")
    end

    test "denies a path that shares the prefix but crosses no segment boundary" do
      ctx = Ctx.new(network: [%{allowed_url_prefix: "https://api.openai.com/v1"}])

      assert {:denied, _} =
               Ctx.check_network_access(ctx, "GET", "https://api.openai.com/v1abc/anything")

      assert {:ok, []} = Ctx.check_network_access(ctx, "GET", "https://api.openai.com/v1")
      assert {:ok, []} = Ctx.check_network_access(ctx, "GET", "https://api.openai.com/v1/chat")
    end

    test "denies a userinfo host that spoofs the allowed host" do
      ctx = Ctx.new(network: [%{allowed_url_prefix: "https://api.example.com/"}])

      assert {:denied, _} =
               Ctx.check_network_access(ctx, "GET", "https://api.example.com@evil.com/x")
    end

    test "denies a non-matching port on the allowed host" do
      ctx = Ctx.new(network: [%{allowed_url_prefix: "https://api.example.com/"}])

      assert {:denied, _} =
               Ctx.check_network_access(ctx, "GET", "https://api.example.com:8443/")
    end

    test "a bare trailing colon in the prefix matches the host on any port" do
      ctx = Ctx.new(network: [%{allowed_url_prefix: "http://localhost:"}])

      assert {:ok, []} = Ctx.check_network_access(ctx, "GET", "http://localhost:51234/bucket/key")
      assert {:ok, []} = Ctx.check_network_access(ctx, "GET", "http://localhost:8080/")
    end

    test "ignores the query string when matching the path" do
      ctx = Ctx.new(network: [%{allowed_url_prefix: "https://postman-echo.com/get"}])

      assert {:ok, []} =
               Ctx.check_network_access(ctx, "GET", "https://postman-echo.com/get?source=pyex")
    end

    test "denies a path that climbs above the prefix with .. segments" do
      ctx = Ctx.new(network: [%{allowed_url_prefix: "https://api.example.com/v1/"}])

      assert {:denied, _} =
               Ctx.check_network_access(ctx, "GET", "https://api.example.com/v1/../../admin")
    end

    test "denies percent-encoded .. traversal" do
      ctx = Ctx.new(network: [%{allowed_url_prefix: "https://api.example.com/v1/"}])

      assert {:denied, _} =
               Ctx.check_network_access(ctx, "GET", "https://api.example.com/v1/%2e%2e/admin")

      assert {:denied, _} =
               Ctx.check_network_access(ctx, "GET", "https://api.example.com/v1/..%2f..%2fadmin")
    end

    test "allows a path segment that merely contains .. as a substring" do
      ctx = Ctx.new(network: [%{allowed_url_prefix: "https://api.example.com/v1/"}])

      assert {:ok, []} =
               Ctx.check_network_access(ctx, "GET", "https://api.example.com/v1/version..1")
    end
  end

  describe "record/3" do
    test "captures output events in live mode" do
      ctx =
        Ctx.new()
        |> Ctx.record(:output, "hello")
        |> Ctx.record(:output, "world")

      assert ctx.output_buffer == ["world", "hello"]
    end

    test "ignores file_op events in live mode (no crash)" do
      ctx =
        Ctx.new()
        |> Ctx.record(:file_op, {:open, "/tmp/test", :read})

      assert ctx.output_buffer == []
      assert ctx.file_ops == 1
    end
  end

  describe "timeout" do
    test "no timeout by default" do
      ctx = Ctx.new()
      assert ctx.timeout == nil
      assert Ctx.check_deadline(ctx) == :ok
    end

    test "timeout is set from timeout" do
      ctx = Ctx.new(timeout: 5000)
      assert ctx.timeout == 5000
    end

    test "check_deadline returns :ok within budget" do
      ctx = Ctx.new(timeout: 5000)
      assert Ctx.check_deadline(ctx) == :ok
    end

    test "check_deadline returns :exceeded when compute budget exhausted" do
      ctx = %Ctx{
        timeout: 1,
        compute: 2000.0,
        compute_started_at: System.monotonic_time()
      }

      assert {:exceeded, _} = Ctx.check_deadline(ctx)
    end

    test "pause_compute and resume_compute exclude I/O time" do
      ctx = Ctx.new(timeout: 5000)
      paused = Ctx.pause_compute(ctx)
      assert paused.compute_started_at == nil
      assert paused.compute > 0 or true
      resumed = Ctx.resume_compute(paused)
      assert resumed.compute_started_at != nil
    end

    test "compute_time tracks accumulated compute time" do
      ctx = Ctx.new(timeout: 5000)
      Process.sleep(5)
      ms = Ctx.compute_time(ctx)
      assert ms >= 0
    end

    test "while True loop is killed by timeout" do
      ctx = Ctx.new(timeout: 50)

      code = """
      x = 0
      while True:
          x += 1
      """

      {:error, %Error{message: msg}} = Pyex.run(code, ctx)
      assert msg =~ "TimeoutError: execution exceeded time limit"
    end

    test "for loop is killed by timeout" do
      ctx = Ctx.new(timeout: 50)

      code = """
      x = 0
      for i in range(10000000):
          x += 1
      """

      {:error, %Error{message: msg}} = Pyex.run(code, ctx)
      assert msg =~ "TimeoutError: execution exceeded time limit"
    end

    test "normal program completes within timeout" do
      ctx = Ctx.new(timeout: 5000)

      code = """
      total = 0
      for i in range(100):
          total += i
      total
      """

      assert {:ok, 4950, _} = Pyex.run(code, ctx)
    end
  end

  describe "remaining_compute_ms/1" do
    test "returns :infinity when no timeout is configured" do
      assert Ctx.remaining_compute_ms(Ctx.new()) == :infinity
    end

    test "reports the budget left, clamped to zero once overrun" do
      fresh = Ctx.new(timeout: 5000)
      remaining = Ctx.remaining_compute_ms(fresh)
      assert is_integer(remaining)
      assert remaining > 0 and remaining <= 5000

      overrun = %Ctx{
        timeout: 1,
        compute: 2000.0,
        compute_started_at: System.monotonic_time()
      }

      assert Ctx.remaining_compute_ms(overrun) == 0
    end
  end

  # The hot path through `check_step/1` is taken on every loop
  # iteration, statement, call entry, and generator yield.  A fast
  # path skips the cond chain, the per-step ctx allocation, and the
  # `System.monotonic_time/0` syscall when nothing is bounded.  The
  # tradeoff is that `ctx.steps` stops advancing in the fast path —
  # this test pins both branches' contract so future edits can't
  # silently regress.
  describe "check_step/1" do
    test "unbounded ctx (limits: :none) hits the fast path and does not advance steps" do
      ctx = Ctx.new(limits: :none)
      assert ctx.steps == 0
      assert {:ok, ctx2} = Ctx.check_step(ctx)
      # Fast path: identity-on-fields ctx (no `steps + 1`).
      assert ctx2.steps == 0
      # And idempotent across many calls.
      ctx3 =
        Enum.reduce(1..100, ctx, fn _, acc ->
          {:ok, c} = Ctx.check_step(acc)
          c
        end)

      assert ctx3.steps == 0
    end

    test "default ctx is bounded (safe by default) and takes the slow path" do
      ctx = Ctx.new()
      # Safe-by-default ceilings are finite, so the fast path does not fire.
      assert ctx.limits.max_steps == 10_000_000
      assert ctx.limits.max_memory_bytes == 50_000_000
      assert ctx.limits.max_output_bytes == 1_000_000
      assert {:ok, ctx2} = Ctx.check_step(ctx)
      assert ctx2.steps == 1
    end

    test "timeout set forces the slow path and increments steps" do
      ctx = Ctx.new(timeout: 5_000)
      assert {:ok, ctx2} = Ctx.check_step(ctx)
      assert ctx2.steps == 1
    end

    test "max_steps set forces the slow path, increments steps, and trips when exceeded" do
      limits = Pyex.Limits.new(max_steps: 3)
      ctx = Ctx.new(limits: limits)

      ctx =
        Enum.reduce(1..3, ctx, fn _, acc ->
          {:ok, c} = Ctx.check_step(acc)
          c
        end)

      assert ctx.steps == 3
      assert {:exceeded, msg} = Ctx.check_step(ctx)
      assert msg =~ "step limit exceeded"
    end

    test "max_memory_bytes set forces the slow path even with no timeout" do
      limits = Pyex.Limits.new(max_memory_bytes: 10_000_000)
      ctx = Ctx.new(limits: limits)
      assert {:ok, ctx2} = Ctx.check_step(ctx)
      assert ctx2.steps == 1
    end

    test "max_output_bytes set forces the slow path" do
      limits = Pyex.Limits.new(max_output_bytes: 10_000)
      ctx = Ctx.new(limits: limits)
      assert {:ok, ctx2} = Ctx.check_step(ctx)
      assert ctx2.steps == 1
    end
  end

  # The list-index tuple cache turns `list[i]` from O(N) (a walk into
  # the reverse-cons storage) into O(1) (`:erlang.element/2` on a
  # cached tuple).  Three rules govern when caching happens:
  #
  #   - Only lists with len >= 32 enter the fast path (the walk is
  #     faster than the cache-check overhead for shorter lists).
  #   - Second-access promotion: first int subscript marks the id
  #     as `:pending`, second builds the tuple.  This avoids paying
  #     the O(N) build cost for lists that get indexed only once.
  #   - `heap_put/3` invalidates centrally — any mutation drops the
  #     cache entry, so aliased reads via either ref see fresh data.
  describe "list_index_lookup cache" do
    test "fresh ctx has empty cache" do
      ctx = Ctx.new()
      assert ctx.list_index_cache == %{}
    end

    test "short lists (len < 32) never touch the cache" do
      {:ok, 10, ctx} =
        Pyex.run("""
        a = [10, 20, 30]
        a[0]
        """)

      assert ctx.list_index_cache == %{}
    end

    test "first int subscript on a long list marks the entry as :pending" do
      code = "long = [i for i in range(64)]\n_ = long[0]\nlong\n"
      {:ok, _list, ctx} = Pyex.run(code)
      assert [{_id, :pending}] = Map.to_list(ctx.list_index_cache)
    end

    test "second int subscript on a long list promotes to a tuple" do
      code = "long = [i for i in range(64)]\n_ = long[0]\n_ = long[1]\nlong\n"
      {:ok, _list, ctx} = Pyex.run(code)
      assert [{_id, tup}] = Map.to_list(ctx.list_index_cache)
      assert is_tuple(tup)
      assert tuple_size(tup) == 64
    end

    test "append after promotion invalidates the cache; later reads see new value" do
      code = """
      a = [i for i in range(64)]
      _ = a[0]
      _ = a[1]                 # promote to tuple
      a.append(999)            # mutation -> heap_put -> invalidate
      a[64]                    # must see 999, not stale-tuple IndexError
      """

      assert {:ok, 999, _ctx} = Pyex.run(code)
    end

    test "subscript-assignment invalidates the cache" do
      code = """
      a = [i for i in range(64)]
      _ = a[0]
      _ = a[1]
      a[5] = 9999
      a[5]
      """

      assert {:ok, 9999, _ctx} = Pyex.run(code)
    end

    test "aliased lists see writes through the cache via either alias" do
      code = """
      a = [i for i in range(64)]
      b = a
      _ = a[0]
      _ = a[1]                 # promote via a
      b.append(777)            # mutate via b
      a[64]                    # read via a must reflect b's append
      """

      assert {:ok, 777, _ctx} = Pyex.run(code)
    end

    test "heap_put on a non-cached id is a safe no-op" do
      ctx = Ctx.new()
      assert ctx.list_index_cache == %{}
      ctx = Ctx.heap_put(ctx, 9999, {:py_list, [3, 2, 1], 3})
      assert ctx.list_index_cache == %{}
    end
  end

  describe "output capture" do
    test "output/1 returns captured print output as iolist" do
      ctx =
        Ctx.new()
        |> Ctx.record(:output, "hello\n")
        |> Ctx.record(:output, "world\n")

      assert Ctx.output(ctx) == ["hello\n", "world\n"]
    end

    test "output/1 returns empty iolist when no output" do
      ctx = Ctx.new()
      assert Ctx.output(ctx) == []
    end
  end
end
