defmodule Pyex.Stdlib.RequestsTest do
  use ExUnit.Case

  @network [dangerously_allow_full_internet_access: true]

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
        Pyex.run!(
          """
          import requests
          response = requests.get("http://localhost:#{port}/data")
          response.status_code
          """,
          network: @network
        )

      assert result == 200
    end

    test "response.text contains the body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/text", fn conn ->
        Plug.Conn.resp(conn, 200, "hello body")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.get("http://localhost:#{port}/text")
          response.text
          """,
          network: @network
        )

      assert result == "hello body"
    end

    test "response.ok is true for 2xx status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/ok", fn conn ->
        Plug.Conn.resp(conn, 200, "fine")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.get("http://localhost:#{port}/ok")
          response.ok
          """,
          network: @network
        )

      assert result == true
    end

    test "response.ok is false for non-2xx status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/fail", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.get("http://localhost:#{port}/fail")
          response.ok
          """,
          network: @network
        )

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
        Pyex.run!(
          """
          import requests
          response = requests.get("http://localhost:#{port}/json")
          data = response.json()
          [data["name"], data["age"]]
          """,
          network: @network
        )

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
        Pyex.run!(
          """
          import requests
          response = requests.get("http://localhost:#{port}/headers")
          "content-type" in response.headers
          """,
          network: @network
        )

      assert result == true
    end

    test "response.content is same as response.text", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/content", fn conn ->
        Plug.Conn.resp(conn, 200, "hello")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.get("http://localhost:#{port}/content")
          response.content == response.text
          """,
          network: @network
        )

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
        Pyex.run!(
          """
          import requests
          import json
          response = requests.post("http://localhost:#{port}/api/data", json={"name": "test", "value": 42})
          data = json.loads(response.text)
          [response.status_code, data["created"]]
          """,
          network: @network
        )

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
        Pyex.run!(
          """
          import requests
          import json
          response = requests.post(
              "http://localhost:#{port}/api/auth",
              json={"action": "login"},
              headers={"X-Api-Key": "my-secret"}
          )
          json.loads(response.text)
          """,
          network: @network
        )

      assert result == %{"auth" => "ok"}
    end

    test "response.ok is true for 2xx POST", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/ok", fn conn ->
        Plug.Conn.resp(conn, 200, "done")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.post("http://localhost:#{port}/ok", json={})
          response.ok
          """,
          network: @network
        )

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
        Pyex.run!(
          """
          import requests
          response = requests.put("http://localhost:#{port}/api/item/1", json={"name": "updated"})
          [response.status_code, response.json()["name"]]
          """,
          network: @network
        )

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
        Pyex.run!(
          """
          import requests
          response = requests.patch("http://localhost:#{port}/api/item/1", json={"name": "patched"})
          [response.status_code, response.json()["name"]]
          """,
          network: @network
        )

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
        Pyex.run!(
          """
          import requests
          response = requests.delete("http://localhost:#{port}/api/item/1")
          [response.status_code, response.ok]
          """,
          network: @network
        )

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
        Pyex.run!(
          """
          import requests
          response = requests.head("http://localhost:#{port}/ping")
          [response.status_code, response.ok]
          """,
          network: @network
        )

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
        Pyex.run!(
          """
          import requests
          response = requests.options("http://localhost:#{port}/api")
          [response.status_code, "allow" in response.headers]
          """,
          network: @network
        )

      assert result == [200, true]
    end
  end

  describe "redirect handling" do
    test "does not follow redirects", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/redirect", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://evil.com/steal")
        |> Plug.Conn.resp(302, "")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.get("http://localhost:#{port}/redirect")
          response.status_code
          """,
          network: @network
        )

      assert result == 302
    end
  end

  describe "network access control" do
    test "denied by default when no network config", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/data", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      assert_raise RuntimeError, ~r/NetworkError.*network access is disabled/, fn ->
        Pyex.run!("""
        import requests
        requests.get("http://localhost:#{port}/data")
        """)
      end
    end

    test "allowed with matching URL prefix", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/data", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.get("http://localhost:#{port}/api/data")
          response.status_code
          """,
          network: [allowed_url_prefixes: ["http://localhost:#{port}/api/"]]
        )

      assert result == 200
    end

    test "denied when URL does not match any prefix", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/secret", fn conn ->
        Plug.Conn.resp(conn, 200, "secret data")
      end)

      port = bypass.port

      assert_raise RuntimeError, ~r/NetworkError.*URL is not allowed/, fn ->
        Pyex.run!(
          """
          import requests
          requests.get("http://localhost:#{port}/secret")
          """,
          network: [allowed_url_prefixes: ["https://api.example.com"]]
        )
      end
    end

    test "GET allowed by default, POST denied", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/data", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port
      prefix = "http://localhost:#{port}/"

      result =
        Pyex.run!(
          """
          import requests
          response = requests.get("http://localhost:#{port}/data")
          response.status_code
          """,
          network: [allowed_url_prefixes: [prefix]]
        )

      assert result == 200

      assert_raise RuntimeError, ~r/NetworkError.*HTTP method POST is not allowed/, fn ->
        Pyex.run!(
          """
          import requests
          requests.post("http://localhost:#{port}/data", json={})
          """,
          network: [allowed_url_prefixes: [prefix]]
        )
      end
    end

    test "custom allowed_methods", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/data", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.resp(conn, 201, "created")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.post("http://localhost:#{port}/api/data", json={"x": 1})
          response.status_code
          """,
          network: [
            allowed_url_prefixes: ["http://localhost:#{port}/"],
            allowed_methods: ["GET", "HEAD", "POST"]
          ]
        )

      assert result == 201
    end

    test "dangerously_allow_full_internet_access allows everything", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/api/item/1", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.delete("http://localhost:#{port}/api/item/1")
          response.status_code
          """,
          network: [dangerously_allow_full_internet_access: true]
        )

      assert result == 204
    end

    test "multiple prefixes work", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v2/data", fn conn ->
        Plug.Conn.resp(conn, 200, "v2")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.get("http://localhost:#{port}/v2/data")
          response.text
          """,
          network: [
            allowed_url_prefixes: [
              "http://localhost:#{port}/v1/",
              "http://localhost:#{port}/v2/"
            ]
          ]
        )

      assert result == "v2"
    end

    test "HEAD allowed by default", %{bypass: bypass} do
      Bypass.expect_once(bypass, "HEAD", "/ping", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.head("http://localhost:#{port}/ping")
          response.status_code
          """,
          network: [allowed_url_prefixes: ["http://localhost:#{port}/"]]
        )

      assert result == 200
    end

    test "empty config denies all URLs" do
      assert_raise RuntimeError, ~r/NetworkError.*no allowed hosts or URL prefixes/, fn ->
        Pyex.run!(
          """
          import requests
          requests.get("http://example.com")
          """,
          network: []
        )
      end
    end
  end

  describe "network access control: allowed_hosts" do
    test "allows request to matching host", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/data", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.get("http://localhost:#{port}/data")
          response.status_code
          """,
          network: [allowed_hosts: ["localhost"]]
        )

      assert result == 200
    end

    test "denies request to non-matching host" do
      assert_raise RuntimeError, ~r/NetworkError.*URL is not allowed/, fn ->
        Pyex.run!(
          """
          import requests
          requests.get("http://evil.com/data")
          """,
          network: [allowed_hosts: ["api.example.com"]]
        )
      end
    end

    test "rejects subdomains (exact match only)" do
      assert_raise RuntimeError, ~r/NetworkError.*URL is not allowed/, fn ->
        Pyex.run!(
          """
          import requests
          requests.get("http://evil.api.example.com/data")
          """,
          network: [allowed_hosts: ["api.example.com"]]
        )
      end
    end

    test "host matching is case-insensitive" do
      assert_raise RuntimeError, ~r/NetworkError.*URL is not allowed/, fn ->
        Pyex.run!(
          """
          import requests
          requests.get("http://evil.com/data")
          """,
          network: [allowed_hosts: ["API.EXAMPLE.COM"]]
        )
      end
    end

    test "multiple allowed hosts", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/data", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.get("http://localhost:#{port}/data")
          response.status_code
          """,
          network: [allowed_hosts: ["api.example.com", "localhost"]]
        )

      assert result == 200
    end

    test "allowed_methods still applies with allowed_hosts", %{bypass: bypass} do
      port = bypass.port

      assert_raise RuntimeError, ~r/NetworkError.*HTTP method POST is not allowed/, fn ->
        Pyex.run!(
          """
          import requests
          requests.post("http://localhost:#{port}/data", json={})
          """,
          network: [allowed_hosts: ["localhost"]]
        )
      end
    end

    test "allowed_hosts and allowed_url_prefixes work together", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/v1/data", fn conn ->
        Plug.Conn.resp(conn, 200, "from prefix")
      end)

      Bypass.expect_once(bypass, "GET", "/other", fn conn ->
        Plug.Conn.resp(conn, 200, "from host")
      end)

      port = bypass.port

      opts = [
        network: [
          allowed_hosts: ["localhost"],
          allowed_url_prefixes: ["http://localhost:#{port}/api/"]
        ]
      ]

      r1 =
        Pyex.run!(
          """
          import requests
          requests.get("http://localhost:#{port}/api/v1/data").text
          """,
          opts
        )

      r2 =
        Pyex.run!(
          """
          import requests
          requests.get("http://localhost:#{port}/other").text
          """,
          opts
        )

      assert r1 == "from prefix"
      assert r2 == "from host"
    end

    test "prevents api.example.com.evil.com subdomain attack" do
      assert_raise RuntimeError, ~r/NetworkError.*URL is not allowed/, fn ->
        Pyex.run!(
          """
          import requests
          requests.get("https://api.example.com.evil.com/data")
          """,
          network: [allowed_hosts: ["api.example.com"]]
        )
      end
    end
  end
end
