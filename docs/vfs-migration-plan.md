# Pyex VFS migration plan — integrating with JustBash without depending on it

**Constraint:** JustBash is fixed as-is. Pyex adapts. Pyex must not
hard-depend on JustBash — standalone use matters.

**End state:** `%Pyex.Ctx{fs: bash.fs}` Just Works. Python's
`open("/foo")` reads the same bytes as bash's `cat /foo`, including
when `/foo` lives inside a `ReadOnlyFS` decorator, an S3 mount, or a
future GitFS / OverlayFS mount in bash's mount table. No copy, no
translation, no bridge.

## 1. The core idea

Pyex has its own full virtual filesystem — mount-table dispatcher,
pluggable backends, `ReadOnlyFS` decorator, synthetic-mountpoint
visibility, cross-mount `cp`/`mv`/`ln -s` semantics. Everything
JustBash's FS has, pyex has too. Pyex stands alone.

Compat with JustBash is **at the data shape**, not at the type
level. `%Pyex.FS{}` and `%JustBash.FS{}` are distinct struct types
with bit-identical internal representations:

- Both are `%_{mounts: [...]}`.
- Every mount entry is a `{mountpoint, module, state}` tuple.
- Every backend module (from either library) is called by name —
  `mod.read_file(state, path)` etc. — and works unchanged in either
  dispatcher because the callback signatures are the same.

That gives us interop at the JustBash integration boundary via
a single struct-field copy, no per-callback bridging:

```elixir
# bash → pyex
ctx = Pyex.Ctx.new(fs: %Pyex.FS{mounts: bash.fs.mounts}, ...)

# pyex → bash
%{bash | fs: %JustBash.FS{mounts: ctx.fs.mounts}}
```

