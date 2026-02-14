# Pyex Agent Guidelines

## Project
Pyex is a Python 3 interpreter written in Elixir, designed as a capabilities-based
sandbox for LLMs to safely run compute. It is the core of a PaaS where customers
write arbitrary Python -- it must be rock solid.

## Runtime
- Elixir ~> 1.19, OTP 28
- asdf for version management (`.tool-versions` in project root)
- LSP runs Elixir 1.17 and reports version mismatch errors on `mix.exs` -- these
  are false positives; ignore them.

## Style
- Write code in Jose Valim's style: clear, minimal, well-structured
- Prefer pattern matching and multi-clause functions over conditionals
- Small focused modules with clear responsibilities
- No one-line comments
- Use NimbleParsec for lexing/tokenization where it makes sense

## Architecture

### Core pipeline: Lexer -> Parser -> Interpreter

- `Pyex` -- public API: `compile/1`, `run/2`, `run!/2`, `output/1`
- `Pyex.Lexer` -- NimbleParsec-based tokenizer with indent/dedent/newline handling
- `Pyex.Parser` -- recursive descent parser producing `{node_type, meta, children}`
  AST nodes with `[line: n]` metadata
- `Pyex.Interpreter` -- tree-walking evaluator (~4600+ lines). Control flow via
  tagged tuples (`{:returned, val}`, `{:break}`, `{:continue}`, `{:exception, msg}`,
  `{:yielded, val, continuation}`). Never raise/rescue for Python semantics.

### Environment and context

- `Pyex.Env` -- scope-stack environment with global/nonlocal/put_at_source support
- `Pyex.Ctx` -- execution context: append-only event log for observability,
  filesystem handles, environ, compute timeout, `:noop` mode for compilation checks,
  custom modules, `imported_modules` cache, profile data, `generator_mode`
  (`:accumulate | :defer | nil`), `generator_acc`
- `Pyex.Error` -- structured error type with `kind` (`:syntax | :python | :timeout |
  :import | :io | :route_not_found | :internal`), `message`, `line`,
  `exception_type`. Auto-classifies from raw error strings.

### Web / Lambda

- `Pyex.Lambda` -- Lambda-style execution of FastAPI programs without a server.
  `boot/2` compiles routes, `handle/2` dispatches requests (stateful, threads ctx),
  `handle_stream/2` returns lazy `Stream` of chunks via continuations.
- `Pyex.Trace` -- custom OpenTelemetry exporter for span tree visualization

### Builtins and methods

- `Pyex.Builtins` -- built-in Python functions (len, range, print, str, int, float,
  type, abs, min, max, sum, sorted, reversed, enumerate, zip, map, filter, any, all,
  chr, ord, hex, oct, bin, pow, divmod, repr, callable, open, iter, next, getattr,
  setattr, hasattr, super, isinstance, issubclass, id, hash, vars, dir, etc.)
- `Pyex.Methods` -- method dispatch for string, list, dict, set, tuple, file_handle
  types. Resolves attribute access to bound method closures.

### Stdlib modules

- `Pyex.Stdlib` -- registry mapping Python module names to Elixir implementations.
  `module_names/0` returns all registered names.
- `Pyex.Stdlib.Module` -- behaviour that all stdlib modules implement via
  `module_value/0` returning an attribute map.
- `Pyex.Stdlib.Collections` -- Counter, defaultdict, OrderedDict
- `Pyex.Stdlib.Csv` -- reader, DictReader, writer, DictWriter
- `Pyex.Stdlib.Datetime` -- datetime.now(), date.today(), timedelta, fromisoformat
- `Pyex.Stdlib.FastAPI` -- route registration with decorators, HTMLResponse,
  JSONResponse, StreamingResponse. List-based, no ETS/Bandit.
- `Pyex.Stdlib.Html` -- html.escape(), html.unescape()
- `Pyex.Stdlib.Itertools` -- combinatoric iterators (eagerly materialized for safety)
- `Pyex.Stdlib.Jinja2` -- template engine with loops, conditionals, includes, extends
- `Pyex.Stdlib.Json` -- json.loads() / json.dumps() backed by Jason
- `Pyex.Stdlib.Markdown` -- Markdown to HTML via cmark NIF
- `Pyex.Stdlib.Math` -- trig, sqrt, pow, log, ceil, floor, pi, e via `:math`
- `Pyex.Stdlib.Random` -- randint, choice, shuffle, uniform, sample via `:rand`
- `Pyex.Stdlib.Re` -- match, search, findall, sub, split, compile via `Regex`
- `Pyex.Stdlib.Requests` -- requests.get() / requests.post() backed by Req
- `Pyex.Stdlib.Sql` -- parameterized sql.query() against PostgreSQL via Postgrex
- `Pyex.Stdlib.Time` -- time, sleep, monotonic, time_ns via `:os` / `:timer`
- `Pyex.Stdlib.Unittest` -- TestCase with assertion methods and main() discovery
- `Pyex.Stdlib.Uuid` -- uuid4() (random) and uuid7() (time-ordered)

### Filesystem backends

- `Pyex.Filesystem` -- behaviour for pluggable filesystem backends
- `Pyex.Filesystem.Memory` -- in-memory map, fully serializable for suspend/resume
- `Pyex.Filesystem.S3` -- S3-backed via Req with AWS sigv4

## Scope
- Build a decent stdlib over time
- Do NOT try to support existing Python libraries
- This is a sandbox interpreter for LLM-generated compute

