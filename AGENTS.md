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

- `Pyex` -- public API: `compile/1`, `run/2`, `run!/2`, `resume/2`, `events/1`,
  `snapshot/1`, `profile/1`
- `Pyex.Lexer` -- NimbleParsec-based tokenizer with indent/dedent/newline handling
- `Pyex.Parser` -- recursive descent parser producing `{node_type, meta, children}`
  AST nodes with `[line: n]` metadata
- `Pyex.Interpreter` -- tree-walking evaluator (~4600+ lines). Control flow via
  tagged tuples (`{:returned, val}`, `{:break}`, `{:continue}`, `{:exception, msg}`,
  `{:yielded, val, continuation}`). Never raise/rescue for Python semantics.

### Environment and context

- `Pyex.Env` -- scope-stack environment with global/nonlocal/put_at_source support
- `Pyex.Ctx` -- execution context: deterministic replay via append-only event log,
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
- `Pyex.Filesystem.Local` -- sandboxed real directory with path traversal protection
- `Pyex.Filesystem.S3` -- S3-backed via Req with AWS sigv4

### Agent

- `Pyex.Agent` -- LLM agent loop using Claude via Anthropic API

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

## Testing

~1970+ tests, 0 failures, 3 skipped (plus 39 property-based tests).

### Core layer tests
- `test/pyex/lexer_test.exs` -- tokenizer
- `test/pyex/parser_test.exs` -- AST generation
- `test/pyex/interpreter_test.exs` -- eval clauses
- `test/pyex/builtins_test.exs` -- built-in functions
- `test/pyex/methods_test.exs` -- type methods
- `test/pyex/classes_test.exs` -- class definitions, inheritance, dunder methods
- `test/pyex/comprehensions_test.exs` -- list/dict/set comprehensions
- `test/pyex/generators_test.exs` -- generator functions, yield, yield from
- `test/pyex/aug_assign_test.exs` -- augmented assignment
- `test/pyex/try_except_test.exs` -- exception handling
- `test/pyex/match_case_test.exs` -- structural pattern matching
- `test/pyex/ctx_test.exs` -- execution context
- `test/pyex/suspend_test.exs` -- suspend/resume/replay
- `test/pyex/filesystem_test.exs` -- filesystem backends
- `test/pyex/filesystem_import_test.exs` -- importing from filesystem
- `test/pyex/lambda_test.exs` -- Lambda invocation and routing

### Streaming and continuations
- `test/pyex/streaming_test.exs` -- 37 streaming tests (lazy behavior, timing,
  back-pressure, early halt, composition)
- `test/pyex/continuation_test.exs` -- 57 continuation stress tests (nested loops,
  break/continue, mutation, generator-calling-generator, yield from, exceptions,
  closures, interleaved generators, large generators, edge cases)

### Quality and conformance
- `test/pyex/conformance_test.exs` -- CPython vs Pyex output comparison
- `test/pyex/property_test.exs` -- 39 property-based tests
- `test/pyex/error_test.exs` -- 33 error classification tests
- `test/pyex/error_boundary_test.exs` -- error boundary coverage
- `test/pyex/error_messages_test.exs` -- error message quality
- `test/pyex/telemetry_test.exs` -- 18 telemetry tests
- `test/pyex/profile_test.exs` -- profiling tests
- `test/pyex/custom_modules_test.exs` -- custom module injection

### Integration
- `test/pyex_test.exs` -- end-to-end integration tests
- `test/pyex/llm_programs_test.exs` -- realistic LLM-generated programs
- `test/pyex/interaction_test.exs` -- multi-step interaction patterns
- `test/pyex/ssr_blog_test.exs` -- server-side rendered blog
- `test/pyex/todo_api_test.exs` -- TODO API app

### Stdlib tests
- `test/pyex/stdlib/collections_test.exs`
- `test/pyex/stdlib/csv_test.exs`
- `test/pyex/stdlib/datetime_test.exs`
- `test/pyex/stdlib/fastapi_test.exs`
- `test/pyex/stdlib/html_test.exs`
- `test/pyex/stdlib/itertools_test.exs`
- `test/pyex/stdlib/jinja2_test.exs`
- `test/pyex/stdlib/json_test.exs`
- `test/pyex/stdlib/markdown_test.exs`
- `test/pyex/stdlib/random_test.exs`
- `test/pyex/stdlib/re_test.exs`
- `test/pyex/stdlib/requests_test.exs`
- `test/pyex/stdlib/sql_test.exs`
- `test/pyex/stdlib/time_test.exs`
- `test/pyex/stdlib/unittest_test.exs`

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

## TODO: Python 3 feature gaps (in priority order)

### HIGH -- LLMs will use these immediately

- [x] t1: `# comments` -- lexer ignores everything from # to end of line
- [x] t2: `break` / `continue` -- keywords are lexed but interpreter has no handling
- [x] t3: `in` / `not in` operators -- `x in list`, `key in dict` as boolean expressions
- [x] t4: `for` over strings -- `for ch in "hello"` should iterate characters
- [x] t5: `for` over dicts -- `for k in d` should iterate keys
- [x] t6: negative division semantics -- `//` should floor toward -inf, `%` should match divisor sign
- [x] t7: `int * str` and `int * list` -- reversed operand order for repetition
- [x] t8: slice notation `list[1:3]` -- parse colon in subscript as slice
- [x] t9: list comprehension -- `[x*2 for x in items]` and `[x for x in items if x > 0]`
- [x] t10: ternary if/else expression -- `x if cond else y`
- [x] t11: tuple type -- `(1, 2, 3)` literal, `tuple()` constructor, immutability
- [x] t12: multiple assignment / unpacking -- `a, b = 1, 2` and `a, b = func()`
- [x] t13: default function arguments -- `def f(x, y=10)`
- [x] t14: `lambda` expressions -- `lambda x: x + 1`
- [x] t15: f-strings -- `f"Hello {name}"` with expression interpolation
- [x] t16: triple-quoted strings -- `"""..."""` and `'''...'''` for multiline
- [x] t17: dict methods -- `.keys()`, `.values()`, `.items()`, `.get()`, `.pop()`, `.update()`, `.setdefault()`, `.clear()`, `.copy()`
- [x] t18: list methods -- `.extend()`, `.insert()`, `.remove()`, `.pop()`, `.sort()`, `.reverse()`, `.clear()`
- [x] t19: bare `return` -- return with no value should return None
- [x] t20: `is` / `is not` operators -- identity comparison, especially `x is None`

