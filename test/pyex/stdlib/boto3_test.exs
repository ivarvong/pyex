defmodule Pyex.Stdlib.Boto3Test do
  use ExUnit.Case

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, port: bypass.port}
  end

  describe "boto3.client" do
    test "creates an s3 client with expected methods", %{port: port} do
      result =
        Pyex.run!("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        methods = ['put_object' in s3, 'get_object' in s3, 'delete_object' in s3, 'list_objects_v2' in s3]
        methods
        """)

      assert result == [true, true, true, true]
    end

    test "rejects unsupported service" do
      {:error, error} =
        Pyex.run("""
        import boto3
        s3 = boto3.client('dynamodb', endpoint_url='http://localhost:9999')
        """)

      assert error.message =~ "unsupported service 'dynamodb'"
    end

    test "requires a service name string" do
      {:error, error} =
        Pyex.run("""
        import boto3
        s3 = boto3.client(123)
        """)

      assert error.message =~ "requires a service name string"
    end
  end

  describe "s3.put_object" do
    test "uploads an object", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "PUT", "/my-bucket/hello.txt", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == "world"
        Plug.Conn.resp(conn, 200, "")
      end)

      result =
        Pyex.run!("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        resp = s3.put_object(Bucket='my-bucket', Key='hello.txt', Body='world')
        resp['ResponseMetadata']['HTTPStatusCode']
        """)

      assert result == 200
    end

    test "sends content-type when provided", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "PUT", "/bucket/data.json", fn conn ->
        [ct] = Plug.Conn.get_req_header(conn, "content-type")
        assert ct == "application/json"
        Plug.Conn.resp(conn, 200, "")
      end)

      result =
        Pyex.run!("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        resp = s3.put_object(Bucket='bucket', Key='data.json', Body='{}', ContentType='application/json')
        resp['ResponseMetadata']['HTTPStatusCode']
        """)

      assert result == 200
    end

    test "returns error on missing Bucket" do
      {:error, error} =
        Pyex.run("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:9999')
        s3.put_object(Key='hello.txt', Body='world')
        """)

      assert error.message =~ "Missing required parameter: 'Bucket'"
    end

    test "returns error on missing Key" do
      {:error, error} =
        Pyex.run("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:9999')
        s3.put_object(Bucket='my-bucket', Body='world')
        """)

      assert error.message =~ "Missing required parameter: 'Key'"
    end

    test "handles server error", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "PUT", "/bucket/key.txt", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      {:error, error} =
        Pyex.run("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        s3.put_object(Bucket='bucket', Key='key.txt', Body='data')
        """)

      assert error.message =~ "S3 PutObject failed (500)"
    end
  end

  describe "s3.get_object" do
    test "retrieves an object with Body.read()", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "GET", "/my-bucket/hello.txt", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "world")
      end)

      result =
        Pyex.run!("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        obj = s3.get_object(Bucket='my-bucket', Key='hello.txt')
        obj['Body'].read()
        """)

      assert result == "world"
    end

    test "returns ContentLength and ContentType", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "GET", "/bucket/data.json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"key": "value"}))
      end)

      result =
        Pyex.run!("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        obj = s3.get_object(Bucket='bucket', Key='data.json')
        [obj['ContentLength'], obj['ResponseMetadata']['HTTPStatusCode']]
        """)

      [content_length, status] = result
      assert content_length > 0
      assert status == 200
    end

    test "returns NoSuchKey on 404", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "GET", "/bucket/missing.txt", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      {:error, error} =
        Pyex.run("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        s3.get_object(Bucket='bucket', Key='missing.txt')
        """)

      assert error.message =~ "NoSuchKey"
    end

    test "returns error on missing Bucket" do
      {:error, error} =
        Pyex.run("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:9999')
        s3.get_object(Key='hello.txt')
        """)

      assert error.message =~ "Missing required parameter: 'Bucket'"
    end

    test "handles JSON body from S3 correctly", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "GET", "/bucket/data.json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "Alice", "age": 30}))
      end)

      result =
        Pyex.run!("""
        import boto3
        import json
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        obj = s3.get_object(Bucket='bucket', Key='data.json')
        data = json.loads(obj['Body'].read())
        [data['name'], data['age']]
        """)

      assert result == ["Alice", 30]
    end
  end

  describe "s3.delete_object" do
    test "deletes an object", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "DELETE", "/bucket/old.txt", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      result =
        Pyex.run!("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        resp = s3.delete_object(Bucket='bucket', Key='old.txt')
        resp['ResponseMetadata']['HTTPStatusCode']
        """)

      assert result == 204
    end

    test "returns error on missing Key" do
      {:error, error} =
        Pyex.run("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:9999')
        s3.delete_object(Bucket='my-bucket')
        """)

      assert error.message =~ "Missing required parameter: 'Key'"
    end

    test "handles server error", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "DELETE", "/bucket/key.txt", fn conn ->
        Plug.Conn.resp(conn, 403, "Forbidden")
      end)

      {:error, error} =
        Pyex.run("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        s3.delete_object(Bucket='bucket', Key='key.txt')
        """)

      assert error.message =~ "S3 DeleteObject failed (403)"
    end
  end

  describe "s3.list_objects_v2" do
    test "lists objects in a bucket", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "GET", "/bucket/", fn conn ->
        params = Plug.Conn.fetch_query_params(conn).query_params
        assert params["list-type"] == "2"
        assert params["prefix"] == ""

        body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Contents><Key>file1.txt</Key></Contents>
          <Contents><Key>file2.txt</Key></Contents>
          <Contents><Key>subdir/file3.txt</Key></Contents>
        </ListBucketResult>
        """

        Plug.Conn.resp(conn, 200, body)
      end)

      result =
        Pyex.run!("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        resp = s3.list_objects_v2(Bucket='bucket')
        keys = [item['Key'] for item in resp['Contents']]
        [keys, resp['KeyCount']]
        """)

      [keys, count] = result
      assert keys == ["file1.txt", "file2.txt", "subdir/file3.txt"]
      assert count == 3
    end

    test "lists objects with prefix filter", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "GET", "/bucket/", fn conn ->
        params = Plug.Conn.fetch_query_params(conn).query_params
        assert params["prefix"] == "data/"

        body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Contents><Key>data/a.csv</Key></Contents>
          <Contents><Key>data/b.csv</Key></Contents>
        </ListBucketResult>
        """

        Plug.Conn.resp(conn, 200, body)
      end)

      result =
        Pyex.run!("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        resp = s3.list_objects_v2(Bucket='bucket', Prefix='data/')
        [item['Key'] for item in resp['Contents']]
        """)

      assert result == ["data/a.csv", "data/b.csv"]
    end

    test "returns empty list for empty bucket", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "GET", "/empty-bucket/", fn conn ->
        body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult></ListBucketResult>
        """

        Plug.Conn.resp(conn, 200, body)
      end)

      result =
        Pyex.run!("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        resp = s3.list_objects_v2(Bucket='empty-bucket')
        [resp['Contents'], resp['KeyCount']]
        """)

      assert result == [[], 0]
    end

    test "returns error on missing Bucket" do
      {:error, error} =
        Pyex.run("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:9999')
        s3.list_objects_v2()
        """)

      assert error.message =~ "Missing required parameter: 'Bucket'"
    end
  end

  describe "roundtrip" do
    test "put then get returns same data", %{bypass: bypass, port: port} do
      store = Agent.start_link(fn -> %{} end) |> elem(1)

      Bypass.expect(bypass, fn conn ->
        path = conn.request_path

        case conn.method do
          "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            Agent.update(store, &Map.put(&1, path, body))
            Plug.Conn.resp(conn, 200, "")

          "GET" ->
            case Agent.get(store, &Map.get(&1, path)) do
              nil ->
                Plug.Conn.resp(conn, 404, "Not Found")

              body ->
                conn
                |> Plug.Conn.put_resp_content_type("text/plain")
                |> Plug.Conn.resp(200, body)
            end
        end
      end)

      result =
        Pyex.run!("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        s3.put_object(Bucket='store', Key='docs/readme.md', Body='# Hello World')
        obj = s3.get_object(Bucket='store', Key='docs/readme.md')
        obj['Body'].read()
        """)

      assert result == "# Hello World"

      Agent.stop(store)
    end

    test "put JSON then get and parse with json module", %{bypass: bypass, port: port} do
      store = Agent.start_link(fn -> %{} end) |> elem(1)

      Bypass.expect(bypass, fn conn ->
        path = conn.request_path

        case conn.method do
          "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            Agent.update(store, &Map.put(&1, path, body))
            Plug.Conn.resp(conn, 200, "")

          "GET" ->
            case Agent.get(store, &Map.get(&1, path)) do
              nil ->
                Plug.Conn.resp(conn, 404, "Not Found")

              body ->
                conn
                |> Plug.Conn.put_resp_content_type("text/plain")
                |> Plug.Conn.resp(200, body)
            end
        end
      end)

      result =
        Pyex.run!("""
        import boto3
        import json
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        user = {"name": "Alice", "age": 30, "active": True}
        s3.put_object(Bucket='data', Key='records/user.json', Body=json.dumps(user))
        obj = s3.get_object(Bucket='data', Key='records/user.json')
        parsed = json.loads(obj['Body'].read())
        [parsed['name'], parsed['age'], parsed['active']]
        """)

      assert result == ["Alice", 30, true]

      Agent.stop(store)
    end

    test "list after multiple puts", %{bypass: bypass, port: port} do
      store = Agent.start_link(fn -> %{} end) |> elem(1)

      Bypass.expect(bypass, fn conn ->
        path = conn.request_path

        case conn.method do
          "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            Agent.update(store, &Map.put(&1, path, body))
            Plug.Conn.resp(conn, 200, "")

          "GET" ->
            params = Plug.Conn.fetch_query_params(conn).query_params

            if params["list-type"] == "2" do
              prefix = params["prefix"] || ""
              keys = Agent.get(store, &Map.keys/1)

              filtered =
                keys
                |> Enum.filter(&String.contains?(&1, prefix))
                |> Enum.sort()

              xml_contents =
                Enum.map(filtered, fn k ->
                  key = String.replace_prefix(k, "/bucket/", "")
                  "<Contents><Key>#{key}</Key></Contents>"
                end)
                |> Enum.join("\n")

              body = """
              <?xml version="1.0" encoding="UTF-8"?>
              <ListBucketResult>#{xml_contents}</ListBucketResult>
              """

              Plug.Conn.resp(conn, 200, body)
            else
              Plug.Conn.resp(conn, 404, "Not Found")
            end
        end
      end)

      result =
        Pyex.run!("""
        import boto3
        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        s3.put_object(Bucket='bucket', Key='a.txt', Body='aaa')
        s3.put_object(Bucket='bucket', Key='b.txt', Body='bbb')
        s3.put_object(Bucket='bucket', Key='c.txt', Body='ccc')
        resp = s3.list_objects_v2(Bucket='bucket')
        resp['KeyCount']
        """)

      assert result == 3

      Agent.stop(store)
    end
  end

  describe "integration with pydantic" do
    test "put and get with pydantic model validation", %{bypass: bypass, port: port} do
      store = Agent.start_link(fn -> %{} end) |> elem(1)

      Bypass.expect(bypass, fn conn ->
        path = conn.request_path

        case conn.method do
          "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            Agent.update(store, &Map.put(&1, path, body))
            Plug.Conn.resp(conn, 200, "")

          "GET" ->
            case Agent.get(store, &Map.get(&1, path)) do
              nil ->
                Plug.Conn.resp(conn, 404, "Not Found")

              body ->
                conn
                |> Plug.Conn.put_resp_content_type("text/plain")
                |> Plug.Conn.resp(200, body)
            end
        end
      end)

      result =
        Pyex.run!("""
        import boto3
        import json
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            age: int
            active: bool

        s3 = boto3.client('s3', endpoint_url='http://localhost:#{port}')
        user = User(name='Alice', age=30, active=True)
        s3.put_object(Bucket='models', Key='users/1.json', Body=json.dumps(user.model_dump()))
        obj = s3.get_object(Bucket='models', Key='users/1.json')
        data = json.loads(obj['Body'].read())
        loaded = User(**data)
        [loaded.name, loaded.age, loaded.active]
        """)

      assert result == ["Alice", 30, true]

      Agent.stop(store)
    end
  end
end