## Design Principles
- One module per file. No nested `defmodule` inside other modules.
- **We are a library, not an application** -- never own global state.
- **No processes, no message passing, no process dict.** The continuation-based
  generator system eliminated all of these. Streaming uses pure functional
  continuations driven by `Stream.resource`.
- Never use throw/catch for control flow. Use tagged tuples
  (`{:returned, value}`, `{:break}`, `{:continue}`, `{:exception, msg}`,
  `{:yielded, value, continuation}`) that unwind naturally through the call stack.
- NimbleParsec `reduce` callbacks must be public but should be marked
  `@doc false` since they are implementation details.
- The parser must return `{:ok, ast}` or `{:error, message}` with
  line numbers -- never crash with `FunctionClauseError` on bad input.
- AST nodes carry metadata (`[line: n]`) for error reporting.
- `@doc` on all public functions. `@moduledoc` on all modules.
- `@type` and `@spec` on everything. Dialyzer must pass clean (`mix dialyzer`).
- Error messages must be high-quality -- LLMs use them to self-heal.

## Generator / Streaming Architecture

Generators have two modes, controlled by `ctx.generator_mode`:

### Eager mode (`:accumulate`, default)
Used by `Pyex.run`, `Lambda.handle`, and anywhere generators are consumed
synchronously (e.g. `list(gen())`, `for x in gen()`). The interpreter runs the
entire generator body, collecting yields into `ctx.generator_acc`, and returns
`{:generator, [values]}`.

### Deferred mode (`:defer`)
Used by `Lambda.handle_stream` for lazy streaming. The generator body executes
until the first `yield`, then returns `{:generator_suspended, value, continuation,
gen_env}`. `Stream.resource` drives subsequent yields via
`Interpreter.resume_generator/3`.

### Continuation frames
When `yield` fires in defer mode, `{:yielded, value, []}` propagates up the call
stack. Each enclosing construct **appends** its own frame:

- `{:cont_stmts, remaining_statements}` -- statements after the yield point
- `{:cont_for, var_names, remaining_items, body, else_body}` -- for-loop state
- `{:cont_while, condition, body, else_body}` -- while-loop state
- `{:cont_yield_from, remaining_items}` -- yield-from delegation

Frame ordering is critical: frames are **appended** (not prepended) so inner
contexts are processed before outer contexts by `resume_generator/3`, which pops
frames from the head.

### Key functions
- `Interpreter.resume_generator/3` (public) -- processes continuation frames
- `Lambda.generator_stream/4` (private) -- wraps suspended generator in
  `Stream.resource` for lazy chunk delivery
- `Interpreter.contains_yield?/1` -- static AST analysis to detect generator functions

### Infinite generators
`while True: yield x` works in defer mode (consumer can halt early via
`Enum.take`, `Enum.reduce_while`, etc.) but hangs in eager mode since all
values are collected. This is by design.

### Running tests
- `mix test` -- all tests
- `mix test test/specific_test.exs` -- single file
- `mix test test/specific_test.exs:42` -- single test by line number
- No stdout should leak from tests

## Verification procedure (run after every feature)
1. `mix test` -- all tests must pass
2. `mix format` -- code must be formatted
3. `mix dialyzer` -- zero warnings (15 intentionally suppressed in `.dialyzer_ignore.exs`)
4. Update the TODO below to mark the item completed

## Procedure for adding a Python feature
Each feature touches up to 3 layers. Work through them in order:

1. **Lexer** (`lib/pyex/lexer.ex`) -- add any new tokens, keywords, or operators.
   Add tests in `test/pyex/lexer_test.exs`.
2. **Parser** (`lib/pyex/parser.ex`) -- add new AST node types and parse functions.
   Add the node type to `@type node_type`. Add tests in `test/pyex/parser_test.exs`.
3. **Interpreter** (`lib/pyex/interpreter.ex`) -- add `eval/3` clause for the new node.
   Add tests in `test/pyex/interpreter_test.exs`.
4. **Builtins** (`lib/pyex/builtins.ex`) -- if it's a builtin function, add it here
   and register it in `all/0`. Test in `test/pyex/builtins_test.exs`.
5. **Methods** (`lib/pyex/methods.ex`) -- if it's a method on a type (string, list,
   dict, set, tuple), add it here. Test in `test/pyex/methods_test.exs`.
6. **End-to-end** -- if it's a significant feature, add an integration test in
   `test/pyex_test.exs` showing a realistic Python program using it.

Always add `@spec` to new functions. Keep Dialyzer clean.

## Procedure for adding a stdlib module
1. Create `lib/pyex/stdlib/mymodule.ex` implementing `Pyex.Stdlib.Module` behaviour.
   The module must have `@moduledoc`, `@behaviour Pyex.Stdlib.Module`, and implement
   `module_value/0` returning `%{String.t() => Interpreter.pyvalue()}`.
2. Register the module in `lib/pyex/stdlib.ex` by adding it to the `@modules` map.
3. Create `test/pyex/stdlib/mymodule_test.exs` with tests.
4. If the module introduces new types or objects (like classes), they may need
   support in `Pyex.Interpreter` (attribute access, method calls) or `Pyex.Methods`.
5. Run verification procedure.

## Known Limitations
- Multiple closures sharing mutable state -- would require reference-based mutable
  cells (3 conformance tests skipped for this)
- Nested tuple unpacking -- `(a, b), c = (1, 2), 3` not supported by parser
- Infinite generators hang in eager mode (by design -- use defer/streaming instead)
