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
      {"scan", {:builtin_kw, &scan(name, &1, &2)}}
    ])
  end

  # ── Table operations ──────────────────────────────────────────────────────

  @spec put_item(String.t(), [pyvalue()], %{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp put_item(table, _args, kwargs) do
    item = Map.get(kwargs, "Item")

    with_table(table, fn backend, schema, env, ctx ->
      with {:py_dict, _, _} <- item,
           {:ok, marshalled} <- marshal(item),
           {:ok, sk} <- storage_key(table, schema, item) do
        case Pyex.Storage.put(backend, sk, JSON.dumps(marshalled)) do
          {:ok, backend} -> {empty_response(), env, %{ctx | storage: backend}}
          {:error, reason} -> {storage_error(reason), env, ctx}
        end
      else
        {:error, msg} -> {{:exception, msg}, env, ctx}
        _ -> {{:exception, "ParamValidationError: put_item requires Item to be a dict"}, env, ctx}
      end
    end)
  end

  @spec get_item(String.t(), [pyvalue()], %{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp get_item(table, _args, kwargs) do
    key = Map.get(kwargs, "Key")

    with_table(table, fn backend, schema, env, ctx ->
      case storage_key(table, schema, key) do
        {:ok, sk} ->
          case Pyex.Storage.get(backend, sk) do
            {:ok, json} ->
              {PyDict.from_pairs([{"Item", unmarshal(JSON.decode(json))}]), env, ctx}

            :miss ->
              {empty_response(), env, ctx}

            {:error, reason} ->
              {storage_error(reason), env, ctx}
          end

        {:error, msg} ->
          {{:exception, msg}, env, ctx}
      end
    end)
  end

  @spec delete_item(String.t(), [pyvalue()], %{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp delete_item(table, _args, kwargs) do
    key = Map.get(kwargs, "Key")

    with_table(table, fn backend, schema, env, ctx ->
      case storage_key(table, schema, key) do
        {:ok, sk} ->
          case Pyex.Storage.delete(backend, sk) do
            {:ok, backend} -> {empty_response(), env, %{ctx | storage: backend}}
            {:error, reason} -> {storage_error(reason), env, ctx}
          end

        {:error, msg} ->
          {{:exception, msg}, env, ctx}
      end
    end)
  end

  @spec scan(String.t(), [pyvalue()], %{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp scan(table, _args, _kwargs) do
    with_table(table, fn backend, _schema, env, ctx ->
      case Pyex.Storage.scan_prefix(backend, item_prefix(table)) do
        {:ok, pairs} ->
          items = Enum.map(pairs, fn {_k, json} -> unmarshal(JSON.decode(json)) end)

          {PyDict.from_pairs([
             {"Items", py_list(items)},
             {"Count", length(items)},
             {"ScannedCount", length(items)}
           ]), env, ctx}

        {:error, reason} ->
          {storage_error(reason), env, ctx}
      end
    end)
  end

  # update_item with the common SET / ADD update-expression forms is involved;
  # the read-modify-write via get_item + put_item covers the same ground, so
  # this raises a clear, honest error rather than silently mis-applying.
  @spec update_item(String.t(), [pyvalue()], %{optional(String.t()) => pyvalue()}) :: pyvalue()
  defp update_item(_table, _args, _kwargs) do
    {:exception,
     "NotImplementedError: update_item is not supported; read with get_item, " <>
       "modify, and write back with put_item"}
  end

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
end
