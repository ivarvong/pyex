defmodule Pyex.Stdlib.RequestsSessionTest do
  @moduledoc """
  Tests for staff-level requests patterns: Session, params=, data=dict,
  and raise_for_status().
  """
  use ExUnit.Case

  @network [%{dangerously_allow_full_internet_access: true, methods: :all}]

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  # ── requests.Session ──────────────────────────────────────────────

  describe "requests.Session" do
    test "session headers flow into every request", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == "Bearer tok123"
        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          s = requests.Session()
          s.headers.update({"Authorization": "Bearer tok123"})
          r = s.get("http://localhost:#{port}/a")
          r.status_code
          """,
          network: @network
        )

      assert result == 200
    end

    test "session headers can be set via update", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/b", fn conn ->
        [key] = Plug.Conn.get_req_header(conn, "x-api-key")
        assert key == "secret"
        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          s = requests.Session()
          s.headers.update({"X-Api-Key": "secret"})
          r = s.get("http://localhost:#{port}/b")
          r.status_code
          """,
          network: @network
        )

      assert result == 200
    end

    test "per-request headers merge with session headers", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/c", fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        [extra] = Plug.Conn.get_req_header(conn, "x-extra")
        assert auth == "Bearer session"
        assert extra == "per-request"
        Plug.Conn.resp(conn, 201, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          s = requests.Session()
          s.headers.update({"Authorization": "Bearer session"})
          r = s.post("http://localhost:#{port}/c", json={}, headers={"X-Extra": "per-request"})
          r.status_code
          """,
          network: @network
        )

      assert result == 201
    end

    test "session supports all HTTP methods", %{bypass: bypass} do
      for method <- ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"] do
        Bypass.expect_once(bypass, method, "/#{String.downcase(method)}", fn conn ->
          Plug.Conn.resp(conn, 200, "")
        end)
      end

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          s = requests.Session()
          codes = []
          codes.append(s.get("http://localhost:#{port}/get").status_code)
          codes.append(s.post("http://localhost:#{port}/post", json={}).status_code)
          codes.append(s.put("http://localhost:#{port}/put", json={}).status_code)
          codes.append(s.patch("http://localhost:#{port}/patch", json={}).status_code)
          codes.append(s.delete("http://localhost:#{port}/delete").status_code)
          codes.append(s.head("http://localhost:#{port}/head").status_code)
          codes.append(s.options("http://localhost:#{port}/options").status_code)
          codes
          """,
          network: @network
        )

      assert result == [200, 200, 200, 200, 200, 200, 200]
    end
  end

  # ── params= kwarg ─────────────────────────────────────────────────

  describe "params= kwarg" do
    test "params dict is appended as query string", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/search", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["q"] == "elixir"
        assert conn.query_params["page"] == "2"
        Plug.Conn.resp(conn, 200, "results")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          r = requests.get("http://localhost:#{port}/search", params={"q": "elixir", "page": "2"})
          r.text
          """,
          network: @network
        )

      assert result == "results"
    end

    test "params with integer values are stringified", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["venue_id"] == "5456"
        assert conn.query_params["day"] == "2026-04-02"
        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          r = requests.get("http://localhost:#{port}/api", params={"venue_id": 5456, "day": "2026-04-02"})
          r.status_code
          """,
          network: @network
        )

      assert result == 200
    end

    test "params appends to URL that already has a query string", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/search", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["existing"] == "1"
        assert conn.query_params["added"] == "2"
        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          r = requests.get("http://localhost:#{port}/search?existing=1", params={"added": "2"})
          r.status_code
          """,
          network: @network
        )

      assert result == 200
    end

    test "params works with Session too", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/sess", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["token"] == "abc"
        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          s = requests.Session()
          r = s.get("http://localhost:#{port}/sess", params={"token": "abc"})
          r.status_code
          """,
          network: @network
        )

      assert result == 200
    end
  end

  # ── data=dict auto-encoding ───────────────────────────────────────

  describe "data=dict auto form-encoding" do
    test "data=dict sends form-encoded body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/login", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["email"] == "a@b.com"
        assert params["password"] == "hunter2"
        Plug.Conn.resp(conn, 200, "logged in")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          r = requests.post("http://localhost:#{port}/login", data={"email": "a@b.com", "password": "hunter2"})
          r.text
          """,
          network: @network
        )

      assert result == "logged in"
    end

    test "data=dict works with Session", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/form", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["user"] == "alice"
        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          s = requests.Session()
          r = s.post("http://localhost:#{port}/form", data={"user": "alice"})
          r.text
          """,
          network: @network
        )

      assert result == "ok"
    end

    test "data=string still sends raw body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/raw", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == "raw payload"
        Plug.Conn.resp(conn, 200, "ok")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          r = requests.post("http://localhost:#{port}/raw", data="raw payload")
          r.text
          """,
          network: @network
        )

      assert result == "ok"
    end
  end

  # ── raise_for_status() ────────────────────────────────────────────

  describe "response.raise_for_status()" do
    test "no-op on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/ok", fn conn ->
        Plug.Conn.resp(conn, 200, "fine")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          r = requests.get("http://localhost:#{port}/ok")
          r.raise_for_status()
          r.text
          """,
          network: @network
        )

      assert result == "fine"
    end

    test "raises HTTPError on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/missing", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      port = bypass.port

      assert_raise RuntimeError, ~r/requests\.HTTPError.*404/, fn ->
        Pyex.run!(
          """
          import requests
          r = requests.get("http://localhost:#{port}/missing")
          r.raise_for_status()
          """,
          network: @network
        )
      end
    end

    test "no-op on 302 redirect", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/redir", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/other")
        |> Plug.Conn.resp(302, "")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          r = requests.get("http://localhost:#{port}/redir")
          r.raise_for_status()
          r.status_code
          """,
          network: @network
        )

      assert result == 302
    end

    test "raises HTTPError on 500", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/error", fn conn ->
        Plug.Conn.resp(conn, 500, "internal error")
      end)

      port = bypass.port

      assert_raise RuntimeError, ~r/requests\.HTTPError.*500/, fn ->
        Pyex.run!(
          """
          import requests
          r = requests.get("http://localhost:#{port}/error")
          r.raise_for_status()
          """,
          network: @network
        )
      end
    end

    test "catchable with except requests.HTTPError", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/fail", fn conn ->
        Plug.Conn.resp(conn, 403, "forbidden")
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          try:
              r = requests.get("http://localhost:#{port}/fail")
              r.raise_for_status()
          except requests.HTTPError as e:
              result = "caught"
          result
          """,
          network: @network
        )

      assert result == "caught"
    end
  end
end
