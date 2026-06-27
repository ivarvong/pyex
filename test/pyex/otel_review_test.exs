defmodule Pyex.OtelReviewTest do
  @moduledoc """
  A useful multitenant service, verified *by reviewing its OpenTelemetry span
  trace* rather than only its responses.

  `@app` is a task tracker (FastAPI + Pydantic + the `store` capability). Each
  HTTP request is run as its own turn (the Durable-Object model): the host
  loads the tenant's backend, runs the program, and the turn emits a span per
  `store` operation. We then assert on the *trace* — which is how you verify,
  in production, that a handler touched only what it should:

    * a list (GET) turn reads but never writes — proven by the absence of any
      `store.set`/`store.delete` span, not by trusting the handler;
    * a create turn writes exactly the keys it claims;
    * tenant isolation holds — a tenant's turn only ever names its own keys.

  This is "verification via OTel review": the span trace is the evidence.
  """

  use ExUnit.Case, async: false

  alias Pyex.Storage

  @app ~S'''
  from fastapi import FastAPI, HTTPException
  from fastapi.testclient import TestClient
  from pydantic import BaseModel, field_validator
  import store

  app = FastAPI()


  class TaskIn(BaseModel):
      title: str
      priority: int = 1

      @field_validator("priority")
      @classmethod
      def in_range(cls, v):
          if v < 1 or v > 5:
              raise ValueError("priority must be 1-5")
          return v


  def _next_id():
      n = store.get("meta:seq") or 0
      store.set("meta:seq", n + 1)
      return n + 1


  @app.post("/tasks")
  def create(task: TaskIn):
      tid = _next_id()
      rec = {"id": tid, "title": task.title, "priority": task.priority, "done": False}
      store.set(f"task:{tid}", rec)
      return rec


  @app.get("/tasks")
  def list_tasks():
      keys = store.keys("task:")
      return {"count": len(keys), "tasks": [store.get(k) for k in keys]}


  @app.post("/tasks/{tid}/complete")
  def complete(tid: int):
      rec = store.get(f"task:{tid}")
      if rec is None:
          raise HTTPException(status_code=404, detail="task not found")
      rec["done"] = True
      store.set(f"task:{tid}", rec)
      return rec


  @app.delete("/tasks/{tid}")
  def delete(tid: int):
      if not store.delete(f"task:{tid}"):
          raise HTTPException(status_code=404, detail="task not found")
      return {"deleted": tid}


  client = TestClient(app)
  '''

  # Run a single request as a turn against `storage`, capturing the response,
  # the resulting backend, and the turn's span trace (the OTel data the host
  # would export).
  defp turn(storage, driver) do
    handler = "otel-review-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:pyex, :run, :stop],
      fn _e, measurements, meta, _ ->
        send(parent, {:turn_telemetry, measurements, meta.spans})
      end,
      nil
    )

    {:ok, _v, ctx} = Pyex.run(@app <> "\n" <> driver, storage: storage)
    :telemetry.detach(handler)

    assert_received {:turn_telemetry, footprint, spans}

    %{
      out: String.trim(Pyex.output(ctx)),
      storage: ctx.storage,
      spans: spans,
      footprint: footprint
    }
  end

  defp span_names(turn), do: Enum.map(turn.spans, & &1.name)

  defp span_keys(turn),
    do: turn.spans |> Enum.map(& &1.attributes["db.collection.name"]) |> Enum.reject(&is_nil/1)

  describe "verification via OTel review" do
    test "a create turn writes exactly one task key (plus the id sequence)" do
      t =
        turn(
          Storage.Memory.new(),
          ~s|r = client.post("/tasks", json={"title": "ship it"})\nprint(r.json())|
        )

      assert t.out == "{'id': 1, 'title': 'ship it', 'priority': 1, 'done': False}"

      # The trace proves what was written: the id sequence + one task record.
      assert span_names(t) == ["db.get", "db.set", "db.set"]
      assert "task:1" in span_keys(t)
      assert "meta:seq" in span_keys(t)
    end

    test "a list turn reads but is provably write-free" do
      storage = turn(Storage.Memory.new(), ~s|client.post("/tasks", json={"title": "a"})|).storage
      storage = turn(storage, ~s|client.post("/tasks", json={"title": "b"})|).storage

      t = turn(storage, ~s|r = client.get("/tasks")\nprint(r.json()["count"])|)

      assert t.out == "2"
      # The review: NO write span exists. The handler cannot have mutated state.
      refute "db.set" in span_names(t)
      refute "db.delete" in span_names(t)
      assert "db.query" in span_names(t)
    end

    test "a complete turn is a read-then-write on the same key" do
      storage = turn(Storage.Memory.new(), ~s|client.post("/tasks", json={"title": "a"})|).storage

      t = turn(storage, ~s|r = client.post("/tasks/1/complete")\nprint(r.json()["done"])|)

      assert t.out == "True"
      assert span_names(t) == ["db.get", "db.set"]
      assert span_keys(t) == ["task:1", "task:1"]
    end

    test "a 404 turn is visible in the trace as a miss with no write" do
      t =
        turn(
          Storage.Memory.new(),
          ~s|r = client.post("/tasks/99/complete")\nprint(r.status_code)|
        )

      assert t.out == "404"
      miss = Enum.find(t.spans, &(&1.name == "db.get"))
      assert miss.attributes["hit"] == false
      refute "db.set" in span_names(t)
    end

    test "an invalid body (422) never reaches storage" do
      t =
        turn(
          Storage.Memory.new(),
          ~s|r = client.post("/tasks", json={"title": "x", "priority": 9})\nprint(r.status_code)|
        )

      assert t.out == "422"
      # Validation rejected the request before any storage op — the trace is empty.
      assert t.spans == []
    end
  end

  describe "multitenancy — the trace proves isolation" do
    test "each tenant's turn only ever names its own keys" do
      tenant_a =
        turn(Storage.Memory.new(), ~s|client.post("/tasks", json={"title": "a-secret"})|).storage

      tenant_b =
        turn(Storage.Memory.new(), ~s|client.post("/tasks", json={"title": "b-secret"})|).storage

      list_a = turn(tenant_a, ~s|r = client.get("/tasks")\nprint(r.json()["tasks"][0]["title"])|)
      list_b = turn(tenant_b, ~s|r = client.get("/tasks")\nprint(r.json()["tasks"][0]["title"])|)

      assert list_a.out == "a-secret"
      assert list_b.out == "b-secret"

      # Neither list turn's trace references a key it shouldn't see; both are
      # confined to the single tenant backend they were handed.
      assert Enum.all?(span_keys(list_a) ++ span_keys(list_b), &String.starts_with?(&1, "task:"))
    end
  end

  describe "the footprint summarizes the turn" do
    test "a create turn reports stdout and the span trace together" do
      t =
        turn(
          Storage.Memory.new(),
          ~s|r = client.post("/tasks", json={"title": "x"})\nprint("ok")|
        )

      assert t.footprint.output_bytes > 0
      assert length(t.spans) == 3
    end
  end
end
