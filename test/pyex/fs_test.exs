defmodule Pyex.FSTest do
  @moduledoc """
  Direct unit coverage of the `Pyex.FS` boundary: path resolution, the full
  `%VFS.Error{}` → Python-exception mapping, and seed validation.
  """
  use ExUnit.Case, async: true

  doctest Pyex.FS

  describe "resolve/2" do
    test "an absolute path ignores the cwd" do
      assert Pyex.FS.resolve("/project", "/etc/hosts") == "/etc/hosts"
    end

    test "a relative path joins the cwd" do
      assert Pyex.FS.resolve("/project", "data.txt") == "/project/data.txt"
    end

    test "the empty path is the cwd" do
      assert Pyex.FS.resolve("/project", "") == "/project"
    end

    test ".. and . segments collapse against the cwd" do
      assert Pyex.FS.resolve("/a/b", "../c") == "/a/c"
      assert Pyex.FS.resolve("/a/b", "./c") == "/a/b/c"
    end

    test "the root cwd reproduces the historical root-relative behavior" do
      assert Pyex.FS.resolve("/", "posts/a.md") == "/posts/a.md"
      assert Pyex.FS.resolve("/", "/posts/a.md") == "/posts/a.md"
    end
  end

  describe "py_error/2 maps every VFS.Error kind to a CPython exception" do
    # Every kind in VFS.Error.kind/0 must produce a concrete, errno-bearing
    # Python exception — no kind may fall through to a bare-atom message.
    cases = [
      {:enoent, "FileNotFoundError: [Errno 2] No such file or directory: '/x'"},
      {:enotdir, "NotADirectoryError: [Errno 20] Not a directory: '/x'"},
      {:eisdir, "IsADirectoryError: [Errno 21] Is a directory: '/x'"},
      {:eexist, "FileExistsError: [Errno 17] File exists: '/x'"},
      {:eacces, "PermissionError: [Errno 13] Permission denied: '/x'"},
      {:erofs, "OSError: [Errno 30] Read-only file system: '/x'"},
      {:exdev, "OSError: [Errno 18] Invalid cross-device link: '/x'"},
      {:einval, "OSError: [Errno 22] Invalid argument: '/x'"},
      {:eio, "OSError: [Errno 5] Input/output error: '/x'"},
      {:enotsup, "OSError: [Errno 95] Operation not supported: '/x'"},
      {:eloop, "OSError: [Errno 40] Too many levels of symbolic links: '/x'"}
    ]

    for {kind, expected} <- cases do
      test "#{kind}" do
        error = VFS.Error.new(unquote(kind), path: "/x")
        assert Pyex.FS.py_error(error, "/x") == unquote(expected)
      end
    end

    test "a backend-specific message (e.g. S3 status) is appended in parentheses" do
      error = VFS.Error.new(:eio, path: "/x", message: "S3 returned 500: \"\"")

      assert Pyex.FS.py_error(error, "/x") ==
               "OSError: [Errno 5] Input/output error: '/x' (S3 returned 500: \"\")"
    end

    test "the default '<kind> at <path>' message is not appended" do
      error = VFS.Error.new(:eio, path: "/x")
      assert Pyex.FS.py_error(error, "/x") == "OSError: [Errno 5] Input/output error: '/x'"
    end

    test "the message names the caller's path, not the resolved one" do
      error = VFS.Error.new(:enoent, path: "/project/missing.txt")
      assert Pyex.FS.py_error(error, "missing.txt") =~ "'missing.txt'"
    end

    test "emits a [:pyex, :fs, :error] telemetry event with structured context" do
      handler = "test-fs-error-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:pyex, :fs, :error],
        fn _event, _measurements, meta, pid -> send(pid, {:fs_error, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Pyex.FS.py_error(VFS.Error.new(:eio, path: "/data/x", mount: "/data"), "x")

      assert_received {:fs_error, %{kind: :eio, mount: "/data", vfs_path: "/data/x", path: "x"}}
    end
  end

  describe "from_map/1 validates the seed" do
    test "a conflicting file/dir seed raises a Pyex-flavored error" do
      assert_raise ArgumentError, ~r/invalid filesystem seed/, fn ->
        Pyex.FS.from_map(%{"a" => "f", "a/b" => "c"})
      end
    end

    test "a '/' key seed raises" do
      assert_raise ArgumentError, ~r/invalid filesystem seed/, fn ->
        Pyex.FS.from_map(%{"/" => "x"})
      end
    end

    test "a valid seed roots keys at /" do
      mem = Pyex.FS.from_map(%{"posts/a.md" => "A"})
      assert {:ok, "A"} = Pyex.FS.read(mem, "/posts/a.md")
      assert {:ok, "A"} = Pyex.FS.read(mem, "posts/a.md")
    end
  end
end
