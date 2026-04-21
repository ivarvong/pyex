defmodule Pyex.Highlighter.Formatters.Html do
  @moduledoc """
  HTML formatter. Produces `<div class="highlight"><pre>...</pre></div>`
  wrapping the tokenized source, with each token in a `<span class="…">`
  using Pygments-compatible short class names (`k`, `s2`, `nf`, …).

  ## Options

    * `:style` — style to use. Accepts a built-in name, a user-supplied
      map, or a `Pyex.Highlighter.Style.t()`. Default: `"default"`.
    * `:cssclass` — outer div class. Default: `"highlight"`.
    * `:linenos` — `false` (default) or `:table` / `:inline`. Emits
      line numbers as a sibling `<span class="lineno">` on each line.
    * `:nowrap` — if `true`, skips the outer `<div>` and `<pre>`. Useful
      when embedding into an existing `<pre>`.
    * `:prestyles` — extra inline styles on the `<pre>` element.
    * `:line_number_start` — first line number (default `1`).
  """

  alias Pyex.Highlighter.{Style, Token}

  @type opts :: %{
          style: Style.t(),
          cssclass: String.t(),
          linenos: false | :inline | :table,
          nowrap: boolean(),
          prestyles: String.t() | nil,
          line_number_start: pos_integer()
        }

  @default_opts %{
    style: nil,
    cssclass: "highlight",
    linenos: false,
    nowrap: false,
    prestyles: nil,
    line_number_start: 1
  }

  @doc """
  Normalizes raw option keywords/maps into a resolved opts map.

  Callers (including the Python-facing wrapper) pass arbitrary kwargs
  and this tidies them into the canonical shape.
  """
  @spec build_opts(map() | keyword()) :: {:ok, opts()} | {:error, String.t()}
  def build_opts(raw) do
    map = Map.new(raw)
    style_input = Map.get(map, :style) || Map.get(map, "style") || "default"

    case Style.resolve(style_input) do
      {:ok, style} ->
        cssclass = Map.get(map, :cssclass) || Map.get(map, "cssclass") || "highlight"
        linenos = normalize_linenos(Map.get(map, :linenos) || Map.get(map, "linenos"))
        nowrap = truthy(Map.get(map, :nowrap) || Map.get(map, "nowrap"))
        prestyles = Map.get(map, :prestyles) || Map.get(map, "prestyles")
        start = Map.get(map, :linenostart) || Map.get(map, "linenostart") || 1

        {:ok,
         %{
           @default_opts
           | style: style,
             cssclass: cssclass,
             linenos: linenos,
             nowrap: nowrap,
             prestyles: prestyles,
             line_number_start: start
         }}

      {:error, _} = err ->
        err
    end
  end

  defp normalize_linenos(false), do: false
  defp normalize_linenos(nil), do: false
  defp normalize_linenos(true), do: :inline
  defp normalize_linenos("inline"), do: :inline
  defp normalize_linenos(:inline), do: :inline
  defp normalize_linenos("table"), do: :table
  defp normalize_linenos(:table), do: :table
  defp normalize_linenos(_), do: false

  defp truthy(nil), do: false
  defp truthy(false), do: false
  defp truthy(0), do: false
  defp truthy(""), do: false
  defp truthy(_), do: true

  @doc """
  Formats a token stream into an HTML string using the given opts.

  Tokens is a list of `{type, text}` tuples from a lexer.
  """
  @spec format([{Token.t(), String.t()}], opts()) :: String.t()
  def format(tokens, opts) do
    body = tokens |> Enum.map(&render_token(&1)) |> IO.iodata_to_binary()

    body =
      case opts.linenos do
        :inline -> wrap_inline_linenos(body, opts.line_number_start)
        :table -> wrap_table_linenos(body, opts.line_number_start)
        false -> body
      end

    if opts.nowrap do
      body
    else
      pre_style =
        case opts.prestyles do
          nil -> ""
          s -> ~s( style="#{escape_attr(s)}")
        end

      ~s(<div class="#{escape_attr(opts.cssclass)}"><pre#{pre_style}><code>) <>
        body <> "</code></pre></div>"
    end
  end

  defp render_token({:text, text}), do: escape(text)
  defp render_token({:whitespace, text}), do: escape(text)

  defp render_token({type, text}) do
    case Token.short_class(type) do
      "" -> escape(text)
      cls -> ~s(<span class=") <> cls <> ~s(">) <> escape(text) <> "</span>"
    end
  end

  defp wrap_inline_linenos(body, start) do
    lines = String.split(body, "\n")
    last_idx = length(lines) - 1
    # Last split chunk is "" if body ended with \n — don't emit a line
    # number for it.

    lines
    |> Enum.with_index()
    |> Enum.map_join("\n", fn
      {"", ^last_idx} ->
        ""

      {line, idx} ->
        n = start + idx
        ~s(<span class="lineno">#{pad(n)}</span>) <> line
    end)
  end

  defp wrap_table_linenos(body, start) do
    lines = String.split(body, "\n")
    last_idx = length(lines) - 1

    code_rows =
      lines
      |> Enum.with_index()
      |> Enum.reject(fn {line, idx} -> line == "" and idx == last_idx end)

    numbers =
      code_rows
      |> Enum.map_join("\n", fn {_line, idx} -> Integer.to_string(start + idx) end)

    code =
      code_rows
      |> Enum.map_join("\n", fn {line, _idx} -> line end)

    ~s(<table class="linenotable"><tr>) <>
      ~s(<td class="linenos"><pre>#{numbers}</pre></td>) <>
      ~s(<td class="code"><pre>#{code}</pre></td>) <>
      "</tr></table>"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(4)

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_attr(text) do
    text
    |> escape()
    |> String.replace("\"", "&quot;")
  end

  @doc """
  Returns CSS rules for the given style, scoped under `selector`.

  `selector` is typically `.highlight` or `.custom-class`.
  """
  @spec style_defs(Style.t(), String.t()) :: String.t()
  def style_defs(%Style{} = style, selector) do
    container_rules =
      "#{selector} { background: #{style.background_color}; " <>
        "color: #{default_fg(style)}; }"

    hll_rule =
      "#{selector} .hll { background-color: #{style.highlight_color}; }"

    # Emit a CSS rule for every token whose *resolved* rule is non-empty.
    # Resolution walks the hierarchy (Comment.Hashbang → Comment → …), so
    # a theme that only defines `Comment` still produces rules for `.c1`,
    # `.ch`, `.cm`, etc. — matching Pygments' behavior.
    empty = Style.empty_rule()

    token_rules =
      Token.all()
      |> Enum.flat_map(fn type ->
        case {Token.short_class(type), Style.rule_for(style, type)} do
          {"", _} -> []
          {_, ^empty} -> []
          {_, rule} -> [token_rule(selector, type, rule)]
        end
      end)

    [container_rules, hll_rule | token_rules]
    |> Enum.join("\n")
  end

  defp default_fg(%Style{} = style) do
    case Style.rule_for(style, :text).color do
      nil -> "#000000"
      c -> c
    end
  end

  defp token_rule(selector, type, rule) do
    cls = Token.short_class(type)
    parts = []

    parts = if rule.color, do: ["color: " <> rule.color | parts], else: parts
    parts = if rule.bgcolor, do: ["background-color: " <> rule.bgcolor | parts], else: parts
    parts = if rule.bold, do: ["font-weight: bold" | parts], else: parts
    parts = if rule.italic, do: ["font-style: italic" | parts], else: parts
    parts = if rule.underline, do: ["text-decoration: underline" | parts], else: parts
    parts = if rule.border, do: ["border: 1px solid " <> rule.border | parts], else: parts

    decls = parts |> Enum.reverse() |> Enum.join("; ")
    "#{selector} .#{cls} { #{decls} } /* #{Token.dotted_name(type)} */"
  end
end
