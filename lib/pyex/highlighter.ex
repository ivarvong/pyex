defmodule Pyex.Highlighter do
  @moduledoc """
  Clean-room syntax highlighter with Pygments-compatible API.

  ## Quick start

      Pyex.Highlighter.highlight(source, "python", style: "monokai")

  Equivalent to:

      lexer = Pyex.Highlighter.lexer_for_name("python")
      tokens = Pyex.Highlighter.Lexer.tokenize(lexer, source)
      {:ok, opts} = Pyex.Highlighter.Formatters.Html.build_opts(style: "monokai")
      Pyex.Highlighter.Formatters.Html.format(tokens, opts)

  ## Supported languages

    * `python`, `py`
    * `json`
    * `bash`, `sh`, `shell`
    * `javascript`, `js`
    * `typescript`, `ts`
    * `jsx`
    * `tsx`
    * `elixir`, `ex`, `exs`

  ## Themes

  Built-in: `monokai`, `github-light`, `dracula`, `solarized-light`.
  Custom themes can be passed as a map — see `Pyex.Highlighter.Style`.
  """

  alias Pyex.Highlighter.{Formatters, Lexer, Style}

  @lexer_registry %{
    "python" => Pyex.Highlighter.Lexers.Python,
    "py" => Pyex.Highlighter.Lexers.Python,
    "py3" => Pyex.Highlighter.Lexers.Python,
    "python3" => Pyex.Highlighter.Lexers.Python,
    "json" => Pyex.Highlighter.Lexers.Json,
    "bash" => Pyex.Highlighter.Lexers.Bash,
    "sh" => Pyex.Highlighter.Lexers.Bash,
    "shell" => Pyex.Highlighter.Lexers.Bash,
    "zsh" => Pyex.Highlighter.Lexers.Bash,
    "javascript" => Pyex.Highlighter.Lexers.Javascript,
    "js" => Pyex.Highlighter.Lexers.Javascript,
    "typescript" => Pyex.Highlighter.Lexers.Typescript,
    "ts" => Pyex.Highlighter.Lexers.Typescript,
    "jsx" => Pyex.Highlighter.Lexers.Jsx,
    "tsx" => Pyex.Highlighter.Lexers.Tsx,
    "elixir" => Pyex.Highlighter.Lexers.Elixir,
    "ex" => Pyex.Highlighter.Lexers.Elixir,
    "exs" => Pyex.Highlighter.Lexers.Elixir
  }

  @doc """
  Highlights `source` in the given `lang` and returns an HTML string.

  Options are passed through to the HTML formatter — see
  `Pyex.Highlighter.Formatters.Html` for the full list. Most important:

    * `:style` — built-in name (`"monokai"`), dict, or `%Style{}`
    * `:cssclass` — outer div class
    * `:linenos` — `false`, `:inline`, or `:table`
  """
  @spec highlight(String.t(), String.t(), keyword() | map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def highlight(source, lang, opts \\ []) do
    with {:ok, lexer} <- lexer_for_name(lang),
         {:ok, resolved} <- Formatters.Html.build_opts(opts) do
      tokens = Lexer.tokenize(lexer, source)
      {:ok, Formatters.Html.format(tokens, resolved)}
    end
  end

  @doc "Same as `highlight/3` but raises on error."
  @spec highlight!(String.t(), String.t(), keyword() | map()) :: String.t()
  def highlight!(source, lang, opts \\ []) do
    case highlight(source, lang, opts) do
      {:ok, html} -> html
      {:error, msg} -> raise ArgumentError, msg
    end
  end

  @doc """
  Returns CSS rule definitions for `style` scoped under `selector`.

      iex> {:ok, css} = Pyex.Highlighter.css("monokai")
      iex> String.contains?(css, "monokai") or String.contains?(css, "#272822")
      true
  """
  @spec css(String.t() | map() | Style.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def css(style_input, selector \\ ".highlight") do
    case Style.resolve(style_input) do
      {:ok, style} -> {:ok, Formatters.Html.style_defs(style, selector)}
      {:error, _} = err -> err
    end
  end

  @doc "Looks up a lexer module by name or alias."
  @spec lexer_for_name(String.t()) :: {:ok, module()} | {:error, String.t()}
  def lexer_for_name(name) when is_binary(name) do
    case Map.fetch(@lexer_registry, String.downcase(name)) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, "no lexer for #{inspect(name)}"}
    end
  end

  @doc "Sorted list of canonical lexer names (not aliases)."
  @spec lexer_names() :: [String.t()]
  def lexer_names do
    # Canonical name is the first alias in each lexer's :aliases list.
    # Filter to just those.
    @lexer_registry
    |> Map.values()
    |> Enum.uniq()
    |> Enum.map(fn m -> m.name() end)
    |> Enum.sort()
  end

  @doc "All registered lexer aliases (including canonical names)."
  @spec lexer_aliases() :: [String.t()]
  def lexer_aliases do
    @lexer_registry |> Map.keys() |> Enum.sort()
  end
end
