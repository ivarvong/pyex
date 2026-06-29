defmodule Pyex.ExpenseTrackerTest do
  @moduledoc """
  End-to-end verification of an idiomatic expense-tracker service running on
  pyex: FastAPI routes, pydantic models with field validation, and a DynamoDB
  table via `boto3.resource("dynamodb")` (the local-DynamoDB pattern devs test
  against). The Python below is written to be *in distribution* — what an LLM
  or engineer would actually write — so passing it is a real conformance
  signal, not a tailored shim exercise.

  Numbers go through `Decimal` (DynamoDB's number type), so money math is
  exact. Storage is the `Pyex.Storage` backend, threaded across requests.
  """

  use ExUnit.Case, async: true

  # The application + a TestClient bound to it. Each scenario appends client
  # calls and prints assertions; persistence within a scenario is real because
  # the TestClient shares one run's storage backend.
  @app ~S'''
  import uuid
  from decimal import Decimal

  import boto3
  from fastapi import FastAPI, HTTPException
  from fastapi.testclient import TestClient
  from pydantic import BaseModel, Field, field_validator

  dynamodb = boto3.resource("dynamodb")
  dynamodb.create_table(
      TableName="expenses",
      KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
      AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
      BillingMode="PAY_PER_REQUEST",
  )
  table = dynamodb.Table("expenses")

  app = FastAPI()


  class ExpenseIn(BaseModel):
      amount: float = Field(gt=0)
      category: str = Field(min_length=1, max_length=40)
      note: str = ""

      @field_validator("category")
      @classmethod
      def normalize(cls, v):
          return v.strip().lower()


  class Expense(ExpenseIn):
      id: str


  def _present(item):
      return {**item, "amount": float(item["amount"])}


  @app.post("/expenses", status_code=201)
  def create_expense(payload: ExpenseIn):
      expense = Expense(id=str(uuid.uuid4()), **payload.model_dump())
      item = expense.model_dump()
      item["amount"] = Decimal(str(item["amount"]))
      table.put_item(Item=item)
      return expense.model_dump()


  @app.get("/expenses")
  def list_expenses():
      return [_present(i) for i in table.scan()["Items"]]


  @app.get("/expenses/{expense_id}")
  def get_expense(expense_id: str):
      result = table.get_item(Key={"id": expense_id})
      if "Item" not in result:
          raise HTTPException(status_code=404, detail="expense not found")
      return _present(result["Item"])


  @app.delete("/expenses/{expense_id}")
  def delete_expense(expense_id: str):
      if "Item" not in table.get_item(Key={"id": expense_id}):
          raise HTTPException(status_code=404, detail="expense not found")
      table.delete_item(Key={"id": expense_id})
      return {"deleted": expense_id}


  @app.get("/summary")
  def summary():
      totals = {}
      for item in table.scan()["Items"]:
          cat = item["category"]
          totals[cat] = totals.get(cat, Decimal("0")) + item["amount"]
      return {cat: float(total) for cat, total in totals.items()}


  client = TestClient(app)
  '''

  defp run(scenario) do
    {:ok, _value, ctx} = Pyex.run(@app <> "\n" <> scenario, storage: Pyex.Storage.Memory.new())
    String.trim(Pyex.output(ctx))
  end

  describe "positive paths" do
    test "creating an expense returns 201 with a generated id and normalized category" do
      out =
        run("""
        r = client.post("/expenses", json={"amount": 9.99, "category": "  Food  ", "note": "lunch"})
        body = r.json()
        print(r.status_code)
        print(body["category"], body["note"], body["amount"])
        print(len(body["id"]) > 0)
        """)

      assert out == "201\nfood lunch 9.99\nTrue"
    end

    test "listing returns every stored expense" do
      out =
        run("""
        client.post("/expenses", json={"amount": 5, "category": "coffee"})
        client.post("/expenses", json={"amount": 12.5, "category": "food"})
        client.post("/expenses", json={"amount": 3, "category": "coffee"})
        items = client.get("/expenses").json()
        print(len(items))
        print(sorted(i["category"] for i in items))
        """)

      assert out == "3\n['coffee', 'coffee', 'food']"
    end

    test "fetching by id returns the stored expense" do
      out =
        run("""
        eid = client.post("/expenses", json={"amount": 7.25, "category": "books"}).json()["id"]
        got = client.get("/expenses/" + eid).json()
        print(got["amount"], got["category"], got["id"] == eid)
        """)

      assert out == "7.25 books True"
    end

    test "deleting removes the expense" do
      out =
        run("""
        eid = client.post("/expenses", json={"amount": 1, "category": "x"}).json()["id"]
        print(client.delete("/expenses/" + eid).status_code)
        print(client.get("/expenses/" + eid).status_code)
        print(len(client.get("/expenses").json()))
        """)

      assert out == "200\n404\n0"
    end

    test "summary aggregates by category with exact Decimal money math" do
      out =
        run("""
        for amount, cat in [(9.99, "food"), (12.00, "food"), (3.50, "coffee"), (0.01, "coffee")]:
            client.post("/expenses", json={"amount": amount, "category": cat})
        s = client.get("/summary").json()
        print(s["food"], s["coffee"])
        """)

      # 9.99 + 12.00 = 21.99 and 3.50 + 0.01 = 3.51, exactly — no float drift.
      assert out == "21.99 3.51"
    end
  end

  describe "negative paths (validation and not-found)" do
    test "a non-positive amount is rejected with 422" do
      out =
        run("""
        print(client.post("/expenses", json={"amount": 0, "category": "x"}).status_code)
        print(client.post("/expenses", json={"amount": -5, "category": "x"}).status_code)
        print(len(client.get("/expenses").json()))
        """)

      assert out == "422\n422\n0"
    end

    test "an empty or over-long category is rejected with 422" do
      out =
        run("""
        print(client.post("/expenses", json={"amount": 1, "category": ""}).status_code)
        print(client.post("/expenses", json={"amount": 1, "category": "x" * 41}).status_code)
        """)

      assert out == "422\n422"
    end

    test "a missing required field is rejected with 422" do
      out =
        run("""
        print(client.post("/expenses", json={"category": "food"}).status_code)
        print(client.post("/expenses", json={"amount": 5}).status_code)
        """)

      assert out == "422\n422"
    end

    test "fetching or deleting an unknown id returns 404" do
      out =
        run("""
        print(client.get("/expenses/does-not-exist").status_code)
        print(client.delete("/expenses/does-not-exist").status_code)
        """)

      assert out == "404\n404"
    end
  end

  describe "storage durability" do
    test "expenses persist across separate Pyex.run calls via the threaded backend" do
      # First run: create two expenses, keep the resulting storage backend.
      {:ok, _v, ctx1} =
        Pyex.run(@app <> "\nclient.post('/expenses', json={'amount': 4, 'category': 'a'})\n",
          storage: Pyex.Storage.Memory.new()
        )

      {:ok, _v, ctx2} =
        Pyex.run(@app <> "\nclient.post('/expenses', json={'amount': 6, 'category': 'b'})\n",
          storage: ctx1.storage
        )

      # Third run reuses the accumulated backend and lists what survived.
      out =
        Pyex.run(
          @app <>
            "\nprint(len(client.get('/expenses').json()))\nprint(sorted(client.get('/summary').json().items()))\n",
          storage: ctx2.storage
        )
        |> case do
          {:ok, _v, ctx} -> String.trim(Pyex.output(ctx))
        end

      assert out == "2\n[('a', 4.0), ('b', 6.0)]"
    end
  end
end
