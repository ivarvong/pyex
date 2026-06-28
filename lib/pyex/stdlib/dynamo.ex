defmodule Pyex.Stdlib.Dynamo do
  @moduledoc """
  **Experimental.** A DynamoDB-style single-table store for sandboxed Python,
  layered over the host-provided `Pyex.Storage` capability.

      import dynamo

      t = dynamo.Table("app")                       # bound to ctx.storage
      t.put_item({"pk": "USER#1", "sk": "PROFILE", "name": "Ada"})
      t.put_item({"pk": "USER#1", "sk": "ORDER#2024-01", "total": 42})

      t.get_item("USER#1", "PROFILE")               # -> {...} or None
      t.query("USER#1")                             # whole partition, sorted by sk
      t.query("USER#1", begins_with="ORDER#")       # range within the partition
      t.query("USER#1", gte="ORDER#2024", limit=10, reverse=True)
      t.delete_item("USER#1", "ORDER#2024-01")
      t.put_item(item, overwrite=False)             # create-only (conditional)

  ## Why single-table

  An agent is handed a *schemaless* table and decides its own data model — the
  classic DynamoDB single-table design, where one table holds every entity and
  relationship, distinguished by how the partition key (`pk`) and sort key
  (`sk`) are composed (`USER#1` / `ORDER#…`, adjacency lists, etc.). There is no
  migration step: the model is in the keys the program chooses.

  ## How it maps onto a KV backend

  DynamoDB's primitive is "a partition, sorted by sort key, range-scannable".
  That is exactly a prefix scan over lexicographically-sorted composite keys.
  Each item is stored at `table␟pk␟sk` (`␟` = ASCII unit separator, 0x1F —
  sorts below any printable byte and effectively never appears in real keys), so
  `query(pk)` is one `Pyex.Storage.scan_prefix("table␟pk␟")` that returns the
  partition already ordered by sort key. The host therefore backs this with the
  same plain KV it backs `store` with — Postgres, SQLite, a CSV file, the
  in-memory reference — and the table semantics live here. Sort keys order
  *lexicographically*, so model numbers/dates as zero-padded or ISO strings.

  ## Capability + multitenancy

  Identical to `store`: the table uses `ctx.storage`, granted per run. No
  backend → every op raises `StorageError` (denied by default). Tenancy is a
  backend boundary (a distinct store per tenant); attenuate within a tenant with
  `Pyex.Storage.View` (e.g. a read-only handle). Every operation also opens an
  unforgeable runtime span (OTel `db.*` semconv, `db.system.name = pyex.dynamo`)
  so the host can audit exactly what the agent's data layer did.

  > #### Experimental {: .warning}
  > This API is new and may change without a major-version bump.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.{Ctx, Env, PyDict, Storage}
  alias Pyex.Interpreter.Helpers
  alias Pyex.Stdlib.JSON

  # Component separator for composite keys. 0x1F (unit separator) sorts below
  # every printable character — so a partition prefix never collides with a
  # longer partition name — and does not occur in realistic text/JSON keys.
  @sep "\x1f"

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "__name__" => "dynamo",
      "Table" => {:builtin_kw, &table/2}
    }
  end

  # dynamo.Table(name="default", pk="pk", sk="sk") -> a table handle bound to
  # ctx.storage. The handle is a pure value carrying only its config.
  @spec table([Pyex.Interpreter.pyvalue()], %{optional(String.t()) => Pyex.Interpreter.pyvalue()}) ::
          Pyex.Interpreter.pyvalue()
  defp table(args, kwargs) do
    name =
      case args do
        [n | _] -> n
        [] -> Map.get(kwargs, "name", "default")
      end

    {:instance, table_class(),
     %{
       "__table__" => to_str(name),
       "__pk__" => to_str(Map.get(kwargs, "pk", "pk")),
       "__sk__" => to_str(Map.get(kwargs, "sk", "sk"))
     }}
  end

  @spec table_class() :: Pyex.Interpreter.pyvalue()
  defp table_class do
    {:class, "Table", [],
     %{
       "__name__" => "Table",
       "put_item" => {:builtin_kw, &put_item/2},
       "get_item" => {:builtin, &get_item/1},
       "query" => {:builtin_kw, &query/2},
       "delete_item" => {:builtin, &delete_item/1},
       "update_item" => {:builtin, &update_item/1}
     }}
  end

  # ── put_item(item, overwrite=True) ────────────────────────────────────────

  @spec put_item([Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) ::
          Pyex.Interpreter.pyvalue()
  defp put_item([self, item | _], kwargs) do
    overwrite = Map.get(kwargs, "overwrite", true) != false

    with_backend(fn backend, env, ctx ->
      cfg = cfg(self)

      with {:dict, dict} <- as_dict(ctx, item),
           {:ok, pk} <- key_field(dict, cfg.pk),
           {:ok, sk} <- key_field(dict, cfg.sk) do
        key = compose(cfg.table, pk, sk)
        {ctx, span} = open_span(ctx, "set", cfg.table)

        case JSON.dumps(item) do
          {:exception, _} = exc ->
            {exc, env, close_error(ctx, span, "item not JSON-serializable")}

          json when is_binary(json) ->
            do_put(backend, key, json, overwrite, item, env, ctx, span)
        end
      else
        {:error, msg} -> {{:exception, msg}, env, ctx}
      end
    end)
  end

  defp put_item(_, _),
    do: {:exception, "TypeError: put_item(item, overwrite=True) expects an item dict"}

  defp do_put(backend, key, json, overwrite, item, env, ctx, span) do
    exists? = match?({:ok, _}, Storage.get(backend, key))

    cond do
      not overwrite and exists? ->
        {storage_error("ConditionalCheckFailed: item already exists"), env,
         close_error(ctx, span, "ConditionalCheckFailed")}

      true ->
        case Storage.put(backend, key, json) do
          {:ok, backend} ->
            ctx =
              Ctx.close_runtime_span(%{ctx | storage: backend}, span, %{
                "bytes" => byte_size(json)
              })

            {item, env, ctx}

          {:error, reason} ->
            {storage_error(reason), env, close_error(ctx, span, reason)}
        end
    end
  end

  # ── get_item(pk, sk) -> dict | None ───────────────────────────────────────

  @spec get_item([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp get_item([self, pk, sk | _]) do
    with_backend(fn backend, env, ctx ->
      cfg = cfg(self)
      key = compose(cfg.table, to_str(pk), to_str(sk))
      {ctx, span} = open_span(ctx, "get", cfg.table)

      case Storage.get(backend, key) do
        {:ok, json} ->
          {JSON.decode(json), env, Ctx.close_runtime_span(ctx, span, %{"hit" => true})}

        :miss ->
          {nil, env, Ctx.close_runtime_span(ctx, span, %{"hit" => false})}

        {:error, reason} ->
          {storage_error(reason), env, close_error(ctx, span, reason)}
      end
    end)
  end

  defp get_item(_),
    do: {:exception, "TypeError: get_item(pk, sk) expects a partition and sort key"}

  # ── query(pk, begins_with=, eq=, lt=, lte=, gt=, gte=, limit=, reverse=) ───

  @spec query([Pyex.Interpreter.pyvalue()], %{optional(String.t()) => Pyex.Interpreter.pyvalue()}) ::
          Pyex.Interpreter.pyvalue()
  defp query([self, pk | _], kwargs) do
    with_backend(fn backend, env, ctx ->
      cfg = cfg(self)
      pk_s = to_str(pk)
      partition = compose_prefix(cfg.table, pk_s)
      # begins_with narrows the scan itself; other comparators scan the whole
      # partition (already sorted) and filter the sort key.
      {scan_key, pred} = sk_predicate(partition, kwargs)
      {ctx, span} = open_span(ctx, "query", cfg.table)

      case Storage.scan_prefix(backend, scan_key) do
        {:ok, pairs} ->
          items =
            pairs
            |> Enum.filter(fn {k, _json} -> pred.(sort_key_of(k)) end)
            |> maybe_reverse(truthy(Map.get(kwargs, "reverse", false)))
            |> maybe_limit(Map.get(kwargs, "limit"))
            |> Enum.map(fn {_k, json} -> JSON.decode(json) end)

          ctx = Ctx.close_runtime_span(ctx, span, %{"count" => length(items)})
          {{:py_list, Enum.reverse(items), length(items)}, env, ctx}

        {:error, reason} ->
          {storage_error(reason), env, close_error(ctx, span, reason)}
      end
    end)
  end

  defp query(_, _), do: {:exception, "TypeError: query(pk, ...) expects a partition key"}

  # ── delete_item(pk, sk) -> bool ───────────────────────────────────────────

  @spec delete_item([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp delete_item([self, pk, sk | _]) do
    with_backend(fn backend, env, ctx ->
      cfg = cfg(self)
      key = compose(cfg.table, to_str(pk), to_str(sk))
      {ctx, span} = open_span(ctx, "delete", cfg.table)
      existed = match?({:ok, _}, Storage.get(backend, key))

      case Storage.delete(backend, key) do
        {:ok, backend} ->
          ctx = Ctx.close_runtime_span(%{ctx | storage: backend}, span, %{"existed" => existed})
          {existed, env, ctx}

        {:error, reason} ->
          {storage_error(reason), env, close_error(ctx, span, reason)}
      end
    end)
  end

  defp delete_item(_),
    do: {:exception, "TypeError: delete_item(pk, sk) expects a partition and sort key"}

  # ── update_item(pk, sk, updates) -> the merged item ───────────────────────

  @spec update_item([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp update_item([self, pk, sk, updates | _]) do
    with_backend(fn backend, env, ctx ->
      cfg = cfg(self)
      pk_s = to_str(pk)
      sk_s = to_str(sk)
      key = compose(cfg.table, pk_s, sk_s)

      with {:dict, patch} <- as_dict(ctx, updates) do
        {ctx, span} = open_span(ctx, "set", cfg.table)

        base =
          case Storage.get(backend, key) do
            {:ok, json} -> as_plain_dict(ctx, JSON.decode(json))
            _ -> PyDict.new()
          end

        merged =
          base
          |> PyDict.merge(patch)
          |> PyDict.put(cfg.pk, pk_s)
          |> PyDict.put(cfg.sk, sk_s)

        case JSON.dumps(merged) do
          {:exception, _} = exc ->
            {exc, env, close_error(ctx, span, "item not JSON-serializable")}

          json when is_binary(json) ->
            case Storage.put(backend, key, json) do
              {:ok, backend} ->
                ctx =
                  Ctx.close_runtime_span(%{ctx | storage: backend}, span, %{
                    "bytes" => byte_size(json)
                  })

                {merged, env, ctx}

              {:error, reason} ->
                {storage_error(reason), env, close_error(ctx, span, reason)}
            end
        end
      else
        {:error, msg} -> {{:exception, msg}, env, ctx}
      end
    end)
  end

  defp update_item(_),
    do: {:exception, "TypeError: update_item(pk, sk, updates) expects keys and an updates dict"}

  # ── key composition ───────────────────────────────────────────────────────

  @spec compose(String.t(), String.t(), String.t()) :: String.t()
  defp compose(table, pk, sk), do: table <> @sep <> pk <> @sep <> sk

  @spec compose_prefix(String.t(), String.t()) :: String.t()
  defp compose_prefix(table, pk), do: table <> @sep <> pk <> @sep

  # The sort key is everything after `table␟pk␟` — i.e. the third component.
  @spec sort_key_of(String.t()) :: String.t()
  defp sort_key_of(key) do
    case String.split(key, @sep, parts: 3) do
      [_table, _pk, sk] -> sk
      _ -> ""
    end
  end

  # Build {scan_prefix, sort_key_predicate} from the query kwargs. `begins_with`
  # tightens the scanned prefix; `eq`/`gt`/`gte`/`lt`/`lte`/`between` filter the
  # (already sorted) partition. They compose (AND) — `begins_with="ORDER#",
  # gte="ORDER#2024"` scans the ORDER# range and keeps the dated tail.
  @spec sk_predicate(String.t(), %{optional(String.t()) => Pyex.Interpreter.pyvalue()}) ::
          {String.t(), (String.t() -> boolean())}
  defp sk_predicate(partition, kwargs) do
    scan_key =
      case kwargs["begins_with"] do
        nil -> partition
        bw -> partition <> to_str(bw)
      end

    pred =
      case kwargs["eq"] do
        nil ->
          comparator_predicate(kwargs)

        eq ->
          v = to_str(eq)
          &(&1 == v)
      end

    {scan_key, pred}
  end

  # AND of whichever of gt/gte/lt/lte/between are present (default: match all).
  @spec comparator_predicate(%{optional(String.t()) => Pyex.Interpreter.pyvalue()}) ::
          (String.t() -> boolean())
  defp comparator_predicate(kwargs) do
    checks =
      [
        cmp(kwargs["gt"], fn sk, v -> sk > v end),
        cmp(kwargs["gte"], fn sk, v -> sk >= v end),
        cmp(kwargs["lt"], fn sk, v -> sk < v end),
        cmp(kwargs["lte"], fn sk, v -> sk <= v end),
        between_check(kwargs["between"])
      ]
      |> Enum.reject(&is_nil/1)

    fn sk -> Enum.all?(checks, & &1.(sk)) end
  end

  @spec cmp(Pyex.Interpreter.pyvalue() | nil, (String.t(), String.t() -> boolean())) ::
          (String.t() -> boolean()) | nil
  defp cmp(nil, _f), do: nil

  defp cmp(v, f) do
    vs = to_str(v)
    fn sk -> f.(sk, vs) end
  end

  defp between_check(nil), do: nil

  defp between_check(pair) do
    case pair do
      {:py_list, rev, 2} ->
        [lo, hi] = Enum.reverse(rev)
        lo_s = to_str(lo)
        hi_s = to_str(hi)
        fn sk -> sk >= lo_s and sk <= hi_s end

      {:tuple, [lo, hi | _]} ->
        lo_s = to_str(lo)
        hi_s = to_str(hi)
        fn sk -> sk >= lo_s and sk <= hi_s end

      _ ->
        nil
    end
  end

  @spec maybe_reverse([term()], boolean()) :: [term()]
  defp maybe_reverse(pairs, true), do: Enum.reverse(pairs)
  defp maybe_reverse(pairs, _), do: pairs

  @spec maybe_limit([term()], Pyex.Interpreter.pyvalue()) :: [term()]
  defp maybe_limit(pairs, n) when is_integer(n) and n >= 0, do: Enum.take(pairs, n)
  defp maybe_limit(pairs, _), do: pairs

  # ── item field helpers ────────────────────────────────────────────────────

  # Deref an item argument to a {:py_dict, ...}; anything else is a TypeError.
  @spec as_dict(Ctx.t(), Pyex.Interpreter.pyvalue()) ::
          {:dict, Pyex.Interpreter.pyvalue()} | {:error, String.t()}
  defp as_dict(ctx, value) do
    case Ctx.deref(ctx, value) do
      {:py_dict, _, _} = d -> {:dict, d}
      _ -> {:error, "TypeError: item must be a dict"}
    end
  end

  defp as_plain_dict(ctx, value) do
    case Ctx.deref(ctx, value) do
      {:py_dict, _, _} = d -> d
      _ -> PyDict.new()
    end
  end

  # Read a required key attribute from the item, coerced to a string.
  @spec key_field(Pyex.Interpreter.pyvalue(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp key_field(dict, field) do
    case PyDict.fetch(dict, field) do
      {:ok, v} -> {:ok, to_str(v)}
      :error -> {:error, "StorageError: item is missing key attribute '#{field}'"}
    end
  end

  @spec cfg(Pyex.Interpreter.pyvalue()) :: %{table: String.t(), pk: String.t(), sk: String.t()}
  defp cfg({:instance, _cls, attrs}) do
    %{
      table: to_str(Map.get(attrs, "__table__", "default")),
      pk: to_str(Map.get(attrs, "__pk__", "pk")),
      sk: to_str(Map.get(attrs, "__sk__", "sk"))
    }
  end

  defp cfg(_), do: %{table: "default", pk: "pk", sk: "sk"}

  # Total, never-raising coercion to a string — keys/values flow into composite
  # keys and the host span renderer, so a non-string must never crash the host
  # (the lesson from the OpenTelemetry hardening pass).
  @spec to_str(Pyex.Interpreter.pyvalue()) :: String.t()
  defp to_str(s) when is_binary(s), do: s

  defp to_str(other) do
    Helpers.py_str(other)
  rescue
    _ -> inspect(other)
  catch
    _, _ -> inspect(other)
  end

  @spec truthy(Pyex.Interpreter.pyvalue()) :: boolean()
  defp truthy(false), do: false
  defp truthy(nil), do: false
  defp truthy(_), do: true

  # ── capability gate + telemetry (mirrors Pyex.Stdlib.Store) ───────────────

  @spec open_span(Ctx.t(), String.t(), String.t()) :: {Ctx.t(), non_neg_integer()}
  defp open_span(ctx, operation, table) do
    Ctx.open_runtime_span(ctx, "db.#{operation}", %{
      "db.system.name" => "pyex.dynamo",
      "db.operation.name" => operation,
      "db.collection.name" => table
    })
  end

  @spec storage_error(String.t()) :: Pyex.Interpreter.pyvalue()
  defp storage_error(reason), do: {:exception, "StorageError: #{reason}"}

  @spec close_error(Ctx.t(), non_neg_integer(), String.t()) :: Ctx.t()
  defp close_error(ctx, span, reason),
    do: Ctx.close_runtime_span(ctx, span, %{"error.type" => reason})

  @spec with_backend((term(), Env.t(), Ctx.t() ->
                        {Pyex.Interpreter.pyvalue(), Env.t(), Ctx.t()})) ::
          Pyex.Interpreter.pyvalue()
  defp with_backend(fun) do
    {:io_call,
     fn env, ctx ->
       case ctx.storage do
         nil ->
           {{:exception,
             "StorageError: no storage backend configured. " <>
               "Pass `storage:` to Pyex.run to enable the dynamo module."}, env, ctx}

         backend ->
           fun.(backend, env, ctx)
       end
     end}
  end
end