Mount entries pass through untouched. A mount like
`{"/project", JustBash.FS.ReadOnlyFS, state}` from bash works inside
pyex's dispatcher — pyex calls `JustBash.FS.ReadOnlyFS.read_file(
state, backend_path)` by name, and `JustBash.FS.ReadOnlyFS` happens
to have that function with the right signature. Symmetric for pyex
backends when bash runs against the shared FS.

### 1.1 Why not "just use the same struct"

Considered: `%Pyex.FS{}` = alias for `%JustBash.FS{}`. Rejected
because it requires pyex to hard-depend on JustBash, and pyex's
standalone use case (Python sandbox without any shell) matters.

Considered: dispatching pyex's stdlib via `fs.__struct__.read_file(
fs, path)` so `ctx.fs` can be any struct with the right public
functions. Rejected because it defeats pyex's own dispatcher (pyex
wouldn't know when to use `Pyex.FS.*` versus the struct's module
directly), and Dialyzer can't see through dynamic module dispatch.

Struct-shape compat with a two-line boundary conversion gives us:

- Pyex is fully standalone (its own dispatcher, own backends).
- Zero dep on JustBash in pyex's module graph.
- Interop that costs O(1) at the boundary and preserves backend
  state identity (no deep copy, no backend re-wrap).
- Typed dispatch inside pyex (`Pyex.FS.read_file(ctx.fs, path)` is
  a direct, statically-dispatched call).

## 2. What we're keeping identical to JustBash

The callback surface is copied verbatim from `JustBash.FS.Backend`,
not because we want interop for its own sake but because these
callbacks are the right shape for implementing Python's `open`,
`os.*`, `pathlib`, `shutil`, and `glob` correctly.

- **14 callbacks.** `exists?/2`, `stat/2`, `lstat/2`, `read_file/2`,
  `write_file/4`, `append_file/3`, `mkdir/3`, `readdir/2`, `rm/3`,
  `chmod/3`, `symlink/3`, `readlink/2`, `link/3`.
- **POSIX-atom errors.** `:enoent`, `:eisdir`, `:enotdir`, `:eexist`,
  `:eacces`, `:erofs`, `:exdev`, `:einval`, `:eloop`.
- **Absolute paths.** Always begin with `/`. Root is `/`.
- **State-threaded mutations.** `{:ok, new_state} | {:error, reason}`
  for any op that mutates.
- **stat_result shape.** Same keys as JustBash's — `is_file`,
  `is_directory`, `is_symbolic_link`, `mode`, `size`, `mtime`.

The `stat`/`lstat` return, the write/mkdir/rm opts, and the
stat_result struct all match JustBash bit-for-bit.

## 3. What we're explicitly not doing

- **No per-callback bridge module.** The original plan had
  `Pyex.FS.JustBashBridge` wrapping a `%JustBash.FS{}` inside a pyex
  mount with 14 forwarding functions. Replaced with a two-line
  struct-field copy at the custom-command boundary.
- **No hard dep on JustBash from pyex.** `mix.exs` lists JustBash as
  an optional dep; the `Pyex.JustBashCommand` module is the only
  place JustBash types appear, and it compile-guards on
  `Code.ensure_loaded?(JustBash.Commands.Command)` so pyex
  compiles and passes its own tests without the dep installed.
- **No Pyex.Filesystem coexistence phase.** Single-cutover rename.
  Pyex is pre-1.0 and every call site is internal.
- **No port of NullFS.** JustBash ships it as a test fixture only.
  If pyex tests end up wanting a `/dev/null`-style sink, we add
  it then.

## 4. Module layout after the cutover

| Current                       | After                         | Notes                                        |
|-------------------------------|-------------------------------|----------------------------------------------|
| `Pyex.Filesystem`             | `Pyex.FS.Backend`             | 14 callbacks, POSIX errors — byte-compat     |
| `Pyex.Filesystem.Memory`      | `Pyex.FS.InMemoryFS`          | Port of `JustBash.FS.InMemoryFS`             |
| `Pyex.Filesystem.S3`          | `Pyex.FS.S3FS`                | Rewritten in follow-up PR; shim during PR 1  |
| _(new)_                       | `Pyex.FS`                     | Mount-table dispatcher + path helpers        |
| _(new)_                       | `Pyex.FS.ReadOnlyFS`          | Port of JustBash's decorator                 |
| _(new)_                       | `Pyex.FS.Errors`              | atom → Python exception                      |
| _(new)_                       | `Pyex.JustBashCommand`        | Custom-command adapter (PR 2)                |

### 4.1 `Pyex.FS` — full mount-table dispatcher

Ported verbatim from
`/Users/ivar/code/just_bash/lib/just_bash/fs/fs.ex` (~765 lines) with
`JustBash.FS` → `Pyex.FS`, `JustBash.FS.InMemoryFS` →
`Pyex.FS.InMemoryFS`. Do not rewrite — the logic is non-trivial
(longest-prefix match, synthetic-mountpoint visibility, cross-mount
`cp`, refused cross-mount `mv`/`ln -s`, state threading by mount
index) and bug-for-bug parity with JustBash is what makes the
boundary conversion safe.

**What to port:**

- `%Pyex.FS{mounts: [{mountpoint, module, state}]}` struct.
- `new/0`, `new/1` (map seeds InMemoryFS root; `root: {mod, state}`
  custom root).
- `mount/3`, `umount/2`, `mounts/1`.
- `normalize_path/1`, `dirname/1`, `basename/1`, `resolve_path/2`.
- All 14 dispatcher functions: `exists?/2`, `stat/2`, `lstat/2`,
  `read_file/2`, `write_file/3,4`, `append_file/3`, `mkdir/2,3`,
  `readdir/2`, `rm/2,3`, `chmod/3`, `symlink/3`, `readlink/2`,
  `link/3`.
- Composed ops: `cp/3,4`, `mv/3`.
- `get_all_paths/1`.
- Private helpers: `resolve/2`, `put_mount_state/3`, `mountpoint?/2`,
  `has_descendant_mount?/2`, `child_mount_basenames/2`,
  `symlink_crosses_mount?/4`, `synthetic_dir_stat/0`.

### 4.2 `Pyex.FS.Backend`

```elixir
defmodule Pyex.FS.Backend do
  @type state :: term()
  @type path :: String.t()          # always begins with "/"
  @type reason :: atom()             # POSIX-style

  @type stat_result :: %{
          is_file: boolean(),
          is_directory: boolean(),
          is_symbolic_link: boolean(),
          mode: non_neg_integer(),
          size: non_neg_integer(),
          mtime: DateTime.t()
        }

  @type write_opts :: [mode: non_neg_integer(), mtime: DateTime.t()]
  @type mkdir_opts :: [recursive: boolean()]
  @type rm_opts :: [recursive: boolean(), force: boolean()]

  @callback exists?(state, path) :: boolean()
  @callback stat(state, path) :: {:ok, stat_result} | {:error, reason}
  @callback lstat(state, path) :: {:ok, stat_result} | {:error, reason}
  @callback read_file(state, path) :: {:ok, binary} | {:error, reason}
  @callback write_file(state, path, binary, write_opts) ::
              {:ok, state} | {:error, reason}
  @callback append_file(state, path, binary) ::
              {:ok, state} | {:error, reason}
  @callback mkdir(state, path, mkdir_opts) ::
              {:ok, state} | {:error, reason}
  @callback readdir(state, path) :: {:ok, [String.t()]} | {:error, reason}
  @callback rm(state, path, rm_opts) :: {:ok, state} | {:error, reason}
  @callback chmod(state, path, non_neg_integer()) ::
              {:ok, state} | {:error, reason}
  @callback symlink(state, path, path) :: {:ok, state} | {:error, reason}
  @callback readlink(state, path) :: {:ok, path} | {:error, reason}
  @callback link(state, path, path) :: {:ok, state} | {:error, reason}
