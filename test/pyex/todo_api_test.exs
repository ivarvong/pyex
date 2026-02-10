defmodule Pyex.TodoApiTest do
  @moduledoc """
  Integration test modeling a stateful Todo API using FastAPI
  routes and Lambda's boot/handle cycle.

  One Python program defines CRUD endpoints. `Lambda.boot/2`
  interprets it once and extracts the route table. Each test
  step dispatches a request via `Lambda.handle/2`, which
  threads the `Ctx` (and its in-memory filesystem) through
  every call — exactly how a Phoenix controller would operate.
  """
  use ExUnit.Case, async: true

  alias Pyex.{Ctx, Error, Lambda, Filesystem.Memory}

  @source ~S"""
  import fastapi
  import json
  import uuid

  app = fastapi.FastAPI()
  DB = "todos.json"

  def load_todos():
      try:
          f = open(DB)
          data = json.loads(f.read())
          f.close()
          return data
      except:
          return []

  def save_todos(todos):
      f = open(DB, "w")
      f.write(json.dumps(todos))
      f.close()

  @app.post("/todos")
  def create_todo(request):
      body = request.json()
      todos = load_todos()
      todo = {"id": str(uuid.uuid4()), "title": body["title"], "done": False}
      todos.append(todo)
      save_todos(todos)
      return todo

  @app.get("/todos")
  def list_todos():
      return load_todos()

  @app.get("/todos/{todo_id}")
  def get_todo(todo_id):
      for todo in load_todos():
          if todo["id"] == todo_id:
              return todo
      return None

  @app.put("/todos/{todo_id}")
  def update_todo(todo_id, request):
      body = request.json()
      todos = load_todos()
      for i in range(len(todos)):
          todo = todos[i]
          if todo["id"] == todo_id:
              if "title" in body:
                  todo["title"] = body["title"]
              if "done" in body:
                  todo["done"] = body["done"]
              todos[i] = todo
              save_todos(todos)
              return todo
      return None

  @app.delete("/todos/{todo_id}")
  def delete_todo(todo_id):
      todos = load_todos()
      new_todos = [t for t in todos if t["id"] != todo_id]
      if len(new_todos) == len(todos):
          return {"deleted": False}
      save_todos(new_todos)
      return {"deleted": True}
  """

  defp boot do
    ctx = Ctx.new(filesystem: Memory.new(), fs_module: Memory)
    {:ok, app} = Lambda.boot(@source, ctx: ctx)
    app
  end

  defp post(app, path, body) do
    {:ok, resp, app} =
      Lambda.handle(app, %{
        method: "POST",
        path: path,
        body: Jason.encode!(body)
      })

    {resp, app}
  end

  defp get(app, path) do
    {:ok, resp, app} = Lambda.handle(app, %{method: "GET", path: path})
    {resp, app}
  end

  defp put(app, path, body) do
    {:ok, resp, app} =
      Lambda.handle(app, %{
        method: "PUT",
        path: path,
        body: Jason.encode!(body)
      })

    {resp, app}
  end

  defp delete(app, path) do
    {:ok, resp, app} = Lambda.handle(app, %{method: "DELETE", path: path})
    {resp, app}
  end

  test "full CRUD lifecycle with persistent filesystem" do
    app = boot()

    {resp, app} = post(app, "/todos", %{"title" => "Buy milk"})
    assert resp.status == 200
    assert resp.body["title"] == "Buy milk"
    assert resp.body["done"] == false
    id1 = resp.body["id"]
    assert is_binary(id1) and String.length(id1) == 36

    {resp, app} = post(app, "/todos", %{"title" => "Write tests"})
    id2 = resp.body["id"]
    assert resp.body["title"] == "Write tests"
    assert id1 != id2

    {resp, app} = post(app, "/todos", %{"title" => "Deploy app"})
    id3 = resp.body["id"]

    {resp, app} = get(app, "/todos")
    assert resp.status == 200
    assert length(resp.body) == 3
    titles = Enum.map(resp.body, & &1["title"])
    assert "Buy milk" in titles
    assert "Write tests" in titles
    assert "Deploy app" in titles

    {resp, app} = get(app, "/todos/#{id1}")
    assert resp.body["title"] == "Buy milk"
    assert resp.body["done"] == false

    {resp, app} = put(app, "/todos/#{id1}", %{"done" => true})
    assert resp.body["title"] == "Buy milk"
    assert resp.body["done"] == true

    {resp, app} = put(app, "/todos/#{id2}", %{"title" => "Write MORE tests"})
    assert resp.body["title"] == "Write MORE tests"
    assert resp.body["done"] == false

    {resp, app} = get(app, "/todos/#{id1}")
    assert resp.body["done"] == true

    {resp, app} = delete(app, "/todos/#{id3}")
    assert resp.body["deleted"] == true

    {resp, app} = get(app, "/todos")
    assert length(resp.body) == 2
    remaining_ids = Enum.map(resp.body, & &1["id"])
    assert id1 in remaining_ids
    assert id2 in remaining_ids
    refute id3 in remaining_ids

    {resp, app} = get(app, "/todos/#{id3}")
    assert resp.body == nil

    {resp, _app} = delete(app, "/todos/nonexistent-id")
    assert resp.body["deleted"] == false
  end

  test "empty list on fresh boot" do
    app = boot()
    {resp, _app} = get(app, "/todos")
    assert resp.status == 200
    assert resp.body == []
  end

  test "filesystem contains valid JSON after operations" do
    app = boot()
    {_resp, app} = post(app, "/todos", %{"title" => "Check JSON"})

    {:ok, raw} = Memory.read(app.ctx.filesystem, "todos.json")
    decoded = Jason.decode!(raw)
    assert is_list(decoded)
    assert length(decoded) == 1
    assert hd(decoded)["title"] == "Check JSON"
  end

  test "ten sequential creates all persist" do
    app =
      Enum.reduce(1..10, boot(), fn i, app ->
        {resp, app} = post(app, "/todos", %{"title" => "Item #{i}"})
        assert resp.body["title"] == "Item #{i}"
        app
      end)

    {resp, _app} = get(app, "/todos")
    assert length(resp.body) == 10

    ids = Enum.map(resp.body, & &1["id"]) |> MapSet.new()
    assert MapSet.size(ids) == 10
  end

  test "404 for unmatched route" do
    app = boot()
    result = Lambda.handle(app, %{method: "GET", path: "/nonexistent"})
    assert {:error, %Error{message: "no route matches GET /nonexistent"}} = result
  end
end
