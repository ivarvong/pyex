defmodule Pyex.MixProject do
  use Mix.Project

  def project do
    [
      app: :pyex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix],
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :opentelemetry_exporter, :opentelemetry]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:cmark, "~> 0.10"},
      {:nimble_parsec, "~> 1.4"},
      {:req, "~> 0.5"},
      {:postgrex, "~> 0.22"},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.10"},
      {:stream_data, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: :dev},
      {:bandit, "~> 1.6", only: :dev}
    ]
  end
end
