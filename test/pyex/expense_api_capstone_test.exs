defmodule Pyex.ExpenseAPICapstoneTest do
  @moduledoc """
  Capstone proof that pyex runs a *complete, realistic* application.

  `@app` is a self-contained expense-tracking REST API — the kind of code
  an LLM is asked to write every day:

    * `pydantic` request models with `@field_validator` business rules
    * a `fastapi` app with path params, a query filter, and all of
      POST/GET/DELETE
    * in-memory storage over `dict`, with `collections.defaultdict` /
      `Counter` aggregation in the summary endpoint
    * the full error surface — 422 on invalid input, 404 on missing rows,
      via `HTTPException`
    * driven end-to-end through `fastapi.testclient.TestClient`

  Two tests pin it from both sides:

    * `golden output` runs the program through pyex alone and asserts the
      exact stdout. It runs in the default suite, so a regression anywhere
      in the stack (parser, interpreter, any of the four shims) trips it
      with no external dependency.

    * `matches real fastapi byte-for-byte` (tagged `:library_conformance`,
      excluded by default) runs the *same source* through the pinned
      `fastapi` + `pydantic` + `httpx` via `uv` and asserts byte-equal
      output — proving the golden string isn't just self-consistent but
      actually matches CPython's reference libraries.
  """

  use ExUnit.Case, async: true

  import Pyex.Test.LibraryConformance

  @app ~S'''
  from fastapi import FastAPI, HTTPException
  from fastapi.testclient import TestClient
  from pydantic import BaseModel, field_validator
  from collections import defaultdict, Counter

  app = FastAPI()

  ALLOWED = {"food", "transport", "rent", "fun", "other"}


  class ExpenseIn(BaseModel):
      amount: float
      category: str
      note: str = ""

      @field_validator("amount")
      @classmethod
      def amount_positive(cls, v):
          if v <= 0:
              raise ValueError("amount must be positive")
          return v

      @field_validator("category")
      @classmethod
      def category_known(cls, v):
          if v not in ALLOWED:
              raise ValueError("unknown category")
          return v


  _db = {}
  _next_id = {"v": 1}


  @app.post("/expenses")
  def create_expense(expense: ExpenseIn):
      eid = _next_id["v"]
      _next_id["v"] += 1
      record = {
          "id": eid,
          "amount": expense.amount,
          "category": expense.category,
          "note": expense.note,
      }
      _db[eid] = record
      return record


  @app.get("/expenses")
  def list_expenses(category: str = ""):
      items = list(_db.values())
      if category:
          items = [e for e in items if e["category"] == category]
      return {"count": len(items), "expenses": items}


  @app.get("/expenses/{expense_id}")
  def get_expense(expense_id: int):
      if expense_id not in _db:
          raise HTTPException(status_code=404, detail="expense not found")
      return _db[expense_id]


  @app.delete("/expenses/{expense_id}")
  def delete_expense(expense_id: int):
      if expense_id not in _db:
          raise HTTPException(status_code=404, detail="expense not found")
      removed = _db.pop(expense_id)
      return {"deleted": removed["id"], "remaining": len(_db)}


  @app.get("/summary")
  def summary():
      totals = defaultdict(float)
      counts = Counter()
      for rec in _db.values():
          totals[rec["category"]] += rec["amount"]
          counts[rec["category"]] += 1
      by_category = {k: round(v, 2) for k, v in sorted(totals.items())}
      top = counts.most_common(1)
      return {
          "total": round(sum(r["amount"] for r in _db.values()), 2),
          "by_category": by_category,
          "top_category": top[0][0] if top else None,
      }


  client = TestClient(app)


  def show(label, r):
      print(f"{label} -> {r.status_code} {r.json()}")


  def show_status(label, r):
      print(f"{label} -> {r.status_code}")


  show("create food", client.post("/expenses", json={"amount": 9.99, "category": "food", "note": "lunch"}))
  show("create rent", client.post("/expenses", json={"amount": 1200, "category": "rent"}))
  show("create transport", client.post("/expenses", json={"amount": 2.75, "category": "transport", "note": "bus"}))
  show("create fun", client.post("/expenses", json={"amount": 45.5, "category": "fun", "note": "movie"}))
  show_status("reject negative", client.post("/expenses", json={"amount": -5, "category": "food"}))
  show_status("reject unknown cat", client.post("/expenses", json={"amount": 5, "category": "crypto"}))
  show_status("reject missing amount", client.post("/expenses", json={"category": "food"}))
  show("get id=1", client.get("/expenses/1"))
  show("get missing", client.get("/expenses/999"))
  show("list all", client.get("/expenses"))
  show("list food", client.get("/expenses?category=food"))
  show("delete id=2", client.delete("/expenses/2"))
  show("delete missing", client.delete("/expenses/2"))
  show("summary", client.get("/summary"))
  '''

  @expected """
  create food -> 200 {'id': 1, 'amount': 9.99, 'category': 'food', 'note': 'lunch'}
  create rent -> 200 {'id': 2, 'amount': 1200.0, 'category': 'rent', 'note': ''}
  create transport -> 200 {'id': 3, 'amount': 2.75, 'category': 'transport', 'note': 'bus'}
  create fun -> 200 {'id': 4, 'amount': 45.5, 'category': 'fun', 'note': 'movie'}
  reject negative -> 422
  reject unknown cat -> 422
  reject missing amount -> 422
  get id=1 -> 200 {'id': 1, 'amount': 9.99, 'category': 'food', 'note': 'lunch'}
  get missing -> 404 {'detail': 'expense not found'}
  list all -> 200 {'count': 4, 'expenses': [{'id': 1, 'amount': 9.99, 'category': 'food', 'note': 'lunch'}, {'id': 2, 'amount': 1200.0, 'category': 'rent', 'note': ''}, {'id': 3, 'amount': 2.75, 'category': 'transport', 'note': 'bus'}, {'id': 4, 'amount': 45.5, 'category': 'fun', 'note': 'movie'}]}
  list food -> 200 {'count': 1, 'expenses': [{'id': 1, 'amount': 9.99, 'category': 'food', 'note': 'lunch'}]}
  delete id=2 -> 200 {'deleted': 2, 'remaining': 3}
  delete missing -> 404 {'detail': 'expense not found'}
  summary -> 200 {'total': 58.24, 'by_category': {'food': 9.99, 'fun': 45.5, 'transport': 2.75}, 'top_category': 'food'}
  """

  test "the expense API produces the expected golden output on pyex" do
    {:ok, _value, ctx} = Pyex.run(@app)
    assert Pyex.output(ctx) == @expected
  end

  @tag :library_conformance
  test "the expense API matches real fastapi + pydantic byte-for-byte" do
    if uv_available?() do
      assert_matches_library(@app)
    else
      # The default suite excludes :library_conformance; when it *is* run
      # without uv on PATH, treat the reference half as skipped.
      assert true
    end
  end
end
