defmodule Pyex.Stdlib.Boto3.DynamoDB do
  @moduledoc """
  A local DynamoDB backend for `boto3.resource("dynamodb")`, the way real
  apps are tested against `dynamodb-local` / `moto`.

      import boto3
      from decimal import Decimal

      dynamodb = boto3.resource("dynamodb")
      dynamodb.create_table(
          TableName="expenses",
          KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
          AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
          BillingMode="PAY_PER_REQUEST",
      )
      table = dynamodb.Table("expenses")
      table.put_item(Item={"id": "1", "amount": Decimal("9.99")})
      table.get_item(Key={"id": "1"})["Item"]   # numbers come back as Decimal
      table.scan()["Items"]
      table.delete_item(Key={"id": "1"})

  Items persist in the run's `Pyex.Storage` backend (so they survive across
  `Pyex.run` calls and inherit the same per-tenant / object-capability
  attenuation as the `store` module), marshalled to DynamoDB's typed wire
  format so a `Decimal` round-trips exactly (numbers are the `N` string type).
  """

  alias Pyex.{Interpreter, PyDict}
  alias Pyex.Stdlib.Boto3.DynamoDB.Expr
  alias Pyex.Stdlib.JSON

  @typep pyvalue :: Interpreter.pyvalue()
  @sep ""

  @doc ~S{The boto3.resource("dynamodb") value.}
  @spec resource() :: pyvalue()
  def resource do
    PyDict.from_pairs([
      {"__boto3_dynamodb_resource__", true},
      {"create_table", {:builtin_kw, &create_table/2}},
      {"Table", {:builtin, &table/1}}
    ])
  end

  # ── resource.create_table / resource.Table ────────────────────────────────

  @spec create_table([pyvalue()], %{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp create_table(_args, kwargs) do
    with name when is_binary(name) <- Map.get(kwargs, "TableName"),
         {:ok, hash, range} <- key_schema(Map.get(kwargs, "KeySchema")) do
      with_backend(fn backend, env, ctx ->
        schema = JSON.dumps(PyDict.from_pairs([{"hash", hash}, {"range", range || nil}]))

        case Pyex.Storage.put(backend, schema_key(name), schema) do
          {:ok, backend} -> {table_value(name), env, %{ctx | storage: backend}}
          {:error, reason} -> {storage_error(reason), env, ctx}
        end
      end)
    else
      _ -> {:exception, "ParamValidationError: create_table requires TableName and KeySchema"}
    end
  end

  @spec table([pyvalue()]) :: pyvalue()
  defp table([name]) when is_binary(name), do: table_value(name)
  defp table(_), do: {:exception, "TypeError: Table(name) requires a table name string"}

  @spec table_value(String.t()) :: pyvalue()
  defp table_value(name) do
    PyDict.from_pairs([
      {"__boto3_dynamodb_table__", true},
      {"name", name},
      {"table_name", name},
      {"put_item", {:builtin_kw, &put_item(name, &1, &2)}},
      {"get_item", {:builtin_kw, &get_item(name, &1, &2)}},
      {"delete_item", {:builtin_kw, &delete_item(name, &1, &2)}},
      {"update_item", {:builtin_kw, &update_item(name, &1, &2)}},
      {"scan", {:builtin_kw, &scan(name, &1, &2)}},
      {"query", {:builtin_kw, &query(name, &1, &2)}}
    ])
  end

  # ── Table operations ──────────────────────────────────────────────────────

  # Each operation runs inside a host runtime span named after the real
  # DynamoDB API call, carrying the OTel database semantic-convention
  # attributes. The `do_*` body returns `{result, ctx, close_attrs}`; `traced`
  # owns the span lifecycle so the operation logic stays free of telemetry.
  @spec put_item(String.t(), [pyvalue()], %{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp put_item(table, _args, kwargs) do
    item = Map.get(kwargs, "Item")

    with_table(table, fn backend, schema, env, ctx ->
      traced(ctx, env, "PutItem", table, fn ctx ->
        do_put_item(table, schema, item, kwargs, backend, ctx)
      end)
    end)
  end

  defp do_put_item(table, schema, item, kwargs, backend, ctx) do
    with {:py_dict, _, _} <- item,
         {:ok, marshalled} <- marshal(item),
         {:ok, sk} <- storage_key(table, schema, item) do
      subs = subs_of(kwargs)

      case check_condition(backend, sk, Map.get(kwargs, "ConditionExpression"), subs) do
        :ok ->
          case Pyex.Storage.put(backend, sk, JSON.dumps(marshalled)) do
            {:ok, backend} -> {empty_response(), %{ctx | storage: backend}, %{}}
            {:error, reason} -> {storage_error(reason), ctx, error_attr(reason)}
          end

        :failed ->
          {conditional_check_failed(), ctx, error_attr("ConditionalCheckFailedException")}

        {:error, msg} ->
          {{:exception, msg}, ctx, error_attr(msg)}
      end
    else
      {:error, msg} ->
        {{:exception, msg}, ctx, error_attr(msg)}

      _ ->
        {{:exception, "ParamValidationError: put_item requires Item to be a dict"}, ctx,
         error_attr("ParamValidationError")}
    end
  end

  @spec get_item(String.t(), [pyvalue()], %{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp get_item(table, _args, kwargs) do
    key = Map.get(kwargs, "Key")

    with_table(table, fn backend, schema, env, ctx ->
      traced(ctx, env, "GetItem", table, fn ctx ->
        do_get_item(table, schema, key, backend, ctx)
      end)
    end)
  end

  defp do_get_item(table, schema, key, backend, ctx) do
    case storage_key(table, schema, key) do
      {:ok, sk} ->
        case Pyex.Storage.get(backend, sk) do
          {:ok, json} ->
            {PyDict.from_pairs([{"Item", unmarshal(JSON.decode(json))}]), ctx, %{"hit" => true}}

          :miss ->
            {empty_response(), ctx, %{"hit" => false}}

          {:error, reason} ->
            {storage_error(reason), ctx, error_attr(reason)}
        end

      {:error, msg} ->
        {{:exception, msg}, ctx, error_attr(msg)}
    end
  end

  @spec delete_item(String.t(), [pyvalue()], %{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp delete_item(table, _args, kwargs) do
    key = Map.get(kwargs, "Key")

    with_table(table, fn backend, schema, env, ctx ->
      traced(ctx, env, "DeleteItem", table, fn ctx ->
        do_delete_item(table, schema, key, backend, ctx)
      end)
    end)
  end

  defp do_delete_item(table, schema, key, backend, ctx) do
    case storage_key(table, schema, key) do
      {:ok, sk} ->
        case Pyex.Storage.delete(backend, sk) do
          {:ok, backend} -> {empty_response(), %{ctx | storage: backend}, %{}}
          {:error, reason} -> {storage_error(reason), ctx, error_attr(reason)}
        end

      {:error, msg} ->
        {{:exception, msg}, ctx, error_attr(msg)}
    end
  end

  @spec scan(String.t(), [pyvalue()], %{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp scan(table, _args, _kwargs) do
    with_table(table, fn backend, _schema, env, ctx ->
      traced(ctx, env, "Scan", table, fn ctx -> do_scan(table, backend, ctx) end)
    end)
  end

  defp do_scan(table, backend, ctx) do
    case Pyex.Storage.scan_prefix(backend, item_prefix(table)) do
      {:ok, pairs} ->
        items = Enum.map(pairs, fn {_k, json} -> unmarshal(JSON.decode(json)) end)
        {result_page(items), ctx, count_attrs(length(items), length(items))}

      {:error, reason} ->
        {storage_error(reason), ctx, error_attr(reason)}
    end
  end

  @spec update_item(String.t(), [pyvalue()], %{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp update_item(table, _args, kwargs) do
    key = Map.get(kwargs, "Key")

    with_table(table, fn backend, schema, env, ctx ->
      traced(ctx, env, "UpdateItem", table, fn ctx ->
        do_update_item(table, schema, key, kwargs, backend, ctx)
      end)
    end)
  end

  defp do_update_item(table, schema, key, kwargs, backend, ctx) do
    subs = subs_of(kwargs)

    with {:ok, sk} <- storage_key(table, schema, key),
         :ok <- check_condition(backend, sk, Map.get(kwargs, "ConditionExpression"), subs),
         current = load_item_map(backend, sk) || key_to_map(key),
         {:ok, updated} <- Expr.update(Map.get(kwargs, "UpdateExpression"), current, subs) do
      case store_item_map(backend, sk, updated) do
        {:ok, backend} -> {empty_response(), %{ctx | storage: backend}, %{}}
        {:error, reason} -> {storage_error(reason), ctx, error_attr(reason)}
      end
    else
      :failed -> {conditional_check_failed(), ctx, error_attr("ConditionalCheckFailedException")}
      {:error, msg} -> {{:exception, msg}, ctx, error_attr(msg)}
    end
  end

  @spec query(String.t(), [pyvalue()], %{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp query(table, _args, kwargs) do
    with_table(table, fn backend, schema, env, ctx ->
      kwargs = Map.update(kwargs, "KeyConditionExpression", nil, &Pyex.Ctx.deref(ctx, &1))

      traced(ctx, env, "Query", table, fn ctx -> do_query(backend, table, schema, kwargs, ctx) end)
    end)
  end

  defp do_query(backend, table, schema, kwargs, ctx) do
    case query_plan(schema, kwargs) do
      {:ok, partition_prefix, sort_pred} ->
        case Pyex.Storage.scan_prefix(backend, item_prefix(table) <> partition_prefix) do
          {:ok, pairs} ->
            items =
              pairs
              |> Enum.map(fn {_k, json} -> unmarshal(JSON.decode(json)) end)
              |> Enum.filter(sort_pred)
              |> maybe_reverse(Map.get(kwargs, "ScanIndexForward", true))
              |> maybe_limit(Map.get(kwargs, "Limit"))

            {result_page(items), ctx, count_attrs(length(items), length(pairs))}

          {:error, reason} ->
            {storage_error(reason), ctx, error_attr(reason)}
        end

      {:error, msg} ->
        {{:exception, msg}, ctx, error_attr(msg)}
    end
  end

  defp result_page(items) do
    PyDict.from_pairs([
      {"Items", py_list(items)},
      {"Count", length(items)},
      {"ScannedCount", length(items)}
    ])
  end

  # ── host telemetry (OTel database semantic conventions) ────────────────────
  #
  # Each table op becomes a host runtime span named "<Operation> <table>"
  # ("PutItem ledger") with `db.system.name="dynamodb"`, the real DynamoDB
  # `db.operation.name`, `db.collection.name`, and the AWS-specific
  # `aws.dynamodb.table_names`. The body returns `{result, ctx, close_attrs}`;
  # the span is closed with those attrs (an `error.type` on any failure, so a
  # denied storage capability or a failed condition is visible in the ledger).
  @spec traced(
          Pyex.Ctx.t(),
          Pyex.Env.t(),
          String.t(),
          String.t(),
          (Pyex.Ctx.t() -> {pyvalue(), Pyex.Ctx.t(), map()})
        ) :: {pyvalue(), Pyex.Env.t(), Pyex.Ctx.t()}
  defp traced(ctx, env, operation, table, fun) do
    {ctx, span} = open_ddb_span(ctx, operation, table)
    {result, ctx, close_attrs} = fun.(ctx)
    {result, env, Pyex.Ctx.close_runtime_span(ctx, span, close_attrs)}
  end

  defp open_ddb_span(ctx, operation, table) do
    Pyex.Ctx.open_runtime_span(ctx, "#{operation} #{table}", %{
      "db.system.name" => "dynamodb",
      "db.operation.name" => operation,
      "db.collection.name" => table,
      "aws.dynamodb.table_names" => [table]
    })
  end

  defp error_attr(reason), do: %{"error.type" => reason}

  defp count_attrs(count, scanned),
    do: %{"aws.dynamodb.count" => count, "aws.dynamodb.scanned_count" => scanned}

  # Pairs come back sorted by storage key (== sort-key ascending). DynamoDB
  # default is forward; ScanIndexForward=False reverses.
  defp maybe_reverse(items, false), do: Enum.reverse(items)
  defp maybe_reverse(items, _), do: items

  defp maybe_limit(items, n) when is_integer(n), do: Enum.take(items, n)
  defp maybe_limit(items, _), do: items

  # Builds {partition_storage_prefix, sort_key_predicate} from a
  # KeyConditionExpression (a boto3.dynamodb.conditions.Key chain).
  @spec query_plan(map(), %{optional(String.t()) => pyvalue()}) ::
          {:ok, String.t(), (pyvalue() -> boolean())} | {:error, String.t()}
  defp query_plan(schema, kwargs) do
    case Map.get(kwargs, "KeyConditionExpression") do
      nil ->
        {:error, "ValidationException: Query requires a KeyConditionExpression"}

      cond_val ->
        case condition_ast(cond_val) do
          {:ok, ast} -> plan_from_ast(ast, schema)
          {:error, _} = err -> err
        end
    end
  end

  defp plan_from_ast(ast, schema) do
    clauses = flatten_and(ast)
    hash = schema["hash"]
    range = schema["range"]

    case Enum.find(clauses, fn {_op, attr, _v} -> attr == hash end) do
      {:eq, ^hash, hash_val} ->
        sort_clauses = Enum.filter(clauses, fn {_op, attr, _v} -> attr == range end)
        prefix = key_part(hash_val) <> @sep
        {:ok, prefix, sort_predicate(sort_clauses, range)}

      _ ->
        {:error, "ValidationException: KeyConditionExpression must fix the partition key"}
    end
  end

  defp flatten_and({:and, a, b}), do: flatten_and(a) ++ flatten_and(b)
  defp flatten_and({op, attr, v}), do: [{op, attr, v}]

  # Combines the sort-key clauses into one item predicate over the unmarshalled
  # item dict.
  defp sort_predicate([], _range), do: fn _item -> true end

  defp sort_predicate(clauses, range) do
    fn item ->
      sv = dget(item, range)
      Enum.all?(clauses, fn clause -> sort_matches?(clause, sv) end)
    end
  end

  defp sort_matches?(_clause, nil), do: false
  defp sort_matches?({:eq, _a, v}, sv), do: sv == v
  defp sort_matches?({:begins_with, _a, v}, sv), do: is_binary(sv) and String.starts_with?(sv, v)
  defp sort_matches?({:lt, _a, v}, sv), do: sv < v
  defp sort_matches?({:lte, _a, v}, sv), do: sv <= v
  defp sort_matches?({:gt, _a, v}, sv), do: sv > v
  defp sort_matches?({:gte, _a, v}, sv), do: sv >= v
  defp sort_matches?({:between, _a, {lo, hi}}, sv), do: sv >= lo and sv <= hi
  defp sort_matches?(_clause, _sv), do: false

  # ── key schema / storage keys ─────────────────────────────────────────────

  # Parses a KeySchema list into {hash_attr, range_attr_or_nil}.
  @spec key_schema(pyvalue()) :: {:ok, String.t(), String.t() | nil} | :error
  defp key_schema(schema) do
    case to_list(schema) do
      list when is_list(list) ->
        roles =
          Enum.reduce(list, %{}, fn entry, acc ->
            with {:py_dict, _, _} <- entry,
                 attr when is_binary(attr) <- dget(entry, "AttributeName"),
                 type when is_binary(type) <- dget(entry, "KeyType") do
              Map.put(acc, type, attr)
            else
              _ -> acc
            end
          end)

        case Map.get(roles, "HASH") do
          nil -> :error
          hash -> {:ok, hash, Map.get(roles, "RANGE")}
        end

      _ ->
        :error
    end
  end

  # Builds the Storage key for an item/key dict given the table's schema.
  @spec storage_key(String.t(), map(), pyvalue()) :: {:ok, String.t()} | {:error, String.t()}
  defp storage_key(table, schema, dict) do
    hash_attr = schema["hash"]
    range_attr = schema["range"]

    case dget(dict, hash_attr) do
      nil ->
        {:error, "ValidationException: missing the key attribute '#{hash_attr}'"}

      hash_val ->
        parts =
          if is_binary(range_attr) do
            [key_part(hash_val), key_part(dget(dict, range_attr))]
          else
            [key_part(hash_val)]
          end

        {:ok, item_prefix(table) <> Enum.join(parts, @sep)}
    end
  end

  defp key_part(v) when is_binary(v), do: "S:" <> v
  defp key_part(v) when is_integer(v), do: "N:" <> Integer.to_string(v)
  defp key_part({:pyex_decimal, d}), do: "N:" <> Decimal.to_string(d, :normal)
  defp key_part(v), do: "S:" <> Interpreter.Helpers.py_str(v)

  defp schema_key(table), do: "__ddb__#{@sep}schema#{@sep}" <> table
  defp item_prefix(table), do: "__ddb__#{@sep}item#{@sep}#{table}#{@sep}"

  # ── DynamoDB typed marshalling (preserves Decimal as the N string type) ────

  @spec marshal(pyvalue()) :: {:ok, pyvalue()} | {:error, String.t()}
  defp marshal({:py_dict, _, _} = dict) do
    pairs = pairs(dict)

    Enum.reduce_while(pairs, {:ok, []}, fn {k, v}, {:ok, acc} ->
      case marshal_value(v) do
        {:ok, mv} -> {:cont, {:ok, [{to_string(k), mv} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, PyDict.from_pairs(Enum.reverse(acc))}
      {:error, _} = err -> err
    end
  end

  @spec marshal_value(pyvalue()) :: {:ok, pyvalue()} | {:error, String.t()}
  defp marshal_value(v) when is_binary(v), do: {:ok, typed("S", v)}
  defp marshal_value(v) when is_boolean(v), do: {:ok, typed("BOOL", v)}
  defp marshal_value(nil), do: {:ok, typed("NULL", true)}
  defp marshal_value(v) when is_integer(v), do: {:ok, typed("N", Integer.to_string(v))}

  defp marshal_value({:pyex_decimal, d}), do: {:ok, typed("N", Decimal.to_string(d, :normal))}

  defp marshal_value(v) when is_float(v),
    do: {:error, "TypeError: Float types are not supported. Use Decimal types instead."}

  defp marshal_value({:py_dict, _, _} = m) do
    case marshal(m) do
      {:ok, marshalled} -> {:ok, typed("M", marshalled)}
      {:error, _} = err -> err
    end
  end

  defp marshal_value(list_or_tuple) when is_tuple(list_or_tuple) or is_list(list_or_tuple) do
    case to_list(list_or_tuple) do
      items when is_list(items) ->
        Enum.reduce_while(items, {:ok, []}, fn v, {:ok, acc} ->
          case marshal_value(v) do
            {:ok, mv} -> {:cont, {:ok, [mv | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, typed("L", py_list(Enum.reverse(acc)))}
          {:error, _} = err -> err
        end

      _ ->
        {:error, "TypeError: unsupported attribute value"}
    end
  end

  defp marshal_value(_), do: {:error, "TypeError: unsupported attribute value"}

  defp typed(tag, value), do: PyDict.from_pairs([{tag, value}])

  @spec unmarshal(pyvalue()) :: pyvalue()
  defp unmarshal({:py_dict, _, _} = dict) do
    dict
    |> pairs()
    |> Enum.map(fn {k, v} -> {to_string(k), unmarshal_value(v)} end)
    |> PyDict.from_pairs()
  end

  defp unmarshal(other), do: other

  @spec unmarshal_value(pyvalue()) :: pyvalue()
  defp unmarshal_value({:py_dict, _, _} = typed) do
    case pairs(typed) do
      [{"S", s}] -> s
      [{"N", n}] when is_binary(n) -> {:pyex_decimal, Decimal.new(n)}
      [{"BOOL", b}] -> b
      [{"NULL", _}] -> nil
      [{"M", m}] -> unmarshal(m)
      [{"L", l}] -> l |> to_list() |> Enum.map(&unmarshal_value/1) |> py_list()
      _ -> typed
    end
  end

  defp unmarshal_value(other), do: other

  # ── backend gating (mirrors the store module) ─────────────────────────────

  @spec with_backend((term(), Pyex.Env.t(), Pyex.Ctx.t() ->
                        {pyvalue(), Pyex.Env.t(), Pyex.Ctx.t()})) :: pyvalue()
  defp with_backend(fun) do
    {:io_call,
     fn env, ctx ->
       case ctx.storage do
         nil ->
           {{:exception,
             "StorageError: no storage backend configured. Pass `storage:` to " <>
               "Pyex.run to enable DynamoDB."}, env, ctx}

         backend ->
           fun.(backend, env, ctx)
       end
     end}
  end

  # Like with_backend, but first loads the table's registered key schema.
  @spec with_table(String.t(), (term(), map(), Pyex.Env.t(), Pyex.Ctx.t() ->
                                  {pyvalue(), Pyex.Env.t(), Pyex.Ctx.t()})) :: pyvalue()
  defp with_table(table, fun) do
    with_backend(fn backend, env, ctx ->
      case Pyex.Storage.get(backend, schema_key(table)) do
        {:ok, json} ->
          schema = json |> JSON.decode() |> dict_to_map()
          fun.(backend, schema, env, ctx)

        :miss ->
          {{:exception,
            "ResourceNotFoundException: Requested resource not found: Table: #{table} not found"},
           env, ctx}

        {:error, reason} ->
          {storage_error(reason), env, ctx}
      end
    end)
  end

  # ── small helpers ─────────────────────────────────────────────────────────

  # Ordered {key, value} pairs of a py_dict (insertion order).
  defp pairs({:py_dict, _, _} = d) do
    Enum.map(PyDict.keys(d), fn k -> {k, elem(PyDict.fetch(d, k), 1)} end)
  end

  defp dget({:py_dict, _, _} = d, key) when is_binary(key) do
    case PyDict.fetch(d, key) do
      {:ok, v} -> v
      :error -> nil
    end
  end

  defp dget(_, _), do: nil

  defp dict_to_map({:py_dict, _, _} = d),
    do: d |> pairs() |> Map.new(fn {k, v} -> {to_string(k), v} end)

  # (pairs/1 defined above)

  defp to_list({:py_list, reversed, _}), do: Enum.reverse(reversed)
  defp to_list({:tuple, items}), do: items
  defp to_list(list) when is_list(list), do: list
  defp to_list(_), do: :error

  defp py_list(items), do: {:py_list, Enum.reverse(items), length(items)}

  defp empty_response,
    do: PyDict.from_pairs([{"ResponseMetadata", PyDict.from_pairs([{"HTTPStatusCode", 200}])}])

  defp storage_error(reason), do: {:exception, "StorageError: #{reason}"}

  # ── condition / update support (resource level; plain pyex values) ─────────

  # Expression substitutions: ExpressionAttributeValues (plain pyex values) and
  # ExpressionAttributeNames.
  defp subs_of(kwargs) do
    %{
      values: kw_map(kwargs, "ExpressionAttributeValues"),
      names: kw_map(kwargs, "ExpressionAttributeNames")
    }
  end

  defp kw_map(kwargs, key) do
    case Map.get(kwargs, key) do
      {:py_dict, _, _} = d -> dict_to_map(d)
      _ -> %{}
    end
  end

  @spec check_condition(term(), String.t(), String.t() | nil, map()) ::
          :ok | :failed | {:error, String.t()}
  defp check_condition(_backend, _sk, nil, _subs), do: :ok

  defp check_condition(backend, sk, cond_expr, subs) do
    case Expr.condition(cond_expr, load_item_map(backend, sk) || %{}, subs) do
      true -> :ok
      false -> :failed
      {:error, _} = err -> err
    end
  end

  defp conditional_check_failed,
    do: {:exception, "ConditionalCheckFailedException: The conditional request failed"}

  # Loads the item at `sk` as a plain Elixir map (numbers as Decimal); nil on miss.
  defp load_item_map(backend, sk) do
    case Pyex.Storage.get(backend, sk) do
      {:ok, json} -> json |> JSON.decode() |> unmarshal() |> dict_to_map()
      _ -> nil
    end
  end

  defp store_item_map(backend, sk, emap) do
    case marshal(PyDict.from_pairs(Map.to_list(emap))) do
      {:ok, marshalled} -> Pyex.Storage.put(backend, sk, JSON.dumps(marshalled))
      {:error, _} = err -> err
    end
  end

  defp key_to_map({:py_dict, _, _} = key), do: dict_to_map(key)
  defp key_to_map(_), do: %{}

  # Extracts the condition AST stored on a boto3.dynamodb.conditions.Key chain.
  defp condition_ast({:instance, _, attrs}) do
    case Map.get(attrs, "__cond__") do
      nil ->
        {:error, "ValidationException: KeyConditionExpression must be a conditions.Key chain"}

      ast ->
        {:ok, ast}
    end
  end

  defp condition_ast(_),
    do: {:error, "ValidationException: KeyConditionExpression must be a conditions.Key chain"}

  # ── boto3.dynamodb.conditions (Key / Attr DSL) ─────────────────────────────

  @doc false
  @spec conditions_module() :: pyvalue()
  def conditions_module do
    {:module, "boto3.dynamodb.conditions",
     %{
       "__name__" => "boto3.dynamodb.conditions",
       "Key" => {:builtin, &key_builder/1},
       "Attr" => {:builtin, &key_builder/1}
     }}
  end

  defp key_builder([name]) when is_binary(name) do
    method = fn op -> {:builtin, fn [v] -> make_condition({op, name, v}) end} end

    PyDict.from_pairs([
      {"eq", method.(:eq)},
      {"lt", method.(:lt)},
      {"lte", method.(:lte)},
      {"gt", method.(:gt)},
      {"gte", method.(:gte)},
      {"begins_with", method.(:begins_with)},
      {"between", {:builtin, fn [lo, hi] -> make_condition({:between, name, {lo, hi}}) end}}
    ])
  end

  defp key_builder(_), do: {:exception, "TypeError: Key(name) requires a string attribute name"}

  defp make_condition(ast), do: {:instance, cond_class(), %{"__cond__" => ast}}

  defp cond_class do
    {:class, "Condition", [],
     %{
       "__name__" => "Condition",
       "__and__" => {:builtin, &cond_and/1},
       "__or__" => {:builtin, &cond_or/1}
     }}
  end

  defp cond_and([{:instance, _, a}, {:instance, _, b}]),
    do: make_condition({:and, Map.get(a, "__cond__"), Map.get(b, "__cond__")})

  defp cond_or([{:instance, _, a}, {:instance, _, b}]),
    do: make_condition({:or, Map.get(a, "__cond__"), Map.get(b, "__cond__")})

  # ── boto3.client("dynamodb") (low-level, typed wire, transactions) ─────────

  @doc ~S{The boto3.client("dynamodb") value (low-level, for transactions).}
  @spec client() :: pyvalue()
  def client do
    PyDict.from_pairs([
      {"__boto3_dynamodb_client__", true},
      {"transact_write_items", {:builtin_kw, &transact_write_items/2}},
      {"exceptions", client_exceptions()}
    ])
  end

  defp client_exceptions do
    PyDict.from_pairs([
      {"TransactionCanceledException", {:exception_class, "TransactionCanceledException"}},
      {"ConditionalCheckFailedException", {:exception_class, "ConditionalCheckFailedException"}}
    ])
  end

  # The whole call is one parent `TransactWriteItems` host span. Each write that
  # is actually applied opens a child span under it — so a *cancelled*
  # transaction is visible in the trace as the parent closed with
  # `error.type="TransactionCanceledException"` and **zero** child writes
  # (atomicity, observable from the ledger rather than inferred from the
  # program), while a committed one carries exactly its applied writes.
  @transact_ops %{
    "Put" => :put,
    "Update" => :update,
    "Delete" => :delete,
    "ConditionCheck" => :check
  }

  @spec transact_write_items([pyvalue()], %{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp transact_write_items(_args, kwargs) do
    items = Map.get(kwargs, "TransactItems")

    {:io_call,
     fn env, ctx ->
       case ctx.storage do
         nil ->
           {{:exception, "RuntimeError: DynamoDB requires a storage backend"}, env, ctx}

         backend ->
           {ctx, span} = open_transact_span(ctx, transact_table_names(items, ctx))

           case run_transaction(backend, items, ctx) do
             {:ok, backend, ctx} ->
               {empty_response(), env,
                Pyex.Ctx.close_runtime_span(%{ctx | storage: backend}, span, %{})}

             {:cancelled, reasons, ctx} ->
               inst = transaction_cancelled_instance(reasons)

               ctx =
                 Pyex.Ctx.close_runtime_span(
                   ctx,
                   span,
                   error_attr("TransactionCanceledException")
                 )

               {{:exception,
                 "TransactionCanceledException: Transaction cancelled, please refer cancellation reasons for specific reasons " <>
                   inspect(reasons)}, env, %{ctx | exception_instance: inst}}

             {:error, msg, ctx} ->
               {{:exception, msg}, env, Pyex.Ctx.close_runtime_span(ctx, span, error_attr(msg))}
           end
       end
     end}
  end

  defp open_transact_span(ctx, tables) do
    Pyex.Ctx.open_runtime_span(ctx, "TransactWriteItems", %{
      "db.system.name" => "dynamodb",
      "db.operation.name" => "TransactWriteItems",
      "aws.dynamodb.table_names" => tables
    })
  end

  # The distinct table names a TransactItems list touches — for the parent
  # span's `aws.dynamodb.table_names`. Best-effort and read-only; the real
  # parse/validation happens in `run_transaction`.
  defp transact_table_names(items_val, ctx) do
    case ctx |> Pyex.Ctx.deref(items_val) |> to_list() do
      list when is_list(list) ->
        list
        |> Enum.flat_map(fn item -> item_table_names(Pyex.Ctx.deref(ctx, item), ctx) end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp item_table_names({:py_dict, _, _} = item, ctx) do
    for key <- Map.keys(@transact_ops),
        spec = dget(item, key),
        spec != nil,
        table = dget(Pyex.Ctx.deref(ctx, spec), "TableName"),
        is_binary(table),
        do: table
  end

  defp item_table_names(_item, _ctx), do: []

  # Two-phase: check every condition against the pre-transaction snapshot, then
  # — only if all pass — apply every write, threading the backend. DynamoDB
  # reports one CancellationReason per item ("None" or "ConditionalCheckFailed").
  defp run_transaction(backend, items_val, ctx) do
    items = ctx |> Pyex.Ctx.deref(items_val) |> to_list()

    with items when is_list(items) <- items,
         {:ok, ops} <- parse_transact_items(items, backend, ctx) do
      reasons = Enum.map(ops, &check_op(backend, &1))

      if Enum.any?(reasons, &(&1 == "ConditionalCheckFailed")) do
        {:cancelled, reasons, ctx}
      else
        apply_ops(backend, ops, ctx)
      end
    else
      :error -> {:error, "ValidationException: TransactItems must be a list", ctx}
      {:error, msg} -> {:error, msg, ctx}
    end
  end

  defp parse_transact_items(items, backend, ctx) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case parse_transact_item(Pyex.Ctx.deref(ctx, item), backend, ctx) do
        {:ok, op} -> {:cont, {:ok, [op | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp parse_transact_item({:py_dict, _, _} = item, backend, ctx) do
    case Enum.find_value(@transact_ops, fn {key, kind} ->
           case dget(item, key) do
             nil -> nil
             spec -> {kind, Pyex.Ctx.deref(ctx, spec)}
           end
         end) do
      {kind, spec} -> build_transact_op(kind, spec, backend, ctx)
      nil -> {:error, "ValidationException: TransactItem needs Put/Update/Delete/ConditionCheck"}
    end
  end

  defp parse_transact_item(_other, _backend, _ctx),
    do: {:error, "ValidationException: each TransactItem must be a dict"}

  defp build_transact_op(kind, spec, backend, ctx) do
    table = dget(spec, "TableName")

    with name when is_binary(name) <- table,
         {:ok, schema} <- load_schema(backend, name) do
      key_field = if kind == :put, do: "Item", else: "Key"
      key_dict = ctx |> deref_field(spec, key_field) |> unmarshal()
      emap = if match?({:py_dict, _, _}, key_dict), do: dict_to_map(key_dict), else: %{}

      case storage_key(name, schema, key_dict) do
        {:ok, sk} ->
          {:ok,
           %{
             kind: kind,
             table: name,
             sk: sk,
             emap: emap,
             cond: dget(spec, "ConditionExpression"),
             update: dget(spec, "UpdateExpression"),
             subs: typed_subs(spec)
           }}

        {:error, _} = err ->
          err
      end
    else
      nil -> {:error, "ValidationException: TransactItem requires a TableName"}
      {:error, _} = err -> err
    end
  end

  defp deref_field(ctx, spec, field), do: Pyex.Ctx.deref(ctx, dget(spec, field))

  defp load_schema(backend, table) do
    case Pyex.Storage.get(backend, schema_key(table)) do
      {:ok, json} -> {:ok, json |> JSON.decode() |> dict_to_map()}
      :miss -> {:error, "ResourceNotFoundException: Table: #{table} not found"}
      {:error, reason} -> {:error, "StorageError: #{reason}"}
    end
  end

  # Substitutions from the typed-wire ExpressionAttributeValues/Names.
  defp typed_subs(spec) do
    values =
      case dget(spec, "ExpressionAttributeValues") do
        {:py_dict, _, _} = d -> d |> unmarshal() |> dict_to_map()
        _ -> %{}
      end

    %{values: values, names: kw_map_from(dget(spec, "ExpressionAttributeNames"))}
  end

  defp kw_map_from({:py_dict, _, _} = d), do: dict_to_map(d)
  defp kw_map_from(_), do: %{}

  defp check_op(_backend, %{cond: nil}), do: "None"

  defp check_op(backend, %{cond: cond_expr, sk: sk, subs: subs}) do
    case Expr.condition(cond_expr, load_item_map(backend, sk) || %{}, subs) do
      true -> "None"
      _ -> "ConditionalCheckFailed"
    end
  end

  defp apply_ops(backend, ops, ctx) do
    Enum.reduce_while(ops, {:ok, backend, ctx}, fn op, {:ok, backend, ctx} ->
      apply_op_traced(backend, op, ctx)
    end)
  end

  # A ConditionCheck applies no write, so it gets no child span — keeping
  # "child spans == the writes that happened" exact.
  defp apply_op_traced(backend, %{kind: :check} = op, ctx) do
    {:ok, ^backend} = apply_op(backend, op)
    {:cont, {:ok, backend, ctx}}
  end

  defp apply_op_traced(backend, %{kind: kind, table: table} = op, ctx) do
    {ctx, span} = open_ddb_span(ctx, transact_op_name(kind), table)

    case apply_op(backend, op) do
      {:ok, backend} ->
        {:cont, {:ok, backend, Pyex.Ctx.close_runtime_span(ctx, span, %{})}}

      {:error, reason} ->
        {:halt,
         {:error, "StorageError: #{reason}",
          Pyex.Ctx.close_runtime_span(ctx, span, error_attr(reason))}}
    end
  end

  defp transact_op_name(:put), do: "PutItem"
  defp transact_op_name(:update), do: "UpdateItem"
  defp transact_op_name(:delete), do: "DeleteItem"

  defp apply_op(backend, %{kind: :put, sk: sk, emap: emap}), do: store_item_map(backend, sk, emap)

  defp apply_op(backend, %{kind: :update, sk: sk, emap: emap, update: uexpr, subs: subs}) do
    current = load_item_map(backend, sk) || emap

    case Expr.update(uexpr, current, subs) do
      {:ok, updated} -> store_item_map(backend, sk, updated)
      {:error, msg} -> {:error, msg}
    end
  end

  defp apply_op(backend, %{kind: :delete, sk: sk}), do: Pyex.Storage.delete(backend, sk)
  defp apply_op(backend, %{kind: :check}), do: {:ok, backend}

  defp transaction_cancelled_instance(reasons) do
    reason_dicts = Enum.map(reasons, fn code -> PyDict.from_pairs([{"Code", code}]) end)

    response =
      PyDict.from_pairs([
        {"CancellationReasons", py_list(reason_dicts)},
        {"Error",
         PyDict.from_pairs([
           {"Code", "TransactionCanceledException"},
           {"Message", "Transaction cancelled"}
         ])}
      ])

    {:instance,
     Interpreter.exception_instance_class({:exception_class, "TransactionCanceledException"}),
     %{"args" => {:tuple, ["Transaction cancelled"]}, "response" => response}}
  end
end
