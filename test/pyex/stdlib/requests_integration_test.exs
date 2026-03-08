defmodule Pyex.Stdlib.RequestsIntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Pyex.Error

  @moduletag :external_http
  @moduletag timeout: 30_000

  describe "real HTTP endpoints" do
    test "GETs a real JSON endpoint with a prefix rule" do
      result =
        Pyex.run!(
          """
          import requests

          response = requests.get("https://postman-echo.com/get?source=pyex")
          data = response.json()
          [
              response.status_code,
              response.ok,
              "content-type" in response.headers,
              data["args"]["source"],
              data["headers"]["host"],
              data["url"]
          ]
          """,
          network: [%{allowed_url_prefix: "https://postman-echo.com/get"}]
        )

      assert result == [
               200,
               true,
               true,
               "pyex",
               "postman-echo.com",
               "https://postman-echo.com/get?source=pyex"
             ]
    end

    test "denies a live request when the prefix rule does not match" do
      assert {:error, %Error{message: message}} =
               Pyex.run(
                 """
                 import requests
                 requests.get("https://postman-echo.com/get?blocked=1")
                 """,
                 network: [%{allowed_url_prefix: "https://example.com/"}]
               )

      assert message =~ "NetworkError: URL is not allowed"
      assert message =~ "https://example.com/"
    end

    test "POSTs to a real endpoint with injected headers" do
      result =
        Pyex.run!(
          """
          import requests

          response = requests.post(
              "https://postman-echo.com/post",
              json={"message": "hello"},
              headers={"X-User-Header": "from-python"}
          )
          data = response.json()
          [
              response.status_code,
              response.ok,
              response.headers["content-type"][0],
              data["json"]["message"],
              data["headers"]["x-pyex-token"],
              data["headers"]["x-user-header"],
              data["headers"]["content-type"],
              data["url"]
          ]
          """,
          network: [
            %{
              allowed_url_prefix: "https://postman-echo.com/post",
              methods: ["POST"],
              headers: %{"x-pyex-token" => "integration-secret"}
            }
          ]
        )

      assert result == [
               200,
               true,
               "application/json; charset=utf-8",
               "hello",
               "integration-secret",
               "from-python",
               "application/json",
               "https://postman-echo.com/post"
             ]
    end

    test "config-injected headers win over Python headers on a live endpoint" do
      result =
        Pyex.run!(
          """
          import requests

          response = requests.post(
              "https://postman-echo.com/post",
              json={"message": "hello"},
              headers={
                  "X-Pyex-Token": "from-python",
                  "X-User-Header": "still-present"
              }
          )
          data = response.json()
          [
              response.status_code,
              response.ok,
              response.headers["content-type"][0],
              data["headers"]["x-pyex-token"],
              data["headers"]["x-user-header"],
              data["data"]["message"],
              data["url"]
          ]
          """,
          network: [
            %{dangerously_allow_full_internet_access: true, methods: ["POST"]},
            %{
              allowed_url_prefix: "https://postman-echo.com/post",
              methods: ["POST"],
              headers: %{"x-pyex-token" => "from-config"}
            }
          ]
        )

      assert result == [
               200,
               true,
               "application/json; charset=utf-8",
               "from-config",
               "still-present",
               "hello",
               "https://postman-echo.com/post"
             ]
    end

    test "handles a live non-2xx response without crashing" do
      result =
        Pyex.run!(
          """
          import requests

          response = requests.get("https://postman-echo.com/status/418")
          [response.status_code, response.ok, response.text, response.json()["status"]]
          """,
          network: [%{allowed_url_prefix: "https://postman-echo.com/status/"}]
        )

      assert result == [418, false, ~s({"status":418}), 418]
    end
  end
end
