defmodule PyexTest do
  use ExUnit.Case

  alias Pyex.Error

  @network [dangerously_allow_full_internet_access: true]

  describe "end-to-end: two functions doing math" do
    test "define add and multiply, compose them" do
      result =
        Pyex.run!("""
        def add(a, b):
            return a + b

        def multiply(x, y):
            return x * y

        result = add(3, 4)
        result = multiply(result, 5)
        result
        """)

      assert result == 35
    end

    test "nested function calls in expressions" do
      result =
        Pyex.run!("""
        def square(n):
            return n * n

        def add(a, b):
            return a + b

        add(square(3), square(4))
        """)

      assert result == 25
    end

    test "function with conditional logic" do
      result =
        Pyex.run!("""
        def abs_val(x):
            if x < 0:
                return -x
            else:
                return x

        def distance(a, b):
            return abs_val(a - b)

        distance(3, 10)
        """)

      assert result == 7
    end
  end

  describe "end-to-end: HTTP GET, parse JSON, iterate" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass}
    end

    test "fetch JSON list and sum a field", %{bypass: bypass} do
      payload =
        Jason.encode!([
          %{"name" => "a", "value" => 10},
          %{"name" => "b", "value" => 20},
          %{"name" => "c", "value" => 12}
        ])

      Bypass.expect_once(bypass, "GET", "/api/items", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, payload)
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          import json

          response = requests.get("http://localhost:#{port}/api/items")
          data = json.loads(response.text)
          total = 0
          for item in data:
              total = total + item["value"]
          total
          """,
          network: @network
        )

      assert result == 42
    end

    test "fetch JSON and filter with conditional", %{bypass: bypass} do
      payload =
        Jason.encode!([
          %{"name" => "x", "score" => 85},
          %{"name" => "y", "score" => 42},
          %{"name" => "z", "score" => 91}
        ])

      Bypass.expect_once(bypass, "GET", "/api/scores", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, payload)
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          import json

          response = requests.get("http://localhost:#{port}/api/scores")
          items = json.loads(response.text)
          count = 0
          for item in items:
              if item["score"] > 80:
                  count = count + 1
          count
          """,
          network: @network
        )

      assert result == 2
    end
  end

  describe "end-to-end: haversine distance in nautical miles" do
    @moduledoc """
    Coordinates sourced from METAR station data via
    https://echo.2fsk.com/v1/metars/{station}

    KJFK  40.6392  -73.7639
    KPDX  45.5958 -122.6092
    KLAX  33.9382 -118.3866
    """

    test "computes great-circle distances for JFK, PDX, LAX" do
      result =
        Pyex.run!("""
        import math

        EARTH_RADIUS_NM = 3440.065

        def haversine_nm(lat1, lon1, lat2, lon2):
          dlat = math.radians(lat2 - lat1)
          dlon = math.radians(lon2 - lon1)
          rlat1 = math.radians(lat1)
          rlat2 = math.radians(lat2)
          a = math.sin(dlat / 2) ** 2 + math.cos(rlat1) * math.cos(rlat2) * math.sin(dlon / 2) ** 2
          c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
          return EARTH_RADIUS_NM * c

        airports = {
          "JFK": [40.6392, -73.7639],
          "PDX": [45.5958, -122.6092],
          "LAX": [33.9382, -118.3866]
        }

        pairs = [["JFK", "LAX"], ["JFK", "PDX"], ["PDX", "LAX"]]

        distances = {}
        for pair in pairs:
          origin = airports[pair[0]]
          dest = airports[pair[1]]
          nm = round(haversine_nm(origin[0], origin[1], dest[0], dest[1]))
          key = pair[0] + "-" + pair[1]
          distances[key] = nm

        distances
        """)

      assert result == %{
               "JFK-LAX" => 2146,
               "JFK-PDX" => 2128,
               "PDX-LAX" => 726
             }
    end

    test "same airport returns zero distance" do
      result =
        Pyex.run!("""
        import math

        EARTH_RADIUS_NM = 3440.065

        def haversine_nm(lat1, lon1, lat2, lon2):
          dlat = math.radians(lat2 - lat1)
          dlon = math.radians(lon2 - lon1)
          rlat1 = math.radians(lat1)
          rlat2 = math.radians(lat2)
          a = math.sin(dlat / 2) ** 2 + math.cos(rlat1) * math.cos(rlat2) * math.sin(dlon / 2) ** 2
          c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
          return EARTH_RADIUS_NM * c

        haversine_nm(45.5958, -122.6092, 45.5958, -122.6092)
        """)

      assert result == 0.0
    end
  end

  describe "end-to-end: FastAPI handler calls external API" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass}
    end

    test "handler reads environ, POSTs to external API, computes, returns JSON", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/v1/enrich", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer sk-test-key-123"]
        assert payload["ticker"] == "AAPL"

        response =
          Jason.encode!(%{
            "ticker" => payload["ticker"],
            "prices" => [150.0, 155.0, 148.0, 162.0, 158.0],
            "volume" => 1_250_000
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response)
      end)

      port = bypass.port

      source = """
      import fastapi
      import requests
      import json
      import os

      app = fastapi.FastAPI()

      @app.get("/analyze")
      def analyze(ticker):
          api_key = os.environ["API_KEY"]
          api_url = os.environ["API_URL"]
          response = requests.post(
              api_url + "/v1/enrich",
              json={"ticker": ticker},
              headers={"Authorization": "Bearer " + api_key}
          )
          data = json.loads(response.text)
          prices = data["prices"]
          total = 0
          for p in prices:
              total = total + p
          avg_price = round(total / len(prices), 2)
          high = max(prices)
          low = min(prices)
          return {
              "ticker": data["ticker"],
              "avg_price": avg_price,
              "high": high,
              "low": low,
              "volume": data["volume"],
              "spread": round(high - low, 2)
          }
      """

      ctx =
        Pyex.Ctx.new(
          environ: %{
            "API_KEY" => "sk-test-key-123",
            "API_URL" => "http://localhost:#{port}"
          },
          network: @network
        )

      request = %{method: "GET", path: "/analyze", query: %{"ticker" => "AAPL"}}
      assert {:ok, resp} = Pyex.Lambda.invoke(source, request, ctx: ctx)

      assert resp.status == 200
      assert resp.body["ticker"] == "AAPL"
      assert resp.body["avg_price"] == 154.6
      assert resp.body["high"] == 162.0
      assert resp.body["low"] == 148.0
      assert resp.body["volume"] == 1_250_000
      assert resp.body["spread"] == 14.0
    end
  end

  describe "end-to-end: fetch METAR and validate with pydantic" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass}
    end

    @metar_json """
    {"id":"KJFK","object":"metar","wind_speed_kt":12,"latitude":40.6392,"longitude":-73.7639,"flight_category":"VFR","cloud_layers":[{"cover":"FEW","base_ft_agl":13000},{"cover":"SCT","base_ft_agl":25000}],"visibility_sm":10.0,"wind_direction_degrees":300,"wind_gust_kt":null,"raw_text":"METAR KJFK 091951Z 30012KT 10SM FEW130 SCT250 M02/M14 A3021 RMK AO2 SLP231 T10171144 $","station_id":"KJFK","temperature_c":-1.7,"altimeter_inhg":30.21,"observed_at":"2026-02-09T19:51:00.000Z","fetched_at":"2026-02-09T20:50:04.320912Z","dewpoint_c":-14.4,"elevation_m":3.0,"metar_type":"METAR","sea_level_pressure_mb":1023.1,"wx_string":null,"density_altitude_ft":-2349,"observation_age_min":59.5}
    """

    test "fetch METAR JSON and parse into pydantic model", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/metars/KJFK", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, @metar_json)
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          from pydantic import BaseModel, Field

          class Metar(BaseModel):
              id: str
              station_id: str
              metar_type: str
              raw_text: str
              observed_at: str
              flight_category: str
              temperature_c: float
              dewpoint_c: float
              wind_speed_kt: int
              wind_direction_degrees: int
              wind_gust_kt: Optional[int] = None
              visibility_sm: float
              altimeter_inhg: float
              sea_level_pressure_mb: float
              elevation_m: float
              latitude: float
              longitude: float
              density_altitude_ft: int
              cloud_layers: list
              wx_string: Optional[str] = None
              observation_age_min: float

          resp = requests.get("http://localhost:#{port}/v1/metars/KJFK")
          data = resp.json()
          metar = Metar.model_validate(data)

          [
              metar.station_id,
              metar.flight_category,
              metar.temperature_c,
              metar.dewpoint_c,
              metar.wind_speed_kt,
              metar.wind_direction_degrees,
              metar.wind_gust_kt,
              metar.visibility_sm,
              metar.altimeter_inhg,
              metar.latitude,
              metar.longitude,
              metar.wx_string,
              len(metar.cloud_layers),
              metar.density_altitude_ft,
          ]
          """,
          network: @network
        )

      assert [
               "KJFK",
               "VFR",
               -1.7,
               -14.4,
               12,
               300,
               nil,
               10.0,
               30.21,
               40.6392,
               -73.7639,
               nil,
               2,
               -2349
             ] = result
    end

    test "compute spread and density altitude from METAR", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/metars/KJFK", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, @metar_json)
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          from pydantic import BaseModel

          class Metar(BaseModel):
              station_id: str
              temperature_c: float
              dewpoint_c: float
              wind_speed_kt: int
              wind_gust_kt: Optional[int] = None
              altimeter_inhg: float
              density_altitude_ft: int

          resp = requests.get("http://localhost:#{port}/v1/metars/KJFK")
          metar = Metar.model_validate(resp.json())

          spread = metar.temperature_c - metar.dewpoint_c
          effective_wind = metar.wind_gust_kt if metar.wind_gust_kt is not None else metar.wind_speed_kt
          below_sea = metar.density_altitude_ft < 0

          d = metar.model_dump()
          d["spread"] = round(spread, 1)
          d["effective_wind"] = effective_wind
          d["below_sea_level"] = below_sea
          [d["station_id"], d["spread"], d["effective_wind"], d["below_sea_level"], d["density_altitude_ft"]]
          """,
          network: @network
        )

      assert result == ["KJFK", 12.7, 12, true, -2349]
    end

    test "METAR validation rejects missing required field", %{bypass: bypass} do
      incomplete = Jason.encode!(%{"station_id" => "KJFK"})

      Bypass.expect_once(bypass, "GET", "/v1/metars/KJFK", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, incomplete)
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          from pydantic import BaseModel

          class Metar(BaseModel):
              station_id: str
              temperature_c: float
              wind_speed_kt: int

          resp = requests.get("http://localhost:#{port}/v1/metars/KJFK")

          try:
              metar = Metar.model_validate(resp.json())
              "should not reach"
          except Exception as e:
              error = str(e)

          [
              "temperature_c" in error,
              "wind_speed_kt" in error,
          ]
          """,
          network: @network
        )

      assert result == [true, true]
    end

    test "batch parse multiple METARs", %{bypass: bypass} do
      stations =
        Jason.encode!([
          %{
            "station_id" => "KJFK",
            "temperature_c" => -1.7,
            "wind_speed_kt" => 12,
            "flight_category" => "VFR"
          },
          %{
            "station_id" => "KLAX",
            "temperature_c" => 15.0,
            "wind_speed_kt" => 7,
            "flight_category" => "VFR"
          },
          %{
            "station_id" => "KORD",
            "temperature_c" => -8.3,
            "wind_speed_kt" => 22,
            "flight_category" => "MVFR"
          }
        ])

      Bypass.expect_once(bypass, "GET", "/v1/metars", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, stations)
      end)

      port = bypass.port

      result =
        Pyex.run!(
          """
          import requests
          from pydantic import BaseModel

          class StationWeather(BaseModel):
              station_id: str
              temperature_c: float
              wind_speed_kt: int
              flight_category: str

          resp = requests.get("http://localhost:#{port}/v1/metars")
          raw_list = resp.json()
          stations = [StationWeather.model_validate(s) for s in raw_list]

          vfr = [s for s in stations if s.flight_category == "VFR"]
          coldest = min(stations, key=lambda s: s.temperature_c)
          windiest = max(stations, key=lambda s: s.wind_speed_kt)
          avg_temp = sum([s.temperature_c for s in stations]) / len(stations)

          [
              len(vfr),
              coldest.station_id,
              windiest.station_id,
              round(avg_temp, 1),
          ]
          """,
          network: @network
        )

      assert result == [2, "KORD", "KORD", 1.7]
    end
  end

  describe "end-to-end: error reporting" do
    test "parse errors propagate through Pyex.run/1" do
      assert {:error, %Error{message: message}} = Pyex.run("(1 +")
      assert message =~ "unexpected"
    end

    test "lexer errors propagate through Pyex.run/1" do
      assert {:error, %Error{message: message}} = Pyex.run("`invalid")
      assert message =~ "Lexer error"
    end
  end
end
