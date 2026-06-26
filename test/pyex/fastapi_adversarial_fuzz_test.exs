defmodule Pyex.FastAPIAdversarialFuzzTest do
  @moduledoc """
  Property/fuzz testing for FastAPI endpoints under adversarial input.

  Generates random hostile requests — malformed bodies (wrong types, missing
  fields, deep nesting, nulls), weird paths (traversal, percent-encoding,
  long/empty segments), and arbitrary methods — and drives them at a small
  app via a `raise_server_exceptions=False` TestClient (the deployed-server
  posture).

  The invariant under test is the one a production endpoint must hold: **no
  input ever crashes the endpoint**. Every request resolves to a well-formed
  HTTP response with a sane status code — never an interpreter crash, a
  non-response, or a hang. Schema-violating requests must be rejected (4xx),
  not silently accepted with bad data.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

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
      return {"id": item_id, "double": item_id * 2}

  @app.post("/items")
  def create(item: Item):
      return {"created": item.name, "price": item.price}

  client = TestClient(app, raise_server_exceptions=False)
  """

  # Adversarial path fragments — traversal, encoding, overflow, emptiness.
  @paths [
    "/items/1",
    "/items/-99999999999999999999",
    "/items/abc",
    "/items/1.5",
    "/items/",
    "/items/%2e%2e%2f",
    "/items/../../etc/passwd",
    "/items/" <> String.duplicate("9", 400),
    "/items",
    "/items/1?evil=' OR 1=1--",
    "/../../",
    "/items/1/extra/segments",
    "/"
  ]

  @methods ["get", "post", "put", "delete", "patch"]

  describe "no adversarial request crashes an endpoint" do
    property "every generated request yields a valid HTTP status code" do
      check all(
              method <- member_of(@methods),
              path <- member_of(@paths),
              body <- adversarial_body(),
              max_runs: 150
            ) do
        program = @app <> "\nprint(client.#{method}(#{py(path)}, json=#{py(body)}).status_code)\n"

        case Pyex.run(program) do
          {:ok, _value, ctx} ->
            status = ctx |> Pyex.output() |> String.trim()

            assert valid_status?(status),
                   "non-HTTP response for #{method} #{path} body=#{inspect(body)}: #{inspect(status)}"

          {:error, err} ->
            flunk("endpoint crashed on #{method} #{path} body=#{inspect(body)}: #{err.message}")
        end
      end
    end

    property "schema-violating POST bodies are always rejected, never accepted as 200" do
      check all(body <- invalid_item_body(), max_runs: 100) do
        program = @app <> "\nprint(client.post(\"/items\", json=#{py(body)}).status_code)\n"

        {:ok, _value, ctx} = Pyex.run(program)
        status = ctx |> Pyex.output() |> String.trim()

        assert status == "422",
               "invalid body should be 422, got #{status} for #{inspect(body)}"
      end
    end
  end

  # ── generators ─────────────────────────────────────────────────────────────

  # A grab-bag of JSON-ish values: the right shape, wrong types, nesting, nulls.
  defp adversarial_body do
    one_of([
      constant(nil),
      constant(%{"name" => "ok", "price" => 1}),
      json_value()
    ])
  end

  # A body that is structurally a dict but violates the Item schema in some way.
  defp invalid_item_body do
    one_of([
      constant(%{"name" => "x"}),
      constant(%{"price" => 1}),
      constant(%{}),
      constant(%{"name" => "x", "price" => "not-an-int"}),
      constant(%{"name" => "x", "price" => nil}),
      constant(%{"name" => nil, "price" => 1}),
      constant(%{"name" => "x", "price" => [1, 2]}),
      constant(%{"name" => "x", "price" => %{"nested" => 1}})
    ])
  end

  defp json_value do
    leaf =
      one_of([
        constant(nil),
        boolean(),
        integer(),
        string(:alphanumeric, max_length: 12)
      ])

    tree =
      tree(leaf, fn child ->
        one_of([
          list_of(child, max_length: 4),
          map_of(string(:alphanumeric, min_length: 1, max_length: 6), child, max_length: 4)
        ])
      end)

    tree
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp valid_status?(status) do
    case Integer.parse(status) do
      {n, ""} -> n >= 100 and n <= 599
      _ -> false
    end
  end

  # Render an Elixir term as a Python literal (paths and request bodies).
  defp py(nil), do: "None"
  defp py(true), do: "True"
  defp py(false), do: "False"
  defp py(n) when is_integer(n), do: Integer.to_string(n)
  defp py(s) when is_binary(s), do: py_string(s)
  defp py(list) when is_list(list), do: "[" <> Enum.map_join(list, ", ", &py/1) <> "]"

  defp py(map) when is_map(map) do
    "{" <>
      Enum.map_join(map, ", ", fn {k, v} -> "#{py_string(to_string(k))}: #{py(v)}" end) <> "}"
  end

  # Python string literal — only printable ASCII is generated, so the escape
  # rules coincide with Elixir's for the characters that appear.
  defp py_string(s) do
    escaped = s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"" <> escaped <> "\""
  end
end
