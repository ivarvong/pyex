defmodule Pyex.Highlighter.Styles do
  @moduledoc """
  Registry of built-in styles (themes).

  Each style lives in its own module under `Pyex.Highlighter.Styles.*`
  and exposes `style/0` returning a `Pyex.Highlighter.Style.t()`.
  """

  alias Pyex.Highlighter.Style

  @registry %{
    "monokai" => Pyex.Highlighter.Styles.Monokai,
    "github-light" => Pyex.Highlighter.Styles.GithubLight,
    "github_light" => Pyex.Highlighter.Styles.GithubLight,
    "dracula" => Pyex.Highlighter.Styles.Dracula,
    "solarized-light" => Pyex.Highlighter.Styles.SolarizedLight,
    "solarized_light" => Pyex.Highlighter.Styles.SolarizedLight,
    "default" => Pyex.Highlighter.Styles.GithubLight
  }

  @doc "Looks up a style by name. Accepts hyphen or underscore separators."
  @spec by_name(String.t()) :: {:ok, Style.t()} | :error
  def by_name(name) do
    case Map.fetch(@registry, String.downcase(name)) do
      {:ok, mod} -> {:ok, mod.style()}
      :error -> :error
    end
  end

  @doc "Sorted list of all built-in style names (canonical form)."
  @spec all_names() :: [String.t()]
  def all_names do
    canonical =
      @registry
      |> Map.keys()
      |> Enum.reject(&(String.contains?(&1, "_") or &1 == "default"))

    Enum.sort(canonical)
  end
end