end
```

Byte-identical to `JustBash.FS.Backend`. A conformance test
guards against drift (only runs when JustBash happens to be loaded
in the test env):

```elixir
test "Pyex.FS.Backend callback list matches JustBash.FS.Backend" do
  if Code.ensure_loaded?(JustBash.FS.Backend) do
    pyex = Pyex.FS.Backend.behaviour_info(:callbacks) |> MapSet.new()
    jb   = JustBash.FS.Backend.behaviour_info(:callbacks) |> MapSet.new()
    assert pyex == jb
  end
end
```

### 4.3 `Pyex.FS.InMemoryFS`

Ported from `/Users/ivar/code/just_bash/lib/just_bash/fs/in_memory_fs.ex`
verbatim. Rename the module, drop the soft-deprecated path-helper
shims JustBash keeps for backward compat. Everything else copies.

### 4.4 `Pyex.FS.ReadOnlyFS`

Ported from `/Users/ivar/code/just_bash/lib/just_bash/fs/read_only_fs.ex`
verbatim (~83 lines). Decorator that wraps another backend as
`{module, state}` and rejects writes with `:erofs`. Useful for
exposing immutable snapshots to pyex — same role it has in JustBash.

### 4.5 `Pyex.FS.Errors`

```elixir
defmodule Pyex.FS.Errors do
  @doc "Maps an FS error atom + path to a Python-style exception tuple."
  def to_python(:enoent, path),
    do: {"FileNotFoundError",
         "[Errno 2] No such file or directory: '#{path}'"}
  def to_python(:eisdir, path),
    do: {"IsADirectoryError",
         "[Errno 21] Is a directory: '#{path}'"}
  def to_python(:enotdir, path),
    do: {"NotADirectoryError",
         "[Errno 20] Not a directory: '#{path}'"}
  def to_python(:eexist, path),
    do: {"FileExistsError",
         "[Errno 17] File exists: '#{path}'"}
  def to_python(:eacces, path),
    do: {"PermissionError",
         "[Errno 13] Permission denied: '#{path}'"}
  def to_python(:erofs, path),
    do: {"OSError",
         "[Errno 30] Read-only file system: '#{path}'"}
  def to_python(:exdev, path),
    do: {"OSError",
         "[Errno 18] Invalid cross-device link: '#{path}'"}
  def to_python(:einval, path),
    do: {"OSError",
         "[Errno 22] Invalid argument: '#{path}'"}
  # ...
