defmodule Pyex.LibraryConformance.FastAPIAdversarialTest do
  @moduledoc """
  Negative / adversarial conformance for the FastAPI `TestClient` against the
  pinned reference fastapi/httpx. Each snippet drives hostile or malformed
  input at an endpoint and prints the resulting status codes; the reference
  and pyex must agree byte-for-byte.

  This is the oracle half of "prod endpoints under adversarial input": every
  bad request must produce the *same* well-formed HTTP outcome real FastAPI
  produces (422 validation, 405 method, 404 not-found, 500 handler error),
  never a crash or an accepted-but-invalid 200.

  Tagged `:library_conformance` so it's excluded by default. Run with:

      mix test --include library_conformance
  """

  use ExUnit.Case, async: true

  @moduletag :library_conformance

  import Pyex.Test.LibraryConformance

  unless uv_available?() do
    @moduletag skip: "uv not found on PATH"
  end

  # A small app reused across the adversarial probes.
  @app """
  from fastapi import FastAPI, HTTPException
  from fastapi.testclient import TestClient
  from pydantic import BaseModel

  app = FastAPI()

  class Item(BaseModel):
      name: str
      price: int

  @app.get("/items/{item_id}")
  def get_item(item_id: int):
      return {"id": item_id}

  @app.post("/items")
  def create(item: Item):
      return {"created": item.name, "price": item.price}

  @app.get("/boom")
  def boom():
      raise ValueError("handler exploded")

  c = TestClient(app)
  """

  defp probe(body), do: assert_matches_library(@app <> "\n" <> body)

  describe "request body validation → 422" do
    test "wrong field type" do
      probe(~s|print(c.post("/items", json={"name": "x", "price": "NaN"}).status_code)|)
    end

    test "missing required field" do
      probe(~s|print(c.post("/items", json={"name": "x"}).status_code)|)
    end

    test "body is a list, not an object" do
      probe(~s|print(c.post("/items", json=[1, 2, 3]).status_code)|)
    end

    test "body is a bare string" do
      probe(~s|print(c.post("/items", json="just a string").status_code)|)
    end

    test "null value for a required field" do
      probe(~s|print(c.post("/items", json={"name": None, "price": 1}).status_code)|)
    end

    test "extra fields are ignored (still 200)" do
      probe(
        ~s|print(c.post("/items", json={"name": "x", "price": 1, "x": 9, "y": 9}).status_code)|
      )
    end

    test "valid body still succeeds" do
      probe(~s|print(c.post("/items", json={"name": "ok", "price": 5}).status_code)|)
    end
  end

  describe "path parameter coercion → 422" do
    test "non-numeric where int expected" do
      probe(~s|print(c.get("/items/abc").status_code)|)
    end

    test "float where int expected" do
      probe(~s|print(c.get("/items/1.5").status_code)|)
    end

    test "empty-ish segment" do
      probe(~s|print(c.get("/items/%20").status_code)|)
    end

    test "valid int path param succeeds" do
      probe(~s|print(c.get("/items/42").status_code)|)
    end
  end

  describe "routing → 404 / 405" do
    test "unknown path is 404" do
      probe(~s|print(c.get("/nope").status_code)|)
    end

    test "wrong method on an existing path is 405" do
      probe(~s|print(c.post("/items/1").status_code)|)
    end

    test "wrong method on the collection path is 405" do
      probe(~s|print(c.get("/items").status_code)|)
    end
  end

  describe "handler error" do
    test "default TestClient re-raises an unhandled handler exception" do
      probe("""
      try:
          c.get("/boom")
          print("no error")
      except ValueError:
          print("re-raised")
      """)
    end

    test "raise_server_exceptions=False yields a 500 response" do
      probe("""
      safe = TestClient(app, raise_server_exceptions=False)
      print(safe.get("/boom").status_code)
      """)
    end
  end

  describe "many adversarial requests in one program stay consistent" do
    test "status codes across a battery match the reference" do
      probe("""
      cases = [
          ("GET", "/items/7", None),
          ("GET", "/items/-3", None),
          ("GET", "/items/abc", None),
          ("POST", "/items", {"name": "a", "price": 1}),
          ("POST", "/items", {"name": "a", "price": "x"}),
          ("POST", "/items", {}),
          ("POST", "/items", {"price": 1}),
          ("GET", "/items", None),
          ("DELETE", "/items/1", None),
      ]
      for method, path, body in cases:
          if method == "GET":
              r = c.get(path)
          elif method == "POST":
              r = c.post(path, json=body)
          else:
              r = c.delete(path)
          print(method, path, r.status_code)
      """)
    end
  end
end
