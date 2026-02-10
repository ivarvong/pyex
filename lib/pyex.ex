defmodule Pyex do
  @moduledoc """
  A Python 3 interpreter written in Elixir.

  Designed as a capabilities-based sandbox for LLMs
  to safely run compute. Supports Temporal-style suspend,
  resume, and branch via `Pyex.Ctx` event logging.

  ## Quick start

      {:ok, 5, _ctx} = Pyex.run("2 + 3")
      5 = Pyex.run!("2 + 3")

  ## Pipeline

  Source code flows through two stages:

      source  ->  Pyex.compile/1  ->  ast
      ast     ->  Pyex.run/2      ->  result

  When the same source will be executed many times (e.g. a
  FastAPI handler), compile once and pass the AST to `run/2`
  to skip lexing and parsing.

  ## Context

  Every execution threads a `Pyex.Ctx` which carries the
  filesystem, environment variables, custom modules, compute
  budget, and event log. Pass a `Ctx` or keyword opts as the
  second argument to `run/2`:

      ctx = Pyex.Ctx.new(filesystem: fs, fs_module: Memory)
      {:ok, result, ctx} = Pyex.run(source, ctx)

      {:ok, result, _ctx} = Pyex.run(source,
        modules: %{"mylib" => %{"greet" => {:builtin, fn [n] -> "hi " <> n end}}})
  """

  alias Pyex.{Builtins, Ctx, Error, Lexer, Parser, Interpreter}

  require OpenTelemetry.Tracer, as: Tracer

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

  Returns `{:ok, value, ctx}` on success, `{:suspended, ctx}`
  if the program called `suspend()`, or `{:error, reason}`.

  ## Options (when passing keyword list)

  - `:modules` -- custom Python modules available via `import`
  - `:filesystem` -- a filesystem backend struct
  - `:fs_module` -- the module implementing `Pyex.Filesystem`
  - `:environ` -- environment variables for `os.environ`
  - `:timeout_ms` -- compute time budget in milliseconds
  - `:network` -- network access policy for the `requests` module.
    Accepts a keyword list with `:allowed_hosts` (exact hostname match),
    `:allowed_url_prefixes`, `:allowed_methods` (default `["GET", "HEAD"]`),
    or `:dangerously_allow_full_internet_access`. When omitted,
    all network access is denied.
  - `:boto3` -- when `true`, enables the `boto3` module to make S3
    API calls. Default `false` (all S3 operations raise `PermissionError`).
  - `:sql` -- when `true`, enables the `sql` module to execute
    database queries. Default `false` (all queries raise `PermissionError`).

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
          | {:suspended, Ctx.t()}
          | {:error, Error.t()}
  def run(source_or_ast, ctx_or_opts \\ [])

  def run(source, ctx_or_opts) when is_binary(source) do
    case compile(source) do
      {:ok, ast} -> run(ast, ctx_or_opts)
      {:error, msg} -> {:error, Error.syntax(msg)}
    end
  end

  def run(ast, %Ctx{} = ctx) when is_tuple(ast) do
    Tracer.with_span "pyex.run", %{} do
      ctx = %{ctx | compute_ns: 0, compute_started_at: System.monotonic_time(:nanosecond)}
      result = Interpreter.run_with_ctx(ast, Builtins.env(), ctx)

      case result do
        {:ok, value, _env, final_ctx} ->
          Tracer.set_attribute("pyex.compute_us", Ctx.compute_time_us(final_ctx))
          {:ok, value, final_ctx}

        {:suspended, _env, final_ctx} ->
          {:suspended, final_ctx}

        {:error, msg} ->
          {:error, Error.from_message(msg)}
      end
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
      {:suspended, _ctx} -> raise "program suspended"
      {:error, %Error{message: msg}} -> raise msg
    end
  end

  @doc """
  Resumes a suspended program from a context.

  The source must be the same source that was originally
  executed. The interpreter replays the event log to
  reconstruct state, then continues live execution.
  """
  @spec resume(String.t(), Ctx.t()) ::
          {:ok, Interpreter.pyvalue(), Ctx.t()}
          | {:suspended, Ctx.t()}
          | {:error, Error.t()}
  def resume(source, %Ctx{} = ctx) when is_binary(source) do
    with {:ok, ast} <- compile(source) do
      run(ast, Ctx.for_resume(ctx))
    end
  end

  @doc """
  Returns the event log from a context as a list of
  `{type, step, data}` tuples.
  """
  @spec events(Ctx.t()) :: [Ctx.event()]
  def events(%Ctx{} = ctx), do: Ctx.events(ctx)

  @doc """
  Returns all captured print output as a single string.

  Python's `print()` records each line as an `:output` event
  in the context. This function extracts and joins them.

  ## Example

      {:ok, _val, ctx} = Pyex.run("print('hello')")
      "hello" = Pyex.output(ctx)
  """
  @spec output(Ctx.t()) :: String.t()
  def output(%Ctx{} = ctx), do: Ctx.output(ctx)

  @doc """
  Returns the profile data from a context, or `nil` if profiling
  was not enabled.

  The profile is a map with:
  - `:line_counts` -- `%{line_number => execution_count}`
  - `:call_counts` -- `%{function_name => call_count}`
  - `:call_us` -- `%{function_name => total_microseconds}`

  ## Example

      {:ok, _val, ctx} = Pyex.run(source, profile: true)
      %{line_counts: lines, call_counts: calls, call_us: timing} = Pyex.profile(ctx)
  """
  @spec profile(Ctx.t()) :: Ctx.profile_data() | nil
  def profile(%Ctx{profile: profile}), do: profile
end
