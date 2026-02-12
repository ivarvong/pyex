defmodule Pyex.Filesystem.S3IntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: false

  @creds_path "scratch/r2_creds.json"
  @test_prefix "pyex-smoketest-#{:erlang.system_time(:millisecond)}"

  setup_all do
    case File.read(@creds_path) do
      {:ok, json} ->
        creds = Jason.decode!(json)

        System.put_env("AWS_ACCESS_KEY_ID", creds["access_key_id"])
        System.put_env("AWS_SECRET_ACCESS_KEY", creds["secret_access_key"])

        fs =
          Pyex.Filesystem.S3.new(
            bucket: creds["bucket"],
            prefix: @test_prefix,
            region: "auto",
            endpoint_url: creds["endpoint"]
          )

        on_exit(fn ->
          cleanup(fs)
          System.delete_env("AWS_ACCESS_KEY_ID")
          System.delete_env("AWS_SECRET_ACCESS_KEY")
        end)

        {:ok, fs: fs, creds: creds}

      {:error, _} ->
        :skip
    end
  end

  defp cleanup(fs) do
    case Pyex.Filesystem.S3.list_dir(fs, "") do
      {:ok, entries} ->
        for entry <- entries do
          Pyex.Filesystem.S3.delete(fs, entry)
        end

      _ ->
        :ok
    end
  end

  describe "real R2 smoketest" do
    @tag :r2
    test "write, read, exists?, list_dir, delete lifecycle", %{fs: fs} do
      path = "hello.txt"
      content = "Hello from Pyex smoketest @ #{DateTime.utc_now()}"

      assert {:ok, fs} = Pyex.Filesystem.S3.write(fs, path, content, :write)
      assert {:ok, ^content} = Pyex.Filesystem.S3.read(fs, path)
      assert Pyex.Filesystem.S3.exists?(fs, path)
      assert {:ok, entries} = Pyex.Filesystem.S3.list_dir(fs, "")
      assert "hello.txt" in entries
      assert {:ok, fs} = Pyex.Filesystem.S3.delete(fs, path)
      refute Pyex.Filesystem.S3.exists?(fs, path)
      assert {:error, _} = Pyex.Filesystem.S3.read(fs, path)
    end

    @tag :r2
    test "append mode reads existing content and appends", %{fs: fs} do
      path = "append_test.txt"

      assert {:ok, fs} = Pyex.Filesystem.S3.write(fs, path, "line1\n", :write)
      assert {:ok, fs} = Pyex.Filesystem.S3.write(fs, path, "line2\n", :append)
      assert {:ok, "line1\nline2\n"} = Pyex.Filesystem.S3.read(fs, path)
      assert {:ok, _fs} = Pyex.Filesystem.S3.delete(fs, path)
    end

    @tag :r2
    test "nested paths work correctly", %{fs: fs} do
      path = "subdir/nested/deep.txt"

      assert {:ok, fs} = Pyex.Filesystem.S3.write(fs, path, "deep content", :write)
      assert {:ok, "deep content"} = Pyex.Filesystem.S3.read(fs, path)
      assert Pyex.Filesystem.S3.exists?(fs, path)

      assert {:ok, entries} = Pyex.Filesystem.S3.list_dir(fs, "")
      assert "subdir" in entries

      assert {:ok, _fs} = Pyex.Filesystem.S3.delete(fs, path)
    end

    @tag :r2
    test "read nonexistent file returns FileNotFoundError", %{fs: fs} do
      assert {:error, msg} = Pyex.Filesystem.S3.read(fs, "does_not_exist.txt")
      assert msg =~ "FileNotFoundError"
    end

    @tag :r2
    test "exists? returns false for nonexistent file", %{fs: fs} do
      refute Pyex.Filesystem.S3.exists?(fs, "nope.txt")
    end

    @tag :r2
    test "Python open/read/write through Pyex.run", %{fs: fs} do
      code = """
      f = open("data.txt", "w")
      f.write("written from python")
      f.close()

      f = open("data.txt", "r")
      result = f.read()
      f.close()
      result
      """

      assert {:ok, "written from python", _ctx} = Pyex.run(code, filesystem: fs)
      assert {:ok, "written from python"} = Pyex.Filesystem.S3.read(fs, "data.txt")
      assert {:ok, _fs} = Pyex.Filesystem.S3.delete(fs, "data.txt")
    end

    @tag :r2
    test "Python with-statement and json round-trip", %{fs: fs} do
      code = """
      import json

      data = {"name": "pyex", "version": "0.1.0", "tests": 42}

      with open("config.json", "w") as f:
          f.write(json.dumps(data))

      with open("config.json", "r") as f:
          loaded = json.loads(f.read())

      loaded["name"]
      """

      assert {:ok, "pyex", _ctx} = Pyex.run(code, filesystem: fs)
      assert {:ok, _fs} = Pyex.Filesystem.S3.delete(fs, "config.json")
    end

    @tag :r2
    test "binary safety: content with special chars", %{fs: fs} do
      content = "line1\nline2\ttab\r\nwindows\n\"quotes\" & <xml> 'entities'"
      assert {:ok, fs} = Pyex.Filesystem.S3.write(fs, "special.txt", content, :write)
      assert {:ok, ^content} = Pyex.Filesystem.S3.read(fs, "special.txt")
      assert {:ok, _fs} = Pyex.Filesystem.S3.delete(fs, "special.txt")
    end
  end
end
