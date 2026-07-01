defmodule Pyex.Filesystem.OverlayTest do
  @moduledoc """
  The staging overlay for the filesystem capability: a copy-on-write
  `VFS.Mountable` for dry-running writes. Filesystem ops don't carry a
  capability-ledger span (unlike `store`/`requests`/DynamoDB), so the
  load-bearing soundness signal here is *output and final-state equality*
  between a run staged under the overlay and a run applied directly — a
  policy gate on the preview has no time-of-check/time-of-use gap.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pyex.Filesystem.Overlay
  alias VFS.Mountable

  defp seed do
    %{
      "README.md" => "hi",
      "notes.txt" => "seed",
      "stale.txt" => "delete me",
      "old_dir/a.txt" => "a",
      "old_dir/b.txt" => "b"
    }
  end

  # Reads an existing file, writes a new one under a new directory, appends to
  # a pre-existing file, mkdir -p's a nested directory, removes a pre-existing
  # file, `shutil.rmtree`s a pre-existing directory, then writes a fresh file
  # back under that removed directory's path — exercising read / write /
  # append / mkdir / rm / rmtree / recreate-after-whiteout against the overlay.
  @program """
  import os
  import shutil

  with open("README.md") as f:
      original = f.read()

  with open("data/report.txt", "w") as f:
      f.write("hello")

  with open("notes.txt", "a") as f:
      f.write(" appended")

  os.makedirs("archive/2026", exist_ok=True)
  with open("archive/2026/note.txt", "w") as f:
      f.write("archived")

  os.remove("stale.txt")
  shutil.rmtree("old_dir")

  with open("old_dir/reborn.txt", "w") as f:
      f.write("reborn")

  names = sorted(os.listdir("."))
  reborn_dir = sorted(os.listdir("old_dir"))
  print(original, names, reborn_dir)
  """

  test "the previewed run reproduces the same output and final state as the committed run" do
    {:ok, _v, dry} =
      Pyex.run(@program, filesystem: Overlay.new(Pyex.FS.from_map(seed())), seed: 3)

    {:ok, _v, direct} = Pyex.run(@program, filesystem: Pyex.FS.from_map(seed()), seed: 3)

    assert Pyex.output(dry) == Pyex.output(direct)

    {:ok, committed} = Overlay.commit(dry.filesystem)

    for path <- [
          "README.md",
          "notes.txt",
          "data/report.txt",
          "archive/2026/note.txt",
          "old_dir/reborn.txt"
        ] do
      assert Pyex.FS.read(committed, path) == Pyex.FS.read(direct.filesystem, path)
    end

    refute Pyex.FS.exists?(committed, "stale.txt")
    refute Pyex.FS.exists?(committed, "old_dir/a.txt")
    refute Pyex.FS.exists?(committed, "old_dir/b.txt")
    assert Pyex.FS.list_dir(committed, "old_dir") == {:ok, ["reborn.txt"]}
  end

  test "a dry-run touches nothing until commit; diff/1 reports staged changes before commit" do
    base = Pyex.FS.from_map(seed())
    {:ok, _v, dry} = Pyex.run(@program, filesystem: Overlay.new(base), seed: 3)

    # Side-effect-free: the backend the overlay wraps is untouched.
    assert Pyex.FS.read(base, "stale.txt") == {:ok, "delete me"}
    assert Pyex.FS.exists?(base, "old_dir/a.txt")

    diff = Overlay.diff(dry.filesystem)
    assert "/data/report.txt" in diff.added
    assert "/archive/2026/note.txt" in diff.added
    assert "/old_dir/reborn.txt" in diff.added
    assert "/notes.txt" in diff.modified
    assert "/stale.txt" in diff.deleted
    assert "/old_dir" in diff.deleted
    refute "/README.md" in diff.modified

    {:ok, _v, direct} = Pyex.run(@program, filesystem: Pyex.FS.from_map(seed()), seed: 3)
    {:ok, committed} = Overlay.commit(dry.filesystem)
    assert Pyex.FS.read(committed, "notes.txt") == Pyex.FS.read(direct.filesystem, "notes.txt")
  end

  test "reads pass through, upper wins over lower, and a whiteout masks lower until re-created" do
    base = VFS.Memory.new(%{"/a.txt" => "1", "/dir/b.txt" => "2", "/dir/c.txt" => "3"})
    ov = Overlay.new(base)

    assert VFS.read_file(ov, "/a.txt") == {:ok, "1", ov}

    {:ok, ov} = VFS.write_file(ov, "/a.txt", "99")
    assert VFS.read_file(ov, "/a.txt") |> elem(1) == "99"
    # The inner backend never changed (read-your-writes is staged, not applied).
    assert VFS.read_file(base, "/a.txt") == {:ok, "1", base}

    {:ok, ov} = VFS.rm(ov, "/dir/b.txt", [])
    assert {false, ov} = VFS.exists?(ov, "/dir/b.txt")
    assert {:ok, ["c.txt"], ov} = VFS.readdir(ov, "/dir")

    # rm on a non-empty directory without recursive: true fails, same as a
    # real backend, even though the directory only exists in `lower`.
    assert {:error, %VFS.Error{kind: :eisdir}} = VFS.rm(ov, "/dir", [])
    {:ok, ov} = VFS.rm(ov, "/dir", recursive: true)
    assert {false, ov} = VFS.exists?(ov, "/dir/c.txt")
    assert {:error, %VFS.Error{kind: :enoent}} = VFS.readdir(ov, "/dir")

    # Writing a fresh file back under the whited-out directory resurrects it
    # without resurrecting the old, still-deleted sibling.
    {:ok, ov} = VFS.write_file(ov, "/dir/new.txt", "fresh")
    assert VFS.readdir(ov, "/dir") == {:ok, ["new.txt"], ov}

    # mkdir on a path that already exists (via `lower`) is :eexist, exactly
    # as a plain backend would report for a path it alone can see.
    assert {:error, %VFS.Error{kind: :eexist}} = VFS.mkdir(ov, "/a.txt", [])

    {:ok, committed} = Overlay.commit(ov)
    assert VFS.read_file(committed, "/a.txt") == {:ok, "99", committed}
    assert VFS.readdir(committed, "/dir") == {:ok, ["new.txt"], committed}
  end

  test "walk/3 (the VFS.Skeleton default) recurses through the overlay's own stat/readdir" do
    # Neither `diff/1` nor `commit/1` ever calls `walk/3` on the overlay
    # itself (only on `upper` alone) -- this is the only coverage of the
    # Skeleton-composed default actually dispatching through this module's
    # `stat/2` and `readdir/2`, not just exercising them individually.
    lower = VFS.Memory.new(%{"/a.txt" => "1", "/dir/b.txt" => "2", "/dir/c.txt" => "3"})
    ov = Overlay.new(lower)

    {:ok, ov} = VFS.write_file(ov, "/dir/d.txt", "4")
    {:ok, ov} = VFS.rm(ov, "/dir/b.txt", [])

    files = ov |> VFS.walk("/", []) |> Enum.map(fn {path, _stat} -> path end) |> Enum.sort()
    assert files == ["/a.txt", "/dir/c.txt", "/dir/d.txt"]

    with_dirs =
      ov |> VFS.walk("/", include_dirs: true) |> Enum.map(fn {path, _stat} -> path end)

    assert "/dir" in with_dirs
  end

  describe "property: staging under the overlay is behaviorally identical to applying directly" do
    defp seg_gen, do: member_of(["a", "b", "c", "seed.txt", "keep", "keep.txt"])

    defp overlay_path_gen do
      gen all(depth <- integer(1..2), segs <- list_of(seg_gen(), length: depth)) do
        "/" <> Enum.join(segs, "/")
      end
    end

    defp overlay_op_gen do
      one_of([
        gen all(path <- overlay_path_gen(), content <- string(:alphanumeric, max_length: 4)) do
          {:write, path, content}
        end,
        gen all(path <- overlay_path_gen()) do
          {:mkdir, path}
        end,
        gen all(path <- overlay_path_gen()) do
          {:rm, path}
        end,
        gen all(path <- overlay_path_gen()) do
          {:rm_recursive, path}
        end
      ])
    end

    defp overlay_apply_op(backend, {:write, path, content}),
      do: Mountable.write_file(backend, path, content, [])

    defp overlay_apply_op(backend, {:mkdir, path}), do: Mountable.mkdir(backend, path, [])
    defp overlay_apply_op(backend, {:rm, path}), do: Mountable.rm(backend, path, [])

    defp overlay_apply_op(backend, {:rm_recursive, path}),
      do: Mountable.rm(backend, path, recursive: true)

    # On error the backend is unchanged (VFS's own contract), so the caller
    # keeps threading the same value forward regardless of the outcome.
    defp overlay_step(backend, op) do
      case overlay_apply_op(backend, op) do
        {:ok, backend} -> {:ok, backend}
        {:error, %VFS.Error{kind: kind}} -> {{:error, kind}, backend}
      end
    end

    # The observable filesystem, not the raw struct: `commit/1`'s `mkdir -p`
    # walk over `upper` can leave *more* directories explicit than a direct
    # run ever created, even though both are indistinguishable through the
    # protocol (VFS.Memory treats implicit and explicit dirs identically).
    defp overlay_snapshot(backend) do
      backend
      |> Mountable.walk("/", include_dirs: true)
      |> Enum.map(fn
        {path, %VFS.Stat{type: :directory}} ->
          {path, :directory}

        {path, %VFS.Stat{type: :regular}} ->
          {:ok, stream, _backend} = Mountable.stream_read(backend, path, [])
          {path, {:regular, Enum.into(stream, <<>>)}}
      end)
      |> Enum.sort()
    end

    property "a random write/mkdir/rm/rmtree sequence, staged then committed, matches direct" do
      check all(ops <- list_of(overlay_op_gen(), min_length: 1, max_length: 12), max_runs: 100) do
        seed = %{"/seed.txt" => "seed", "/keep/keep.txt" => "keep"}

        direct = VFS.Memory.new(seed)
        staged = Overlay.new(VFS.Memory.new(seed))

        {direct_final, staged_final} =
          Enum.reduce(ops, {direct, staged}, fn op, {direct, staged} ->
            {direct_result, direct} = overlay_step(direct, op)
            {staged_result, staged} = overlay_step(staged, op)

            assert direct_result == staged_result,
                   "op #{inspect(op)} diverged: direct=#{inspect(direct_result)} " <>
                     "staged=#{inspect(staged_result)}"

            {direct, staged}
          end)

        {:ok, committed} = Overlay.commit(staged_final)
        assert overlay_snapshot(committed) == overlay_snapshot(direct_final)
      end
    end
  end
end