end
```

Stdlib callers (`Pyex.Stdlib.Pathlib`, `Pyex.Stdlib.Shutil`, etc.)
use this to build Python exceptions. The FS layer itself returns
atoms — language-agnostic.

## 5. Call sites to rewrite

From `grep -rln "filesystem\|Filesystem" lib/`:

**Core**
- `lib/pyex/ctx.ex` — field rename `:filesystem` → `:fs`,
  `Ctx.new/1` opt rename `filesystem:` → `fs:`. `open_handle/3` and
  `close_handle/2` switch to `Pyex.FS.read_file`/`write_file`.
- `lib/pyex/path.ex` — remove `%Pyex.Filesystem.Memory{}` pattern
  matches. `mkdir_p`/`delete_tree` become `Pyex.FS.mkdir(fs, p,
  recursive: true)` / `Pyex.FS.rm(fs, p, recursive: true, force: true)`.

**Stdlib**
- `lib/pyex/stdlib/pathlib.ex` — ~12 call sites. Each `ctx.filesystem.*`
  → `Pyex.FS.*`. Error atoms → `Pyex.FS.Errors.to_python` → Python
  exception. `is_file`/`is_dir` switch from the ad-hoc
  `exists? + not list_dir` dance to `stat/2` on the `is_directory` key.
- `lib/pyex/stdlib/shutil.ex` — `copy`, `copytree`, `move`, `rmtree`.
  Use `Pyex.FS.cp`/`mv`/`rm`. Wait — `cp` and `mv` aren't in our
  contract (they're composed ops in JustBash, not backend callbacks).
  See §5.1.
- `lib/pyex/stdlib/glob.ex` — `readdir/2` + recursive descent via
  `stat/2`.
- `lib/pyex/stdlib/jinja2.ex` — loader uses `read_file/2`.

**Import machinery**
- `lib/pyex/interpreter/import.ex` — file lookup uses `read_file/2`.
  Line 101 error-hint string references `Pyex.Filesystem.Memory` —
  update text.

**Tooling / docstrings**
- `lib/mix/tasks/pyex.bench.ex` — constructor change.
- `lib/pyex/banned_call_tracer.ex`, `lib/pyex/lambda.ex`,
  `lib/pyex/error.ex` — docstring / error-message references.

**Tests** — ~10–15 files. Mechanical find-and-replace.

### 5.1 `cp` and `mv` — composed ops on the dispatcher

Neither is a backend callback. `Pyex.FS.cp/3,4` and `Pyex.FS.mv/3`
are dispatcher-level functions — ported verbatim from JustBash's
composed cp/mv — so they handle cross-mount semantics (cp via
read+write across mounts; mv refused across mounts with `:exdev`)
using the dispatcher's mount-table knowledge. `shutil.copy`/`move`
call them directly.

## 6. Rollout plan

**Three PRs, landed in order.**

### PR 1 — FS layer cutover

One branch, one atomic change. Pre-1.0 + all internal callers + dense
test suite = no value in incremental-compile-green phases.

1. Add `lib/pyex/fs.ex`, `lib/pyex/fs/backend.ex`,
   `lib/pyex/fs/in_memory_fs.ex`, `lib/pyex/fs/errors.ex`.
2. Rewrite every call site in §5. Rename `:filesystem` →
   `:fs` on `%Pyex.Ctx{}`. Rename keyword opts.
3. Temporary compat shim for `Pyex.FS.S3FS` — keep the OLD
   `Pyex.Filesystem.S3` module alive under its original name,
   wrap it in a thin adapter `Pyex.FS.LegacyS3FS` that translates
   to the new behaviour. Don't rewrite S3 yet — it's a significant
   chunk of work (§6.3) and shouldn't block the main cutover.
4. Delete `lib/pyex/filesystem.ex` and `lib/pyex/filesystem/memory.ex`.
   Leave `lib/pyex/filesystem/s3.ex` alone pending PR 3.
5. Tests, docs, `UPGRADING.md`. `grep -rn "Pyex.Filesystem" lib/ test/`
   returns zero.
6. `mix format && mix compile --warnings-as-errors && mix test` green.

### PR 2 — JustBash custom-command integration

Depends on PR 1. Adds the actual motivating feature.

1. `lib/pyex/just_bash_command.ex` — implements
   `JustBash.Commands.Command` (names `["python", "python3",
   "pyex"]`). Compile-guarded so pyex still compiles without the
   JustBash dep.
2. `mix.exs` — `{:just_bash, "~> 0.4", optional: true}`.
3. Argv / stdin / stdout wiring (§7).
4. End-to-end tests (§8).

### PR 3 — S3FS rewrite

Deferred. Rewrites `Pyex.Filesystem.S3` as `Pyex.FS.S3FS`
implementing the new behaviour. Bigger than it looks — see §6.3.

### 6.3 S3FS rewrite scope (for PR 3 context)

New callbacks S3 has to implement cleanly:

- `stat/2` — HEAD request. 200 → file stat; 404 → `:enoent`; list
  with prefix to detect "this is an implicit directory."
- `lstat/2` — S3 has no symlinks. Same as `stat`.
- `readdir/2` — ListObjectsV2 with `delimiter="/"` and `prefix=path+"/"`.
  `CommonPrefixes` are subdirs; `Contents` are files. Deduplicate.
- `mkdir/3` — S3 has no real directories. Policy options:
  - (a) no-op, rely on implicit prefixes. Problem: empty dirs don't
    exist. `mkdir /foo` then `readdir /foo` → `{:error, :enoent}`.
  - (b) zero-byte sentinel object `/foo/.dir`. Problem: visible in
    `readdir` unless filtered.
  - (c) in-process MapSet of "known empty dirs" inside the backend
    state. Problem: state is not persisted; another S3FS instance
    pointing at the same bucket doesn't see them.
  - **Recommendation: (b), with readdir filtering out `.dir` entries.**
    Survives restart, matches what other S3 tools expect, minor hack.
- `rm/3` with `recursive: true` — paginated ListObjectsV2 + batch
  DeleteObjects (up to 1000 per call).
- `chmod/3` — `:erofs` (S3 doesn't have per-object POSIX modes in the
  general case; skip unless a specific use case comes up).
- `symlink/3`, `link/3` — `:erofs`.

Also: S3 currently returns Python-formatted error strings. Must
change to POSIX atoms.

Also: S3 needs a CWD / absolute-path convention. Current
`Pyex.Filesystem.S3` takes paths like `"foo/bar"`; new contract
requires `/foo/bar`. Strip leading slash before computing the S3 key.

## 7. Custom-command details (for PR 2)

### 7.1 Shape

```elixir
defmodule Pyex.JustBashCommand do
  @behaviour JustBash.Commands.Command

  def names, do: ["python", "python3", "pyex"]

  def execute(bash, args, stdin) do
    {code, argv} = parse_args(bash, args)

    # bash → pyex: struct-shape conversion, mount list passes through.
    pyex_fs = %Pyex.FS{mounts: bash.fs.mounts}

    ctx =
      Pyex.Ctx.new(
        fs: pyex_fs,
        env: bash.env,
        cwd: bash.cwd,
        stdin: stdin,
        argv: argv,
        context: bash.context
      )

    case Pyex.run(code, ctx) do
      {:ok, result, new_ctx} ->
        # pyex → bash: converse conversion. Same mount list.
        updated_fs = %JustBash.FS{mounts: new_ctx.fs.mounts}
        updated_bash = %{bash | fs: updated_fs, env: env_writeback(new_ctx)}
        {updated_bash,
         %{stdout: result.stdout, stderr: result.stderr,
           exit_code: exit_code(result)}}

      {:error, %Pyex.Error{} = err, new_ctx} ->
        updated_fs = %JustBash.FS{mounts: new_ctx.fs.mounts}
        updated_bash = %{bash | fs: updated_fs}
        {updated_bash,
         %{stdout: "", stderr: Pyex.Error.to_string(err), exit_code: 1}}
    end
  end

  defp parse_args(bash, args) do
    # python script.py            -> read script.py from bash.fs
    # python -c "code"            -> inline
    # python -                    -> stdin is code
    # python script.py a b c      -> argv = ["script.py", "a", "b", "c"]
    # ...
  end
