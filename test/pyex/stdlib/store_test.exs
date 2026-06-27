defmodule Pyex.Stdlib.StoreTest do
  @moduledoc """
  Tests for the **experimental** host-provided `store` key/value module
  (`Pyex.Stdlib.Store` over the `Pyex.Storage` protocol).

  Covers the denied-by-default posture, the full KV surface, JSON
  round-tripping of nested Python values, and — the point of the feature —
  state surviving across separate `Pyex.run` calls when the host threads
  `ctx.storage` forward, including a persistent FastAPI service.
  """

  use ExUnit.Case, async: true

  alias Pyex.Storage

  defp run!(src, opts \\ []) do
    {:ok, _value, ctx} = Pyex.run(src, opts)
    {Pyex.output(ctx), ctx}
  end

  describe "denied by default" do
    test "any store operation without a backend raises StorageError" do
      {out, _ctx} =
        run!("""
        import store
        try:
            store.set("k", 1)
        except Exception as e:
            print(type(e).__name__)
        """)

      assert out == "StorageError\n"
    end

    test "store.get without a backend also raises StorageError" do
      {out, _ctx} =
        run!("""
        import store
        try:
            store.get("k")
        except Exception as e:
            print(type(e).__name__)
        """)

      assert out == "StorageError\n"
    end
  end

  describe "key/value operations" do
    test "set then get round-trips a nested value" do
      {out, _ctx} =
        run!(
          """
          import store
          store.set("expense:1", {"amount": 9.99, "items": [1, 2], "ok": True})
          print(store.get("expense:1"))
          """,
          storage: Storage.Memory.new()
        )

      assert out == "{'amount': 9.99, 'items': [1, 2], 'ok': True}\n"
    end

    test "get on a missing key returns None" do
      {out, _ctx} =
        run!(
          """
          import store
          print(store.get("nope"))
          """,
          storage: Storage.Memory.new()
        )

      assert out == "None\n"
    end

    test "keys does a sorted prefix scan, and bare keys() lists everything" do
      {out, _ctx} =
        run!(
          """
          import store
          store.set("expense:2", 2)
          store.set("expense:1", 1)
          store.set("user:1", "x")
          print(store.keys("expense:"))
          print(store.keys())
          """,
          storage: Storage.Memory.new()
        )

      assert out == "['expense:1', 'expense:2']\n['expense:1', 'expense:2', 'user:1']\n"
    end

    test "delete returns True when the key existed and False otherwise" do
      {out, _ctx} =
        run!(
          """
          import store
          store.set("k", 1)
          print(store.delete("k"))
          print(store.delete("k"))
          print(store.get("k"))
          """,
          storage: Storage.Memory.new()
        )

      assert out == "True\nFalse\nNone\n"
    end

    test "a backend can be seeded from a map of JSON strings" do
      {out, _ctx} =
        run!(
          """
          import store
          print(store.get("greeting"))
          """,
          storage: %{"greeting" => ~s("hello")}
        )

      assert out == "hello\n"
    end
  end

  describe "input validation" do
    test "a non-string key is a TypeError" do
      {out, _ctx} =
        run!(
          """
          import store
          try:
              store.get(123)
          except TypeError as e:
              print("TypeError")
          """,
          storage: Storage.Memory.new()
        )

      assert out == "TypeError\n"
    end
  end

  describe "persistence across separate runs" do
    test "a second run reads and mutates what the first run stored" do
      backend = Storage.Memory.new()

      {out1, ctx1} =
        run!(
          """
          import store
          store.set("counter", 1)
          print("run1 wrote", store.get("counter"))
          """,
          storage: backend
        )

      assert out1 == "run1 wrote 1\n"

      # A brand-new run — fresh interpreter, no shared globals — carrying only
      # the backend the host threaded out of the first run.
      {out2, _ctx2} =
        run!(
          """
          import store
          n = store.get("counter")
          store.set("counter", n + 1)
          print("run2 read", n, "wrote", store.get("counter"))
          """,
          storage: ctx1.storage
        )

      assert out2 == "run2 read 1 wrote 2\n"
    end

    test "a FastAPI service backed by store survives across interpreter runs" do
      app = """
      from fastapi import FastAPI
      from fastapi.testclient import TestClient
      from pydantic import BaseModel
      import store

      app = FastAPI()


      class ExpenseIn(BaseModel):
          amount: float
          category: str


      @app.post("/expenses")
      def create(expense: ExpenseIn):
          nid = store.get("meta:next_id") or 1
          rec = {"id": nid, "amount": expense.amount, "category": expense.category}
          store.set(f"expense:{nid}", rec)
          store.set("meta:next_id", nid + 1)
          return rec


      @app.get("/expenses")
      def list_all():
          keys = store.keys("expense:")
          return {"count": len(keys), "ids": [store.get(k)["id"] for k in keys]}


      client = TestClient(app)
      """

      {out1, ctx1} =
        run!(
          app <>
            """
            client.post("/expenses", json={"amount": 9.99, "category": "food"})
            client.post("/expenses", json={"amount": 1200, "category": "rent"})
            print("run1:", client.get("/expenses").json())
            """,
          storage: Storage.Memory.new()
        )

      assert out1 == "run1: {'count': 2, 'ids': [1, 2]}\n"

      # Fresh interpreter: the app, its routes, and its module globals are all
      # rebuilt from scratch. Only the host's backend carries the data over.
      {out2, _ctx2} =
        run!(
          app <>
            """
            print("run2 sees:", client.get("/expenses").json())
            client.post("/expenses", json={"amount": 2.75, "category": "transport"})
            print("run2 after add:", client.get("/expenses").json())
            """,
          storage: ctx1.storage
        )

      assert out2 ==
               "run2 sees: {'count': 2, 'ids': [1, 2]}\n" <>
                 "run2 after add: {'count': 3, 'ids': [1, 2, 3]}\n"
    end
  end
end
