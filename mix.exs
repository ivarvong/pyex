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
      {:yaml_elixir, "~> 2.12", only: :test},
      {:telemetry, "~> 0.4 or ~> 1.0"},
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
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Core API": [
          Pyex,
          Pyex.Ctx,
          Pyex.Error,
          Pyex.Lambda
        ],
        "Stdlib Modules": [
          Pyex.Stdlib.Base64,
          Pyex.Stdlib.Boto3,
          Pyex.Stdlib.Collections,
          Pyex.Stdlib.Csv,
          Pyex.Stdlib.Datetime,
          Pyex.Stdlib.FastAPI,
          Pyex.Stdlib.Hashlib,
          Pyex.Stdlib.Hmac,
          Pyex.Stdlib.Html,
          Pyex.Stdlib.Itertools,
          Pyex.Stdlib.Jinja2,
          Pyex.Stdlib.Json,
          Pyex.Stdlib.Markdown,
          Pyex.Stdlib.Math,
          Pyex.Stdlib.Pandas,
          Pyex.Stdlib.Pydantic,
          Pyex.Stdlib.Random,
          Pyex.Stdlib.Re,
          Pyex.Stdlib.Requests,
          Pyex.Stdlib.Secrets,
          Pyex.Stdlib.Sql,
          Pyex.Stdlib.Time,
          Pyex.Stdlib.Unittest,
          Pyex.Stdlib.Uuid,
          Pyex.Stdlib.Yaml,
          Pyex.Stdlib.YamlParser
        ],
        Filesystem: [
          Pyex.Filesystem,
          Pyex.Filesystem.Memory,
          Pyex.Filesystem.S3
        ],
        Internals: [
          Pyex.Interpreter,
          Pyex.Lexer,
          Pyex.Parser,
          Pyex.Env,
          Pyex.Builtins,
          Pyex.Methods,
          Pyex.Stdlib,
          Pyex.Stdlib.Module,
          Pyex.Interpreter.Format,
          Pyex.Interpreter.Helpers,
          Pyex.Interpreter.Import,
          Pyex.Interpreter.Iteration,
          Pyex.Interpreter.Match,
          Pyex.Interpreter.Unittest,
          Pyex.Trace
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
