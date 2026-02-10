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
end
