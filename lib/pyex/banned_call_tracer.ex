defmodule Pyex.BannedCallTracer do
  @moduledoc """
  Detects banned remote function calls by inspecting compiled BEAM files.

  Rather than re-compiling source, this module reads the abstract code
  (debug info) from already-compiled `.beam` files and walks the call
  tree looking for banned calls. No recompilation, no module-redefinition
  warnings, no load-order problems.

  ## Security model

  Pyex is a **library, not an application** — it owns no global state and
  must not use processes or message passing (see AGENTS.md). All execution
  is purely functional: state threads through `{val, env, ctx}` tuples.
  The banned categories are:

  ### Process creation and process dictionary
  Pyex must not spawn or communicate with OS or Erlang processes, and must
  not use the process dictionary as a side channel. Spawning creates hidden
  shared state; the process dict violates the purely functional contract.

  ### Filesystem (`File`, `:file`)
  Any call into `File.*` or the Erlang `:file` module. Filesystem access
  goes through the pluggable `Pyex.Filesystem` behaviour so callers can
  inject Memory or S3 backends. Direct `File.*` calls would bypass that.

  ### Environment (`System.get_env`, `System.put_env`, `System.delete_env`)
  Real OS environment variables are not visible to sandboxed code.
  `ctx.env` (a plain map) is the sandboxed environment.

  ### OS process spawning (`System.cmd`, `System.shell`, `Port`, `:os.cmd`)
  Spawning real OS processes would escape the sandbox entirely.

  ### Node escape (`Node`)
  Connecting to remote Erlang nodes bypasses all local sandboxing.

  ## Allowlist

  Some uses inside the stdlib shims are legitimate and explicitly allowed:

  - `Process.sleep/1` — `time.sleep()` must actually block the calling process.
  - `Task.async/1`, `Task.yield/2`, `Task.shutdown/2` — the regex engine uses
    a supervised task to enforce a per-call timeout. This is an internal safety
    mechanism, not user-visible concurrency.
  - `GenServer.stop/1` — `sql.query()` manages a short-lived Postgrex connection
    process per call and tears it down immediately after use.
  - `:os.system_time/1` — `time.time()` and `time.time_ns()` must read the real
    wall clock.

  ## What this catches

  - Direct calls: `File.read(path)`, `System.cmd("rm", [...])`
  - Calls through Elixir aliases (resolved before compilation)
  - `apply/3` and `:erlang.apply/3` when both module and function
    are literal atoms, e.g. `apply(File, :read, [path])`

  ## What this cannot catch

  Dynamic dispatch where the module or function is a runtime variable:

      mod = File
      mod.read(path)           # module is a variable — opaque to static analysis
      fun = :read
      apply(File, fun, [path]) # function is a variable — opaque

  This is acceptable: there is no legitimate reason for Pyex library code to
  hold a reference to `File` or `Process` in a variable.
  """

  # Entire modules whose every function is banned.
  @banned_modules [
    File,
    :file,
    Port,
    Node,
    Agent,
    GenServer,
    Supervisor,
    Task,
    Process
  ]

  # Specific functions banned within modules that have some safe functions.
  @banned_functions [
    # Environment
    {System, :get_env, 1},
    {System, :get_env, 2},
    {System, :put_env, 2},
    {System, :put_env, 3},
    {System, :delete_env, 1},
    # OS process spawning
    {System, :cmd, 2},
    {System, :cmd, 3},
    {System, :shell, 1},
    {System, :shell, 2},
    # Erlang-level OS / port escape
    {:os, :cmd, 1},
    {:os, :cmd, 2},
    {:erlang, :open_port, 2},
    # Direct spawn variants
    {:erlang, :spawn, 1},
    {:erlang, :spawn, 3},
    {:erlang, :spawn_link, 1},
    {:erlang, :spawn_link, 3},
    {:erlang, :spawn_monitor, 1},
    {:erlang, :spawn_monitor, 3},
    # Process dictionary — violates purely functional contract
    {:erlang, :get, 0},
    {:erlang, :get, 1},
    {:erlang, :put, 2},
    {:erlang, :erase, 0},
    {:erlang, :erase, 1}
  ]

  # Calls that look banned by module but are explicitly permitted.
  # Entries are {module, function, arity}.
  @allowed [
    # time.sleep() must block the calling process
    {Process, :sleep, 1},
    # regex timeout — supervised Task for per-call safety enforcement
    {Task, :async, 1},
    {Task, :yield, 2},
    {Task, :shutdown, 2},
    # sql stdlib — short-lived Postgrex connection per call
    {GenServer, :stop, 1},
    {GenServer, :stop, 3},
    # wall clock reads — no side effects, no shared state
    {:os, :system_time, 1}
  ]

  @type violation :: %{
          call: {module(), atom(), arity()},
          beam: Path.t(),
          line: non_neg_integer()
        }

  @doc """
  Checks all `.beam` files under `beam_dir` for banned calls.

  Returns a list of violations. An empty list means the library
  is clean.
  """
  @spec check_app(Path.t()) :: [violation()]
  def check_app(beam_dir \\ "_build/test/lib/pyex/ebin") do
    beam_dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(&check_beam/1)
  end

  @doc """
  Checks a single `.beam` file for banned calls.
  """
  @spec check_beam(Path.t()) :: [violation()]
  def check_beam(beam_path) do
    path_charlist = String.to_charlist(beam_path)

    case :beam_lib.chunks(path_charlist, [:abstract_code]) do
      {:ok, {_mod, [{:abstract_code, {:raw_abstract_v1, abstract_code}}]}} ->
        walk(abstract_code, beam_path, [])

      {:ok, {_mod, [{:abstract_code, :no_debug_info}]}} ->
        []

      {:error, :beam_lib, _reason} ->
        []
    end
  end

  # Walk the abstract code tree collecting banned remote calls.
  # Abstract code is Erlang's internal AST — tuples all the way down.

  # apply(Mod, :fun, [...]) and :erlang.apply(Mod, :fun, [...])
  # When mod and fun are literal atoms we can determine the effective call statically.
  defp walk(
         {:call, ann, {:remote, _, {:atom, _, :erlang}, {:atom, _, :apply}},
          [{:atom, _, mod}, {:atom, _, fun}, args_list]},
         beam,
         acc
       ) do
    arity = list_length(args_list)
    line = :erl_anno.line(ann)

    acc =
      if arity != :unknown and banned?(mod, fun, arity) do
        [%{call: {mod, fun, arity}, beam: beam, line: line} | acc]
      else
        acc
      end

    walk(args_list, beam, acc)
  end

  # Direct remote call: Mod.fun(args...)
  defp walk({:call, ann, {:remote, _, {:atom, _, mod}, {:atom, _, fun}}, args}, beam, acc) do
    arity = length(args)
    line = :erl_anno.line(ann)

    acc =
      if banned?(mod, fun, arity) do
        [%{call: {mod, fun, arity}, beam: beam, line: line} | acc]
      else
        acc
      end

    Enum.reduce(args, acc, &walk(&1, beam, &2))
  end

  defp walk(tuple, beam, acc) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.reduce(acc, &walk(&1, beam, &2))
  end

  defp walk(list, beam, acc) when is_list(list) do
    Enum.reduce(list, acc, &walk(&1, beam, &2))
  end

  defp walk(_other, _beam, acc), do: acc

  @spec banned?(module(), atom(), arity()) :: boolean()
  defp banned?(mod, fun, arity) do
    not allowed?(mod, fun, arity) and
      (mod in @banned_modules or {mod, fun, arity} in @banned_functions)
  end

  @spec allowed?(module(), atom(), arity()) :: boolean()
  defp allowed?(mod, fun, arity), do: {mod, fun, arity} in @allowed

  # Count elements of an abstract code list (cons cells) to determine arity.
  # Returns :unknown if the list is not fully literal.
  defp list_length({nil, _}), do: 0
  defp list_length({:cons, _, _head, tail}), do: add_one(list_length(tail))
  defp list_length(_), do: :unknown

  defp add_one(:unknown), do: :unknown
  defp add_one(n), do: n + 1
end
