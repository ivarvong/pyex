# Guidelines for Pyex Development

## IMPORTANT: Code Requirement

**ALWAYS run `mix format`, `mix compile --warnings-as-errors`, and `mix test` after every code change.** This is a non-negotiable requirement. All code must be properly formatted, warning-free, and tested before being committed.

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
- Run `mix format --check-formatted` to verify all files are properly formatted
