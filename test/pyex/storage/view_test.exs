defmodule Pyex.Storage.ViewTest do
  @moduledoc """
  Tests for the **experimental** `Pyex.Storage.View` attenuating membrane —
  the object-capability layer over the `store` capability.

  Exercises both axes (rights and a non-prefix scope selector), their
  composition, and — the reason the membrane exists — multitenant
  isolation under the host-binding ("Workers") model, asserted through the
  Python `store` surface so it proves what a *program* can and cannot reach.
  """

  use ExUnit.Case, async: true

  alias Pyex.Storage
  alias Pyex.Storage.View

  defp run!(src, opts) do
    {:ok, _value, ctx} = Pyex.run(src, opts)
    Pyex.output(ctx)
  end

  describe "rights attenuation" do
    test "a read-only view permits get and keys but denies set and delete" do
      out =
        run!(
          """
          import store
          print(store.get("k"))
          print(store.keys())
          for op in ("set", "delete"):
              try:
                  getattr(store, op)("k", 9) if op == "set" else store.delete("k")
              except Exception as e:
                  print(op, type(e).__name__)
          """,
          storage: View.readonly(Storage.Memory.new(%{"k" => "1"}))
        )

      assert out == "1\n['k']\nset StorageError\ndelete StorageError\n"
    end

    test "a no-list view permits get but denies enumeration" do
      out =
        run!(
          """
          import store
          print(store.get("k"))
          try:
              store.keys()
          except Exception as e:
              print(type(e).__name__)
          """,
          storage: View.new(Storage.Memory.new(%{"k" => "1"}), rights: [:get])
        )

      assert out == "1\nStorageError\n"
    end
  end

  describe "scope attenuation (selector, not just prefix)" do
    test "a key-set selector makes out-of-scope keys invisible and unwritable" do
      backend = Storage.Memory.new(%{"alpha" => "1", "beta" => "2", "gamma" => "3"})

      out =
        run!(
          """
          import store
          print("in:", store.get("alpha"))
          print("out:", store.get("gamma"))
          try:
              store.set("gamma", 9)
          except Exception as e:
              print("write:", type(e).__name__)
          print("keys:", store.keys())
          """,
          storage: View.scope(backend, {:keys, ["alpha", "beta"]})
        )

      assert out == "in: 1\nout: None\nwrite: StorageError\nkeys: ['alpha', 'beta']\n"
    end

    test "a prefix selector filters listing and hides other keys" do
      backend = Storage.Memory.new(%{"t1:a" => "1", "t1:b" => "2", "t2:a" => "3"})

      out =
        run!(
          """
          import store
          print(store.keys())
          print(store.get("t2:a"))
          """,
          storage: View.scope(backend, {:prefix, "t1:"})
        )

      assert out == "['t1:a', 't1:b']\nNone\n"
    end

    test "scan is scoped to reachable keys and needs both list and get rights" do
      backend = Storage.Memory.new(%{"t1:a" => "1", "t1:b" => "2", "t2:a" => "3"})

      scoped =
        run!(
          "import store\nprint(sorted(store.scan().keys()))",
          storage: View.scope(backend, {:prefix, "t1:"})
        )

      assert scoped == "['t1:a', 't1:b']\n"

      # A list-only view (no :get) cannot scan — scan reveals values.
      denied =
        run!(
          """
          import store
          try:
              store.scan()
          except Exception as e:
              print(type(e).__name__)
          """,
          storage: View.new(backend, rights: [:list])
        )

      assert denied == "StorageError\n"
    end

    test "an invalid selector is rejected at construction" do
      assert_raise ArgumentError, fn ->
        View.scope(Storage.Memory.new(), {:glob, "*"})
      end
    end
  end

  describe "composition" do
    test "scope and read-only stack into a narrower capability" do
      backend = Storage.Memory.new(%{"alpha" => "1", "beta" => "2"})
      view = backend |> View.scope({:prefix, "al"}) |> View.readonly()

      out =
        run!(
          """
          import store
          print(store.get("alpha"))
          print(store.get("beta"))
          try:
              store.set("alpha", 9)
          except Exception as e:
              print(type(e).__name__)
          """,
          storage: view
        )

      # beta is out of scope (invisible -> None); alpha is readable but the
      # read-only right blocks the write.
      assert out == "1\nNone\nStorageError\n"
    end
  end

  describe "multitenancy (host-binding model)" do
    test "tenants on distinct backends cannot observe each other through store" do
      writer = """
      import store
      store.set("note", secret)
      """

      reader = """
      import store
      print(sorted(store.keys()), store.get("note"))
      """

      tenant_a = Storage.Memory.new()
      tenant_b = Storage.Memory.new()

      {:ok, _v, ctx_a} = Pyex.run("secret = 'alpha-secret'\n" <> writer, storage: tenant_a)
      {:ok, _v, ctx_b} = Pyex.run("secret = 'beta-secret'\n" <> writer, storage: tenant_b)

      # Each tenant, on a fresh run, sees only its own slice — there is no key
      # it can name to reach the other, because it holds a different object.
      assert run!(reader, storage: ctx_a.storage) == "['note'] alpha-secret\n"
      assert run!(reader, storage: ctx_b.storage) == "['note'] beta-secret\n"
    end

    test "a per-request read-only view over a shared tenant store cannot mutate it" do
      tenant = Storage.Memory.new(%{"profile" => ~s({"plan": "pro"})})

      # The host hands a read request a read-only capability over the tenant's
      # store. The same Python that would write is structurally unable to.
      out =
        run!(
          """
          import store
          print(store.get("profile"))
          try:
              store.set("profile", {"plan": "free"})
          except Exception as e:
              print(type(e).__name__)
          """,
          storage: View.readonly(tenant)
        )

      assert out == "{'plan': 'pro'}\nStorageError\n"
    end
  end
end
