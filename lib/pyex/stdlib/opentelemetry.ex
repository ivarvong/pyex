defmodule Pyex.Stdlib.Opentelemetry do
  @moduledoc """
  Native `opentelemetry` module for the Pyex interpreter.

  Implements enough of the real OpenTelemetry tracing API for sandboxed
  programs to emit spans idiomatically:

      from opentelemetry import trace
      from opentelemetry.trace import SpanKind, Status, StatusCode

      tracer = trace.get_tracer("name")
      with tracer.start_as_current_span("parse", kind=SpanKind.INTERNAL) as span:
          span.set_attribute("k", v)
          span.set_status(Status(StatusCode.OK))

  Plus pyex-specific read/flush helpers:

      import opentelemetry
      spans = opentelemetry.get_finished_spans()
      opentelemetry.flush_spans("/otel/spans.jsonl")

  ## Platform / tenant separation

  This is the TENANT (sandboxed Python) telemetry channel. Its spans live in a
  namespace dedicated to guest code — `app_span_seq`, `app_span_stack`,
  `app_span_active`, `app_spans` — that is fully DISJOINT from the
  platform's host-side telemetry (`Ctx.open_runtime_span`/`close_runtime_span`/`runtime_spans` over
  `runtime_span_seq`/`runtime_spans`, exported by `Pyex.Turn`). Sandboxed code must not
  be able to write into, parent onto, or read the platform's trace, so the two
  never share storage, a counter, or a stack. `get_finished_spans/0` and
  `flush_spans/1` only ever see tenant spans.

  ## Determinism and isolation

  All tenant span state lives in `Pyex.Ctx`; there is no process dictionary,
  ETS, or other global state, so concurrent `Pyex.run/2` calls are fully
  isolated. Span and trace ids are drawn from a monotonic per-run counter
  (`app_span_seq`) — never wall-clock time or random — so a given program
  always produces identical spans.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.{Ctx, Env, PyDict}
  alias Pyex.Stdlib.JSON

  @default_flush_path "/otel/spans.jsonl"

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "trace" => {:module, "opentelemetry.trace", trace_attrs()},
      "get_tracer" => {:builtin, &get_tracer/1},
      "get_finished_spans" => {:builtin, &get_finished_spans/1},
      "flush_spans" => {:builtin, &flush_spans/1},
      "render" => {:builtin, &render/1},
      "SpanKind" => span_kind_class(),
      "Status" => {:builtin_kw, &status/2},
      "StatusCode" => status_code_class()
    }
  end

  @spec trace_attrs() :: %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
  defp trace_attrs do
    %{
      "get_tracer" => {:builtin, &get_tracer/1},
      "SpanKind" => span_kind_class(),
      "Status" => {:builtin_kw, &status/2},
      "StatusCode" => status_code_class(),
      "get_finished_spans" => {:builtin, &get_finished_spans/1},
      "flush_spans" => {:builtin, &flush_spans/1}
    }
  end

  # ── enum-like classes & Status ────────────────────────────────────────────

  @spec span_kind_class() :: Pyex.Interpreter.pyvalue()
  defp span_kind_class do
    {:class, "SpanKind", [],
     %{
       "__name__" => "SpanKind",
       "INTERNAL" => "INTERNAL",
       "SERVER" => "SERVER",
       "CLIENT" => "CLIENT",
       "PRODUCER" => "PRODUCER",
       "CONSUMER" => "CONSUMER"
     }}
  end

  @spec status_code_class() :: Pyex.Interpreter.pyvalue()
  defp status_code_class do
    {:class, "StatusCode", [],
     %{
       "__name__" => "StatusCode",
       "OK" => "OK",
       "ERROR" => "ERROR",
       "UNSET" => "UNSET"
     }}
  end

  # Status(status_code, description=None) -> instance carrying status_code.
  @spec status([Pyex.Interpreter.pyvalue()], %{optional(String.t()) => Pyex.Interpreter.pyvalue()}) ::
          Pyex.Interpreter.pyvalue()
  defp status(args, kwargs) do
    {code, desc} =
      case args do
        [code, desc | _] -> {code, desc}
        [code] -> {code, Map.get(kwargs, "description")}
        [] -> {Map.get(kwargs, "status_code", "UNSET"), Map.get(kwargs, "description")}
      end

    {:instance, {:class, "Status", [], %{"__name__" => "Status"}},
     %{"status_code" => normalize_code(code), "description" => desc}}
  end

  # A StatusCode enum value is just its string; tolerate already-normalized
  # codes and unknown values (kept as-is for visibility).
  @spec normalize_code(Pyex.Interpreter.pyvalue()) :: Pyex.Interpreter.pyvalue()
  defp normalize_code(code) when code in ["OK", "ERROR", "UNSET"], do: code
  defp normalize_code(code), do: code

  # ── tracer & span classes ─────────────────────────────────────────────────

  @spec get_tracer([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp get_tracer([name | _]), do: tracer_instance(name)
  defp get_tracer([]), do: tracer_instance("")

  @spec tracer_instance(Pyex.Interpreter.pyvalue()) :: Pyex.Interpreter.pyvalue()
  defp tracer_instance(name) do
    {:instance,
     {:class, "Tracer", [],
      %{
        "__name__" => "Tracer",
        "start_as_current_span" => {:builtin_kw, &start_as_current_span/2},
        "start_span" => {:builtin_kw, &start_as_current_span/2}
      }}, %{"__tracer_name__" => name}}
  end

  # start_as_current_span(self, name, kind=SpanKind.INTERNAL) — returns a
  # context-manager INSTANCE. It does NOT create the span yet; the span is
  # created in __enter__ so an un-entered CM never leaks a span.
  @spec start_as_current_span(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: Pyex.Interpreter.pyvalue()
  defp start_as_current_span([self, name | _], kwargs) do
    kind = Map.get(kwargs, "kind", "INTERNAL")
    span_cm(name, kind, tracer_scope(self))
  end

  defp start_as_current_span([self], kwargs) do
    span_cm("", Map.get(kwargs, "kind", "INTERNAL"), tracer_scope(self))
  end

  # The instrumentation scope of a span is its tracer's name (get_tracer(name)).
  @spec tracer_scope(Pyex.Interpreter.pyvalue()) :: String.t()
  defp tracer_scope({:instance, _cls, attrs}),
    do: to_string(Map.get(attrs, "__tracer_name__", ""))

  defp tracer_scope(_), do: ""

  @spec span_cm(Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue(), String.t()) ::
          Pyex.Interpreter.pyvalue()
  defp span_cm(name, kind, scope) do
    {:instance, {:class, "_OtelSpanCM", [], %{"__name__" => "_OtelSpanCM"}},
     %{"__name__" => name, "__kind__" => kind, "__scope__" => scope}}
  end

  @doc """
  The `Span` class exposed to user code. The handle instance carries only
  `__span_id__`; every method mutates the active span by that id through ctx.
  """
  @spec span_class() :: Pyex.Interpreter.pyvalue()
  def span_class do
    {:class, "Span", [],
     %{
       "__name__" => "Span",
       "set_attribute" => {:builtin, &span_set_attribute/1},
       "set_attributes" => {:builtin, &span_set_attributes/1},
       "set_status" => {:builtin, &span_set_status/1},
       "add_event" => {:builtin_kw, &span_add_event/2},
       "record_exception" => {:builtin, &span_record_exception/1},
       "is_recording" => {:builtin, &span_is_recording/1},
       "end" => {:builtin, &span_end/1}
     }}
  end

  @spec span_handle(non_neg_integer()) :: Pyex.Interpreter.pyvalue()
  def span_handle(id), do: {:instance, span_class(), %{"__span_id__" => id}}

  # ── span lifecycle (called from Dunder for __enter__/__exit__) ────────────

  @doc """
  Opens a new span: allocates the next id, links it to the current stack head
  as parent, inherits the parent's trace id (or starts a new trace), pushes it
  onto the active stack, and stores it in `app_span_active`. Returns `{id, ctx}`.
  """
  @spec enter(Ctx.t(), Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          {non_neg_integer(), Ctx.t()}
  def enter(%Ctx{} = ctx, name, kind, scope \\ "") do
    seq = ctx.app_span_seq + 1
    id = seq
    parent_id = List.first(ctx.app_span_stack)
    trace_id = trace_id_for(ctx, parent_id, id)

    span = %{
      # coerce to a string at the source: OTel span names are strings, and a
      # non-string name (e.g. start_as_current_span(123)) must never reach a
      # consumer that assumes a binary (SpanTree.render did, crashing the host).
      name: to_string_key(name),
      id: id,
      parent_id: parent_id,
      trace_id: trace_id,
      kind: kind,
      scope: scope,
      attributes: %{},
      attr_order: [],
      status: nil,
      events: [],
      start_seq: id,
      end_seq: nil
    }

    ctx = %{
      ctx
      | app_span_seq: seq,
        app_span_stack: [id | ctx.app_span_stack],
        app_span_active: Map.put(ctx.app_span_active, id, span)
    }

    # Count the span against the memory budget so guest instrumentation can't
    # become an unbounded, uncounted memory sink.
    {id, Ctx.charge_span_memory(ctx, to_string(name), %{})}
  end

  # All spans in one trace share the root span's id as trace_id. Derive it
  # from the parent's trace_id so any depth inherits the same root id; a span
  # with no parent starts a fresh trace rooted at its own id.
  @spec trace_id_for(Ctx.t(), non_neg_integer() | nil, non_neg_integer()) :: non_neg_integer()
  defp trace_id_for(_ctx, nil, id), do: id

  defp trace_id_for(ctx, parent_id, id) do
    case Map.get(ctx.app_span_active, parent_id) do
      %{trace_id: tid} -> tid
      _ -> id
    end
  end

  @doc """
  Closes the span identified by `id` (from a context manager's `__exit__`):
  finalizes it (setting status/end_seq, recording an exception event on the
  error path), moves it from `app_span_active` to the end of `app_spans`, and
  pops it off the active stack. Safe (no-op finalize) if the span was already
  ended explicitly via `.end()`.
  """
  @spec exit(
          Ctx.t(),
          non_neg_integer() | nil,
          Pyex.Interpreter.pyvalue(),
          Pyex.Interpreter.pyvalue()
        ) ::
          Ctx.t()
  def exit(%Ctx{} = ctx, nil, _exc_type, _exc_val), do: ctx

  def exit(%Ctx{} = ctx, id, exc_type, exc_val) do
    ctx
    |> finalize(id, exc_type, exc_val)
    |> pop_stack(id)
  end

  # Move a span from active to finished. Idempotent: a span already finalized
  # (e.g. by an explicit .end()) is left untouched.
  @spec finalize(
          Ctx.t(),
          non_neg_integer(),
          Pyex.Interpreter.pyvalue(),
          Pyex.Interpreter.pyvalue()
        ) ::
          Ctx.t()
  defp finalize(ctx, id, exc_type, exc_val) do
    case Map.pop(ctx.app_span_active, id) do
      {nil, _active} ->
        ctx

      {span, active} ->
        seq = ctx.app_span_seq + 1

        {status, span} =
          if exc_type != nil do
            {"ERROR", add_exception_event(span, exc_type, exc_val)}
          else
            {span.status || "UNSET", span}
          end

        span = %{span | status: status, end_seq: seq}

        # Prepend (newest-first); finished_in_order/1 reverses for completion
        # order. This is the tenant's OWN app_spans — never the
        # platform's runtime_spans — so guest spans cannot leak into the host
        # trace exported by Pyex.Turn.
        %{
          ctx
          | app_span_seq: seq,
            app_span_active: active,
            app_spans: [span | ctx.app_spans]
        }
    end
  end

  # Finished spans in completion order (oldest first). app_spans is stored
  # newest-first; reverse to read. Kept local so the module does not depend on
  # Ctx.spans/1.
  @spec finished_in_order(Ctx.t()) :: [map()]
  defp finished_in_order(ctx), do: Enum.reverse(ctx.app_spans)

  @spec pop_stack(Ctx.t(), non_neg_integer()) :: Ctx.t()
  defp pop_stack(ctx, id) do
    new_stack =
      case ctx.app_span_stack do
        [^id | rest] -> rest
        other -> List.delete(other, id)
      end

    %{ctx | app_span_stack: new_stack}
  end

  @spec add_exception_event(map(), Pyex.Interpreter.pyvalue(), Pyex.Interpreter.pyvalue()) ::
          map()
  defp add_exception_event(span, exc_type, exc_val) do
    event = %{
      name: "exception",
      attributes: %{
        "exception.type" => exception_type_name(exc_type),
        "exception.message" => exception_message(exc_val)
      }
    }

    %{span | events: span.events ++ [event]}
  end

  @spec exception_type_name(Pyex.Interpreter.pyvalue()) :: String.t()
  defp exception_type_name({:class, name, _, _}), do: name
  defp exception_type_name({:exception_class, name}), do: name
  defp exception_type_name(name) when is_binary(name), do: name
  defp exception_type_name(_), do: "Exception"

  @spec exception_message(Pyex.Interpreter.pyvalue()) :: String.t()
  defp exception_message({:instance, _, attrs}) do
    case Map.get(attrs, "args") do
      {:tuple, [msg | _]} when is_binary(msg) -> msg
      _ -> Map.get(attrs, "__message__", "") |> to_string()
    end
  end

  defp exception_message(msg) when is_binary(msg), do: msg
  defp exception_message(nil), do: ""
  defp exception_message(other), do: inspect(other)

  # ── span methods (run as {:ctx_call, _} so they can mutate ctx) ───────────

  @spec span_set_attribute([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp span_set_attribute([self, key, value | _]) do
    {:ctx_call,
     fn env, ctx ->
       {nil, env, put_attribute(ctx, span_id(self), to_string_key(key), value)}
     end}
  end

  defp span_set_attribute(_), do: {:exception, "TypeError: set_attribute(key, value)"}

  @spec span_set_attributes([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp span_set_attributes([self, mapping | _]) do
    pairs =
      case mapping do
        {:py_dict, _, _} -> PyDict.items(mapping)
        m when is_map(m) and not is_struct(m) -> Map.to_list(m)
        _ -> []
      end

    {:ctx_call,
     fn env, ctx ->
       id = span_id(self)

       ctx =
         Enum.reduce(pairs, ctx, fn {k, v}, acc -> put_attribute(acc, id, to_string_key(k), v) end)

       {nil, env, ctx}
     end}
  end

  defp span_set_attributes(_), do: {:exception, "TypeError: set_attributes(mapping)"}

  @spec span_set_status([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp span_set_status([self, status | _]) do
    code = extract_status_code(status)

    {:ctx_call,
     fn env, ctx ->
       {nil, env, update_active(ctx, span_id(self), &%{&1 | status: code})}
     end}
  end

  defp span_set_status(_), do: {:exception, "TypeError: set_status(status)"}

  @spec extract_status_code(Pyex.Interpreter.pyvalue()) :: Pyex.Interpreter.pyvalue()
  defp extract_status_code({:instance, _, attrs}), do: Map.get(attrs, "status_code", "UNSET")
  defp extract_status_code(code) when is_binary(code), do: normalize_code(code)
  defp extract_status_code(_), do: "UNSET"

  @spec span_add_event(
          [Pyex.Interpreter.pyvalue()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: Pyex.Interpreter.pyvalue()
  defp span_add_event([self, name | rest], kwargs) do
    raw_attrs =
      case rest do
        [attrs | _] -> attrs
        [] -> Map.get(kwargs, "attributes")
      end

    event = %{name: to_string_key(name), attributes: event_attrs(raw_attrs)}

    {:ctx_call,
     fn env, ctx ->
       {nil, env, update_active(ctx, span_id(self), &%{&1 | events: &1.events ++ [event]})}
     end}
  end

  defp span_add_event(_, _), do: {:exception, "TypeError: add_event(name, attributes=None)"}

  @spec event_attrs(Pyex.Interpreter.pyvalue()) :: %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }
  defp event_attrs({:py_dict, _, _} = d) do
    d |> PyDict.items() |> Map.new(fn {k, v} -> {to_string_key(k), v} end)
  end

  defp event_attrs(m) when is_map(m) and not is_struct(m) do
    Map.new(m, fn {k, v} -> {to_string_key(k), v} end)
  end

  defp event_attrs(_), do: %{}

  @spec span_record_exception([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp span_record_exception([self, exc | _]) do
    {:ctx_call,
     fn env, ctx ->
       ctx =
         update_active(ctx, span_id(self), fn span ->
           add_exception_event(span, exc_type_of(exc), exc)
         end)

       {nil, env, ctx}
     end}
  end

  defp span_record_exception(_), do: {:exception, "TypeError: record_exception(exception)"}

  @spec exc_type_of(Pyex.Interpreter.pyvalue()) :: Pyex.Interpreter.pyvalue()
  defp exc_type_of({:instance, {:class, name, _, _}, _}), do: name
  defp exc_type_of(_), do: "Exception"

  @spec span_is_recording([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp span_is_recording([self | _]) do
    {:ctx_call, fn env, ctx -> {Map.has_key?(ctx.app_span_active, span_id(self)), env, ctx} end}
  end

  @spec span_end([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp span_end([self | _]) do
    {:ctx_call, fn env, ctx -> {nil, env, finalize(ctx, span_id(self), nil, nil)} end}
  end

  # ── ctx mutation helpers ──────────────────────────────────────────────────

  @spec put_attribute(Ctx.t(), non_neg_integer() | nil, String.t(), Pyex.Interpreter.pyvalue()) ::
          Ctx.t()
  defp put_attribute(ctx, id, key, value) do
    update_active(ctx, id, fn span ->
      attr_order =
        if Map.has_key?(span.attributes, key),
          do: span.attr_order,
          else: span.attr_order ++ [key]

      %{span | attributes: Map.put(span.attributes, key, value), attr_order: attr_order}
    end)
  end

  # Apply `fun` to the active span `id`. A missing id (already exited, or never
  # entered) is a safe no-op — never crash.
  @spec update_active(Ctx.t(), non_neg_integer() | nil, (map() -> map())) :: Ctx.t()
  defp update_active(ctx, id, fun) do
    case Map.fetch(ctx.app_span_active, id) do
      {:ok, span} -> %{ctx | app_span_active: Map.put(ctx.app_span_active, id, fun.(span))}
      :error -> ctx
    end
  end

  @spec span_id(Pyex.Interpreter.pyvalue()) :: non_neg_integer() | nil
  defp span_id({:instance, _, attrs}), do: Map.get(attrs, "__span_id__")
  defp span_id(_), do: nil

  @spec to_string_key(Pyex.Interpreter.pyvalue()) :: String.t()
  defp to_string_key(k) when is_binary(k), do: k
  defp to_string_key(k), do: to_string(k)

  # ── read / flush helpers ──────────────────────────────────────────────────

  @spec get_finished_spans([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp get_finished_spans(_args) do
    {:ctx_call,
     fn env, ctx ->
       items = Enum.map(finished_in_order(ctx), &serialize_span/1)
       {{:py_list, Enum.reverse(items), length(items)}, env, ctx}
     end}
  end

  # opentelemetry.render() -> an ASCII trace of the program's OWN spans.
  # By design this can only see the guest's app_spans, never the platform's
  # runtime ledger — rendering the latter from inside the sandbox would be a
  # read channel into the unforgeable trace (see Pyex.SpanTree / Pyex.Turn).
  @spec render([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp render(_args) do
    {:ctx_call,
     fn env, ctx ->
       {Pyex.SpanTree.render(finished_in_order(ctx), title: "app"), env, ctx}
     end}
  end

  @spec flush_spans([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp flush_spans(args) do
    path =
      case args do
        [p | _] when is_binary(p) -> p
        _ -> @default_flush_path
      end

    {:ctx_call,
     fn env, ctx ->
       case ctx.filesystem do
         nil ->
           {{:exception, "OSError: no filesystem configured"}, env, ctx}

         _fs ->
           write_jsonl(path, ctx, env)
       end
     end}
  end

  @spec write_jsonl(String.t(), Ctx.t(), Env.t()) ::
          {Pyex.Interpreter.pyvalue(), Env.t(), Ctx.t()}
  defp write_jsonl(path, ctx, env) do
    case encode_lines(finished_in_order(ctx)) do
      {:error, msg} ->
        {{:exception, msg}, env, ctx}

      {:ok, content} ->
        fs = ensure_parent_dir(ctx.filesystem, ctx.cwd, path)

        case Pyex.FS.write_file(fs, ctx.cwd, path, content, :write) do
          {:ok, fs} -> {nil, env, %{ctx | filesystem: fs}}
          {:error, msg} -> {{:exception, msg}, env, ctx}
        end
    end
  end

  @spec encode_lines([map()]) :: {:ok, String.t()} | {:error, String.t()}
  defp encode_lines([]), do: {:ok, ""}

  defp encode_lines(spans) do
    Enum.reduce_while(spans, {:ok, []}, fn span, {:ok, acc} ->
      case JSON.dumps(serialize_span(span)) do
        {:exception, msg} -> {:halt, {:error, msg}}
        line when is_binary(line) -> {:cont, {:ok, [line | acc]}}
      end
    end)
    |> case do
      {:ok, rev_lines} -> {:ok, Enum.join(Enum.reverse(rev_lines), "\n") <> "\n"}
      {:error, _} = err -> err
    end
  end

  @spec ensure_parent_dir(term(), String.t(), String.t()) :: term()
  defp ensure_parent_dir(fs, cwd, path) do
    dir = vfs_dirname(path)

    if dir in ["", "/", "."] do
      fs
    else
      case Pyex.FS.mkdir_p(fs, cwd, dir) do
        {:ok, fs} -> fs
        {:error, _} -> fs
      end
    end
  end

  @spec vfs_dirname(String.t()) :: String.t()
  defp vfs_dirname(path) do
    case String.split(path, "/") do
      [_single] -> ""
      parts -> parts |> Enum.drop(-1) |> Enum.join("/")
    end
  end

  # ── serialization to pyvalues (matches json.ex's value shapes) ────────────

  @spec serialize_span(map()) :: Pyex.Interpreter.pyvalue()
  # Tenant spans are uniform (this module is the only writer of
  # app_spans), but every non-core key is still Map.get-with-default
  # as belt-and-suspenders so serialization can never crash on a malformed or
  # future span shape.
  defp serialize_span(span) do
    PyDict.from_pairs([
      {"name", Map.get(span, :name)},
      {"span_id", Map.get(span, :id)},
      {"parent_id", Map.get(span, :parent_id)},
      {"trace_id", Map.get(span, :trace_id, Map.get(span, :id))},
      {"kind", Map.get(span, :kind)},
      {"attributes", attrs_to_pydict(span)},
      {"status", Map.get(span, :status)},
      {"events", events_to_pylist(Map.get(span, :events, []))},
      {"start_seq", Map.get(span, :start_seq)},
      {"end_seq", Map.get(span, :end_seq)}
    ])
  end

  @spec attrs_to_pydict(map()) :: Pyex.Interpreter.pyvalue()
  defp attrs_to_pydict(span) do
    attributes = Map.get(span, :attributes, %{})

    order =
      Map.get(span, :attr_order, []) ++
        (Map.keys(attributes) -- Map.get(span, :attr_order, []))

    PyDict.from_pairs(Enum.map(order, fn k -> {k, Map.fetch!(attributes, k)} end))
  end

  @spec events_to_pylist([map()]) :: Pyex.Interpreter.pyvalue()
  defp events_to_pylist(events) do
    items =
      Enum.map(events, fn ev ->
        PyDict.from_pairs([
          {"name", ev.name},
          {"attributes", PyDict.from_pairs(Map.to_list(ev.attributes))}
        ])
      end)

    {:py_list, Enum.reverse(items), length(items)}
  end
end
