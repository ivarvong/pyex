defmodule Pyex.Stdlib.DynamoTest do
  @moduledoc """
  Tests for the **experimental** `dynamo` module (`Pyex.Stdlib.Dynamo`) — a
  DynamoDB-style single-table store layered over the `Pyex.Storage` capability.

  Covers the denied-by-default posture, the full item/query surface (incl.
  sort-key ranges, limit, reverse, conditional writes), persistence across
  runs, per-tenant isolation, ocap attenuation via `Pyex.Storage.View`,
  backend pluggability (the same program over a serialized text backend), the
  unforgeable telemetry ledger, and adversarial host-safety.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pyex.{Ctx, Storage}

  defp mem(seed \\ %{}), do: Storage.Memory.new(seed)

  defp run!(src, opts) do
    {:ok, _v, ctx} = Pyex.run(src, opts)
    {Pyex.output(ctx), ctx}
  end

  describe "denied by default" do
    test "any operation without a storage backend raises StorageError" do
      {out, _} =
        run!(
          """
          import dynamo
          t = dynamo.Table("app")
          try:
              t.put_item({"pk": "U#1", "sk": "P", "x": 1})
          except Exception as e:
              print(type(e).__name__)
          """,
          []
        )

      assert out == "StorageError\n"
    end
  end

  describe "item CRUD" do
    test "put_item / get_item round-trips a nested item" do
      {out, _} =
        run!(
          """
          import dynamo
          t = dynamo.Table("app")
          t.put_item({"pk": "U#1", "sk": "PROFILE", "name": "Ada", "tags": [1, 2]})
          item = t.get_item("U#1", "PROFILE")
          print(item["name"], item["tags"])
          print(t.get_item("U#1", "MISSING"))
          """,
          storage: mem()
        )

      assert out == "Ada [1, 2]\nNone\n"
    end

    test "delete_item reports whether the item existed" do
      {out, _} =
        run!(
          """
          import dynamo
          t = dynamo.Table("app")
          t.put_item({"pk": "U#1", "sk": "P"})
          print(t.delete_item("U#1", "P"))
          print(t.delete_item("U#1", "P"))
          """,
          storage: mem()
        )

      assert out == "True\nFalse\n"
    end

    test "missing key attribute is a clean StorageError, not a crash" do
      {out, _} =
        run!(
          """
          import dynamo
          t = dynamo.Table("app")
          try:
              t.put_item({"sk": "P", "x": 1})
          except Exception as e:
              print(type(e).__name__, "-", str(e))
          """,
          storage: mem()
        )

      assert out =~ "StorageError"
      assert out =~ "missing key attribute 'pk'"
    end
  end

  describe "query: partition + sort-key range" do
    @seed_program """
    import dynamo
    t = dynamo.Table("app")
    t.put_item({"pk": "U#1", "sk": "PROFILE", "kind": "profile"})
    t.put_item({"pk": "U#1", "sk": "ORDER#2024-01", "n": 1})
    t.put_item({"pk": "U#1", "sk": "ORDER#2024-02", "n": 2})
    t.put_item({"pk": "U#1", "sk": "ORDER#2024-03", "n": 3})
    t.put_item({"pk": "U#2", "sk": "PROFILE", "kind": "other"})
    """

    test "whole partition comes back sorted by sort key; other partitions excluded" do
      {out, _} =
        run!(
          @seed_program <>
            """
            rows = t.query("U#1")
            print([r["sk"] for r in rows])
            """,
          storage: mem()
        )

      assert out ==
               ~s(['ORDER#2024-01', 'ORDER#2024-02', 'ORDER#2024-03', 'PROFILE']\n)
    end

    test "begins_with narrows to a sort-key prefix" do
      {out, _} =
        run!(
          @seed_program <> "print([r[\"n\"] for r in t.query(\"U#1\", begins_with=\"ORDER#\")])\n",
          storage: mem()
        )

      assert out == "[1, 2, 3]\n"
    end

    test "range comparators (gte/lt/between) filter the sort key" do
      {out, _} =
        run!(
          @seed_program <>
            """
            print([r["n"] for r in t.query("U#1", begins_with="ORDER#", gte="ORDER#2024-02")])
            print([r["n"] for r in t.query("U#1", begins_with="ORDER#", lt="ORDER#2024-03")])
            print([r["n"] for r in t.query("U#1", between=["ORDER#2024-02", "ORDER#2024-02z"])])
            """,
          storage: mem()
        )

      assert out == "[2, 3]\n[1, 2]\n[2]\n"
    end

    test "limit and reverse" do
      {out, _} =
        run!(
          @seed_program <>
            """
            print([r["n"] for r in t.query("U#1", begins_with="ORDER#", reverse=True)])
            print([r["n"] for r in t.query("U#1", begins_with="ORDER#", limit=2)])
            """,
          storage: mem()
        )

      assert out == "[3, 2, 1]\n[1, 2]\n"
    end
  end

  describe "update_item" do
    test "shallow-merges into the existing item, preserving keys" do
      {out, _} =
        run!(
          """
          import dynamo
          t = dynamo.Table("app")
          t.put_item({"pk": "U#1", "sk": "P", "name": "Ada", "tier": "free"})
          t.update_item("U#1", "P", {"tier": "gold", "verified": True})
          print(t.get_item("U#1", "P"))
          """,
          storage: mem()
        )

      assert out =~ "'name': 'Ada'"
      assert out =~ "'tier': 'gold'"
      assert out =~ "'verified': True"
    end

    test "creates the item when absent" do
      {out, _} =
        run!(
          """
          import dynamo
          t = dynamo.Table("app")
          t.update_item("U#9", "P", {"x": 1})
          print(t.get_item("U#9", "P"))
          """,
          storage: mem()
        )

      assert out == "{'x': 1, 'pk': 'U#9', 'sk': 'P'}\n"
    end
  end

  describe "conditional write (overwrite=False)" do
    test "blocks overwriting an existing item" do
      {out, _} =
        run!(
          """
          import dynamo
          t = dynamo.Table("app")
          t.put_item({"pk": "U#1", "sk": "P", "v": 1})
          try:
              t.put_item({"pk": "U#1", "sk": "P", "v": 2}, overwrite=False)
          except Exception as e:
              print("blocked:", type(e).__name__)
          print(t.get_item("U#1", "P")["v"])
          """,
          storage: mem()
        )

      assert out == "blocked: StorageError\n1\n"
    end
  end

  describe "persistence across runs (host threads ctx.storage forward)" do
    test "items written in one run are visible in the next" do
      {_out, ctx1} =
        run!(
          ~s|import dynamo\ndynamo.Table("app").put_item({"pk": "U#1", "sk": "P", "v": 7})\n|,
          storage: mem()
        )

      {out, _} =
        run!(
          ~s|import dynamo\nprint(dynamo.Table("app").get_item("U#1", "P")["v"])\n|,
          storage: ctx1.storage
        )

      assert out == "7\n"
    end
  end

  describe "multitenancy (distinct backend per tenant)" do
    test "one tenant's writes are invisible to another's backend" do
      prog_write =
        ~s|import dynamo\ndynamo.Table("app").put_item({"pk": "U#1", "sk": "P", "v": 1})\n|

      {_o, ctx_a} = run!(prog_write, storage: mem())

      {out, _} =
        run!(
          ~s|import dynamo\nprint(dynamo.Table("app").query("U#1"))\n|,
          # tenant B gets its OWN fresh backend — no reference to A's
          storage: mem()
        )

      assert out == "[]\n"
      # A's data really is in A's store
      assert {:ok, _} = Storage.get(ctx_a.storage, "app\x1fU#1\x1fP")
    end
  end

  describe "ocap attenuation via Pyex.Storage.View" do
    test "a read-only capability denies writes but allows reads" do
      seeded = mem(%{"app\x1fU#1\x1fP" => ~s({"pk":"U#1","sk":"P","v":1})})

      {out, _} =
        run!(
          """
          import dynamo
          t = dynamo.Table("app")
          print(t.get_item("U#1", "P")["v"])
          try:
              t.put_item({"pk": "U#1", "sk": "P", "v": 2})
          except Exception as e:
              print("write denied:", type(e).__name__)
          """,
          storage: Storage.View.readonly(seeded)
        )

      assert out == "1\nwrite denied: StorageError\n"
    end

    test "a partition-scoped capability hides items outside its scope" do
      seeded =
        mem(%{
          "app\x1fU#1\x1fP" => ~s({"pk":"U#1","sk":"P","v":1}),
          "app\x1fU#2\x1fP" => ~s({"pk":"U#2","sk":"P","v":2})
        })

      # Scoped to U#1's partition only.
      view = Storage.View.scope(seeded, {:prefix, "app\x1fU#1\x1f"})

      {out, _} =
        run!(
          """
          import dynamo
          t = dynamo.Table("app")
          print(t.get_item("U#1", "P")["v"])
          print(t.get_item("U#2", "P"))
          """,
          storage: view
        )

      # U#1 visible; U#2 is out of scope -> invisible (None), not an error.
      assert out == "1\nNone\n"
    end
  end

  describe "backend pluggability (same program, a serialized text backend)" do
    test "dynamo runs unchanged over a TSV/base64 text-file-style backend" do
      program = """
      import dynamo
      t = dynamo.Table("app")
      t.put_item({"pk": "U#1", "sk": "ORDER#1", "total": 10})
      t.put_item({"pk": "U#1", "sk": "ORDER#2", "total": 20})
      print([r["total"] for r in t.query("U#1", begins_with="ORDER#")])
      """

      {out, ctx} = run!(program, storage: %Pyex.Test.DynamoTextStore{})

      assert out == "[10, 20]\n"
      # The backend really stored serialized text rows (not an Elixir map).
      assert is_binary(ctx.storage.text)
      assert ctx.storage.text =~ "app"
    end
  end

  describe "unforgeable telemetry ledger" do
    test "every operation emits a runtime span with pyex.dynamo db.* semconv" do
      {_out, ctx} =
        run!(
          """
          import dynamo
          t = dynamo.Table("app")
          t.put_item({"pk": "U#1", "sk": "P", "v": 1})
          t.get_item("U#1", "P")
          t.query("U#1")
          """,
          storage: mem()
        )

      spans = Ctx.runtime_spans(ctx)
      ops = spans |> Enum.map(& &1.attributes["db.operation.name"]) |> Enum.sort()
      assert ops == ["get", "query", "set"]
      assert Enum.all?(spans, &(&1.attributes["db.system.name"] == "pyex.dynamo"))
    end
  end

  describe "adversarial host-safety" do
    property "hostile key/item types never crash the host" do
      hostile =
        StreamData.member_of([
          "0",
          "None",
          "(1, 2)",
          "[1, 2]",
          "{'a': 1}",
          "{1, 2}",
          "float('nan')",
          "b'x'",
          "3.14",
          "'x' * 100"
        ])

      check all(pk <- hostile, sk <- hostile, item <- hostile, max_runs: 200) do
        program = """
        import dynamo
        t = dynamo.Table("app")
        try: t.put_item(#{item})
        except Exception: pass
        try: t.get_item(#{pk}, #{sk})
        except Exception: pass
        try: t.query(#{pk}, begins_with=#{sk})
        except Exception: pass
        try: t.delete_item(#{pk}, #{sk})
        except Exception: pass
        """

        result =
          try do
            Pyex.run(program, storage: mem())
          rescue
            e -> {:host_crash, Exception.message(e)}
          catch
            k, v -> {:host_throw, {k, v}}
          end

        assert match?({:ok, _, _}, result) or match?({:error, %Pyex.Error{}}, result),
               "host crashed on pk=#{pk} sk=#{sk} item=#{item}: #{inspect(result)}"
      end
    end
  end
end