end
```

**Boundary conversion is two lines.** Mount entries — including
backend state — are shared by reference; both dispatchers use the
same `{mountpoint, module, state}` tuple format and call backends
by name, so a `JustBash.FS.ReadOnlyFS` mount registered by bash
works unchanged inside pyex's dispatcher and vice-versa.

### 7.2 Prerequisite: `Pyex.Ctx` gets stdin, argv, cwd fields

I don't know if pyex's `Ctx` currently has `:stdin`, `:argv`, or
`:cwd`. Needs an audit. Likely outcomes:

- `:cwd` — probably absent. Python's `open("rel_path")` has to
  resolve somewhere. Add the field, default to `/`.
- `:argv` — probably absent. `sys.argv` needs it.
- `:stdin` — probably absent. `sys.stdin` needs it.

These additions are **not** coupled to the FS rework — they're pure
Ctx expansion — but they're prereqs for PR 2 working end-to-end. Do
them in PR 2 alongside the command module, or split them into their
own prep PR if they're ugly.

### 7.3 Policy decisions for the command module

1. **`os.environ` write-back.** If Python mutates `os.environ`, does
   bash see it in the next command? **Default: no.** Matches
   subprocess semantics.
2. **Pyex-mounted extra backends persist to bash?** If Python code
   calls a hypothetical `pyex.fs.mount(...)`, does it stick? N/A for
   PR 2 (pyex has no mount API). Revisit when it does.
3. **Network policy.** Pyex's `urllib.urlopen` — goes through
   `bash.network` allowlist or pyex's own? **Default: honor
   `bash.network`.** The shell owns the sandbox boundary.
4. **Resource limits.** `bash.limits` (step/memory caps) — does pyex
   share bash's budget or have its own? **Default: pyex has its
   own** (pyex has its own step counter). Document clearly.
5. **Exit code on uncaught exception.** `1`, with traceback on stderr.
6. **`sys.exit(N)`** surfaces as the command's exit code.

## 8. End-to-end tests (in PR 2)

```elixir
defmodule Pyex.JustBashIntegrationTest do
  use ExUnit.Case

  test "python reads a file the shell just wrote" do
    bash =
      JustBash.new(
        files: %{"/data/in.json" => ~s({"x": 1, "y": 2})},
        commands: %{"python" => Pyex.JustBashCommand}
      )

    {r, _} =
      JustBash.exec(bash, ~S[
        python -c 'import json
        d = json.loads(open("/data/in.json").read())
        print(d["x"] + d["y"])'
      ])

    assert r.exit_code == 0
    assert r.stdout == "3\n"
  end

  test "python writes a file the next shell command reads" do
    bash = JustBash.new(commands: %{"python" => Pyex.JustBashCommand})

    {r, _} =
      JustBash.exec(bash, """
        python -c 'open("/tmp/out.txt", "w").write("hello\\n")'
        cat /tmp/out.txt
      """)

    assert r.exit_code == 0
    assert r.stdout == "hello\n"
  end

  test "ReadOnlyFS mount from shell governs Python too" do
    ro =
      JustBash.FS.ReadOnlyFS.new(
        inner:
          {JustBash.FS.InMemoryFS,
           JustBash.FS.InMemoryFS.new(%{"/readme.md" => "# hi"})}
      )

    fs = JustBash.FS.new()
    {:ok, fs} = JustBash.FS.mount(fs, "/project", ro)

    bash =
      JustBash.new(fs: fs, commands: %{"python" => Pyex.JustBashCommand})

    {r, _} =
      JustBash.exec(bash, ~S[
        python -c 'print(open("/project/readme.md").read())
        try:
          open("/project/readme.md", "w").write("pwned")
        except PermissionError as e:
          print("blocked:", e)'
      ])

    assert r.exit_code == 0
    assert r.stdout =~ "# hi"
    assert r.stdout =~ "blocked:"
  end

  test "bash.fs stays %JustBash.FS{} through a python invocation" do
    bash = JustBash.new(commands: %{"python" => Pyex.JustBashCommand})

    {_r, bash2} =
      JustBash.exec(bash, ~S[python -c 'open("/tmp/x", "w").write("1")'])

    assert bash2.fs.__struct__ == JustBash.FS
    # And the write is visible — mount state was preserved across conversion.
    {r, _} = JustBash.exec(bash2, "cat /tmp/x")
    assert r.stdout == "1"
  end

  test "ReadOnlyFS mount from bash is honored in pyex's dispatcher too" do
    # Same as the third test, but asserts that pyex's OWN cp attempts
    # (via shutil) hit the ReadOnlyFS :erofs error.
  end
