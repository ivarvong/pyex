defmodule Pyex.Stdlib.RequestsTest do
  use ExUnit.Case

  @network [%{dangerously_allow_full_internet_access: true, methods: :all}]

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

    test "posts JSON body containing nested py_list values", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/nested", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert payload == %{
                 "items" => [%{"key" => "value"}],
                 "tags" => ["a", "b"],
                 "nested" => %{"nums" => [1, 2, 3]}
               }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"ok": true}))
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.post("http://localhost:#{port}/api/nested", json={
              "items": [{"key": "value"}],
              "tags": ["a", "b"],
              "nested": {"nums": [1, 2, 3]}
          })
          response.status_code
          """,
          network: @network
        )

      assert result == 200
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
          network: [%{allowed_url_prefix: "http://localhost:#{port}/api/"}]
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
          network: [%{allowed_url_prefix: "https://api.example.com/"}]
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
          network: [%{allowed_url_prefix: prefix}]
        )

      assert result == 200

      assert_raise RuntimeError, ~r/NetworkError.*HTTP method POST is not allowed/, fn ->
        Pyex.run!(
          """
          import requests
          requests.post("http://localhost:#{port}/data", json={})
          """,
          network: [%{allowed_url_prefix: prefix}]
        )
      end
    end

    test "denial message teaches caller how to permit the blocked method", %{bypass: bypass} do
      port = bypass.port
      prefix = "http://localhost:#{port}/"

      err =
        assert_raise RuntimeError, fn ->
          Pyex.run!(
            """
            import requests
            requests.post("http://localhost:#{port}/data", json={})
            """,
            network: [%{allowed_url_prefix: prefix}]
          )
        end

      assert err.message =~ ~s(:methods)
      assert err.message =~ ~s("POST")
    end

    test "custom methods per prefix", %{bypass: bypass} do
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
            %{allowed_url_prefix: "http://localhost:#{port}/", methods: ["GET", "HEAD", "POST"]}
          ]
        )

      assert result == 201
    end

    test "dangerously_allow_full_internet_access defaults to GET/HEAD", %{bypass: bypass} do
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
          network: [%{dangerously_allow_full_internet_access: true}]
        )

      assert result == 200

      assert_raise RuntimeError, ~r/NetworkError.*HTTP method DELETE is not allowed/, fn ->
        Pyex.run!(
          """
          import requests
          requests.delete("http://localhost:#{port}/data")
          """,
          network: [%{dangerously_allow_full_internet_access: true}]
        )
      end
    end

    test "dangerously_allow_full_internet_access with methods: :all", %{bypass: bypass} do
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
          network: [%{dangerously_allow_full_internet_access: true, methods: :all}]
        )

      assert result == 204
    end

    test "dangerously_allow_full_internet_access with method restriction", %{bypass: bypass} do
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
          network: [%{dangerously_allow_full_internet_access: true, methods: ["GET"]}]
        )

      assert result == 200

      assert_raise RuntimeError, ~r/NetworkError.*HTTP method POST is not allowed/, fn ->
        Pyex.run!(
          """
          import requests
          requests.post("http://localhost:#{port}/data", json={})
          """,
          network: [%{dangerously_allow_full_internet_access: true, methods: ["GET"]}]
        )
      end
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
            %{allowed_url_prefix: "http://localhost:#{port}/v1/"},
            %{allowed_url_prefix: "http://localhost:#{port}/v2/"}
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
          network: [%{allowed_url_prefix: "http://localhost:#{port}/"}]
        )

      assert result == 200
    end

    test "empty rules list denies all URLs" do
      assert_raise RuntimeError, ~r/NetworkError.*no network rules/, fn ->
        Pyex.run!(
          """
          import requests
          requests.get("http://example.com")
          """,
          network: []
        )
      end
    end

    test "mixed rules: dangerous GET + prefix POST with headers", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/public", fn conn ->
        Plug.Conn.resp(conn, 200, "public data")
      end)

      Bypass.expect_once(bypass, "POST", "/api/data", fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == "Bearer test-key"
        Plug.Conn.resp(conn, 201, "created")
      end)

      port = bypass.port

      network = [
        %{dangerously_allow_full_internet_access: true, methods: ["GET"]},
        %{
          allowed_url_prefix: "http://localhost:#{port}/api/",
          methods: ["POST"],
          headers: %{"authorization" => "Bearer test-key"}
        }
      ]

      r1 =
        Pyex.run!(
          """
          import requests
          requests.get("http://localhost:#{port}/public").text
          """,
          network: network
        )

      assert r1 == "public data"

      r2 =
        Pyex.run!(
          """
          import requests
          requests.post("http://localhost:#{port}/api/data", json={}).status_code
          """,
          network: network
        )

      assert r2 == 201
    end
  end

  describe "credential injection" do
    test "specific matching rule injects headers even when broader rule also matches", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/v1/chat", fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == "Bearer injected"

        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.post("http://localhost:#{port}/v1/chat", json={})
          response.status_code
          """,
          network: [
            %{dangerously_allow_full_internet_access: true, methods: :all},
            %{
              allowed_url_prefix: "http://localhost:#{port}/v1/",
              methods: ["POST"],
              headers: %{"authorization" => "Bearer injected"}
            }
          ]
        )

      assert result == 200
    end

    test "injects headers from network rule", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat", fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == "Bearer sk-injected"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"result": "ok"}))
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.post("http://localhost:#{port}/v1/chat", json={"prompt": "hi"})
          response.json()["result"]
          """,
          network: [
            %{
              allowed_url_prefix: "http://localhost:#{port}/v1/",
              methods: ["POST"],
              headers: %{"authorization" => "Bearer sk-injected"}
            }
          ]
        )

      assert result == "ok"
    end

    test "injected headers override user-provided headers", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat", fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        # The injected header wins, not the Python-provided one
        assert auth == "Bearer sk-from-config"

        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.post(
              "http://localhost:#{port}/v1/chat",
              json={},
              headers={"Authorization": "Bearer sk-from-python"}
          )
          response.status_code
          """,
          network: [
            %{
              allowed_url_prefix: "http://localhost:#{port}/v1/",
              methods: ["POST"],
              headers: %{"authorization" => "Bearer sk-from-config"}
            }
          ]
        )

      assert result == 200
    end

    test "multiple injected headers", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat", fn conn ->
        [key] = Plug.Conn.get_req_header(conn, "x-api-key")
        [version] = Plug.Conn.get_req_header(conn, "anthropic-version")
        assert key == "sk-ant-test"
        assert version == "2024-10-22"

        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.post("http://localhost:#{port}/v1/chat", json={})
          response.status_code
          """,
          network: [
            %{
              allowed_url_prefix: "http://localhost:#{port}/v1/",
              methods: ["POST"],
              headers: %{
                "x-api-key" => "sk-ant-test",
                "anthropic-version" => "2024-10-22"
              }
            }
          ]
        )

      assert result == 200
    end

    test "no headers injected for plain prefix rules", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/data", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          requests.get("http://localhost:#{port}/data").status_code
          """,
          network: [%{allowed_url_prefix: "http://localhost:#{port}/"}]
        )

      assert result == 200
    end

    test "user headers preserved alongside injected headers", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat", fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        [custom] = Plug.Conn.get_req_header(conn, "x-custom")
        assert auth == "Bearer sk-injected"
        assert custom == "user-value"

        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          response = requests.post(
              "http://localhost:#{port}/v1/chat",
              json={},
              headers={"X-Custom": "user-value"}
          )
          response.status_code
          """,
          network: [
            %{
              allowed_url_prefix: "http://localhost:#{port}/v1/",
              methods: ["POST"],
              headers: %{"authorization" => "Bearer sk-injected"}
            }
          ]
        )

      assert result == 200
    end
  end

  describe "normalize_network validation" do
    test "raises on rule without prefix or dangerous flag" do
      assert_raise ArgumentError, ~r/must have :allowed_url_prefix/, fn ->
        Pyex.run!("1 + 1", network: [%{methods: ["GET"]}])
      end
    end
  end
end
