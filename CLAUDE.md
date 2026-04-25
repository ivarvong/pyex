# Guidelines for Pyex Development

## IMPORTANT: Code Requirement

**Before committing OR opening a PR, run all four:**

1. `mix format --check-formatted`
2. `mix compile --warnings-as-errors`
3. `mix test`
4. `mix dialyzer` — required for any change to `lib/`

CI runs Dialyzer; skipping it locally means a PR comes back red. The
PLT takes ~40s on a cold build, then a few seconds per run. If the
PLT is missing, build it once with `mix dialyzer --plt`.

When Dialyzer reports findings *only* in pre-existing files you did
not touch (e.g. OTP-version-specific opaqueness warnings), call them
out in the PR body and confirm they were also present on `main` —
don't silently fix them.

## Project Overview

Pyex is a Python interpreter written in Elixir. Follow idiomatic Elixir conventions throughout.

## General Guidelines

- Use snake_case for variables/functions, PascalCase for modules
- **Acronyms stay uppercase in identifiers:** `HTML` not `Html`, `JSON`
  not `Json`, `JSX` not `Jsx`, `URL` not `Url`, `API` not `Api`,
  `HTTP` not `Http`, `CSS` not `Css`, `SQL` not `Sql`, `UUID` not
  `Uuid`, `YAML` not `Yaml`, `CSV` not `Csv`. This applies to module
  names (`Pyex.Stdlib.JSON`), type names, and any PascalCase
  identifier — never title-case an acronym.
- Return tagged tuples: `{:ok, result}` or `{:error, reason}`
- Use pattern matching over conditional logic when possible
- Use pipe operators (`|>`) for multi-step transformations
- Organize aliases alphabetically
- Use `with` statements for sequential operations that may fail

## Testing

- Run `mix test` or `mix test path/to/test_file.exs:line_number`
- Don't use mocks
- Test the happy path and edge cases

## Workflow

- **ALWAYS run `mix format` before committing any code changes**
- **ALWAYS run `mix compile --warnings-as-errors` before committing**
- **ALWAYS run `mix test` before committing**
- **ALWAYS run `mix dialyzer` before pushing or opening a PR** — CI
  fails the build on Dialyzer warnings; running it locally first
  catches dead clauses, impossible patterns, and spec mismatches
  before they cost a CI cycle.
- Run `mix format --check-formatted` to verify all files are properly formatted

After opening a PR, also verify CI is green with `gh pr checks <num>`
before declaring the work done.
