defmodule Pyex.LibraryConformance.FastAPITest do
  @moduledoc """
  Conformance tests for the `fastapi` shim — including its `TestClient` —
  against the pinned reference `fastapi`/`httpx`. Each snippet runs through
  pyex and through the reference interpreter, asserting byte-equal output.

  Tagged `:library_conformance` so they're excluded by default. Run with:

      mix test --include library_conformance
  """

  use ExUnit.Case, async: true

  @moduletag :library_conformance

  import Pyex.Test.LibraryConformance

  unless uv_available?() do
    @moduletag skip: "uv not found on PATH"
  end

  describe "TestClient — basics" do
    test "GET returning a dict: status_code and json()" do
      assert_matches_library("""
      from fastapi import FastAPI
      from fastapi.testclient import TestClient

      app = FastAPI()

      @app.get("/")
      def root():
          return {"message": "hello"}

      client = TestClient(app)
      r = client.get("/")
      print(r.status_code)
      print(r.json())
      """)
    end

    test "unmatched route returns 404" do
      assert_matches_library("""
      from fastapi import FastAPI
      from fastapi.testclient import TestClient

      app = FastAPI()

      @app.get("/")
      def root():
          return {"ok": True}

      r = TestClient(app).get("/missing")
      print(r.status_code)
      """)
    end
  end

  describe "TestClient — path & query params" do
    test "typed path parameter is coerced to int" do
      assert_matches_library("""
      from fastapi import FastAPI
      from fastapi.testclient import TestClient

      app = FastAPI()

      @app.get("/items/{id}")
      def get_item(id: int):
          return {"id": id, "double": id * 2}

      print(TestClient(app).get("/items/5").json())
      """)
    end

    test "query parameter with a default" do
      assert_matches_library("""
      from fastapi import FastAPI
      from fastapi.testclient import TestClient

      app = FastAPI()

      @app.get("/search")
      def search(q: str = "none"):
          return {"q": q}

      c = TestClient(app)
      print(c.get("/search?q=hello").json())
      print(c.get("/search").json())
      """)
    end
  end

  describe "TestClient — request body" do
    test "POST with a pydantic model body" do
      assert_matches_library("""
      from fastapi import FastAPI
      from fastapi.testclient import TestClient
      from pydantic import BaseModel

      app = FastAPI()

      class Item(BaseModel):
          name: str
          price: int

      @app.post("/items")
      def create(item: Item):
          return {"created": item.name, "price": item.price}

      r = TestClient(app).post("/items", json={"name": "widget", "price": 10})
      print(r.json())
      """)
    end
  end

  describe "TestClient — HTTPException" do
    test "raised HTTPException sets status_code and detail" do
      assert_matches_library("""
      from fastapi import FastAPI, HTTPException
      from fastapi.testclient import TestClient

      app = FastAPI()

      @app.get("/x")
      def x():
          raise HTTPException(status_code=404, detail="not here")

      r = TestClient(app).get("/x")
      print(r.status_code)
      print(r.json())
      """)
    end
  end
end
