defmodule Pyex.CapabilitiesTest do
  use ExUnit.Case, async: true

  describe "boto3 capability" do
    test "denied by default" do
      {:error, error} =
        Pyex.run("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:9999')
        s3.put_object(Bucket='bucket', Key='key.txt', Body='data')
        """)

      assert error.message =~ "PermissionError"
      assert error.message =~ "boto3 is disabled"
    end

    test "all S3 operations denied" do
      for op <- [
            "put_object(Bucket='b', Key='k', Body='d')",
            "get_object(Bucket='b', Key='k')",
            "delete_object(Bucket='b', Key='k')",
            "list_objects_v2(Bucket='b')"
          ] do
        {:error, error} =
          Pyex.run("""
          import boto3
          s3 = boto3.client('s3', endpoint_url='http://localhost:9999')
          s3.#{op}
          """)

        assert error.message =~ "PermissionError",
               "expected PermissionError for #{op}, got: #{error.message}"
      end
    end

    test "import succeeds when disabled" do
      result =
        Pyex.run!("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:9999')
        'put_object' in s3
        """)

      assert result == true
    end
  end

  describe "sql capability" do
    test "denied by default" do
      ctx = Pyex.Ctx.new(env: %{"DATABASE_URL" => "postgres://localhost/fake"})

      {:error, error} =
        Pyex.run(
          """
          import sql
          sql.query("SELECT 1")
          """,
          ctx
        )

      assert error.message =~ "PermissionError"
      assert error.message =~ "sql is disabled"
    end

    test "import succeeds when disabled" do
      result =
        Pyex.run!("""
        import sql
        m = sql
        "query" in m
        """)

      assert result == true
    end
  end

  describe "network capability" do
    test "denied by default" do
      {:error, error} =
        Pyex.run("""
        import requests
        requests.get("http://localhost:9999/data")
        """)

      assert error.message =~ "NetworkError"
      assert error.message =~ "network access is disabled"
    end

    test "import succeeds when disabled" do
      result =
        Pyex.run!("""
        import requests
        m = requests
        "get" in m
        """)

      assert result == true
    end
  end

  describe "capabilities option" do
    test "accepts list of atoms" do
      ctx = Pyex.Ctx.new(capabilities: [:boto3, :sql])
      assert MapSet.member?(ctx.capabilities, :boto3)
      assert MapSet.member?(ctx.capabilities, :sql)
    end

    test "shorthand options merge with capabilities list" do
      ctx = Pyex.Ctx.new(capabilities: [:boto3], sql: true)
      assert MapSet.member?(ctx.capabilities, :boto3)
      assert MapSet.member?(ctx.capabilities, :sql)
    end

    test "empty by default" do
      ctx = Pyex.Ctx.new()
      assert ctx.capabilities == MapSet.new()
    end
  end
end
