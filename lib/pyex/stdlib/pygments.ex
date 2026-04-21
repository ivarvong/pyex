defmodule Pyex.Stdlib.Pygments do
  @moduledoc """
  Pygments-compatible Python API for `Pyex.Highlighter`.

      from pygments import highlight
      from pygments.lexers import PythonLexer, get_lexer_by_name
      from pygments.formatters import HtmlFormatter
      from pygments.styles import get_style_by_name, get_all_styles

      html = highlight(code, PythonLexer(), HtmlFormatter(style="monokai"))
      css  = HtmlFormatter(style="monokai").get_style_defs(".highlight")

  Lexer and formatter instances are plain dicts tagged with a
  `__pygments_*__` marker so `highlight/3` can dispatch on them without
  needing full Python class semantics.

  A user-defined theme can be passed to `HtmlFormatter` as:

    * a string — built-in name (`"monokai"`, `"github-light"`, …)
    * a dict — `{"Keyword": "bold #8b5cf6", "Comment": "italic #6b7280"}`
    * (Future) a `Style` subclass — not yet wired

  Highlights are returned as HTML strings. `get_style_defs(selector)`
  yields the CSS rules for the formatter's style under that selector.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Highlighter
  alias Pyex.Highlighter.Formatters.Html
  alias Pyex.Highlighter.{Lexer, Style, Styles}
  alias Pyex.Interpreter

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "highlight" => {:builtin, &do_highlight/1},
      "lexers" => {:module, "pygments.lexers", lexers_module()},
      "formatters" => {:module, "pygments.formatters", formatters_module()},
      "styles" => {:module, "pygments.styles", styles_module()}
    }
  end

  # ---- pygments.highlight(code, lexer, formatter) ------------------

  defp do_highlight([code, lexer, formatter])
       when is_binary(code) do
    with {:ok, lexer_mod} <- resolve_lexer(lexer),
         {:ok, opts} <- resolve_formatter(formatter) do
      tokens = Lexer.tokenize(lexer_mod, code)
      Html.format(tokens, opts)
    else
      {:error, msg} -> {:exception, "ValueError: " <> msg}
    end
  end

  defp do_highlight(_) do
    {:exception, "TypeError: highlight(code, lexer, formatter)"}
  end

  # ---- pygments.lexers -------------------------------------------

  defp lexers_module do
    %{
      "PythonLexer" => {:builtin_kw, &lexer_ctor("python", &1, &2)},
      "BashLexer" => {:builtin_kw, &lexer_ctor("bash", &1, &2)},
      "JsonLexer" => {:builtin_kw, &lexer_ctor("json", &1, &2)},
      "JavascriptLexer" => {:builtin_kw, &lexer_ctor("javascript", &1, &2)},
      "TypescriptLexer" => {:builtin_kw, &lexer_ctor("typescript", &1, &2)},
      "JsxLexer" => {:builtin_kw, &lexer_ctor("jsx", &1, &2)},
      "TsxLexer" => {:builtin_kw, &lexer_ctor("tsx", &1, &2)},
      "ElixirLexer" => {:builtin_kw, &lexer_ctor("elixir", &1, &2)},
      "get_lexer_by_name" => {:builtin_kw, &get_lexer_by_name/2},
      "get_all_lexers" => {:builtin, &get_all_lexers/1}
    }
  end

  defp lexer_ctor(name, _args, _kwargs) do
    case Highlighter.lexer_for_name(name) do
      {:ok, mod} ->
        %{
          "__pygments_lexer__" => name,
          "__lexer_module__" => mod,
          "name" => mod.name(),
          "aliases" => mod.aliases()
        }

      {:error, msg} ->
        {:exception, "ValueError: " <> msg}
    end
  end

  defp get_lexer_by_name([name], _kwargs) when is_binary(name) do
    lexer_ctor(name, [], %{})
  end

  defp get_lexer_by_name(_args, _kwargs) do
    {:exception, "TypeError: get_lexer_by_name(name)"}
  end

  defp get_all_lexers(_args) do
    Highlighter.lexer_names()
    |> Enum.map(fn n ->
      {:ok, mod} = Highlighter.lexer_for_name(n)
      {:tuple, [mod.name(), mod.aliases(), mod.filenames(), mod.mimetypes()]}
    end)
  end

  # ---- pygments.formatters ---------------------------------------

  defp formatters_module do
    %{
      "HtmlFormatter" => {:builtin_kw, &html_formatter_ctor/2},
      "get_formatter_by_name" => {:builtin_kw, &get_formatter_by_name/2}
    }
  end

  defp html_formatter_ctor(_args, kwargs) do
    opts_map =
      kwargs
      |> normalize_kwargs()
      |> convert_style_value()

    case Html.build_opts(opts_map) do
      {:ok, opts} ->
        build_formatter_instance(opts)

      {:error, msg} ->
        {:exception, "ValueError: " <> msg}
    end
  end

  defp get_formatter_by_name([name], kwargs) when is_binary(name) do
    case String.downcase(name) do
      "html" -> html_formatter_ctor([], kwargs)
      "terminal" -> {:exception, "ValueError: terminal formatter not implemented"}
      other -> {:exception, "ValueError: no formatter " <> inspect(other)}
    end
  end

  defp get_formatter_by_name(_, _), do: {:exception, "TypeError: get_formatter_by_name(name)"}

  # The formatter instance exposes opaque state plus a `get_style_defs`
  # method. Method closures capture the resolved opts so subsequent
  # calls don't re-parse.
  defp build_formatter_instance(opts) do
    %{
      "__pygments_formatter__" => "html",
      "__formatter_opts__" => opts,
      "style" => opts.style.name,
      "cssclass" => opts.cssclass,
      "get_style_defs" =>
        {:builtin,
         fn
           [] -> Html.style_defs(opts.style, ".#{opts.cssclass}")
           [selector] when is_binary(selector) -> Html.style_defs(opts.style, selector)
           _ -> {:exception, "TypeError: get_style_defs([selector])"}
         end}
    }
  end

  # ---- pygments.styles -------------------------------------------

  defp styles_module do
    %{
      "get_style_by_name" => {:builtin, &get_style_by_name/1},
      "get_all_styles" => {:builtin, fn [] -> Styles.all_names() end}
    }
  end

  defp get_style_by_name([name]) when is_binary(name) do
    case Styles.by_name(name) do
      {:ok, style} ->
        %{
          "__pygments_style__" => style.name,
          "name" => style.name,
          "background_color" => style.background_color,
          "highlight_color" => style.highlight_color
        }

      :error ->
        {:exception, "ClassNotFound: no style named " <> inspect(name)}
    end
  end

  defp get_style_by_name(_), do: {:exception, "TypeError: get_style_by_name(name)"}

  # ---- dispatch helpers ------------------------------------------

  # A Python-side lexer instance looks like `%{"__pygments_lexer__" => "python", ...}`.
  defp resolve_lexer(%{"__lexer_module__" => mod}), do: {:ok, mod}

  defp resolve_lexer(%{"__pygments_lexer__" => name}) do
    Highlighter.lexer_for_name(name)
  end

  defp resolve_lexer(name) when is_binary(name) do
    Highlighter.lexer_for_name(name)
  end

  defp resolve_lexer(_), do: {:error, "lexer argument is not a Lexer instance"}

  defp resolve_formatter(%{"__formatter_opts__" => opts}), do: {:ok, opts}

  defp resolve_formatter(%{"__pygments_formatter__" => _} = f) do
    # A formatter instance without cached opts — shouldn't happen for
    # our built-in constructors. Rebuild defaults.
    Html.build_opts(Map.drop(f, ["__pygments_formatter__"]))
  end

  defp resolve_formatter(_), do: {:error, "formatter argument is not a Formatter instance"}

  # Python kwargs come in as a %{"key" => value} map. Some values need
  # coercion — notably `style` which can be a Python dict (PyDict).
  @spec normalize_kwargs(%{optional(String.t()) => Interpreter.pyvalue()}) :: map()
  defp normalize_kwargs(kwargs) when is_map(kwargs), do: kwargs
  defp normalize_kwargs(_), do: %{}

  # If the user supplied `style=` as a Python dict, turn it into a
  # plain map of dotted-name → spec-string. Other forms (string name,
  # already-resolved %Style{}) pass through.
  defp convert_style_value(opts) do
    case Map.get(opts, "style") do
      {:py_dict, map, _order} ->
        Map.put(opts, "style", pydict_to_style_map(map))

      {:py_dict, map} ->
        Map.put(opts, "style", pydict_to_style_map(map))

      %Style{} = s ->
        Map.put(opts, "style", s)

      _ ->
        opts
    end
  end

  defp pydict_to_style_map(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_binary(k) and is_binary(v) -> Map.put(acc, k, v)
      _, acc -> acc
    end)
  end
end
