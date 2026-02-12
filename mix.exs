defmodule Pyex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ivarvong/pyex"

  def project do
    [
      app: :pyex,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      name: "Pyex",
      description:
        "A Python 3 interpreter written in Elixir for safely running LLM-generated code.",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:cmark, "~> 0.10"},
      {:jason, "~> 1.4"},
      {:nimble_parsec, "~> 1.4"},
      {:req, "~> 0.5"},
      {:postgrex, "~> 0.22", optional: true},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.10"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:explorer, "~> 0.10", optional: true},
      {:stream_data, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: :dev},
      {:bandit, "~> 1.6", only: :dev}
    ]
  end

  defp docs do
    [
      main: "Pyex",
      extras: ["README.md", "LICENSE"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Core Pipeline": [
          Pyex,
          Pyex.Lexer,
          Pyex.Parser,
          Pyex.Interpreter
        ],
        Runtime: [
          Pyex.Ctx,
          Pyex.Env,
          Pyex.Error,
          Pyex.Builtins,
          Pyex.Methods
        ],
        "Lambda / Web": [
          Pyex.Lambda,
          Pyex.Stdlib.FastAPI
        ],
        "Stdlib Modules": [
          Pyex.Stdlib,
          Pyex.Stdlib.Module,
          Pyex.Stdlib.Boto3,
          Pyex.Stdlib.Collections,
          Pyex.Stdlib.Csv,
          Pyex.Stdlib.Datetime,
          Pyex.Stdlib.Html,
          Pyex.Stdlib.Itertools,
          Pyex.Stdlib.Jinja2,
          Pyex.Stdlib.Json,
          Pyex.Stdlib.Markdown,
          Pyex.Stdlib.Math,
          Pyex.Stdlib.Pydantic,
          Pyex.Stdlib.Random,
          Pyex.Stdlib.Re,
          Pyex.Stdlib.Requests,
          Pyex.Stdlib.Sql,
          Pyex.Stdlib.Time,
          Pyex.Stdlib.Unittest,
          Pyex.Stdlib.Uuid
        ],
        Filesystem: [
          Pyex.Filesystem,
          Pyex.Filesystem.Memory,
          Pyex.Filesystem.S3
        ],
        "Interpreter Internals": [
          Pyex.Interpreter.Format,
          Pyex.Interpreter.Helpers,
          Pyex.Interpreter.Import,
          Pyex.Interpreter.Iteration,
          Pyex.Interpreter.Match,
          Pyex.Interpreter.Unittest
        ],
        Observability: [
          Pyex.Trace
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end
end
