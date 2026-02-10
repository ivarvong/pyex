defmodule Pyex.Stdlib.SqlTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias Pyex.Error

  @db_url System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/pyex_test")

  defp connect_opts do
    uri = URI.parse(@db_url)
    userinfo = uri.userinfo || ""

    {username, password} =
      case String.split(userinfo, ":", parts: 2) do
        [u, p] -> {u, p}
        [u] -> {u, nil}
        _ -> {"postgres", nil}
      end

    opts = [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      database: String.trim_leading(uri.path || "/pyex_test", "/"),
      username: username
    ]

    if password, do: Keyword.put(opts, :password, password), else: opts
  end

  setup do
    opts = connect_opts()
    {:ok, conn} = Postgrex.start_link(opts)

    Postgrex.query!(conn, "DROP TABLE IF EXISTS pyex_test_items", [])

    Postgrex.query!(
      conn,
      """
      CREATE TABLE pyex_test_items (
        id serial PRIMARY KEY,
        name text NOT NULL,
        price numeric(10,2),
        active boolean DEFAULT true
      )
      """,
      []
    )

    Postgrex.query!(
      conn,
      """
      INSERT INTO pyex_test_items (name, price, active) VALUES
        ('apple', 1.50, true),
        ('banana', 0.75, true),
        ('cherry', 3.00, false)
      """,
      []
    )

    GenServer.stop(conn)

    on_exit(fn ->
      {:ok, c} = Postgrex.start_link(opts)
      Postgrex.query!(c, "DROP TABLE IF EXISTS pyex_test_items", [])
      GenServer.stop(c)
    end)

    :ok
  end

  defp run(code) do
    ctx = Pyex.Ctx.new(environ: %{"DATABASE_URL" => @db_url})

    case Pyex.run(code, ctx) do
      {:ok, value, ctx} -> {value, ctx}
      {:error, %Error{message: reason}} -> raise reason
    end
  end

  defp run!(code) do
    {value, _ctx} = run(code)
    value
  end

  describe "sql.query" do
    test "SELECT all rows" do
      assert run!("""
             import sql
             sql.query("SELECT name, price FROM pyex_test_items ORDER BY name")
             """) == [
               %{"name" => "apple", "price" => 1.5},
               %{"name" => "banana", "price" => 0.75},
               %{"name" => "cherry", "price" => 3.0}
             ]
    end

    test "SELECT with parameterized WHERE" do
      assert run!("""
             import sql
             sql.query("SELECT name FROM pyex_test_items WHERE price > $1 ORDER BY name", [1.00])
             """) == [
               %{"name" => "apple"},
               %{"name" => "cherry"}
             ]
    end

    test "SELECT with integer param" do
      assert run!("""
             import sql
             rows = sql.query("SELECT name FROM pyex_test_items WHERE id = $1", [2])
             rows[0]["name"]
             """) == "banana"
    end

    test "SELECT with boolean param" do
      assert run!("""
             import sql
             rows = sql.query("SELECT name FROM pyex_test_items WHERE active = $1 ORDER BY name", [False])
             [r["name"] for r in rows]
             """) == ["cherry"]
    end

    test "SELECT returning no rows" do
      assert run!("""
             import sql
             sql.query("SELECT name FROM pyex_test_items WHERE id = $1", [9999])
             """) == []
    end

    test "INSERT with RETURNING" do
      result =
        run!("""
        import sql
        sql.query("INSERT INTO pyex_test_items (name, price) VALUES ($1, $2) RETURNING id, name", ["durian", 5.00])
        """)

      assert [%{"id" => id, "name" => "durian"}] = result
      assert is_integer(id)
    end

    test "query with no params omits second arg" do
      assert run!("""
             import sql
             rows = sql.query("SELECT count(*) AS n FROM pyex_test_items")
             rows[0]["n"]
             """) == 3
    end

    test "error on missing DATABASE_URL" do
      ctx = Pyex.Ctx.new(environ: %{})

      assert {:error, %Error{message: msg}} =
               Pyex.run(
                 """
                 import sql
                 sql.query("SELECT 1")
                 """,
                 ctx
               )

      assert msg =~ "DATABASE_URL not set"
    end

    test "error on bad SQL" do
      ctx = Pyex.Ctx.new(environ: %{"DATABASE_URL" => @db_url})

      assert {:error, %Error{message: msg}} =
               Pyex.run(
                 """
                 import sql
                 sql.query("SELECT FROM nonexistent_table_xyz")
                 """,
                 ctx
               )

      assert msg =~ "sql.DatabaseError"
    end
  end
end
