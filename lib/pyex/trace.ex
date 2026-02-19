defmodule Pyex.Trace do
  @moduledoc """
  Lightweight tracing for Pyex executions via `:telemetry`.

  Attaches to `[:pyex, :run, :*]`, `[:pyex, :request, :*]`, and
  `[:pyex, :query, :*]` events and collects them into an ETS table.
  Call `flush/1` to print a summary tree and detach all handlers.

  This is a development/debugging tool. Typical usage:

      handle = Pyex.Trace.attach()
      Pyex.run!(code, ctx)
      Pyex.Trace.flush(handle)

  Or with the zero-argument convenience form (creates and stores
  the handle automatically):

      Pyex.Trace.attach()
      Pyex.run!(code, ctx)
      Pyex.Trace.flush()
  """

  @type handle :: :ets.table()

  @events [
    [:pyex, :run, :start],
    [:pyex, :run, :stop],
    [:pyex, :run, :exception],
    [:pyex, :request, :start],
    [:pyex, :request, :stop],
    [:pyex, :query, :start],
    [:pyex, :query, :stop]
  ]

  @doc """
  Attaches telemetry handlers and returns a trace handle.

  The handle is an ETS table reference that collects all
  telemetry events until `flush/1` is called.
  """
  @spec attach() :: handle()
  def attach do
    table = :ets.new(:pyex_trace, [:public, :bag])
    handler_prefix = "pyex_trace_#{:erlang.unique_integer([:positive])}"

    for event <- @events do
      handler_id = "#{handler_prefix}_#{Enum.join(event, "_")}"

      :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, %{
        table: table,
        handler_id: handler_id
      })
    end

    :ets.insert(table, {:handler_prefix, handler_prefix})
    table
  end

  @doc """
  Prints collected trace events as a tree, then cleans up.

  Accepts either an explicit handle from `attach/0` or no
  argument (uses the most recently created handle from the
  calling process).
  """
  @spec flush(handle()) :: :ok
  def flush(table) do
    spans = collect_spans(table)
    detach_handlers(table)
    :ets.delete(table)

    if spans != [] do
      print_tree(spans)
    end

    :ok
  end

  @spec flush() :: :ok
  def flush do
    :ok
  end

  @doc false
  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(event, measurements, metadata, %{table: table}) do
    :ets.insert(table, {:event, event, measurements, metadata, System.monotonic_time()})
    :ok
  end

  @spec collect_spans(:ets.table()) :: [map()]
  defp collect_spans(table) do
    events =
      :ets.select(table, [
        {{:event, :"$1", :"$2", :"$3", :"$4"}, [], [{{:"$1", :"$2", :"$3", :"$4"}}]}
      ])
      |> Enum.sort_by(&elem(&1, 3))

    build_spans(events, [])
  end

  @spec build_spans([{[atom()], map(), map(), integer()}], [map()]) :: [map()]
  defp build_spans([], acc), do: Enum.reverse(acc)

  defp build_spans([{[:pyex, kind, :start], _meas, meta, start_ts} | rest], acc) do
    {stop_event, remaining} = find_stop(kind, rest)

    span =
      case stop_event do
        {_event, meas, stop_meta, _stop_ts} ->
          duration_ns = Map.get(meas, :duration, 0)
          duration_us = System.convert_time_unit(duration_ns, :native, :microsecond)

          %{
            name: span_name(kind, meta),
            start_ns: start_ts,
            duration_us: duration_us,
            attrs: build_attrs(kind, Map.merge(meta, stop_meta))
          }

        nil ->
          %{
            name: span_name(kind, meta),
            start_ns: start_ts,
            duration_us: 0,
            attrs: build_attrs(kind, meta)
          }
      end

    build_spans(remaining, [span | acc])
  end

  defp build_spans([_ | rest], acc), do: build_spans(rest, acc)

  @spec find_stop(atom(), [{[atom()], map(), map(), integer()}]) ::
          {{[atom()], map(), map(), integer()} | nil, [{[atom()], map(), map(), integer()}]}
  defp find_stop(kind, events) do
    stop_event_name = [:pyex, kind, :stop]
    exception_event_name = [:pyex, kind, :exception]

    case Enum.split_while(events, fn {name, _, _, _} ->
           name != stop_event_name and name != exception_event_name
         end) do
      {before, [match | after_match]} -> {match, before ++ after_match}
      {all, []} -> {nil, all}
    end
  end

  @spec span_name(atom(), map()) :: String.t()
  defp span_name(:run, _meta), do: "pyex.run"

  defp span_name(:request, %{method: m, url: u}),
    do: "http.#{String.downcase(m)} #{truncate_url(u)}"

  defp span_name(:request, _meta), do: "http.request"
  defp span_name(:query, _meta), do: "sql.query"
  defp span_name(kind, _meta), do: "pyex.#{kind}"

  @spec build_attrs(atom(), map()) :: map()
  defp build_attrs(:run, meta) do
    meta
    |> Map.take([:compute_us])
    |> Map.new(fn {k, v} -> {"pyex.#{k}", v} end)
  end

  defp build_attrs(:request, meta) do
    meta
    |> Map.take([:method, :url, :status, :response_body_size, :error])
    |> Map.new(fn
      {:method, v} -> {"http.method", v}
      {:url, v} -> {"http.url", v}
      {:status, v} -> {"http.status_code", v}
      {:response_body_size, v} -> {"http.response_body_size", v}
      {:error, v} -> {"error", v}
    end)
  end

  defp build_attrs(:query, meta) do
    meta
    |> Map.take([:statement, :rows_returned, :error])
    |> Map.new(fn
      {:statement, v} -> {"db.statement", v}
      {:rows_returned, v} -> {"db.rows_returned", v}
      {:error, v} -> {"error", v}
    end)
  end

  defp build_attrs(_kind, _meta), do: %{}

  @spec detach_handlers(:ets.table()) :: :ok
  defp detach_handlers(table) do
    case :ets.lookup(table, :handler_prefix) do
      [{:handler_prefix, prefix}] ->
        for event <- @events do
          handler_id = "#{prefix}_#{Enum.join(event, "_")}"
          :telemetry.detach(handler_id)
        end

        :ok

      _ ->
        :ok
    end
  end

  @spec print_tree([map()]) :: :ok
  defp print_tree(spans) do
    IO.puts("\n\e[36m── trace ──\e[0m")

    Enum.each(spans, fn span ->
      duration = format_duration(span.duration_us)
      attrs = format_attrs(span.attrs)
      IO.puts("\e[33m#{span.name}\e[0m  #{duration}#{attrs}")
    end)

    print_summary(spans)
    IO.puts("")
  end

  @spec print_summary([map()]) :: :ok
  defp print_summary(spans) do
    io_spans = Enum.filter(spans, &String.starts_with?(&1.name, "http."))
    io_spans = io_spans ++ Enum.filter(spans, &(&1.name == "sql.query"))
    io_us = Enum.reduce(io_spans, 0, &(&1.duration_us + &2))

    run_span = Enum.find(spans, &(&1.name == "pyex.run"))

    compute_us =
      case run_span do
        %{attrs: %{"pyex.compute_us" => us}} when is_integer(us) -> us
        _ -> nil
      end

    cond do
      run_span != nil and compute_us != nil ->
        wall_us = run_span.duration_us

        io_part =
          if io_us > 0, do: " · io #{format_duration_raw(io_us)}", else: ""

        IO.puts(
          "\e[36m── compute #{format_duration_raw(compute_us)}" <>
            "#{io_part} · wall #{format_duration_raw(wall_us)} ──\e[0m"
        )

      run_span != nil and io_us > 0 ->
        pyex_us = max(run_span.duration_us - io_us, 0)

        IO.puts(
          "\e[36m── pyex #{format_duration_raw(pyex_us)} · " <>
            "io #{format_duration_raw(io_us)} ──\e[0m"
        )

      true ->
        :ok
    end
  end

  @spec format_duration_raw(non_neg_integer()) :: String.t()
  defp format_duration_raw(us) when us < 1_000, do: "#{us}µs"
  defp format_duration_raw(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  defp format_duration_raw(us), do: "#{Float.round(us / 1_000_000, 2)}s"

  @spec format_duration(non_neg_integer()) :: String.t()
  defp format_duration(us) when us < 1_000, do: "\e[32m#{us}µs\e[0m"

  defp format_duration(us) when us < 1_000_000 do
    ms = Float.round(us / 1_000, 1)
    "\e[32m#{ms}ms\e[0m"
  end

  defp format_duration(us) do
    s = Float.round(us / 1_000_000, 2)
    "\e[31m#{s}s\e[0m"
  end

  @spec format_attrs(map()) :: String.t()
  defp format_attrs(attrs) when map_size(attrs) == 0, do: ""

  defp format_attrs(attrs) do
    interesting =
      attrs
      |> Enum.map(fn {k, v} -> "#{k}=#{truncate(v)}" end)
      |> Enum.join(" ")

    if interesting == "", do: "", else: "  \e[90m#{interesting}\e[0m"
  end

  @spec truncate_url(String.t()) :: String.t()
  defp truncate_url(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) ->
        "#{host}#{path || "/"}"

      _ ->
        truncate(url)
    end
  end

  @spec truncate(term()) :: String.t()
  defp truncate(v) when is_binary(v) do
    clean = String.replace(v, ~r/\s+/, " ") |> String.trim()

    if String.length(clean) > 60 do
      String.slice(clean, 0, 57) <> "..."
    else
      clean
    end
  end

  defp truncate(v), do: inspect(v)
end