end
```

The third test is the proof-of-value. The fourth pins that the
mount-list passthrough preserves backend state across the boundary.

## 9. Risks and open questions

**What we're accepting:**

- `fs.__struct__.func(...)` dispatch means Dialyzer can't see through
  the call to typecheck the return shape. Mitigated by typing
  `Pyex.FS.*` top-level functions explicitly.
- Backend-contract drift between pyex and JustBash is a silent
  runtime failure for features that use the drifted callback.
  Mitigation: the conformance test in §4.3 pins the callback list
  when JustBash is loaded. Doesn't catch signature drift — for that
  we'd need an integration test that exercises every callback through
  a `%JustBash.FS{}`. Worth adding.

**Open questions needing a call:**

1. **Does `%Pyex.Ctx{}` have `:cwd`, `:stdin`, `:argv` today?** If
   not, PR 2 grows. Not a blocker — but affects PR ordering.
2. **`mkdir` behaviour on `InMemoryFS` when path exists.** JustBash's
   returns `{:error, :eexist}` unless `recursive: true`. Pyex's
   current Memory backend always succeeds. Adopting JustBash's
   stricter semantics matches POSIX and Python's `os.mkdir` →
   `FileExistsError`. Go with JustBash's. (Not really a question,
   just flagging.)
3. **S3 PR 3 ordering.** If there are tests that currently depend on
   `Pyex.Filesystem.S3`, they need the `LegacyS3FS` shim working
   through PR 1. Audit before starting.
4. **The "python" command name in bash.** Does that step on any
   existing JustBash builtin? Currently no (just `cd`, `export`,
   etc. are protected). Safe.

**Risks not covered above:**

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Path-normalization edge case differs between pyex's copy of `normalize_path` and JustBash's | Low | Port verbatim + add doctest for every JustBash example |
| `:cwd`/`:stdin`/`:argv` addition to `Ctx` conflicts with existing Python semantics in pyex | Medium | Audit `Pyex.Ctx` early; write the Ctx-expansion PR separately if scope grows |
| `LegacyS3FS` compat shim is harder than expected | Medium | Escape hatch: delete it in PR 1, mark S3 support as "temporarily broken pending PR 3" |
| JustBash changes its public API between `0.4` and whatever pyex pins | Low | Pin to an exact `~>` range; conformance test catches callback-list changes |

## 10. Done criteria (PR 1)

- `grep -rn "Pyex.Filesystem" lib/ test/` → zero (S3 shim
  lives under `Pyex.FS.LegacyS3FS`).
- `%Pyex.Ctx{}` has `:fs`, not `:filesystem`.
- All 14 `Pyex.FS.Backend` callbacks implemented by `Pyex.FS.InMemoryFS`.
- `Pyex.FS.{read_file, write_file, stat, lstat, readdir, mkdir,
  rm, cp, mv, chmod, symlink, readlink, link, append_file,
  exists?}` all work against both `%Pyex.FS.InMemoryFS{}` and
  (if JustBash is present in the test env) `%JustBash.FS{}`.
- Conformance test green.
- `UPGRADING.md` written.
- `mix format`, `mix compile --warnings-as-errors`, `mix test` all
  green.

## 11. Done criteria (PR 2)

- `Pyex.JustBashCommand` module present and tested.
- All four tests in §8 pass.
- `mix.exs` has `{:just_bash, "~> 0.4", optional: true}`.
- Pyex still compiles and tests green with `mix deps.unlock just_bash
  && mix deps.clean just_bash --unlock` (i.e., without JustBash
  actually installed).
- README has a 10-line "use pyex as a JustBash custom command"
  example.
