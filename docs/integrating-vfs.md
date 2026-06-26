# Integrating VFS

Pyex runs every filesystem operation through the
[`vfs`](https://hexdocs.pm/vfs) package. This is the reference for how that
integration works — both for *using* a filesystem with Pyex and for *building a
backend* that Pyex (and any other `vfs` consumer) can host.

The whole design exists to make one thing true: **a single filesystem value
threads through Pyex and any other `vfs`-based tool with no copying or
translation.** Hand a `%VFS{}` to Pyex, run some Python, and what comes back is
the same `%VFS{}` — mutated, ready to hand to the next tool.

## The model

`Pyex.Ctx` carries two filesystem-related fields:

| Field | Meaning |
| --- | --- |
| `:filesystem` | any [`VFS.Mountable`](https://hexdocs.pm/vfs/VFS.Mountable.html) — a `VFS.Memory`, a `%VFS{}` mount table, `Pyex.Filesystem.S3`, or your own backend |
| `:cwd` | the working directory relative paths resolve against (absolute, default `"/"`) |

Python file operations (`open`, `os.*`, `pathlib`, `shutil`, `glob`,
`zipfile`) go through `Pyex.FS` and `Pyex.Path`, which:

1. **resolve** the Python path against `ctx.cwd` into an absolute VFS path,
2. call the corresponding `VFS` op,
3. **thread** the possibly-updated backend back into `ctx.filesystem`, and
4. **translate** any `%VFS.Error{}` into the Python exception string Pyex raises.

## Passing a filesystem

`filesystem:` accepts any `VFS.Mountable`, or a plain `%{path => content}` map
that is wrapped as a seeded `VFS.Memory`:

```elixir
# A plain map — keys are rooted at "/" (so "data.json" seeds "/data.json").
Pyex.run(source, filesystem: %{"data.json" => json})

# A VFS.Memory directly (keys are absolute).
Pyex.run(source, filesystem: VFS.Memory.new(%{"/data.json" => json}))

# A mount table — compose backends under different prefixes.
fs =
  VFS.new()
  |> VFS.mount("/", VFS.Memory.new(%{"/main.py" => source}))
  |> VFS.mount("/assets", VFS.Memory.new(%{"/logo.svg" => svg}))

Pyex.run(source, filesystem: fs)

# An S3-backed filesystem.
Pyex.run(source, filesystem: Pyex.Filesystem.S3.new(bucket: "...", ...))
```

After a run, `ctx.filesystem` is the same backend type you passed in, carrying
every write the program made:

```elixir
{:ok, _value, ctx} = Pyex.run(~s|open("/out.txt", "w").write("hi")|, filesystem: VFS.new() |> VFS.mount("/", VFS.Memory.new()))
%VFS{} = ctx.filesystem
{:ok, "hi", _} = VFS.read_file(ctx.filesystem, "/out.txt")
```

## The working directory

Relative Python paths resolve against `ctx.cwd`; absolute paths ignore it. The
default cwd is `"/"`, which reproduces Pyex's historical behavior (everything
rooted at `/`). Set `cwd:` to share a coherent view with a shell:

```elixir
# Under cwd "/project", open("data.txt") reads "/project/data.txt" —
# exactly what `cat data.txt` would read in a shell with the same cwd.
Pyex.run(~s|open("data.txt").read()|, filesystem: %{"project/data.txt" => "hi"}, cwd: "/project")
```

`os.getcwd()` returns the cwd and `os.chdir(path)` updates it. With a
filesystem configured it validates the target is a directory (raising
`NotADirectoryError`/`FileNotFoundError` otherwise); with no filesystem it sets
the cwd unchecked. `open()` binds its resolved absolute path at open time, so a
later `chdir` never moves where a buffered write flushes — matching CPython.

## The sharing pattern (agent loops)

Because every op threads the backend and the cwd is explicit, the same `%VFS{}`
can flow through a sequence of tools — multiple Pyex runs, or a Pyex run and a
shell — each seeing the others' writes:

```elixir
fs = VFS.new() |> VFS.mount("/", VFS.Memory.new())

# Step 1: Python writes a file.
{:ok, _, ctx} = Pyex.run(~s|open("/work/data.json", "w").write('{"n": 1}')|, filesystem: fs)

# Step 2: a later Python run (or any vfs tool) reads it back from the same fs.
{:ok, value, ctx} = Pyex.run("import json; json.load(open('/work/data.json'))['n']", filesystem: ctx.filesystem)
# value == 1
```

The cwd is the contract that makes this coherent with a shell: pass the shell's
cwd as `cwd:` and `open("rel")` resolves the way `cat rel` does.

## Writing a backend Pyex can host

Implement the `VFS.Mountable` protocol for your struct. Pyex hosts any
conformant backend — see `Pyex.Filesystem.S3` for a worked example (an object
store with implicit, prefix-based directories). The contract that matters most:

> **Every operation returns the possibly-updated backend.** Reads included:
> `read_file`/`stream_read`, `stat`, `exists?`, and `readdir` return the
> backend as the last element of their success tuple, and Pyex threads it
> forward. A backend that warms a cache on read *must* return the warmed value,
> or callers lose it.

Pyex relies on this being honored. The test backend
`Pyex.Test.CountingFS` (in `test/support/`) makes the threading *observable* —
its reads increment a counter exposed as `/seq`, so a Python program that
interleaves operations with reads of `/seq` observes the counter advancing iff
Pyex threaded state correctly. `test/pyex/vfs_threading_test.exs` uses it to
prove every Python read path (open, `os.path.*`, `os.listdir`, `os.walk`,
`glob`, `pathlib`, `shutil`) threads the backend — and a negative control (drop
one `fs'`) makes those tests fail. Copy that pattern to verify your own
integration.

### Errors

Backends return `%VFS.Error{kind: kind}` with a POSIX-style kind; Pyex maps each
to a concrete CPython exception in `Pyex.FS.py_error/2`:

| kind | Python exception |
| --- | --- |
| `:enoent` | `FileNotFoundError` |
| `:enotdir` | `NotADirectoryError` |
| `:eisdir` | `IsADirectoryError` |
| `:eexist` | `FileExistsError` |
| `:eacces` | `PermissionError` |
| `:erofs` `:exdev` `:einval` `:eio` `:enotsup` `:eloop` | `OSError` (with the matching errno) |

A backend-specific `:message` (e.g. an S3 HTTP status on `:eio`) is appended so
the cause reaches the traceback.

### Observability

`vfs` wraps its data-flow ops (`read_file`, `write_file`, `mkdir`, `rm`,
`walk`, `materialize`) in `:telemetry.span/3`, so attaching to `[:vfs, _, _]`
gives you per-op timing and the `%VFS.Error{}` on failures for free.

Pyex adds one event at its own boundary: `[:pyex, :fs, :error]`, emitted by
`Pyex.FS.py_error/2` with `%{kind, mount, vfs_path, path}`. The Python-facing
exception is a flat string that loses the structured kind and which mount
failed; this event is the channel to recover them for logging or metrics.

## Known limitations

- `glob`/`pathlib.Path.glob` support `*` and `?` but not the recursive `**`
  pattern. A `**` segment is treated literally, not as a recursive descent.
- `os.walk` is eager — it materializes the whole tree before yielding (Python's
  `os.walk` is a generator). `VFS.walk/3` is lazy; a future change could route
  `os.walk` through it for early-`break` efficiency on large/remote trees.
- S3 append (`open(path, "a")`) is read-modify-write and **not** atomic — there
  is no `If-Match` precondition, so concurrent appenders can lose updates.

## The boundary module: `Pyex.FS`

`Pyex.FS` is the single seam between Pyex's namespace and VFS's. It exposes:

- `resolve/2` — Python path + cwd → absolute VFS path.
- Threaded primitives — `read_file/3`, `write_file/5`, `stat/3`, `exists/3`,
  `readdir/3`, `rm/3`, `mkdir_p/3`, `rm_rf/3` — each returns the updated
  backend; the interpreter uses these.
- A root-relative convenience layer — `read/2`, `write/4`, `exists?/2`,
  `list_dir/2`, `delete/2` — for seeding fixtures and inspecting final state
  (these drop the threaded value, so don't use them on a hot path).
- `py_error/2` — `%VFS.Error{}` → Python exception string.

If you're integrating VFS into your own interpreter or tool, a `Pyex.FS`-shaped
boundary module is the pattern to copy: keep path resolution, state threading,
and error translation in exactly one place.
