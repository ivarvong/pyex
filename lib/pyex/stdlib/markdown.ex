if Code.ensure_loaded?(Cmark) do
  defmodule Pyex.Stdlib.Markdown do
    @moduledoc """
    Python `markdown` module for converting Markdown text to HTML.

    Provides `markdown.markdown(text)` which returns an HTML string.
    Delegates to the `cmark` NIF (the C reference CommonMark implementation)
    for fast, spec-compliant Markdown-to-HTML conversion.

    `:cmark` is an optional dependency — it ships native code the core has no
    reason to carry. This module is compiled only when the consumer adds the
    dep; otherwise `import markdown` raises a clean Python ImportError
    (`Pyex.Stdlib.fetch/1` degrades).
    """

    @behaviour Pyex.Stdlib.Module

    @doc """
    Returns the module value map with the `markdown` function.
    """
    @impl Pyex.Stdlib.Module
    @spec module_value() :: Pyex.Stdlib.Module.module_value()
    def module_value do
      %{
        "markdown" => {:builtin, &do_markdown/1}
      }
    end

    @spec do_markdown([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
    defp do_markdown([text]) when is_binary(text) do
      result = Cmark.to_html(text)
      String.trim_trailing(result, "\n")
    end

    defp do_markdown(_) do
      {:exception, "TypeError: markdown.markdown() argument must be a string"}
    end
  end
end
