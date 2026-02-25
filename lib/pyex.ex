defmodule Pyex do
  @moduledoc """
  A Python 3 interpreter written in Elixir.

  Pyex lexes, parses, and evaluates Python source code entirely
  within the BEAM -- no external runtime, no NIFs, no ports.
  It is designed as a capabilities-based sandbox for running
  LLM-generated compute safely: every I/O operation (network,
  filesystem, database) is denied by default and must be
  explicitly granted through `Pyex.Ctx` options.

  ## Quick start

      Pyex.run!("sorted([3, 1, 2])")
      # => [1, 2, 3]

      {:ok, 42, _ctx} = Pyex.run("40 + 2")

  ## Public API

  - `compile/1` -- parse source to AST (reusable)
  - `run/2` -- execute source or AST, returns `{:ok, value, ctx}` or `{:error, error}`
  - `run!/2` -- execute, returns value or raises
  - `output/1` -- extract print output from a context

  ## Sandbox

  All external access is configured through `Pyex.Ctx` options.
  Python code can only reach what you explicitly grant:

      Pyex.run(source,
        env: %{"API_KEY" => "sk-..."},
        timeout_ms: 5_000,
        modules: %{"mylib" => %{"greet" => {:builtin, fn [n] -> "hi \#{n}" end}}})

  See `run/2` for the full list of options.
  """

  alias Pyex.{Builtins, Ctx, Error, Lexer, Parser, Interpreter}

  @doc """
  Compiles a Python source string to an AST.

  The lexer and parser are pure functions of the source text.
  Callers that execute the same program repeatedly should
  compile once and reuse the AST with `run/2`.
  """
  @spec compile(String.t()) :: {:ok, Parser.ast_node()} | {:error, String.t()}
  def compile(source) when is_binary(source) do
    with {:ok, tokens} <- Lexer.tokenize(source) do
      Parser.parse(tokens)
    end
  end

  @doc """
  Runs Python code through the full pipeline.

  Accepts either a source string or a pre-compiled AST.
  The optional second argument can be a `Pyex.Ctx` struct
  or a keyword list of options (forwarded to `Pyex.Ctx.new/1`).

  Returns `{:ok, value, ctx}` on success, or `{:error, reason}`.

  ## Options (when passing keyword list)

  - `:modules` -- custom Python modules available via `import`
  - `:filesystem` -- a filesystem backend struct (module derived automatically)
  - `:env` -- environment variables for `os.environ`
  - `:timeout_ms` -- compute time budget in milliseconds
  - `:network` -- network access policy for the `requests` module.
    Accepts a keyword list with `:allowed_hosts` (exact hostname match),
    `:allowed_url_prefixes`, `:allowed_methods` (default `["GET", "HEAD"]`),
    or `:dangerously_allow_full_internet_access`. When omitted,
    all network access is denied.
  - `:capabilities` -- list of enabled I/O capabilities (e.g.
    `[:boto3, :sql]`). All capabilities are denied by default.
  - `:boto3` -- shorthand for adding `:boto3` to capabilities.
  - `:sql` -- shorthand for adding `:sql` to capabilities.

  ## Examples

      {:ok, 42, _ctx} = Pyex.run("40 + 2")

      {:ok, ast} = Pyex.compile("40 + 2")
      {:ok, 42, _ctx} = Pyex.run(ast)

      {:ok, "hello world", _ctx} = Pyex.run(
        ~s|import mylib; mylib.greet("world")|,
        modules: %{
          "mylib" => %{
            "greet" => {:builtin, fn [name] -> "hello " <> name end}
          }
        })
  """
  @spec run(String.t() | Parser.ast_node(), Ctx.t() | keyword()) ::
          {:ok, Interpreter.pyvalue(), Ctx.t()}
          | {:error, Error.t()}
  def run(source_or_ast, ctx_or_opts \\ [])

  def run(source, ctx_or_opts) when is_binary(source) do
    case compile(source) do
      {:ok, ast} -> run(ast, ctx_or_opts)
      {:error, msg} -> {:error, Error.syntax(msg)}
    end
  end

  def run(ast, %Ctx{} = ctx) when is_tuple(ast) do
    start_mono = System.monotonic_time()

    :telemetry.execute([:pyex, :run, :start], %{system_time: System.system_time()}, %{})

    ctx = %{ctx | compute: 0.0, compute_started_at: System.monotonic_time()}
    result = Interpreter.run_with_ctx(ast, Builtins.env(), ctx)

    case result do
      {:ok, value, _env, final_ctx} ->
        duration_ms =
          System.convert_time_unit(System.monotonic_time() - start_mono, :native, :millisecond)

        :telemetry.execute([:pyex, :run, :stop], %{duration_ms: duration_ms}, %{
          compute: Ctx.compute_time(final_ctx)
        })

        {:ok, Interpreter.Helpers.to_python_view(value), final_ctx}

      {:error, msg} ->
        duration_ms =
          System.convert_time_unit(System.monotonic_time() - start_mono, :native, :millisecond)

        error = Error.from_message(msg)

        :telemetry.execute([:pyex, :run, :exception], %{duration_ms: duration_ms}, %{
          error: error
        })

        {:error, error}
    end
  end

  def run(ast, opts) when is_tuple(ast) and is_list(opts) do
    run(ast, Ctx.new(opts))
  end

  @doc """
  Runs Python code and returns the result directly.

  Raises on lexer, parser, or runtime errors. Accepts the
  same arguments as `run/2`.

  ## Examples

      42 = Pyex.run!("40 + 2")
      "hello" = Pyex.run!(ast, ctx)
  """
  @spec run!(String.t() | Parser.ast_node(), Ctx.t() | keyword()) :: Interpreter.pyvalue()
  def run!(source_or_ast, ctx_or_opts \\ []) do
    case run(source_or_ast, ctx_or_opts) do
      {:ok, result, _ctx} -> result
      {:error, %Error{message: msg}} -> raise msg
    end
  end

  @doc """
  Returns all captured print output as a single string.

  Python's `print()` records each line as an `:output` event
  in the context. This function extracts and joins them with newlines.

  ## Example

      {:ok, _val, ctx} = Pyex.run("print('hello')")
      "hello" = Pyex.output(ctx)

      {:ok, _val, ctx} = Pyex.run("print('line1')\nprint('line2')")
      "line1\nline2" = Pyex.output(ctx)
  """
  @spec output(Ctx.t()) :: String.t()
  def output(%Ctx{} = ctx), do: ctx |> Ctx.output() |> IO.iodata_to_binary()
end
