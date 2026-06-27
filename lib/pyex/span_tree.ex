defmodule Pyex.SpanTree do
  @moduledoc """
  Renders a span list to a compact ASCII waterfall tree — a trace an LLM (or a
  human) can read directly in context.

  Both span shapes are accepted (the guest `app_spans` and the runtime
  `runtime_spans`); only `:name`, `:parent_id`, `:start_seq`, `:end_seq`, and
  `:attributes` are required, with `:kind`/`:status` shown when present.

  Because pyex spans are ordered by a *logical* clock (never the wall clock),
  the render is **deterministic** — identical inputs produce an identical
  string, so it diffs cleanly across runs. The waterfall column maps
  `[start_seq, end_seq]` to a fixed width (nesting + ordering at a glance);
  indentation follows `parent_id`.

      ━━━━━━━━━━━━━━━━━━━━━━━━ process_order      SERVER   order.id="A1"
         ━━━━                   validate           INTERNAL OK
                ━━━━            charge             CLIENT   OK  gateway="stripe"
  """

  @type span :: %{
          optional(:kind) => String.t() | nil,
          optional(:status) => String.t() | nil,
          required(:name) => String.t(),
          required(:parent_id) => non_neg_integer() | nil,
          required(:start_seq) => non_neg_integer(),
          required(:end_seq) => non_neg_integer() | nil,
          required(:attributes) => %{optional(String.t()) => term()}
        }

  @default_width 24

  @doc """
  Renders `spans` to an ASCII waterfall tree string.

  Options:
    * `:title` — a header line above the tree (e.g. the scope name)
    * `:width` — waterfall column width in characters (default #{@default_width})
  """
  @spec render([span()], keyword()) :: String.t()
  def render(spans, opts \\ [])

  def render([], opts), do: header(opts, 0) <> "(no spans)"

  def render(spans, opts) when is_list(spans) do
    spans = Enum.map(spans, &normalize/1)
    lo = spans |> Enum.map(& &1.start_seq) |> Enum.min()
    hi = spans |> Enum.map(& &1.end_seq) |> Enum.max()
    width = Keyword.get(opts, :width, @default_width)
    span_w = max(hi - lo, 1)

    by_parent = Enum.group_by(spans, & &1.parent_id)
    lines = walk(by_parent, nil, 0, lo, span_w, width, [])

    header(opts, length(spans)) <> Enum.join(Enum.reverse(lines), "\n")
  end

  @spec header(keyword(), non_neg_integer()) :: String.t()
  defp header(opts, count) do
    case Keyword.get(opts, :title) do
      nil -> ""
      title -> "── #{title} · #{count} span#{if count == 1, do: "", else: "s"} ──\n"
    end
  end

  # Depth-first over the parent→children tree, children in logical-clock order.
  defp walk(by_parent, parent_id, depth, lo, span_w, width, acc) do
    children = by_parent |> Map.get(parent_id, []) |> Enum.sort_by(& &1.start_seq)

    Enum.reduce(children, acc, fn s, acc ->
      line = render_line(s, depth, lo, span_w, width)
      walk(by_parent, s.id, depth + 1, lo, span_w, width, [line | acc])
    end)
  end

  defp render_line(s, depth, lo, span_w, width) do
    bar = waterfall(s, lo, span_w, width)
    label = String.pad_trailing(String.duplicate("  ", depth) <> s.name, 26)
    meta = [s.kind, s.status, attrs(s.attributes)] |> Enum.reject(&(&1 in [nil, ""]))
    String.trim_trailing("#{bar} #{label} #{Enum.join(meta, " ")}")
  end

  defp waterfall(s, lo, span_w, width) do
    a = round((s.start_seq - lo) / span_w * width)
    b = max(round((s.end_seq - lo) / span_w * width), a + 1) |> min(width)
    String.duplicate(" ", a) <> String.duplicate("━", b - a) <> String.duplicate(" ", width - b)
  end

  defp attrs(attributes) do
    attributes
    |> Enum.sort()
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end

  # Accept both span shapes; default kind/status/end_seq sensibly.
  defp normalize(s) do
    %{
      id: Map.get(s, :id) || Map.get(s, "id"),
      name: s.name,
      parent_id: Map.get(s, :parent_id),
      start_seq: s.start_seq,
      end_seq: s.end_seq || s.start_seq,
      kind: format_kind(Map.get(s, :kind)),
      status: format_status(Map.get(s, :status)),
      attributes: Map.get(s, :attributes, %{})
    }
  end

  defp format_kind(nil), do: nil
  defp format_kind(k), do: to_string(k)

  defp format_status(nil), do: nil
  defp format_status("UNSET"), do: nil
  defp format_status(s), do: to_string(s)
end
