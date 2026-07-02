defmodule Pyex.Storage.OverlayTest do
  @moduledoc """
  The staging overlay: a copy-on-write `Pyex.Storage` backend for dry-running
  effects. The load-bearing test is *soundness* — that the capability ledger
  you preview under an overlay is byte-for-byte the ledger that commits, so a
  policy gate on the preview has no time-of-check/time-of-use gap.
  """
  use ExUnit.Case, async: true

  alias Pyex.Storage.{Memory, Overlay}

  # Reads an existing value, writes derived ones (incl. a read-your-writes
  # update over a *staged* value), deletes a pre-existing key, and lists a
  # prefix — exercising get / set / delete / keys against the overlay.
  @program """
  import store
  bal = store.get("acct:1")["bal"]                              # 100 (seed)
  store.set("acct:1", {"bal": bal + 50})                        # update
  store.set("acct:2", {"bal": 0})                               # new
  store.delete("seed:stale")                                     # delete a seed key
  store.set("acct:1", {"bal": store.get("acct:1")["bal"] + 1})  # read-your-write on staged value
  print(sorted(store.keys("acct:")))                             # sees the overlay
  """

  defp seed do
    %{
      "acct:1" => Jason.encode!(%{"bal" => 100}),
      "seed:stale" => Jason.encode!(%{"x" => 1}),
      "seed:keep" => Jason.encode!(%{"y" => 2})
    }
  end

  test "the previewed ledger equals the committed ledger (sound, no TOCTOU)" do
    # Dry-run against an overlay — writes are staged, nothing hits the backend.
    {:ok, _v, dry} = Pyex.run(@program, storage: Overlay.new(Memory.new(seed())), seed: 7)

    # Commit-run: same program, same seed, writing for real.
    {:ok, _v, direct} = Pyex.run(@program, storage: Memory.new(seed()), seed: 7)

    # The property that makes preview-then-commit safe: what you approve is
    # exactly what runs. The unforgeable capability ledger is identical...
    assert Pyex.Ctx.runtime_spans(dry) == Pyex.Ctx.runtime_spans(direct)
    # ...and so is the observable output.
    assert Pyex.output(dry) == Pyex.output(direct)

    # The ledger isn't empty — the equality above is meaningful.
    ops = dry |> Pyex.Ctx.runtime_spans() |> Enum.map(& &1.name)
    assert "db.set" in ops and "db.get" in ops and "db.delete" in ops
  end

  test "a dry-run touches nothing until commit, then commits to the same state" do
    base = Memory.new(seed())
    {:ok, _v, dry} = Pyex.run(@program, storage: Overlay.new(base), seed: 7)

    # Side-effect-free: the backend the overlay wraps is untouched.
    assert dry.storage.inner.data == seed()

    # The staged effects are inspectable before committing — the unit a policy
    # gate decides on.
    pending = Overlay.pending(dry.storage)
    assert Map.has_key?(pending.writes, "acct:1")
    assert Map.has_key?(pending.writes, "acct:2")
    assert "seed:stale" in pending.deletes

    # Committing yields the identical final state as having run for real.
    {:ok, _v, direct} = Pyex.run(@program, storage: Memory.new(seed()), seed: 7)
    {:ok, committed} = Overlay.commit(dry.storage)
    assert committed.data == direct.storage.data

    # And the net effect is what we expect: acct:1 = 100+50+1, acct:2 = 0,
    # the stale key gone, the kept key intact.
    assert Jason.decode!(committed.data["acct:1"]) == %{"bal" => 151}
    assert Jason.decode!(committed.data["acct:2"]) == %{"bal" => 0}
    refute Map.has_key?(committed.data, "seed:stale")
    assert Map.has_key?(committed.data, "seed:keep")
  end

  test "reads pass through; writes, deletes, and listing reflect the overlay" do
    base = Memory.new(%{"a" => "1", "b" => "2"})
    ov = Overlay.new(base)

    assert Pyex.Storage.get(ov, "a") == {:ok, "1"}

    {:ok, ov} = Pyex.Storage.put(ov, "a", "99")
    {:ok, ov} = Pyex.Storage.put(ov, "c", "3")
    {:ok, ov} = Pyex.Storage.delete(ov, "b")

    assert Pyex.Storage.get(ov, "a") == {:ok, "99"}
    assert Pyex.Storage.get(ov, "c") == {:ok, "3"}
    assert Pyex.Storage.get(ov, "b") == :miss
    assert Pyex.Storage.list_prefix(ov, "") == {:ok, ["a", "c"]}
    assert Pyex.Storage.scan_prefix(ov, "") == {:ok, [{"a", "99"}, {"c", "3"}]}

    # The inner backend never changed.
    assert base.data == %{"a" => "1", "b" => "2"}

    {:ok, committed} = Overlay.commit(ov)
    assert committed.data == %{"a" => "99", "c" => "3"}
  end
end
