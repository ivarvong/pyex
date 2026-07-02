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
      # `mix wasm.build` config — compile Pyex to a sandboxed WasmGC module. `deps` is the allowlist
      # of dependencies bundled into the wasm (the sandbox boundary). See lib/pyex/wasm.ex.
      wasm: [
        module: Pyex.Wasm,
        exports: ["pyrun:bin,bin,int->term"],
        deps: [:nimble_parsec, :decimal, :vfs, :jason, :tz]
      ],
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
      {:jason, "~> 1.4"},
      {:nimble_parsec, "~> 1.4"},
      {:req, "~> 0.5"},
      {:decimal, "~> 2.0"},
      {:vfs, "~> 0.1.0"},
      # Optional backends. These stdlib modules need a heavy/native dependency the
      # core has no reason to carry, so they're optional: the feature lights up
      # when the caller adds the dep, and `import sql`/`import pandas`/
      # `import markdown` raise a clean Python ImportError otherwise
      # (`Pyex.Stdlib.fetch/1` degrades). For
      # a consumer that doesn't add them, pyex must still COMPILE without them —
      # `scripts/consumer_smoke.sh` (the `consumer-smoke` CI job) proves it does,
      # the regression class this project's own build can't catch since the
      # optional deps are present here.
      #
      # Adding another optional backend? Use the same shapes — they're the
      # idiomatic ones (and exactly how `:explorer` itself treats *its* optional
      # `:nx`: `@compile {:no_warn_undefined, Nx}` + `is_struct(x, Nx.Tensor)`):
      #   - `optional: true` here;
      #   - wrap the producer module in `if Code.ensure_loaded?(Dep) do …`
      #     (struct patterns/expansion are a hard compile-time requirement);
      #   - `@compile {:no_warn_undefined, [Dep.Mod]}` for scattered calls
      #     elsewhere, and `is_struct(x, Dep.Struct)` (a runtime atom check, no
      #     compile-time struct) instead of `%Dep.Struct{}` in patterns.
      {:postgrex, "~> 0.22", optional: true},
      {:explorer, "~> 0.11.1", optional: true},
      {:cmark, "~> 0.10", optional: true},
      {:yaml_elixir, "~> 2.12", only: :test},
      {:telemetry, "~> 0.4 or ~> 1.0"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:stream_data, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:tz, "~> 0.28"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: :dev},
      {:bandit, "~> 1.6", only: :dev},
      # the Elixir→WasmGC compiler that powers `mix wasm.build` (dev-only, not a runtime dep).
      {:beam2wasm, path: "../elixir_wasm", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "Pyex",
      extras: ["README.md", "docs/integrating-vfs.md", "CHANGELOG.md", "LICENSE"],
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
          Pyex.FS,
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
