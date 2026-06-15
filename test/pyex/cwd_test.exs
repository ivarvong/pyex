defmodule Pyex.CwdTest do
  @moduledoc """
  Current-working-directory semantics: relative paths resolve against
  `ctx.cwd`, `os.getcwd`/`os.chdir` read and update it, and a shared `%VFS{}`
  threads through a run unchanged — the basis for sharing one filesystem with a
  shell that has its own cwd.
  """
  use ExUnit.Case, async: true

  defp run!(code, opts) do
    case Pyex.run(code, opts) do
      {:ok, value, ctx} -> {value, ctx}
      {:error, error} -> {:error, error.message}
    end
  end

  describe "relative paths resolve against cwd" do
    test "a relative open under a non-root cwd reads the cwd-joined path" do
      {value, _ctx} =
        run!(~s|open("data.txt").read()|,
          filesystem: %{"project/data.txt" => "hi"},
          cwd: "/project"
        )

      assert value == "hi"
    end

    test "an absolute open ignores the cwd" do
      {value, _ctx} =
        run!(~s|open("/project/data.txt").read()|,
          filesystem: %{"project/data.txt" => "hi"},
          cwd: "/project"
        )

      assert value == "hi"
    end

    test "a relative path under one cwd does not reach another cwd's file" do
      assert {:error, msg} =
               run!(~s|open("data.txt").read()|,
                 filesystem: %{"other/data.txt" => "x"},
                 cwd: "/project"
               )

      assert msg =~ "FileNotFoundError"
    end

    test "a relative write lands at the cwd-joined path" do
      {_value, ctx} =
        run!(~s|open("out.txt", "w").write("written")|, filesystem: %{}, cwd: "/project")

      assert {:ok, "written"} = Pyex.FS.read(ctx.filesystem, "/project/out.txt")
    end

    test "default cwd is the root" do
      {value, _ctx} = run!(~s|open("a.txt").read()|, filesystem: %{"a.txt" => "root"})
      assert value == "root"
    end

    test "os.listdir of a relative dir resolves against cwd" do
      code = """
      import os
      sorted(os.listdir("."))
      """

      {value, _ctx} =
        run!(code, filesystem: %{"project/a.txt" => "", "project/b.txt" => ""}, cwd: "/project")

      assert value == ["a.txt", "b.txt"]
    end
  end

  describe "os.getcwd / os.chdir" do
    test "os.getcwd returns the configured cwd" do
      code = """
      import os
      os.getcwd()
      """

      {value, _ctx} = run!(code, filesystem: %{}, cwd: "/project")
      assert value == "/project"
    end

    test "os.chdir updates the cwd and relative resolution follows it" do
      code = """
      import os
      os.chdir("sub")
      [os.getcwd(), open("note.txt").read()]
      """

      {value, _ctx} =
        run!(code, filesystem: %{"work/sub/note.txt" => "deep"}, cwd: "/work")

      assert value == ["/work/sub", "deep"]
    end

    test "os.chdir to an absolute directory replaces the cwd" do
      code = """
      import os
      os.chdir("/a/b")
      os.getcwd()
      """

      {value, _ctx} = run!(code, filesystem: %{"a/b/keep.txt" => ""})
      assert value == "/a/b"
    end

    test "os.chdir to a missing directory raises FileNotFoundError" do
      code = """
      import os
      os.chdir("nope")
      """

      assert {:error, msg} = run!(code, filesystem: %{})
      assert msg =~ "FileNotFoundError"
    end

    test "os.chdir onto a file raises NotADirectoryError" do
      code = """
      import os
      os.chdir("f.txt")
      """

      assert {:error, msg} = run!(code, filesystem: %{"f.txt" => "x"})
      assert msg =~ "NotADirectoryError"
    end

    test "the cwd persists on the returned ctx" do
      code = """
      import os
      os.chdir("/a")
      """

      {_value, ctx} = run!(code, filesystem: %{"a/x.txt" => ""})
      assert ctx.cwd == "/a"
    end
  end

  describe "shared %VFS{} threading" do
    test "a %VFS{} mount table threads through a run and comes back a %VFS{}" do
      vfs = VFS.new() |> VFS.mount("/", VFS.Memory.new(%{"/in.txt" => "from vfs\n"}))

      code = """
      data = open("/in.txt").read()
      open("/out.txt", "w").write(data.upper())
      """

      {_value, ctx} = run!(code, filesystem: vfs)

      assert %VFS{} = ctx.filesystem
      assert {:ok, "FROM VFS\n", _} = VFS.read_file(ctx.filesystem, "/out.txt")
    end

    test "a run with no writes still returns the same backend type" do
      vfs = VFS.new() |> VFS.mount("/", VFS.Memory.new(%{"/x" => "1"}))
      {value, ctx} = run!(~s|open("/x").read()|, filesystem: vfs)
      assert value == "1"
      assert %VFS{} = ctx.filesystem
    end
  end

  describe "multi-mount %VFS{} through the Python layer" do
    defp two_mounts do
      VFS.new()
      |> VFS.mount("/", VFS.Memory.new(%{"/root.txt" => "r"}))
      |> VFS.mount("/data", VFS.Memory.new(%{"/x.txt" => "data-x", "/sub/b.txt" => "B"}))
    end

    test "files under a mounted backend are readable and the mountpoint shows as a synthetic dir" do
      code = """
      import os
      [open("/data/x.txt").read(), open("/root.txt").read(), sorted(os.listdir("/"))]
      """

      {[data_x, root, root_listing], ctx} = run!(code, filesystem: two_mounts())

      assert data_x == "data-x"
      assert root == "r"
      # "/data" is a synthetic directory contributed by the mount table.
      assert "data" in root_listing
      assert "root.txt" in root_listing
      assert %VFS{} = ctx.filesystem
    end

    test "glob matches files inside a mounted backend" do
      code = """
      import glob
      sorted(glob.glob("/data/*.txt"))
      """

      {value, _ctx} = run!(code, filesystem: two_mounts())
      assert value == ["/data/x.txt"]
    end

    test "os.walk descends into a mounted backend" do
      code = """
      import os
      sorted(root for root, dirs, files in os.walk("/data"))
      """

      {value, _ctx} = run!(code, filesystem: two_mounts())
      assert value == ["/data", "/data/sub"]
    end

    test "a write into a mounted backend lands in that mount and threads back" do
      code = """
      open("/data/new.txt", "w").write("written")
      """

      {_value, ctx} = run!(code, filesystem: two_mounts())
      assert {:ok, "written", _} = VFS.read_file(ctx.filesystem, "/data/new.txt")
    end
  end
end
