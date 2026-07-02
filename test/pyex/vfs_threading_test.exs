defmodule Pyex.VFSThreadingTest do
  @moduledoc """
  Load-bearing proof that Pyex is a faithful `VFS.Mountable` host: it threads
  the (possibly mutated) backend back into `ctx.filesystem` through *every*
  operation, reads included.

  These use `Pyex.Test.CountingFS`, whose read-side ops mutate an observable
  counter exposed as `"/seq"`. Each test interleaves an operation with reads of
  `"/seq"`: the counter only advances past the bare reads if the operation's
  returned backend was threaded. Drop a single `fs'` on the read path and these
  fail.
  """
  use ExUnit.Case, async: true

  alias Pyex.Test.CountingFS

  defp run!(code, fs) do
    {:ok, value, ctx} = Pyex.run(code, filesystem: fs)
    {value, ctx}
  end

  # Reads `/seq` before and after `op`; threading means the counter advanced by
  # more than the two bare reads (i.e. op's own bumps were carried forward).
  defp threads?(op_code, fs) do
    code = """
    before = int(open("/seq").read())
    #{op_code}
    after = int(open("/seq").read())
    after - before
    """

    {delta, _ctx} = run!(code, fs)
    delta
  end

  describe "the counter itself proves threading is load-bearing" do
    test "sequential reads of /seq observe a strictly increasing counter" do
      code = """
      [int(open("/seq").read()) for _ in range(4)]
      """

      {value, _ctx} = run!(code, CountingFS.new())
      # 0, 1, 2, 3 — each open threads the bumped backend to the next.
      assert value == [0, 1, 2, 3]
    end

    test "the threaded counter is visible on the returned ctx.filesystem" do
      {_value, ctx} = run!(~s|open("/seq").read()|, CountingFS.new())
      # One read happened; the backend Pyex hands back reflects it.
      assert ctx.filesystem.n == 1
    end
  end

  describe "every Python read path threads the backend" do
    setup do
      {:ok, fs: CountingFS.new(%{"/a.txt" => "x", "/dir/b.txt" => "y"})}
    end

    test "open().read() threads", %{fs: fs} do
      assert threads?(~s|open("/a.txt").read()|, fs) > 1
    end

    test "os.path.isfile (stat) threads", %{fs: fs} do
      assert threads?("import os\nos.path.isfile('/a.txt')", fs) > 1
    end

    test "os.path.isdir (stat) threads", %{fs: fs} do
      assert threads?("import os\nos.path.isdir('/dir')", fs) > 1
    end

    test "os.path.exists threads", %{fs: fs} do
      assert threads?("import os\nos.path.exists('/a.txt')", fs) > 1
    end

    test "os.listdir (readdir) threads", %{fs: fs} do
      assert threads?("import os\nos.listdir('/dir')", fs) > 1
    end

    test "os.walk (readdir + stat) threads", %{fs: fs} do
      assert threads?("import os\nlist(os.walk('/dir'))", fs) > 1
    end

    test "glob.glob threads", %{fs: fs} do
      assert threads?("import glob\nglob.glob('/dir/*.txt')", fs) > 1
    end

    test "pathlib exists / is_file / is_dir thread", %{fs: fs} do
      assert threads?("from pathlib import Path\nPath('/a.txt').exists()", fs) > 1
      assert threads?("from pathlib import Path\nPath('/a.txt').is_file()", fs) > 1
      assert threads?("from pathlib import Path\nPath('/dir').is_dir()", fs) > 1
    end

    test "pathlib glob threads", %{fs: fs} do
      assert threads?("from pathlib import Path\nlist(Path('/dir').glob('*.txt'))", fs) > 1
    end

    test "shutil.copyfile (read + write) threads", %{fs: fs} do
      assert threads?("import shutil\nshutil.copyfile('/a.txt', '/c.txt')", fs) > 1
    end
  end

  describe "writes also leave ctx.filesystem current" do
    test "a write is visible on the threaded backend afterward" do
      code = """
      open("/out.txt", "w").write("data")
      """

      {_value, ctx} = run!(code, CountingFS.new())
      assert {:ok, "data", _} = VFS.read_file(ctx.filesystem, "/out.txt")
    end
  end

  describe "Pyex.Filesystem.Overlay threads reads through to its layers" do
    alias Pyex.Filesystem.Overlay

    test "a read served by lower threads lower's bumped state back" do
      ov = Overlay.new(CountingFS.new(%{"/a.txt" => "x"}))

      assert {:ok, "x", ov} = VFS.read_file(ov, "/a.txt")
      assert ov.lower.n == 1

      # A second read against the returned overlay keeps threading forward —
      # proves the bumped `lower` was carried in `ov`, not discarded.
      assert {:ok, "x", ov} = VFS.read_file(ov, "/a.txt")
      assert ov.lower.n == 2
    end

    test "a read served by upper never touches lower" do
      ov = Overlay.new(CountingFS.new(%{"/a.txt" => "x"}))
      {:ok, ov} = VFS.write_file(ov, "/a.txt", "staged")

      assert {:ok, "staged", ov} = VFS.read_file(ov, "/a.txt")
      # upper (plain VFS.Memory) served it; lower's counter never advanced.
      assert ov.lower.n == 0
    end

    test "a read masked by a whiteout is denied without touching lower again" do
      ov = Overlay.new(CountingFS.new(%{"/a.txt" => "x"}))
      {:ok, ov} = VFS.rm(ov, "/a.txt", [])
      n_after_rm = ov.lower.n

      assert {:error, %VFS.Error{kind: :enoent}} = VFS.read_file(ov, "/a.txt")
      # The whiteout short-circuits before consulting lower a second time.
      assert ov.lower.n == n_after_rm
    end

    test "materialize/2 recurses into both layers and threads both back" do
      ov = Overlay.new(CountingFS.new(), CountingFS.new())

      assert {:ok, ov} = VFS.materialize(ov, [])
      assert ov.lower.n == 1
      assert ov.upper.n == 1
    end
  end
end
