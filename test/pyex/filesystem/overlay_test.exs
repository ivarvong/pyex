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

  alias Pyex.Filesystem.Overlay

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
end
