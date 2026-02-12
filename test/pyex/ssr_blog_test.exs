defmodule Pyex.SsrBlogTest do
  use ExUnit.Case, async: true

  alias Pyex.{Ctx, Lambda}
  alias Pyex.Filesystem.Memory

  @source """
  import fastapi
  import json
  import markdown
  import uuid
  from fastapi import HTMLResponse
  from jinja2 import Template

  app = fastapi.FastAPI()

  post_template = Template(\"\"\"<html>
  <head><title>{{ title }}</title></head>
  <body>
  <h1>{{ title }}</h1>
  <article>{{ content | safe }}</article>
  <a href="/posts">Back to posts</a>
  </body>
  </html>\"\"\")

  list_template = Template(\"\"\"<html>
  <head><title>Blog</title></head>
  <body>
  <h1>Blog Posts</h1>
  <ul>
  {% for post in posts %}
  <li><a href="/posts/{{ post.id }}">{{ post.title }}</a></li>
  {% endfor %}
  </ul>
  </body>
  </html>\"\"\")

  def load_posts():
      try:
          f = open("posts.json", "r")
          data = f.read()
          f.close()
          return json.loads(data)
      except:
          return []

  def save_posts(posts):
      f = open("posts.json", "w")
      f.write(json.dumps(posts))
      f.close()

  @app.get("/posts")
  def list_posts():
      posts = load_posts()
      html = list_template.render(posts=posts)
      return HTMLResponse(html)

  @app.get("/posts/{post_id}")
  def get_post(post_id):
      posts = load_posts()
      for p in posts:
          if p["id"] == post_id:
              html_content = markdown.markdown(p["body"])
              html = post_template.render(title=p["title"], content=html_content)
              return HTMLResponse(html)
      return HTMLResponse("<h1>Not Found</h1>", status_code=404)

  @app.post("/posts")
  def create_post(request):
      data = request.json()
      posts = load_posts()
      post = {
          "id": str(uuid.uuid4()),
          "title": data["title"],
          "body": data["body"]
      }
      posts.append(post)
      save_posts(posts)
      return {"id": post["id"], "title": post["title"]}
  """

  defp boot_blog do
    ctx = Ctx.new(filesystem: Memory.new())
    {:ok, app} = Lambda.boot(@source, ctx: ctx)
    app
  end

  defp post(app, path, body) do
    Lambda.handle(app, %{method: "POST", path: path, body: Jason.encode!(body)})
  end

  defp get(app, path) do
    Lambda.handle(app, %{method: "GET", path: path})
  end

  describe "SSR blog" do
    test "empty blog returns HTML with no list items" do
      app = boot_blog()
      {:ok, resp, _app} = get(app, "/posts")

      assert resp.status == 200
      assert resp.headers["content-type"] == "text/html"
      assert resp.body =~ "<h1>Blog Posts</h1>"
      assert resp.body =~ "<ul>"
      refute resp.body =~ "<li>"
    end

    test "create post returns JSON with id and title" do
      app = boot_blog()

      {:ok, resp, _app} =
        post(app, "/posts", %{"title" => "Hello World", "body" => "# Welcome\n\nFirst post!"})

      assert resp.status == 200
      assert resp.headers["content-type"] == "application/json"
      assert is_binary(resp.body["id"])
      assert String.length(resp.body["id"]) == 36
      assert resp.body["title"] == "Hello World"
    end

    test "created post appears in listing" do
      app = boot_blog()

      {:ok, _resp, app} =
        post(app, "/posts", %{"title" => "Test Post", "body" => "Content"})

      {:ok, resp, _app} = get(app, "/posts")

      assert resp.status == 200
      assert resp.body =~ "Test Post"
      assert resp.body =~ "<li>"
      assert resp.body =~ "<a href="
    end

    test "individual post renders markdown to HTML" do
      app = boot_blog()

      {:ok, create_resp, app} =
        post(app, "/posts", %{
          "title" => "Markdown Demo",
          "body" => "# Hello\n\nThis is **bold** and *italic*.\n\n- item1\n- item2"
        })

      post_id = create_resp.body["id"]
      {:ok, resp, _app} = get(app, "/posts/#{post_id}")

      assert resp.status == 200
      assert resp.headers["content-type"] == "text/html"
      assert resp.body =~ "<title>Markdown Demo</title>"
      assert resp.body =~ "<h1>Markdown Demo</h1>"
      assert resp.body =~ "<strong>bold</strong>"
      assert resp.body =~ "<em>italic</em>"
      assert resp.body =~ "<li>item1</li>"
      assert resp.body =~ "Back to posts"
    end

    test "nonexistent post returns 404" do
      app = boot_blog()
      {:ok, resp, _app} = get(app, "/posts/nonexistent-id")

      assert resp.status == 404
      assert resp.body =~ "Not Found"
    end

    test "multiple posts are all listed and individually viewable" do
      app = boot_blog()

      {:ok, r1, app} =
        post(app, "/posts", %{"title" => "Post One", "body" => "Body one"})

      {:ok, r2, app} =
        post(app, "/posts", %{"title" => "Post Two", "body" => "Body two"})

      {:ok, list_resp, app} = get(app, "/posts")
      assert list_resp.body =~ "Post One"
      assert list_resp.body =~ "Post Two"

      {:ok, p1, _app} = get(app, "/posts/#{r1.body["id"]}")
      assert p1.status == 200
      assert p1.body =~ "Post One"
      assert p1.body =~ "<p>Body one</p>"

      {:ok, p2, _app} = get(app, "/posts/#{r2.body["id"]}")
      assert p2.status == 200
      assert p2.body =~ "Post Two"
      assert p2.body =~ "<p>Body two</p>"
    end

    test "post title is HTML-escaped in template" do
      app = boot_blog()

      {:ok, _resp, app} =
        post(app, "/posts", %{
          "title" => "A <script>alert('xss')</script> Post",
          "body" => "safe body"
        })

      {:ok, resp, _app} = get(app, "/posts")

      assert resp.body =~ "&lt;script&gt;"
      refute resp.body =~ "<script>alert"
    end

    test "filesystem state persists across requests" do
      app = boot_blog()

      {:ok, _, app} = post(app, "/posts", %{"title" => "P1", "body" => "B1"})
      {:ok, _, app} = post(app, "/posts", %{"title" => "P2", "body" => "B2"})
      {:ok, _, app} = post(app, "/posts", %{"title" => "P3", "body" => "B3"})

      {:ok, content} = Memory.read(app.ctx.filesystem, "posts.json")
      posts = Jason.decode!(content)
      assert length(posts) == 3
      assert Enum.map(posts, & &1["title"]) == ["P1", "P2", "P3"]
    end
  end
end
