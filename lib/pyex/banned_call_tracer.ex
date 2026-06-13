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
  goes through the pluggable [`VFS`](https://hexdocs.pm/vfs) backend (see
  `Pyex.FS`) so callers can inject in-memory or S3 filesystems. Direct
  `File.*` calls would bypass that.

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
  - `Task.async_stream/3` — `asyncio.gather` over `{:awaitable, _}` capabilities
    fans the queued capability calls out as parallel BEAM Tasks via
    `Task.async_stream`. The Tasks run host-registered functions only — the
    Pyex interpreter itself never spawns. Task lifetimes are bounded by the
    duration of the gather call (`timeout: :infinity` is safe because the
    outer Pyex limits enforce wall-clock at the call boundary).
  - `GenServer.stop/1` — `sql.query()` manages a short-lived Postgrex connection
    process per call and tears it down immediately after use.
  - `:os.system_time/1` — `time.time()` and `time.time_ns()` must read the real
    wall clock.

  ## What this catches

  - Direct calls: `File.read(path)`, `System.cmd("rm", [...])`
  - Calls through Elixir aliases (resolved before compilation)
  - `apply/3` and `:erlang.apply/3` when both module and function
    are literal atoms, e.g. `apply(File, :read, [path])`
  - Literal function captures like `&File.read/1` (the captured M/F/A
    is fully known at compile time, even if the capture is never
    invoked through a variable — a captured-but-unused dangerous
    reference is still a red flag in pyex library code).

  ## `:erlang` is allowlisted, not denylisted

  Unlike other modules, `:erlang` has a vast surface where most BIFs
  are pure (arithmetic, type guards, conversions) and are emitted by
  the Elixir compiler implicitly.  A denylist on `:erlang` is leaky
  by construction: any new dangerous BIF added in a future OTP would
  silently pass.  Instead, pyex library code may only call BIFs in
  `@erlang_allowed`.  Adding a new BIF requires an explicit allowlist
  entry — the test will tell you if you missed one.

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
  # Note: `:erlang` is *not* in this list — it is handled by the allowlist
  # in `@erlang_allowed` because its BIF surface is too large and dangerous
  # for a denylist to be exhaustive.
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
    # Erlang-level OS escape
    {:os, :cmd, 1},
    {:os, :cmd, 2}
  ]

  # Allowlist of `:erlang` BIFs pyex library code may call.  Adding a
  # new entry requires the same justification as removing one from a
  # denylist: confirm the BIF is pure and side-effect free.  Categories:
  #
  # - Arithmetic / numeric / comparison operators emitted by the
  #   Elixir compiler for `+`, `-`, `*`, `/`, `++`, `--`, `abs`,
  #   `ceil`, `floor`, `round`, `trunc`, `max`, `min`, `float`.
  # - Type guards and introspection (`is_*`, `byte_size`, `length`,
  #   `tuple_size`, `map_size`, `element`, `hd`, `tl`, `map_get`,
  #   `setelement`, `tuple_to_list`, `list_to_tuple`).
  # - Pure conversions (`*_to_binary`, `binary_to_*`, `binary_part`,
  #   `iolist_to_binary`).
  # - Reflection (`fun_info`, `function_exported`, `get_module_info`).
  # - Pure hashing / unique identifiers
  #   (`crc32`, `phash2`, `unique_integer`, `make_ref`).
  # - Wall clock / VM stat reads with no side effects on the caller
  #   (`monotonic_time`, `system_time`, `memory`).
  # - Error raising (`error`, `raise`, `throw`) — pyex *must* be able
  #   to raise Elixir exceptions; the AGENTS.md "no throw/catch for
  #   control flow" rule is about pyex semantics, not Elixir errors.
  #
  # Explicitly *not* on this list (and therefore banned for pyex
  # library code, the same way `File.*` is banned):
  #
  # - Process spawning: `spawn/1,3`, `spawn_link/1,3`, `spawn_monitor/1,3`,
  #   `spawn_opt/*`.
  # - Process dictionary: `get/0,1`, `put/2`, `erase/0,1`.
  # - Process plumbing: `self/0`, `send/2`, `send_after/3,4`, `exit/1,2`,
  #   `register/2`, `unregister/1`, `group_leader/0,1`.
  # - Port escape: `open_port/2`, `port_close/1`, `port_command/2,3`,
  #   `port_control/3`, `port_info/1,2`, `port_call/3`.
  # - VM teardown: `halt/0,1,2`.
  # - Atom-table / term-deserialization DoS: `list_to_atom/1`,
  #   `binary_to_atom/1,2`, `binary_to_term/1,2`.
  # - Node escape: `node/0,1`, `nodes/0,1`, `disconnect_node/1`,
  #   `monitor_node/2`, `set_cookie/1,2`.
  @erlang_allowed MapSet.new([
                    # arithmetic / numeric / comparison operators emitted
                    # by the Elixir compiler (`+`, `*`, `++`, `--`, etc.)
                    # and used as captures (`&+/2`, `&*/2`).
                    {:+, 2},
                    {:*, 2},
                    {:++, 2},
                    {:--, 2},
                    {:abs, 1},
                    {:ceil, 1},
                    {:floor, 1},
                    {:round, 1},
                    {:trunc, 1},
                    {:max, 2},
                    {:min, 2},
                    {:float, 1},
                    # type guards and introspection
                    {:is_atom, 1},
                    {:is_binary, 1},
                    {:is_boolean, 1},
                    {:is_float, 1},
                    {:is_function, 1},
                    {:is_function, 2},
                    {:is_integer, 1},
                    {:is_list, 1},
                    {:is_map, 1},
                    {:is_map_key, 2},
                    {:is_number, 1},
                    {:is_tuple, 1},
                    {:byte_size, 1},
                    {:length, 1},
                    {:map_size, 1},
                    {:tuple_size, 1},
                    {:element, 2},
                    {:hd, 1},
                    {:tl, 1},
                    {:map_get, 2},
                    {:setelement, 3},
                    {:tuple_to_list, 1},
                    {:list_to_tuple, 1},
                    # conversions
                    {:atom_to_binary, 1},
                    {:binary_part, 3},
                    {:binary_to_float, 1},
                    {:binary_to_integer, 1},
                    {:binary_to_integer, 2},
                    {:float_to_binary, 2},
                    {:integer_to_binary, 1},
                    {:integer_to_binary, 2},
                    {:iolist_to_binary, 1},
                    {:list_to_binary, 1},
                    # reflection
                    {:fun_info, 1},
                    {:function_exported, 3},
                    {:get_module_info, 2},
                    # pure hashing / unique ids
                    {:crc32, 1},
                    {:phash2, 1},
                    {:make_ref, 0},
                    {:unique_integer, 0},
                    {:unique_integer, 1},
                    # wall clock / VM stat reads (no side effects on others)
                    {:monotonic_time, 0},
                    {:monotonic_time, 1},
                    {:system_time, 0},
                    # error raising — Elixir `raise` compiles to these
                    {:error, 1},
                    {:error, 3},
                    {:raise, 3},
                    {:throw, 1}
                  ])

  # Calls that look banned by module but are explicitly permitted.
  # Entries are {module, function, arity}.
  @allowed [
    # time.sleep() must block the calling process
    {Process, :sleep, 1},
    # regex timeout — supervised Task for per-call safety enforcement
    {Task, :async, 1},
    {Task, :yield, 2},
    {Task, :shutdown, 2},
    # asyncio.gather over {:awaitable, _} capabilities — parallel
    # dispatch of host-registered tools.  Pyex itself never spawns;
    # the Tasks run host code with bounded lifetimes.
    {Task, :async_stream, 3},
    # sql stdlib — short-lived Postgrex connection per call
    {GenServer, :stop, 1},
    {GenServer, :stop, 3},
    # wall clock reads — no side effects, no shared state
    {:os, :system_time, 1}
  ]

  @type violation :: %{
          call: {module(), atom(), arity()} | :no_debug_info,
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

      {:ok, {_mod, [{:abstract_code, missing}]}}
      when missing in [:no_debug_info, :no_abstract_code] ->
        # A BEAM without abstract code cannot be inspected — the tracer
        # would see *nothing* and silently report the module clean,
        # voiding the whole security gate.  `:no_debug_info` means the
        # module was compiled without `+debug_info`; `:no_abstract_code`
        # means the chunk was later stripped (e.g. `strip_beams: true`
        # in a release).  Either way, surface as a violation so the check
        # fails loudly instead of quietly passing.
        [%{call: :no_debug_info, beam: beam_path, line: 0}]

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

  # Literal external function capture: `&Mod.fun/arity`
  # Compiles to a `:fun` node referencing the M/F/A.  The capture is
  # *itself* a reference, not a call, but holding a reference to a
  # banned function in pyex library code is just as much a red flag
  # as calling it (the function will be invoked through the variable
  # later, in a form opaque to static analysis).
  defp walk(
         {:fun, ann, {:function, {:atom, _, mod}, {:atom, _, fun}, {:integer, _, arity}}},
         beam,
         acc
       ) do
    line = :erl_anno.line(ann)

    if banned?(mod, fun, arity) do
      [%{call: {mod, fun, arity}, beam: beam, line: line} | acc]
    else
      acc
    end
  end

  defp walk(tuple, beam, acc) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.reduce(acc, &walk(&1, beam, &2))
  end

  defp walk(list, beam, acc) when is_list(list) do
    Enum.reduce(list, acc, &walk(&1, beam, &2))
  end

  defp walk(_other, _beam, acc), do: acc

  @spec banned?(module(), atom(), arity()) :: boolean()
  defp banned?(:erlang, fun, arity) do
    not MapSet.member?(@erlang_allowed, {fun, arity})
  end

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
