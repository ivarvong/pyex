defmodule Pyex.Stdlib.RequestsTest do
  use ExUnit.Case

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  describe "requests.get" do
    test "returns response with text and status_code", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/data", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"key": "value"}))
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        response = requests.get("http://localhost:#{port}/data")
        response.status_code
        """)

      assert result == 200
    end

    test "response.text contains the body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/text", fn conn ->
        Plug.Conn.resp(conn, 200, "hello body")
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        response = requests.get("http://localhost:#{port}/text")
        response.text
        """)

      assert result == "hello body"
    end

    test "response.ok is true for 2xx status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/ok", fn conn ->
        Plug.Conn.resp(conn, 200, "fine")
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        response = requests.get("http://localhost:#{port}/ok")
        response.ok
        """)

      assert result == true
    end

    test "response.ok is false for non-2xx status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/fail", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        response = requests.get("http://localhost:#{port}/fail")
        response.ok
        """)

      assert result == false
    end

    test "response.json() parses JSON body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "Alice", "age": 30}))
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        response = requests.get("http://localhost:#{port}/json")
        data = response.json()
        [data["name"], data["age"]]
        """)

      assert result == ["Alice", 30]
    end

    test "response.headers is a dict", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/headers", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "{}")
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        response = requests.get("http://localhost:#{port}/headers")
        "content-type" in response.headers
        """)

      assert result == true
    end

    test "response.content is same as response.text", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/content", fn conn ->
        Plug.Conn.resp(conn, 200, "hello")
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        response = requests.get("http://localhost:#{port}/content")
        response.content == response.text
        """)

      assert result == true
    end
  end

  describe "requests.post" do
    test "posts JSON body and returns response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/data", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert payload == %{"name" => "test", "value" => 42}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"id": 1, "created": true}))
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        import json
        response = requests.post("http://localhost:#{port}/api/data", json={"name": "test", "value": 42})
        data = json.loads(response.text)
        [response.status_code, data["created"]]
        """)

      assert result == [201, true]
    end

    test "posts with custom headers", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/auth", fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "x-api-key")
        assert auth == "my-secret"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"auth": "ok"}))
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        import json
        response = requests.post(
            "http://localhost:#{port}/api/auth",
            json={"action": "login"},
            headers={"X-Api-Key": "my-secret"}
        )
        json.loads(response.text)
        """)

      assert result == %{"auth" => "ok"}
    end

    test "response.ok is true for 2xx POST", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/ok", fn conn ->
        Plug.Conn.resp(conn, 200, "done")
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        response = requests.post("http://localhost:#{port}/ok", json={})
        response.ok
        """)

      assert result == true
    end
  end

  describe "requests.put" do
    test "sends PUT with JSON body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/api/item/1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        assert payload == %{"name" => "updated"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"id": 1, "name": "updated"}))
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        response = requests.put("http://localhost:#{port}/api/item/1", json={"name": "updated"})
        [response.status_code, response.json()["name"]]
        """)

      assert result == [200, "updated"]
    end
  end

  describe "requests.patch" do
    test "sends PATCH with JSON body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PATCH", "/api/item/1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        assert payload == %{"name" => "patched"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"id": 1, "name": "patched"}))
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        response = requests.patch("http://localhost:#{port}/api/item/1", json={"name": "patched"})
        [response.status_code, response.json()["name"]]
        """)

      assert result == [200, "patched"]
    end
  end

  describe "requests.delete" do
    test "sends DELETE and returns response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/api/item/1", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        response = requests.delete("http://localhost:#{port}/api/item/1")
        [response.status_code, response.ok]
        """)

      assert result == [204, true]
    end
  end

  describe "requests.head" do
    test "sends HEAD and returns status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "HEAD", "/ping", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        response = requests.head("http://localhost:#{port}/ping")
        [response.status_code, response.ok]
        """)

      assert result == [200, true]
    end
  end

  describe "requests.options" do
    test "sends OPTIONS and returns response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "OPTIONS", "/api", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("allow", "GET, POST, OPTIONS")
        |> Plug.Conn.resp(200, "")
      end)

      port = bypass.port

      result =
        Pyex.run!("""
        import requests
        response = requests.options("http://localhost:#{port}/api")
        [response.status_code, "allow" in response.headers]
        """)

      assert result == [200, true]
    end
  end
end
