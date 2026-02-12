defmodule Pyex.Filesystem.S3Test do
  @moduledoc """
  Tests for the S3 filesystem backend using Bypass to mock S3 HTTP endpoints.
  """
  use ExUnit.Case

  alias Pyex.Filesystem.S3

  setup do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}"

    fs =
      S3.new(
        bucket: "test-bucket",
        prefix: "pyex",
        region: "us-east-1",
        endpoint_url: url,
        access_key_id: "test-key",
        secret_access_key: "test-secret"
      )

    {:ok, bypass: bypass, fs: fs, url: url}
  end

  # ── new/1 ──────────────────────────────────────────────────────

  describe "new/1" do
    test "creates struct with all options" do
      fs =
        S3.new(
          bucket: "my-bucket",
          prefix: "data/v1",
          region: "eu-west-1",
          endpoint_url: "http://localhost:9000",
          access_key_id: "ak",
          secret_access_key: "sk"
        )

      assert fs.bucket == "my-bucket"
      assert fs.prefix == "data/v1"
      assert fs.region == "eu-west-1"
      assert fs.endpoint_url == "http://localhost:9000"
      assert fs.access_key_id == "ak"
      assert fs.secret_access_key == "sk"
    end

    test "defaults prefix to empty string" do
      fs = S3.new(bucket: "b", access_key_id: "ak", secret_access_key: "sk")
      assert fs.prefix == ""
    end

    test "defaults region to us-east-1" do
      fs = S3.new(bucket: "b", access_key_id: "ak", secret_access_key: "sk")
      assert fs.region == "us-east-1"
    end

    test "defaults endpoint_url to nil" do
      fs = S3.new(bucket: "b", access_key_id: "ak", secret_access_key: "sk")
      assert fs.endpoint_url == nil
    end

    test "raises on missing required options" do
      assert_raise KeyError, fn -> S3.new([]) end
      assert_raise KeyError, fn -> S3.new(bucket: "b") end
      assert_raise KeyError, fn -> S3.new(bucket: "b", access_key_id: "ak") end
    end
  end

  # ── read/2 ─────────────────────────────────────────────────────

  describe "read/2" do
    test "returns content on 200", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/pyex/hello.txt", fn conn ->
        Plug.Conn.resp(conn, 200, "hello world")
      end)

      assert {:ok, "hello world"} = S3.read(fs, "hello.txt")
    end

    test "returns FileNotFoundError on 404", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/pyex/missing.txt", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      assert {:error, msg} = S3.read(fs, "missing.txt")
      assert msg =~ "FileNotFoundError"
      assert msg =~ "missing.txt"
    end

    test "returns IOError on other status codes", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/pyex/forbidden.txt", fn conn ->
        Plug.Conn.resp(conn, 403, "Forbidden")
      end)

      assert {:error, msg} = S3.read(fs, "forbidden.txt")
      assert msg =~ "IOError"
      assert msg =~ "403"
    end

    test "returns IOError on connection failure", %{fs: fs} do
      dead_fs = %{fs | endpoint_url: "http://localhost:1"}
      assert {:error, msg} = S3.read(dead_fs, "test.txt")
      assert msg =~ "IOError"
    end

    test "handles path with leading slash", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/pyex/data.txt", fn conn ->
        Plug.Conn.resp(conn, 200, "data")
      end)

      assert {:ok, "data"} = S3.read(fs, "/data.txt")
    end

    test "works with empty prefix", %{bypass: bypass, url: url} do
      fs = S3.new(bucket: "b", endpoint_url: url, access_key_id: "ak", secret_access_key: "sk")

      Bypass.expect_once(bypass, "GET", "/b/file.txt", fn conn ->
        Plug.Conn.resp(conn, 200, "no prefix")
      end)

      assert {:ok, "no prefix"} = S3.read(fs, "file.txt")
    end

    test "handles nested paths", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/pyex/dir/sub/file.txt", fn conn ->
        Plug.Conn.resp(conn, 200, "nested")
      end)

      assert {:ok, "nested"} = S3.read(fs, "dir/sub/file.txt")
    end
  end

  # ── write/4 ────────────────────────────────────────────────────

  describe "write/4" do
    test "write mode PUTs content directly", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "PUT", "/test-bucket/pyex/out.txt", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == "hello"
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, ^fs} = S3.write(fs, "out.txt", "hello", :write)
    end

    test "write mode accepts 201", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "PUT", "/test-bucket/pyex/new.txt", fn conn ->
        Plug.Conn.resp(conn, 201, "")
      end)

      assert {:ok, _} = S3.write(fs, "new.txt", "created", :write)
    end

    test "append mode reads then writes concatenated content", %{bypass: bypass, fs: fs} do
      Bypass.expect(bypass, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/test-bucket/pyex/log.txt"} ->
            Plug.Conn.resp(conn, 200, "line1\n")

          {"PUT", "/test-bucket/pyex/log.txt"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert body == "line1\nline2\n"
            Plug.Conn.resp(conn, 200, "")
        end
      end)

      assert {:ok, _} = S3.write(fs, "log.txt", "line2\n", :append)
    end

    test "append mode on nonexistent file writes content alone", %{bypass: bypass, fs: fs} do
      Bypass.expect(bypass, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/test-bucket/pyex/new.txt"} ->
            Plug.Conn.resp(conn, 404, "Not Found")

          {"PUT", "/test-bucket/pyex/new.txt"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert body == "first line\n"
            Plug.Conn.resp(conn, 200, "")
        end
      end)

      assert {:ok, _} = S3.write(fs, "new.txt", "first line\n", :append)
    end

    test "returns IOError on PUT failure", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "PUT", "/test-bucket/pyex/fail.txt", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, msg} = S3.write(fs, "fail.txt", "data", :write)
      assert msg =~ "IOError"
      assert msg =~ "500"
    end

    test "returns IOError on connection failure", %{fs: fs} do
      dead_fs = %{fs | endpoint_url: "http://localhost:1"}
      assert {:error, msg} = S3.write(dead_fs, "test.txt", "data", :write)
      assert msg =~ "IOError"
    end
  end

  # ── exists?/2 ──────────────────────────────────────────────────

  describe "exists?/2" do
    test "returns true on 200 HEAD", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "HEAD", "/test-bucket/pyex/present.txt", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      assert S3.exists?(fs, "present.txt")
    end

    test "returns false on 404 HEAD", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "HEAD", "/test-bucket/pyex/gone.txt", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      refute S3.exists?(fs, "gone.txt")
    end

    test "returns false on connection error", %{fs: fs} do
      dead_fs = %{fs | endpoint_url: "http://localhost:1"}
      refute S3.exists?(dead_fs, "test.txt")
    end
  end

  # ── list_dir/2 ─────────────────────────────────────────────────

  describe "list_dir/2" do
    test "parses S3 ListBucketResult XML", %{bypass: bypass, fs: fs} do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <Prefix>pyex/data/</Prefix>
        <Key>pyex/data/a.txt</Key>
        <Key>pyex/data/b.json</Key>
      </ListBucketResult>
      """

      Bypass.expect_once(bypass, "GET", "/test-bucket/", fn conn ->
        assert conn.query_string =~ "prefix=pyex%2Fdata%2F"
        assert conn.query_string =~ "delimiter=%2F"
        Plug.Conn.resp(conn, 200, xml)
      end)

      assert {:ok, entries} = S3.list_dir(fs, "data")
      assert entries == ["a.txt", "b.json"]
    end

    test "includes subdirectory prefixes", %{bypass: bypass, fs: fs} do
      xml = """
      <ListBucketResult>
        <Prefix>pyex/</Prefix>
        <Contents><Key>pyex/file.txt</Key></Contents>
        <CommonPrefixes><Prefix>pyex/subdir/</Prefix></CommonPrefixes>
      </ListBucketResult>
      """

      Bypass.expect_once(bypass, "GET", "/test-bucket/", fn conn ->
        assert conn.query_string =~ "prefix=pyex%2F"
        Plug.Conn.resp(conn, 200, xml)
      end)

      assert {:ok, entries} = S3.list_dir(fs, "")
      assert entries == ["file.txt", "subdir"]
    end

    test "returns empty list for empty directory", %{bypass: bypass, fs: fs} do
      xml = """
      <ListBucketResult>
        <Prefix>pyex/empty/</Prefix>
      </ListBucketResult>
      """

      Bypass.expect_once(bypass, "GET", "/test-bucket/", fn conn ->
        Plug.Conn.resp(conn, 200, xml)
      end)

      assert {:ok, []} = S3.list_dir(fs, "empty")
    end

    test "returns IOError on error status", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/", fn conn ->
        Plug.Conn.resp(conn, 403, "Access Denied")
      end)

      assert {:error, msg} = S3.list_dir(fs, "data")
      assert msg =~ "IOError"
      assert msg =~ "403"
    end

    test "returns IOError on connection failure", %{fs: fs} do
      dead_fs = %{fs | endpoint_url: "http://localhost:1"}
      assert {:error, msg} = S3.list_dir(dead_fs, "data")
      assert msg =~ "IOError"
    end

    test "handles root listing with empty prefix", %{bypass: bypass, url: url} do
      fs = S3.new(bucket: "b", endpoint_url: url, access_key_id: "ak", secret_access_key: "sk")

      xml = """
      <ListBucketResult>
        <Key>readme.md</Key>
        <Prefix>src/</Prefix>
      </ListBucketResult>
      """

      Bypass.expect_once(bypass, "GET", "/b/", fn conn ->
        assert conn.query_string =~ "prefix=&"
        Plug.Conn.resp(conn, 200, xml)
      end)

      assert {:ok, entries} = S3.list_dir(fs, "")
      assert "readme.md" in entries
      assert "src" in entries
    end

    test "handles non-binary body gracefully", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "{}")
      end)

      assert {:ok, []} = S3.list_dir(fs, "data")
    end
  end

  # ── delete/2 ───────────────────────────────────────────────────

  describe "delete/2" do
    test "succeeds on 200", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "DELETE", "/test-bucket/pyex/old.txt", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, ^fs} = S3.delete(fs, "old.txt")
    end

    test "succeeds on 204", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "DELETE", "/test-bucket/pyex/old.txt", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert {:ok, _} = S3.delete(fs, "old.txt")
    end

    test "returns IOError on error status", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "DELETE", "/test-bucket/pyex/perm.txt", fn conn ->
        Plug.Conn.resp(conn, 403, "Forbidden")
      end)

      assert {:error, msg} = S3.delete(fs, "perm.txt")
      assert msg =~ "IOError"
      assert msg =~ "403"
    end

    test "returns IOError on connection failure", %{fs: fs} do
      dead_fs = %{fs | endpoint_url: "http://localhost:1"}
      assert {:error, msg} = S3.delete(dead_fs, "test.txt")
      assert msg =~ "IOError"
    end
  end

  # ── path/prefix handling ───────────────────────────────────────

  describe "path normalization" do
    test "prefix with trailing slash is normalized", %{bypass: bypass, url: url} do
      fs =
        S3.new(
          bucket: "b",
          prefix: "data/",
          endpoint_url: url,
          access_key_id: "ak",
          secret_access_key: "sk"
        )

      Bypass.expect_once(bypass, "GET", "/b/data/file.txt", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, "ok"} = S3.read(fs, "file.txt")
    end

    test "path with leading slash is normalized", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/pyex/file.txt", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, "ok"} = S3.read(fs, "/file.txt")
    end

    test "deeply nested prefix works", %{bypass: bypass, url: url} do
      fs =
        S3.new(
          bucket: "b",
          prefix: "a/b/c",
          endpoint_url: url,
          access_key_id: "ak",
          secret_access_key: "sk"
        )

      Bypass.expect_once(bypass, "GET", "/b/a/b/c/d.txt", fn conn ->
        Plug.Conn.resp(conn, 200, "deep")
      end)

      assert {:ok, "deep"} = S3.read(fs, "d.txt")
    end
  end

  # ── Python integration via Pyex.run ────────────────────────────

  describe "Python integration" do
    test "open and read a file", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/pyex/data.txt", fn conn ->
        Plug.Conn.resp(conn, 200, "hello from s3")
      end)

      {:ok, result, _ctx} =
        Pyex.run(
          """
          f = open("data.txt", "r")
          content = f.read()
          f.close()
          content
          """,
          filesystem: fs
        )

      assert result == "hello from s3"
    end

    test "write and read back", %{bypass: bypass, fs: fs} do
      Bypass.expect(bypass, fn conn ->
        case {conn.method, conn.request_path} do
          {"PUT", "/test-bucket/pyex/out.txt"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert body == "written by python"
            Plug.Conn.resp(conn, 200, "")

          {"GET", "/test-bucket/pyex/out.txt"} ->
            Plug.Conn.resp(conn, 200, "written by python")
        end
      end)

      {:ok, result, _ctx} =
        Pyex.run(
          """
          f = open("out.txt", "w")
          f.write("written by python")
          f.close()

          f2 = open("out.txt", "r")
          result = f2.read()
          f2.close()
          result
          """,
          filesystem: fs
        )

      assert result == "written by python"
    end

    test "read nonexistent file raises IOError", %{bypass: bypass, fs: fs} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/pyex/nope.txt", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      assert {:error, %Pyex.Error{kind: :io}} =
               Pyex.run(
                 """
                 f = open("nope.txt", "r")
                 """,
                 filesystem: fs
               )
    end

    test "import from S3 filesystem", %{bypass: bypass, fs: fs} do
      module_source = """
      GREETING = "hello from s3 module"

      def greet(name):
          return GREETING + " " + name
      """

      Bypass.expect_once(bypass, "GET", "/test-bucket/pyex/mylib.py", fn conn ->
        Plug.Conn.resp(conn, 200, module_source)
      end)

      {:ok, result, _ctx} =
        Pyex.run(
          """
          import mylib
          mylib.greet("world")
          """,
          filesystem: fs
        )

      assert result == "hello from s3 module world"
    end

    test "with statement for file I/O", %{bypass: bypass, fs: fs} do
      Bypass.expect(bypass, fn conn ->
        case {conn.method, conn.request_path} do
          {"PUT", "/test-bucket/pyex/ctx.txt"} ->
            Plug.Conn.resp(conn, 200, "")

          {"GET", "/test-bucket/pyex/ctx.txt"} ->
            Plug.Conn.resp(conn, 200, "context manager works")
        end
      end)

      {:ok, result, _ctx} =
        Pyex.run(
          """
          with open("ctx.txt", "w") as f:
              f.write("context manager works")
          with open("ctx.txt", "r") as f:
              data = f.read()
          data
          """,
          filesystem: fs
        )

      assert result == "context manager works"
    end

    test "json round-trip through S3", %{bypass: bypass, fs: fs} do
      Bypass.expect(bypass, fn conn ->
        case {conn.method, conn.request_path} do
          {"PUT", "/test-bucket/pyex/config.json"} ->
            Plug.Conn.resp(conn, 200, "")

          {"GET", "/test-bucket/pyex/config.json"} ->
            Plug.Conn.resp(conn, 200, ~s({"key": "value", "n": 42}))
        end
      end)

      {:ok, result, _ctx} =
        Pyex.run(
          """
          import json

          with open("config.json", "w") as f:
              f.write(json.dumps({"key": "value", "n": 42}))

          with open("config.json", "r") as f:
              data = json.loads(f.read())

          data["key"] + " " + str(data["n"])
          """,
          filesystem: fs
        )

      assert result == "value 42"
    end

    test "csv processing from S3", %{bypass: bypass, fs: fs} do
      csv_data = "name,age\nalice,30\nbob,25\n"

      Bypass.expect_once(bypass, "GET", "/test-bucket/pyex/people.csv", fn conn ->
        Plug.Conn.resp(conn, 200, csv_data)
      end)

      {:ok, result, _ctx} =
        Pyex.run(
          """
          import csv

          f = open("people.csv", "r")
          reader = csv.DictReader(f)
          names = [row["name"] for row in reader]
          f.close()
          names
          """,
          filesystem: fs
        )

      assert result == ["alice", "bob"]
    end
  end
end
