defmodule Pyex.TurnPurityTest do
  @moduledoc """
  Proves the `Pyex.Turn` contract — that a `Pyex.run` is a pure function of
  `(source, ctx)` whose entire footprint is the returned `ctx'`, plus the
  honest boundaries of that claim (ambient entropy/time).

  This is the contract every host layer (a Durable Object, a worker pool)
  relies on for atomic commit-on-success and replay. It also proves the
  observability tooling: the `[:pyex, :run, :stop]` telemetry footprint is a
  faithful, deterministic summary of the turn — purity you can *see*.

  Structural backstops live elsewhere: `Pyex.BannedCallTracer` already proves
  pyex owns no process/global state and does no host I/O. These tests prove
  the *behavioural* consequences.
  """

  use ExUnit.Case, async: false

  alias Pyex.Storage

  describe "caller isolation — a turn cannot leak into the host" do
    test "a run leaks nothing into the caller's process dictionary beyond the documented ambient :rand seed" do
      before = Process.get() |> Keyword.keys() |> MapSet.new()
      {:ok, _v, _ctx} = Pyex.run("x = [i*i for i in range(100)]\nprint(sum(x))")
      new_keys = Process.get() |> Keyword.keys() |> MapSet.new() |> MapSet.difference(before)

      # The only keys a run may add are behaviorally inert:
      #  * :"$decimal_context" — pyex restores the Decimal context to the caller's
      #    prior *value*; if the caller had none, a default-valued key remains,
      #    which is identical to unset (Process.* is banned, so it can't be cleared).
      #  * :rand_seed — OTP's lazy per-process entropy seed; the ambient-entropy
      #    gap `Pyex.Turn`'s determinism boundary documents.
      assert MapSet.subset?(new_keys, MapSet.new([:"$decimal_context", :rand_seed]))
    end

    test "the caller's Decimal context is restored even though the run sets it" do
      saved = Decimal.Context.get()

      {:ok, _v, _ctx} =
        Pyex.run("from decimal import Decimal\nprint(Decimal('1.1') + Decimal('2.2'))")

      assert Decimal.Context.get() == saved
    end
  end

  describe "footprint == ctx — the turn's whole effect is the returned context" do
    test "the input ctx value is unchanged after a run (immutability)" do
      ctx = Pyex.Ctx.new(filesystem: %{"/seed.txt" => "v0"})
      {:ok, _v, _ctx2} = Pyex.run("print(open('/seed.txt').read())", ctx)
      # The host still holds exactly what it passed in.
      assert {:ok, "v0"} = Pyex.FS.read(ctx.filesystem, "/seed.txt")
    end

    test "two runs of the same (source, ctx) produce identical results and state" do
      src = """
      total = 0
      for i in range(50):
          total += i
      print(total)
      open('/out.txt', 'w').write(str(total))
      """

      ctx = Pyex.Ctx.new(filesystem: %{})
      {:ok, v1, c1} = Pyex.run(src, ctx)
      {:ok, v2, c2} = Pyex.run(src, ctx)

      assert v1 == v2
      assert Pyex.output(c1) == Pyex.output(c2)
      assert Pyex.FS.read(c1.filesystem, "/out.txt") == Pyex.FS.read(c2.filesystem, "/out.txt")
    end
  end

  describe "atomicity — a failed turn commits nothing" do
    test "an error leaves the host's input filesystem untouched" do
      ctx = Pyex.Ctx.new(filesystem: %{"/db.csv" => "id\n1\n"})

      assert {:error, _} =
               Pyex.run(
                 """
                 open('/db.csv', 'w').write('id\\n')   # truncate working copy
                 raise RuntimeError('boom')
                 """,
                 ctx
               )

      # The committed state the host holds is intact — nothing was persisted.
      assert {:ok, "id\n1\n"} = Pyex.FS.read(ctx.filesystem, "/db.csv")
    end

    test "an error leaves the host's input storage untouched" do
      backend = Storage.Memory.new(%{"k" => "1"})
      ctx = Pyex.Ctx.new(storage: backend)

      assert {:error, _} =
               Pyex.run(
                 """
                 import store
                 store.set('k', 999)
                 raise RuntimeError('boom')
                 """,
                 ctx
               )

      assert {:ok, "1"} = Storage.get(ctx.storage, "k")
    end
  end

  describe "replay convergence" do
    test "re-running a failed turn from the prior committed state converges" do
      ctx = Pyex.Ctx.new(filesystem: %{"/n.txt" => "1"})

      attempt = """
      n = int(open('/n.txt').read())
      if n < 2:
          raise RuntimeError('not ready')
      print('ok', n)
      """

      # First attempt fails; host keeps prior state and retries from it.
      assert {:error, _} = Pyex.run(attempt, ctx)
      ctx = Pyex.Ctx.new(filesystem: %{"/n.txt" => "2"})
      assert {:ok, _v, c} = Pyex.run(attempt, ctx)
      assert Pyex.output(c) == "ok 2\n"
    end
  end

  describe "turn isolation under true parallelism" do
    test "many concurrent turns with separate contexts do not interfere" do
      results =
        1..50
        |> Task.async_stream(
          fn i ->
            ctx = Pyex.Ctx.new(filesystem: %{})
            {:ok, _v, c} = Pyex.run("print(#{i} * #{i})", ctx)
            String.trim(Pyex.output(c))
          end,
          max_concurrency: 16
        )
        |> Enum.map(fn {:ok, out} -> out end)

      assert results == Enum.map(1..50, fn i -> Integer.to_string(i * i) end)
    end
  end

  describe "determinism boundary (honest negative)" do
    test "entropy-free programs are deterministic across runs" do
      src = "print(sorted([3, 1, 2]), {'a': 1, 'b': 2})"
      assert Pyex.run!(src) == Pyex.run!(src)
    end

    test "time.time() reads the ambient clock, so such a turn is NOT replay-safe" do
      # Documents the known boundary: time/random/uuid/secrets are ambient
      # today, not context-provided, so a turn using them is non-deterministic.
      # Full replay-safety wants a context clock/seed (see Pyex.Turn).
      src = "import time\nprint(time.time())"
      {:ok, _v, c1} = Pyex.run(src)
      Process.sleep(2)
      {:ok, _v, c2} = Pyex.run(src)
      assert Pyex.output(c1) != Pyex.output(c2)
    end
  end

  describe "observability — the footprint is a faithful, deterministic summary" do
    setup do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "turn-purity-#{inspect(ref)}",
        [:pyex, :run, :stop],
        fn _event, measurements, _meta, _cfg -> send(parent, {:footprint, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("turn-purity-#{inspect(ref)}") end)
      :ok
    end

    defp footprint_of(src, opts \\ []) do
      {:ok, _v, _c} = Pyex.run(src, opts)
      assert_received {:footprint, fp}
      fp
    end

    test "a turn's effects show up in its footprint" do
      printing = footprint_of("print('hello world')")
      assert printing.output_bytes > 0

      writing = footprint_of("open('/x.txt', 'w').write('data')", filesystem: %{})
      assert writing.file_ops > 0

      silent = footprint_of("x = 1 + 1")
      assert silent.output_bytes == 0
    end

    test "two identical pure turns emit identical footprints" do
      src = "print(sum(range(1000)))"
      a = footprint_of(src)
      b = footprint_of(src)

      # The *work* counters are a deterministic function of the turn; only the
      # timing fields (duration_ms, compute) vary with the wall clock.
      drop_timing = &Map.drop(&1, [:duration_ms, :compute])
      assert drop_timing.(a) == drop_timing.(b)
    end
  end
end
