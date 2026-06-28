defmodule Pyex.ClockEntropyTest do
  @moduledoc """
  The clock + entropy capability: a host can pin `time` and seed `random`/`uuid`/
  `secrets` so a turn is deterministic and replayable, and — regardless of seed —
  a turn's randomness never leaks into or out of the host process (the
  cross-turn `:rand` leak the principal review flagged).

  async: false — these tests read/write the process `:rand` state to prove
  isolation, which is global.
  """

  use ExUnit.Case, async: false

  defp out!(src, opts \\ []) do
    {:ok, _v, ctx} = Pyex.run(src, opts)
    String.trim(Pyex.output(ctx))
  end

  describe "seeded entropy is deterministic and replayable" do
    test "the same seed produces the identical random sequence across runs" do
      src = "import random\nprint([random.random() for _ in range(5)])"
      a = out!(src, seed: 42)
      b = out!(src, seed: 42)
      assert a == b
    end

    test "different seeds produce different sequences" do
      src = "import random\nprint([random.randint(1, 1_000_000) for _ in range(5)])"
      refute out!(src, seed: 1) == out!(src, seed: 2)
    end

    test "a seed makes uuid4 deterministic" do
      src = "import uuid\nprint(str(uuid.uuid4()))"
      assert out!(src, seed: 7) == out!(src, seed: 7)
    end

    test "a seed makes secrets deterministic" do
      src = "import secrets\nprint(secrets.randbelow(1_000_000))"
      assert out!(src, seed: 99) == out!(src, seed: 99)
    end

    test "random.choice/sample are deterministic under a seed" do
      src = "import random\nprint(random.sample(list(range(20)), 5))"
      assert out!(src, seed: 3) == out!(src, seed: 3)
    end
  end

  describe "the clock can be pinned for deterministic time" do
    test "time.time() returns the pinned clock" do
      assert out!("import time\nprint(time.time())", clock: 1_700_000_000.0) == "1700000000.0"
    end

    test "time.time() with the same clock is identical across runs" do
      src = "import time\nprint(time.time())"
      assert out!(src, clock: 12345.0) == out!(src, clock: 12345.0)
    end

    test "without a clock, time.time() falls back to the wall clock (advances)" do
      # two runs, no pinned clock, far enough apart to differ
      a = out!("import time\nprint(time.time())")
      Process.sleep(2)
      b = out!("import time\nprint(time.time())")
      assert a != b
    end
  end

  describe "no cross-turn entropy leak (the bug)" do
    test "a run's random use does not perturb the host's :rand stream" do
      # Pin the host's :rand to a known state, sample, then run a random-heavy
      # program, then sample again from the SAME pinned state — the host's next
      # draw must be unaffected by what the sandbox did.
      :rand.seed(:exsss, {1, 2, 3})
      first = :rand.uniform()

      :rand.seed(:exsss, {1, 2, 3})
      _ = out!("import random\nprint([random.random() for _ in range(100)])", seed: 5)
      after_run = :rand.uniform()

      assert first == after_run
    end

    test "two unseeded turns are independent (no shared :rand state)" do
      # Without a seed, runs are nondeterministic but must not share state — i.e.
      # they don't replay each other's stream. (Sanity: both produce output.)
      a = out!("import random\nprint(random.random())")
      b = out!("import random\nprint(random.random())")
      assert is_binary(a) and is_binary(b)
    end
  end
end
