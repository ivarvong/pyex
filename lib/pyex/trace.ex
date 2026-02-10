defmodule Pyex.Trace do
  @moduledoc """
  Custom OpenTelemetry exporter that collects spans and prints
  a clean tree with durations.

  Configure via:

      config :opentelemetry,
        span_processor: :simple,
        traces_exporter: {Pyex.Trace, []}

  Then call `Pyex.Trace.flush/0` after execution to print the tree.
  """

  @table :pyex_trace_spans

  @doc false
  @spec init(term()) :: {:ok, term()}
  def init(_config) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :bag])
    end

    {:ok, []}
  end

  @doc false
  @spec export(:ets.table(), term(), term()) :: :ok
  def export(spans_tid, _resource, _config) do
    :ets.foldl(
      fn span, :ok ->
        :ets.insert(@table, {span})
        :ok
      end,
      :ok,
      spans_tid
    )
  end

  @doc false
  @spec shutdown(term()) :: :ok
  def shutdown(_state), do: :ok

  @doc """
  Prints the collected spans as a tree with durations, then clears.
  """
  @spec flush() :: :ok
  def flush do
    if :ets.whereis(@table) != :undefined do
      spans = collect_spans()
      :ets.delete_all_objects(@table)
      print_tree(spans)
    end

    :ok
  end

  defp collect_spans do
    :ets.tab2list(@table)
    |> Enum.map(fn {span} -> parse_span(span) end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_span(span) when is_tuple(span) and elem(span, 0) == :span do
    name = elem(span, 6) |> to_string()
    start_ns = elem(span, 8)
    end_ns = elem(span, 9)
    span_id = elem(span, 2)
    parent_id = elem(span, 4)
    attrs = extract_attrs(elem(span, 10))

    duration_us = div(end_ns - start_ns, 1000)

    %{
      name: name,
      span_id: span_id,
      parent_id: parent_id,
      start_ns: start_ns,
      duration_us: duration_us,
      attrs: attrs
    }
  rescue
    _ -> nil
  end

  defp parse_span(_), do: nil

  defp extract_attrs({:attributes, _, _, _, map}) when is_map(map), do: map
  defp extract_attrs(_), do: %{}

  defp print_tree(spans) do
    roots = Enum.filter(spans, fn s -> s.parent_id == :undefined end)
    by_parent = Enum.group_by(spans, & &1.parent_id)

    IO.puts("\n\e[36m── trace ──\e[0m")

    Enum.sort_by(roots, & &1.start_ns)
    |> Enum.each(fn root -> print_span(root, by_parent, 0) end)

    print_summary(spans)
    IO.puts("")
  end

  defp print_summary(spans) do
    io_names = ["http.request", "sql.query"]
    io_us = spans |> Enum.filter(&(&1.name in io_names)) |> Enum.reduce(0, &(&1.duration_us + &2))

    root = Enum.find(spans, fn s -> s.parent_id == :undefined end)

    interpret_span = Enum.find(spans, fn s -> s.name == "pyex.interpret" end)

    compute_us =
      case interpret_span do
        %{attrs: %{"pyex.compute_us" => us}} when is_integer(us) -> us
        _ -> nil
      end

    cond do
      root != nil and compute_us != nil ->
        wall_us = root.duration_us

        io_part =
          if io_us > 0, do: " · io #{format_duration_raw(io_us)}", else: ""

        IO.puts(
          "\e[36m── compute #{format_duration_raw(compute_us)}" <>
            "#{io_part} · wall #{format_duration_raw(wall_us)} ──\e[0m"
        )

      root != nil and io_us > 0 ->
        pyex_us = max(root.duration_us - io_us, 0)

        IO.puts(
          "\e[36m── pyex #{format_duration_raw(pyex_us)} · " <>
            "io #{format_duration_raw(io_us)} ──\e[0m"
        )

      true ->
        :ok
    end
  end

  defp print_span(span, by_parent, depth) do
    indent = String.duplicate("  ", depth)
    duration = format_duration(span.duration_us)
    attrs = format_attrs(span.attrs)

    children =
      Map.get(by_parent, span.span_id, [])
      |> Enum.sort_by(& &1.start_ns)

    self_time = self_time_suffix(span, children)

    IO.puts("#{indent}\e[33m#{span.name}\e[0m  #{duration}#{self_time}#{attrs}")

    Enum.each(children, fn child -> print_span(child, by_parent, depth + 1) end)
  end

  defp self_time_suffix(span, children) do
    if children != [] do
      child_us = Enum.reduce(children, 0, fn c, acc -> acc + c.duration_us end)
      self_us = max(span.duration_us - child_us, 0)
      "  \e[36m(self #{format_duration_raw(self_us)})\e[0m"
    else
      ""
    end
  end

  defp format_duration_raw(us) when us < 1_000, do: "#{us}µs"
  defp format_duration_raw(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  defp format_duration_raw(us), do: "#{Float.round(us / 1_000_000, 2)}s"

  defp format_duration(us) when us < 1_000, do: "\e[32m#{us}µs\e[0m"

  defp format_duration(us) when us < 1_000_000 do
    ms = Float.round(us / 1_000, 1)
    "\e[32m#{ms}ms\e[0m"
  end

  defp format_duration(us) do
    s = Float.round(us / 1_000_000, 2)
    "\e[31m#{s}s\e[0m"
  end

  defp format_attrs(attrs) when map_size(attrs) == 0, do: ""

  defp format_attrs(attrs) do
    interesting =
      attrs
      |> Map.drop(["db.system"])
      |> Enum.map(fn {k, v} -> "#{k}=#{truncate(v)}" end)
      |> Enum.join(" ")

    if interesting == "", do: "", else: "  \e[90m#{interesting}\e[0m"
  end

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
