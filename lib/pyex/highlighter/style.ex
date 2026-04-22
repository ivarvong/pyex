defmodule Pyex.Highlighter.Style do
  @moduledoc """
  Style / theme model.

  A style is a map from token type (atom) to a rule map:

      %{
        color: "#8b5cf6",
        bgcolor: nil,
        bold: true,
        italic: false,
        underline: false,
        border: nil
      }

  Styles also carry a `background_color` and `highlight_color` for the
  enclosing code block.

  Callers can supply a style in any of three forms and
  `Pyex.Highlighter.Style.resolve/1` normalizes them:

    1. a built-in name as a string: `"monokai"`, `"github-light"`, …
    2. a map keyed by dotted token name: `%{"Keyword" => "bold #f00",
       "Comment" => "italic #6b7280"}` — values parse as Pygments-style
       style spec strings (a space-separated list of colors, flags, and
       `bg:` / `border:` directives)
    3. an already-resolved `%Style{}` struct
  """

  alias Pyex.Highlighter.Token

  @type rule :: %{
          color: String.t() | nil,
          bgcolor: String.t() | nil,
          bold: boolean(),
          italic: boolean(),
          underline: boolean(),
          border: String.t() | nil
        }

  defstruct styles: %{},
            background_color: "#ffffff",
            highlight_color: "#ffffcc",
            name: "custom"

  @type t :: %__MODULE__{
          styles: %{Token.t() => rule()},
          background_color: String.t(),
          highlight_color: String.t(),
          name: String.t()
        }

  @empty_rule %{
    color: nil,
    bgcolor: nil,
    bold: false,
    italic: false,
    underline: false,
    border: nil
  }

  @doc "An empty rule (no styling)."
  @spec empty_rule() :: rule()
  def empty_rule, do: @empty_rule

  @doc """
  Builds a `Style` from a map of `dotted_name => spec_string`.

  Four reserved keys configure the surrounding block rather than a
  specific token:

    * `"background"` / `"background-color"` / `"background_color"` —
      block background
    * `"highlight"` / `"highlight-color"` / `"highlight_color"` —
      selection/hll background

      iex> s = Pyex.Highlighter.Style.from_dict(%{
      ...>   "background" => "#1a1b26",
      ...>   "Keyword" => "bold #bb9af7",
      ...>   "Comment" => "italic #565f89"
      ...> })
      iex> s.background_color
      "#1a1b26"
      iex> s.styles[:keyword].bold
      true
  """
  @spec from_dict(map(), keyword()) :: t()
  def from_dict(dict, opts \\ []) do
    {bg, dict} = extract_key(dict, ["background", "background-color", "background_color"])

    {hl, dict} =
      extract_key(dict, ["highlight", "highlight-color", "highlight_color"])

    styles =
      dict
      |> Enum.reduce(%{}, fn {key, spec}, acc ->
        case resolve_key(key) do
          {:ok, type} -> Map.put(acc, type, parse_spec(spec))
          :error -> acc
        end
      end)

    %__MODULE__{
      styles: styles,
      background_color: bg || Keyword.get(opts, :background_color, "#ffffff"),
      highlight_color: hl || Keyword.get(opts, :highlight_color, "#ffffcc"),
      name: Keyword.get(opts, :name, "custom")
    }
  end

  defp extract_key(dict, keys) do
    Enum.reduce_while(keys, {nil, dict}, fn k, {_, d} ->
      case Map.pop(d, k) do
        {nil, _} -> {:cont, {nil, d}}
        {val, rest} -> {:halt, {val, rest}}
      end
    end)
  end

  @doc """
  Resolves the effective rule for a token type, walking up the
  ancestry chain until a defined rule is found.

  Returns `empty_rule/0` if no ancestor has a definition.
  """
  @spec rule_for(t(), Token.t()) :: rule()
  def rule_for(%__MODULE__{styles: styles}, type) do
    type
    |> Token.ancestry()
    |> find_rule(styles) || @empty_rule
  end

  defp find_rule([], _styles), do: nil

  defp find_rule([type | rest], styles) do
    case Map.get(styles, type) do
      nil -> find_rule(rest, styles)
      rule -> rule
    end
  end

  @doc """
  Parses a spec string like `"bold italic #8b5cf6 bg:#fff border:#000"`
  into a rule map.
  """
  @spec parse_spec(String.t() | rule()) :: rule()
  def parse_spec(spec) when is_map(spec) and not is_struct(spec) do
    Map.merge(@empty_rule, spec)
  end

  def parse_spec(spec) when is_binary(spec) do
    spec
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce(@empty_rule, &apply_token/2)
  end

  defp apply_token("bold", rule), do: %{rule | bold: true}
  defp apply_token("nobold", rule), do: %{rule | bold: false}
  defp apply_token("italic", rule), do: %{rule | italic: true}
  defp apply_token("noitalic", rule), do: %{rule | italic: false}
  defp apply_token("underline", rule), do: %{rule | underline: true}

  defp apply_token("bg:" <> color, rule), do: %{rule | bgcolor: normalize_color(color)}
  defp apply_token("border:" <> color, rule), do: %{rule | border: normalize_color(color)}

  defp apply_token(token, rule) do
    if color?(token) do
      %{rule | color: normalize_color(token)}
    else
      rule
    end
  end

  defp color?("#" <> _), do: true
  # Plain hex color without #
  defp color?(s), do: Regex.match?(~r/^[0-9a-fA-F]{3,8}$/, s)

  defp normalize_color("#" <> _ = c), do: c
  defp normalize_color(c), do: "#" <> c

  @doc """
  Normalizes a style token-key — accepts both dotted names (`"Keyword"`,
  `"Name.Function"`) and atom forms (`:keyword`, `:name_function`).
  """
  @spec resolve_key(String.t() | atom()) :: {:ok, Token.t()} | :error
  def resolve_key(key) when is_atom(key) do
    if Enum.member?(Token.all(), key), do: {:ok, key}, else: :error
  end

  def resolve_key(key) when is_binary(key) do
    case Token.from_dotted(key) do
      {:ok, _} = ok -> ok
      :error -> Token.from_short(key)
    end
  end

  @doc """
  Resolves any caller-supplied style input to a `%Style{}` struct.

  Accepts:
    * a `%Style{}` — returned as-is
    * a string name — looked up in `Pyex.Highlighter.Styles`
    * a map — treated as a user-supplied style dict
  """
  @spec resolve(t() | String.t() | map()) :: {:ok, t()} | {:error, String.t()}
  def resolve(%__MODULE__{} = style), do: {:ok, style}

  def resolve(name) when is_binary(name) do
    case Pyex.Highlighter.Styles.by_name(name) do
      {:ok, _style} = ok -> ok
      :error -> {:error, "unknown style: #{inspect(name)}"}
    end
  end

  def resolve(dict) when is_map(dict) do
    {:ok, from_dict(dict)}
  end
end