### MEDIUM -- important for real programs

- [x] t21: chained comparisons -- `1 < x < 10` with short-circuit semantics
- [x] t22: string subscript -- `s[0]`, `s[-1]`, string slicing `s[1:3]`
- [x] t23: `for` loop tuple unpacking -- `for k, v in items`
- [x] t24: list repetition -- `[1, 2] * 3` and `3 * [1, 2]`
- [x] t25: `finally` clause on try -- lexed but not parsed/evaluated
- [x] t26: `else` on try -- `try/except/else`
- [x] t27: `else` on `for`/`while` loops
- [x] t28: builtins: `any()`, `all()` -- short-circuit boolean checks on iterables
- [x] t29: builtins: `map()`, `filter()` -- listed in moduledoc but never registered
- [x] t30: builtins: `chr()`, `ord()` -- character/codepoint conversion
- [x] t31: builtins: `hex()`, `oct()`, `bin()` -- integer formatting
- [x] t32: builtins: `pow()` with 3 args -- modular exponentiation
- [x] t33: builtins: `divmod()` -- returns (quotient, remainder) tuple
- [x] t34: builtins: `repr()` -- developer-facing string representation
- [x] t35: builtins: `callable()` -- check if value is callable
- [x] t36: numeric literals: `0x` hex, `0o` octal, `0b` binary, underscore separators
- [x] t37: `raise ExcType("msg")` -- exception class instantiation syntax
- [x] t38: `except (TypeError, ValueError)` -- tuple of exception types
- [x] t39: bare `raise` -- re-raise current exception inside except
- [x] t40: `global` / `nonlocal` keywords -- scope declarations
- [x] t41: `from X import Y` -- selective imports
- [x] t42: `import X as Y` -- aliased imports
- [x] t43: `assert` statement -- `assert cond, msg`
- [x] t44: `del` statement -- delete variable or dict key
- [x] t45: augmented assignment on subscripts -- `d["key"] += 1`
- [x] t46: chained assignment -- `a = b = 1`
- [x] t47: line continuation -- backslash at end of line
- [x] t48: `*args` and `**kwargs` -- variadic function parameters
- [x] t49: keyword arguments in calls -- `f(x=1, y=2)`
- [x] t50: dict comprehension -- `{k: v for k, v in items}`
- [x] t51: set type -- `{1, 2, 3}` literal, `set()` constructor, set operations
- [x] t52: stdlib: `random` module -- `random.randint`, `random.choice`, `random.shuffle`, etc.
- [x] t53: stdlib: `re` module -- regex matching, search, findall, sub
- [x] t54: stdlib: `datetime`/`time` modules -- date/time operations
- [x] t55: stdlib: `collections` module -- Counter, defaultdict, OrderedDict

### LOW -- rarely needed for LLM sandbox

- [x] t56: escape sequences: `\r`, `\0`, `\a`, `\b`, `\f`, `\v`, `\xNN`, `\uNNNN`, `\UNNNNNNNN`
- [x] t57: bitwise operators -- `&`, `|`, `^`, `~`, `<<`, `>>` and augmented versions
- [x] t58: unary `+` operator
- [x] t59: walrus operator `:=` -- assignment expression
- [x] t60: `match`/`case` -- structural pattern matching (Python 3.10+)
- [x] t61: class definitions -- `class`, `__init__`, inheritance, dunder methods
- [x] t62: decorators -- `@decorator` syntax
- [x] t62a: `set` comprehension -- `{x for x in items}`
- [x] t63: generators / `yield` / `yield from`
- [ ] t64: `async` / `await`
- [x] t65: `with` statement / context managers
- [x] t66: raw strings `r"..."` and byte strings `b"..."`
- [x] t67: string `%` formatting and additional string methods (center, ljust, rjust, swapcase, etc.)
- [x] t68: builtins: `open()` file I/O (sandboxed)
- [x] t69: builtins: `iter()`, `next()`, `StopIteration` -- iteration protocol
- [ ] t70: builtins: `exec()`, `eval()`, `compile()` -- dynamic execution (sandboxed)
- [x] t71: builtins: `getattr()`, `setattr()`, `hasattr()` -- dynamic attribute access
- [ ] t72: complex number type -- `1+2j`, `complex()` constructor
- [ ] t73: `bytes` / `bytearray` types
- [x] t74: semicolon statement separator
- [x] t75: starred expressions in calls -- `f(*args, **kwargs)`
- [x] t76: `list.append()` should mutate in place and return None (Python semantics)
- [x] t77: `inf`, `-inf`, `nan` float literals
- [x] t78: `int()` with base argument -- `int("ff", 16)`
- [x] t79: `range()` as lazy object with `.start`/`.stop`/`.step`, not eagerly materialized list
- [x] t80: inline if body -- `if x: y` (single-line without indent)
- [x] t81: type annotations -- `def f(x: int) -> str:` parsed and silently discarded
- [x] t82: request body in FastAPI handlers -- `request.json()` for POST/PUT body access
