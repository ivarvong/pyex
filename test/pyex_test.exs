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
          env: %{
            "API_KEY" => "sk-test-key-123",
            "API_URL" => "http://localhost:#{port}"
          },
          network: @network
        )

      request = %{method: "GET", path: "/analyze", query_params: %{"ticker" => "AAPL"}}
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

  describe "Pyex.output/1" do
    test "captures print output" do
      {:ok, _val, ctx} = Pyex.run("print('hello')\nprint('world')")
      assert IO.iodata_to_binary(Pyex.output(ctx)) == "hello\nworld"
    end

    test "returns empty string when no output" do
      {:ok, _val, ctx} = Pyex.run("x = 42")
      assert Pyex.output(ctx) == ""
    end
  end

  describe "ctx.duration_ms" do
    test "is set after a successful run" do
      {:ok, _val, ctx} = Pyex.run("1 + 1")
      assert is_float(ctx.duration_ms)
      assert ctx.duration_ms >= 0.0
    end

    test "reflects actual elapsed time" do
      {:ok, _val, ctx} =
        Pyex.run("""
        x = 0
        for i in range(10000):
            x = x + i
        x
        """)

      assert ctx.duration_ms > 0.0
      assert ctx.duration_ms < 5_000.0
    end

    test "is nil on a fresh ctx before running" do
      ctx = Pyex.Ctx.new()
      assert ctx.duration_ms == nil
    end

    test "is longer for more work" do
      {:ok, _, ctx_small} = Pyex.run("sum(range(100))")
      {:ok, _, ctx_large} = Pyex.run("sum(range(100000))")
      assert ctx_large.duration_ms > ctx_small.duration_ms
    end
  end

  describe "end-to-end: static site generator" do
    @ssg_fs %{
      "config.yaml" => """
      ---
      site_name: My Blog
      author: Ada
      ---
      """,
      "posts/hello-world.md" => """
      ---
      title: Hello World
      date: 2026-01-15
      tags:
        - intro
        - elixir
      ---
      Welcome to the site. This is the **first** post.
      """,
      "posts/deep-dive.md" => """
      ---
      title: A Deep Dive
      date: 2026-02-10
      tags:
        - tutorial
      ---
      Let's explore something *interesting* in depth.
      """,
      "posts/release-notes.md" => """
      ---
      title: Release Notes v2
      date: 2026-03-05
      tags:
        - release
        - changelog
      ---
      Several bugs **fixed**. Performance improved across the board.
      """,
      "templates/layout.html" => ~S"""
      <!doctype html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <title>{{ title }} | {{ site_name }}</title>
        <link rel="stylesheet" href="/style.css">
      </head>
      <body>
        <header><a href="/">{{ site_name }}</a></header>
        <main>{{ content | safe }}</main>
        <footer>&copy; {{ author }}</footer>
      </body>
      </html>
      """,
      "templates/post.html" => ~S"""
      <article>
        <h1>{{ title }}</h1>
        <time>{{ date }}</time>
        <ul class="tags">{% for tag in tags %}<li><a href="/tags/{{ tag }}">{{ tag }}</a></li>{% endfor %}</ul>
        <div class="body">{{ body | safe }}</div>
      </article>
      """,
      "templates/index.html" => ~S"""
      <h1>{{ site_name }}</h1>
      <p>By {{ author }}</p>
      <ul>
        {% for post in posts %}
        <li><a href="/{{ post.slug }}">{{ post.title }}</a> &mdash; <time>{{ post.date }}</time></li>
        {% endfor %}
      </ul>
      """,
      "templates/tag.html" => ~S"""
      <h1>Posts tagged &ldquo;{{ tag }}&rdquo;</h1>
      <ul>
        {% for post in posts %}
        <li><a href="/{{ post.slug }}">{{ post.title }}</a> &mdash; <time>{{ post.date }}</time></li>
        {% endfor %}
      </ul>
      """
    }

    @ssg_script ~S"""
    import json
    import os
    import time
    import yaml
    import markdown
    from datetime import date
    from jinja2 import Template
    from pydantic import BaseModel

    class Config(BaseModel):
        site_name: str
        author: str

    class Post(BaseModel):
        title: str
        slug: str
        date: date
        tags: list
        body: str
        body_html: str

    def parse_frontmatter(text):
        parts = text.split("---\n", 2)
        if len(parts) < 3:
            raise ValueError("missing frontmatter")
        return yaml.safe_load(parts[1]), parts[2].strip()

    build_start = time.monotonic()

    # --- load config and templates ---

    with open("config.yaml") as f:
        config = Config(**parse_frontmatter(f.read())[0])

    with open("templates/layout.html") as f:
        layout_tmpl = Template(f.read())
    with open("templates/post.html") as f:
        post_tmpl = Template(f.read())
    with open("templates/index.html") as f:
        index_tmpl = Template(f.read())
    with open("templates/tag.html") as f:
        tag_tmpl = Template(f.read())

    # --- load and render posts ---

    posts = []
    for filename in sorted(os.listdir("posts")):
        slug = os.path.splitext(filename)[0]
        with open(os.path.join("posts", filename)) as f:
            meta, body = parse_frontmatter(f.read())
        posts.append(Post(
            title=meta["title"],
            slug=slug,
            date=meta["date"],
            tags=meta["tags"],
            body=body,
            body_html=markdown.markdown(body)
        ))

    posts = sorted(posts, key=lambda p: p.date, reverse=True)

    # build tag -> [post] index (sorted newest-first within each tag)
    tag_index = {}
    for post in posts:
        for tag in post.tags:
            if tag not in tag_index:
                tag_index[tag] = []
            tag_index[tag].append(post)

    # --- write output ---

    pages_written = 0

    for post in posts:
        with open(post.slug + ".html", "w") as f:
            f.write(layout_tmpl.render(
                title=post.title,
                site_name=config.site_name,
                author=config.author,
                content=post_tmpl.render(
                    title=post.title,
                    date=post.date,
                    tags=post.tags,
                    body=post.body_html
                )
            ))
        pages_written = pages_written + 1

    with open("index.html", "w") as f:
        f.write(layout_tmpl.render(
            title="Home",
            site_name=config.site_name,
            author=config.author,
            content=index_tmpl.render(
                site_name=config.site_name,
                author=config.author,
                posts=posts
            )
        ))
    pages_written = pages_written + 1

    os.makedirs("tags")
    for tag, tagged_posts in tag_index.items():
        with open(os.path.join("tags", tag + ".html"), "w") as f:
            f.write(layout_tmpl.render(
                title="Tag: " + tag,
                site_name=config.site_name,
                author=config.author,
                content=tag_tmpl.render(tag=tag, posts=tagged_posts)
            ))
        pages_written = pages_written + 1

    build_elapsed_ms = (time.monotonic() - build_start) * 1000

    report = {
        "site_name": config.site_name,
        "posts": len(posts),
        "tags": len(tag_index),
        "pages": pages_written,
        "tag_names": sorted(tag_index.keys()),
        "build_ms": build_elapsed_ms
    }

    with open("build.json", "w") as f:
        f.write(json.dumps(report))

    len(posts)
    """

    @ssg_css """
    body { font-family: sans-serif; max-width: 800px; margin: 0 auto; }
    header { border-bottom: 1px solid #ccc; }
    ul.tags li { background: #eee; padding: 0.2rem 0.6rem; border-radius: 4px; }
    """

    test "generates HTML pages from markdown posts with frontmatter via pydantic, jinja2 templates, and css" do
      fs = Pyex.Filesystem.Memory.new(Map.put(@ssg_fs, "style.css", @ssg_css))

      # Compile once so the warmup and timed runs share the same AST.
      {:ok, ast} = Pyex.compile(@ssg_script)

      # Warmup: one run to let the BEAM JIT compile all touched interpreter clauses.
      {:ok, post_count, ctx} = Pyex.run(ast, filesystem: fs)

      assert post_count == 3

      {:ok, index} = Pyex.Filesystem.Memory.read(ctx.filesystem, "index.html")
      {:ok, hello} = Pyex.Filesystem.Memory.read(ctx.filesystem, "hello-world.html")
      {:ok, dive} = Pyex.Filesystem.Memory.read(ctx.filesystem, "deep-dive.html")
      {:ok, notes} = Pyex.Filesystem.Memory.read(ctx.filesystem, "release-notes.html")

      # layout chrome on every page
      for page <- [index, hello, dive, notes] do
        assert page =~ ~s(<link rel="stylesheet" href="/style.css">)
        assert page =~ ~s(<a href="/">My Blog</a>)
        assert page =~ "&copy; Ada"
      end

      # index: sorted newest-first, all three posts linked
      assert index =~ "<title>Home | My Blog</title>"
      assert index =~ ~s(<a href="/release-notes">Release Notes v2</a>)
      assert index =~ ~s(<a href="/deep-dive">A Deep Dive</a>)
      assert index =~ ~s(<a href="/hello-world">Hello World</a>)

      [release_pos, dive_pos, hello_pos] = [
        :binary.match(index, "Release Notes v2") |> elem(0),
        :binary.match(index, "A Deep Dive") |> elem(0),
        :binary.match(index, "Hello World") |> elem(0)
      ]

      assert release_pos < dive_pos
      assert dive_pos < hello_pos

      # post pages: title in <title>, date, tags linked, markdown body rendered to HTML
      assert hello =~ "<title>Hello World | My Blog</title>"
      assert hello =~ "<h1>Hello World</h1>"
      assert hello =~ "<time>2026-01-15</time>"
      assert hello =~ ~s(<a href="/tags/intro">intro</a>)
      assert hello =~ ~s(<a href="/tags/elixir">elixir</a>)
      assert hello =~ "<strong>first</strong>"

      assert dive =~ "<title>A Deep Dive | My Blog</title>"
      assert dive =~ "<em>interesting</em>"
      assert dive =~ ~s(<a href="/tags/tutorial">tutorial</a>)

      assert notes =~ "<title>Release Notes v2 | My Blog</title>"
      assert notes =~ "<strong>fixed</strong>"
      assert notes =~ ~s(<a href="/tags/release">release</a>)
      assert notes =~ ~s(<a href="/tags/changelog">changelog</a>)

      # tag pages exist and list the right posts
      {:ok, tag_intro} = Pyex.Filesystem.Memory.read(ctx.filesystem, "tags/intro.html")
      {:ok, tag_elixir} = Pyex.Filesystem.Memory.read(ctx.filesystem, "tags/elixir.html")
      {:ok, tag_tutorial} = Pyex.Filesystem.Memory.read(ctx.filesystem, "tags/tutorial.html")
      {:ok, tag_release} = Pyex.Filesystem.Memory.read(ctx.filesystem, "tags/release.html")
      {:ok, tag_changelog} = Pyex.Filesystem.Memory.read(ctx.filesystem, "tags/changelog.html")

      assert tag_intro =~ "<title>Tag: intro | My Blog</title>"
      assert tag_intro =~ ~s(Posts tagged)
      assert tag_intro =~ ~s(<a href="/hello-world">Hello World</a>)
      refute tag_intro =~ "A Deep Dive"
      refute tag_intro =~ "Release Notes"

      assert tag_elixir =~ ~s(<a href="/hello-world">Hello World</a>)

      assert tag_tutorial =~ ~s(<a href="/deep-dive">A Deep Dive</a>)
      refute tag_tutorial =~ "Hello World"

      assert tag_release =~ ~s(<a href="/release-notes">Release Notes v2</a>)
      assert tag_changelog =~ ~s(<a href="/release-notes">Release Notes v2</a>)

      # layout chrome on tag pages too
      for tag_page <- [tag_intro, tag_elixir, tag_tutorial, tag_release, tag_changelog] do
        assert tag_page =~ ~s(<link rel="stylesheet" href="/style.css">)
        assert tag_page =~ ~s(<a href="/">My Blog</a>)
        assert tag_page =~ "&copy; Ada"
      end

      # build report
      {:ok, report_json} = Pyex.Filesystem.Memory.read(ctx.filesystem, "build.json")
      report = Jason.decode!(report_json)

      assert report["site_name"] == "My Blog"
      assert report["posts"] == 3
      assert report["tags"] == 5
      assert report["pages"] == 9
      assert report["tag_names"] == ["changelog", "elixir", "intro", "release", "tutorial"]
      assert is_float(report["build_ms"])
      assert report["build_ms"] > 0

      # Timing: 50 iterations with a fresh filesystem each time, using
      # microsecond-resolution Elixir monotonic clock rather than the
      # 1ms-quantized time.monotonic inside the script.
      n_iters = 50

      iter_times_us =
        for _ <- 1..n_iters do
          fresh_fs = Pyex.Filesystem.Memory.new(Map.put(@ssg_fs, "style.css", @ssg_css))
          t0 = System.monotonic_time(:microsecond)
          {:ok, _, _} = Pyex.run(ast, filesystem: fresh_fs)
          System.monotonic_time(:microsecond) - t0
        end

      sorted_us = Enum.sort(iter_times_us)
      p10_ms = Enum.at(sorted_us, div(n_iters, 10)) / 1000.0
      p50_ms = Enum.at(sorted_us, div(n_iters, 2)) / 1000.0
      p90_ms = Enum.at(sorted_us, div(n_iters * 9, 10)) / 1000.0

      # ctx.duration_ms from the warmup run (interpret-only, excludes compile)
      ctx_ms = ctx.duration_ms

      IO.puts("""

      SSG timing (#{n_iters} warm iterations, pre-compiled AST)
        p10  : #{:erlang.float_to_binary(p10_ms, decimals: 3)} ms
        p50  : #{:erlang.float_to_binary(p50_ms, decimals: 3)} ms
        p90  : #{:erlang.float_to_binary(p90_ms, decimals: 3)} ms
        ctx.duration_ms (warmup, interpret only) : #{:erlang.float_to_binary(ctx_ms, decimals: 3)} ms
      """)

      # p50 should be reasonable; p90 allows for scheduler jitter
      assert p50_ms < 10.0, "warm p50 #{p50_ms}ms should be under 10ms"
      assert p90_ms < 50.0, "warm p90 #{p90_ms}ms should be under 50ms"

      # ctx_ms from the warmup run is interpretation time only, so it should
      # be in the same ballpark as our timed iterations
      assert ctx_ms < 50.0, "ctx.duration_ms #{ctx_ms}ms should be under 50ms"
    end
  end
end
