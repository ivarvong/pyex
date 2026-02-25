defmodule Pyex.Stdlib.Sql do
  @moduledoc """
  Python `sql` module backed by Postgrex.

  Provides `sql.query(sql, params)` for parameterized queries
  against a PostgreSQL database. The connection URL is read from
  `DATABASE_URL` in the execution context's environ.

  Returns a list of dicts (one per row) with column names as keys.

      import sql
      rows = sql.query("SELECT id, name FROM users WHERE id = $1", [42])
      # [{"id": 42, "name": "Alice"}]
  """

  @behaviour Pyex.Stdlib.Module

  @doc """
  Returns the module value -- a map with callable attributes.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "query" => {:builtin, &do_query/1}
    }
  end

  @spec do_query([Pyex.Interpreter.pyvalue()]) ::
          {:io_call, (Pyex.Env.t(), Pyex.Ctx.t() -> {term(), Pyex.Env.t(), Pyex.Ctx.t()})}
          | {:exception, String.t()}
  defp do_query([sql, {:py_list, params, _}]) when is_binary(sql) and is_list(params) do
    do_query([sql, Enum.reverse(params)])
  end

  defp do_query([sql, params]) when is_binary(sql) and is_list(params) do
    Pyex.Ctx.guarded_io_call(:sql, fn env, ctx ->
      case Map.fetch(ctx.env, "DATABASE_URL") do
        {:ok, url} when is_binary(url) ->
          run_query(sql, params, url, env, ctx)

        _ ->
          {{:exception, "sql.query: DATABASE_URL not set in environ"}, env, ctx}
      end
    end)
  end

  defp do_query([sql]) when is_binary(sql) do
    do_query([sql, []])
  end

  defp do_query(_args) do
    {:exception, "TypeError: sql.query(sql_string, params_list)"}
  end

  @spec run_query(
          String.t(),
          [Pyex.Interpreter.pyvalue()],
          String.t(),
          Pyex.Env.t(),
          Pyex.Ctx.t()
        ) ::
          {term(), Pyex.Env.t(), Pyex.Ctx.t()}
  defp run_query(sql, params, url, env, ctx) do
    start_mono = System.monotonic_time()
    telemetry_meta = %{statement: sql}

    :telemetry.execute(
      [:pyex, :query, :start],
      %{system_time: System.system_time()},
      telemetry_meta
    )

    case parse_url(url) do
      {:ok, opts} ->
        conn = Postgrex.start_link(opts)

        case conn do
          {:ok, conn} ->
            try do
              pg_params = Enum.map(params, &to_pg/1)
              result = Postgrex.query(conn, sql, pg_params, timeout: 15_000)

              case result do
                {:ok, %Postgrex.Result{columns: nil}} ->
                  duration = System.monotonic_time() - start_mono

                  :telemetry.execute([:pyex, :query, :stop], %{duration: duration}, %{
                    statement: sql,
                    rows_returned: 0
                  })

                  {[], env, ctx}

                {:ok, %Postgrex.Result{columns: cols, rows: rows, num_rows: n}} ->
                  duration = System.monotonic_time() - start_mono

                  :telemetry.execute([:pyex, :query, :stop], %{duration: duration}, %{
                    statement: sql,
                    rows_returned: n
                  })

                  result = Enum.map(rows, fn row -> row_to_dict(cols, row) end)
                  {result, env, ctx}

                {:error, %Postgrex.Error{postgres: %{message: msg}}} ->
                  duration = System.monotonic_time() - start_mono

                  :telemetry.execute([:pyex, :query, :stop], %{duration: duration}, %{
                    statement: sql,
                    error: msg
                  })

                  {{:exception, "sql.DatabaseError: #{msg}"}, env, ctx}

                {:error, reason} ->
                  duration = System.monotonic_time() - start_mono

                  :telemetry.execute([:pyex, :query, :stop], %{duration: duration}, %{
                    statement: sql,
                    error: inspect(reason)
                  })

                  {{:exception, "sql.DatabaseError: #{inspect(reason)}"}, env, ctx}
              end
            after
              GenServer.stop(conn)
            end

          {:error, reason} ->
            duration = System.monotonic_time() - start_mono

            :telemetry.execute([:pyex, :query, :stop], %{duration: duration}, %{
              statement: sql,
              error: inspect(reason)
            })

            {{:exception, "sql.ConnectionError: #{inspect(reason)}"}, env, ctx}
        end

      {:error, msg} ->
        duration = System.monotonic_time() - start_mono

        :telemetry.execute([:pyex, :query, :stop], %{duration: duration}, %{
          statement: sql,
          error: msg
        })

        {{:exception, msg}, env, ctx}
    end
  end

  @spec parse_url(String.t()) :: {:ok, keyword()} | {:error, String.t()}
  defp parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port, path: path, userinfo: userinfo}
      when scheme in ["postgres", "postgresql"] and is_binary(host) ->
        database =
          case path do
            "/" <> db -> db
            _ -> nil
          end

        {username, password} = parse_userinfo(userinfo)

        opts =
          [
            hostname: host,
            port: port || 5432,
            database: database,
            username: username,
            password: password,
            show_sensitive_data_on_connection_error: false
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        {:ok, opts}

      _ ->
        {:error, "sql.ConnectionError: invalid DATABASE_URL"}
    end
  end

  @spec parse_userinfo(String.t() | nil) :: {String.t() | nil, String.t() | nil}
  defp parse_userinfo(nil), do: {nil, nil}

  defp parse_userinfo(info) do
    case String.split(info, ":", parts: 2) do
      [user, pass] -> {URI.decode(user), URI.decode(pass)}
      [user] -> {URI.decode(user), nil}
    end
  end

  @spec to_pg(Pyex.Interpreter.pyvalue()) :: term()
  defp to_pg(nil), do: nil
  defp to_pg(val) when is_binary(val), do: val
  defp to_pg(val) when is_integer(val), do: val
  defp to_pg(val) when is_float(val), do: Decimal.from_float(val)
  defp to_pg(true), do: true
  defp to_pg(false), do: false
  defp to_pg(val), do: to_string(val)

  @spec row_to_dict([String.t()], [term()]) :: %{String.t() => Pyex.Interpreter.pyvalue()}
  defp row_to_dict(columns, values) do
    columns
    |> Enum.zip(values)
    |> Map.new(fn {col, val} -> {col, from_pg(val)} end)
  end

  @spec from_pg(term()) :: Pyex.Interpreter.pyvalue()
  defp from_pg(nil), do: nil

  defp from_pg(val) when is_binary(val) do
    if byte_size(val) == 16 and not String.printable?(val) do
      <<a::32, b::16, c::16, d::16, e::48>> = val

      :io_lib.format(
        "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
        [a, b, c, d, e]
      )
      |> to_string()
    else
      val
    end
  end

  defp from_pg(val) when is_integer(val), do: val
  defp from_pg(val) when is_float(val), do: val
  defp from_pg(true), do: true
  defp from_pg(false), do: false
  defp from_pg(%Decimal{} = d), do: Decimal.to_float(d)
  defp from_pg(%Date{} = d), do: Date.to_iso8601(d)
  defp from_pg(%Time{} = t), do: Time.to_iso8601(t)
  defp from_pg(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp from_pg(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp from_pg(list) when is_list(list), do: Enum.map(list, &from_pg/1)
  defp from_pg(%Postgrex.INET{address: addr}), do: :inet.ntoa(addr) |> to_string()

  defp from_pg(val) when is_map(val),
    do: Map.new(val, fn {k, v} -> {to_string(k), from_pg(v)} end)

  defp from_pg(val), do: to_string(val)
end
