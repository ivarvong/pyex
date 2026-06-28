defmodule Pyex.ParityTest do
  @moduledoc """
  Surface-parity manifest: pyex's public API vs CPython's, asserted.

  pyex models Python by hand-enumerating method tables and builtin
  registrations. A missing entry isn't a failure — it's *nothing*, and a
  silent hole stays invisible until an agent's program calls the name.
  This suite makes absence loud.

  For each modelled type it compares pyex's own `dir(x)` against CPython's
  (`test/fixtures/parity.json`, regenerate with
  `python3 test/fixtures/parity_gen.py`), and for the builtin namespace it
  compares `Pyex.Builtins.names/0` against `dir(builtins)`. Every CPython
  public name must be either implemented or listed in `@known_gaps` with a
  category. So:

    * Implementing a name without removing its `@known_gaps` entry fails
      the stale-ledger check — you must delete the entry. That is the
      forcing function that burns the gap list down.
    * A new CPython name (or a regenerated manifest) that pyex neither
      implements nor acknowledges fails the coverage check.
    * pyex inventing public surface CPython lacks fails the extras check
      unless it is an acknowledged extension.

  Categories are documentation, not behaviour — all are treated as
  acknowledged:

    * `:unimplemented`  — valid CPython we should eventually support (the
      burn-down queue).
    * `:out_of_scope`   — deliberately not modelled in the sandbox
      (OS handles, buffer internals, REPL/debugger hooks, finalization).
    * `:language_literal` — `True`/`False`/`None`/`NotImplemented`: keywords
      and singletons, not environment bindings.
  """

  use ExUnit.Case, async: true

  alias Pyex.FS, as: Memory

  @manifest_path Path.join([__DIR__, "..", "fixtures", "parity.json"])
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> Jason.decode!()

  # pyex source that evaluates to a representative value of each surface.
  @type_exprs %{
    "str" => "''",
    "list" => "[]",
    "tuple" => "()",
    "dict" => "{}",
    "set" => "set()",
    "frozenset" => "frozenset()",
    "file" => "open('f.txt', 'w')",
    "date" => "__import__('datetime').date(2026, 1, 1)",
    "datetime" => "__import__('datetime').datetime(2026, 1, 1, 12, 30)"
  }

  # Every CPython public name pyex does not implement lives here with a
  # category, or the suite fails. Burning the `:unimplemented` entries down
  # is how parity converges.
  @known_gaps %{
    "str" => %{},
    "dict" => %{},
    "set" => %{},
    "list" => %{},
    "tuple" => %{},
    "frozenset" => %{},
    "file" => %{
      # OS / encoding-layer internals with no meaning in the sandbox
      "buffer" => :out_of_scope,
      "detach" => :out_of_scope,
      "encoding" => :out_of_scope,
      "errors" => :out_of_scope,
      "fileno" => :out_of_scope,
      "isatty" => :out_of_scope,
      "line_buffering" => :out_of_scope,
      "newlines" => :out_of_scope,
      "reconfigure" => :out_of_scope,
      "write_through" => :out_of_scope
    },
    "date" => %{},
    "datetime" => %{},
    "builtins" => %{
      # not yet implemented (burn-down queue)
      "aiter" => :unimplemented,
      "anext" => :unimplemented,
      "globals" => :unimplemented,
      "locals" => :unimplemented,
      "memoryview" => :unimplemented,
      "ExceptionGroup" => :unimplemented,
      "BaseExceptionGroup" => :unimplemented,
      # keywords / singletons, not environment bindings
      "True" => :language_literal,
      "False" => :language_literal,
      "None" => :language_literal,
      "NotImplemented" => :language_literal,
      # REPL / debugger / finalization hooks: no meaning in the sandbox
      "breakpoint" => :out_of_scope,
      "copyright" => :out_of_scope,
      "credits" => :out_of_scope,
      "exit" => :out_of_scope,
      "help" => :out_of_scope,
      "license" => :out_of_scope,
      "quit" => :out_of_scope,
      "PythonFinalizationError" => :out_of_scope
    }
  }

  # Public builtin names pyex binds that CPython's `dir(builtins)` does not
  # surface. Acknowledged on purpose: pyex flattens some module-scoped
  # exception classes (decimal, zipfile, pydantic) into the global
  # namespace, and `__import__` is a dunder filtered out of the reference.
  @builtin_extensions ~w(
    __import__
    ValidationError
    BadZipFile LargeZipFile
    Clamped ConversionSyntax DecimalException DivisionByZero
    DivisionImpossible DivisionUndefined FloatOperation Inexact
    InvalidContext InvalidOperation Overflow Rounded Subnormal Underflow
  )

  defp pyex_public_dir(surface) do
    opts = if surface == "file", do: [filesystem: Memory.new()], else: []

    Pyex.run!("dir(#{@type_exprs[surface]})", opts)
    |> Enum.reject(&String.starts_with?(&1, "_"))
    |> Enum.sort()
  end

  describe "type surface parity vs CPython dir()" do
    for surface <- ~w(str list tuple dict set frozenset file date datetime) do
      @surface surface

      test "#{surface}: every CPython public attribute is implemented or acknowledged" do
        cpython = @manifest["types"][@surface]
        pyex = pyex_public_dir(@surface)
        acknowledged = Map.keys(Map.fetch!(@known_gaps, @surface))

        missing = (cpython -- pyex) -- acknowledged

        assert missing == [],
               "#{@surface}: CPython exposes #{inspect(missing)} but pyex does not. " <>
                 "Implement them, or add each to @known_gaps with a category."

        extra = pyex -- cpython

        assert extra == [],
               "#{@surface}: pyex exposes #{inspect(extra)} which CPython's dir() does not. " <>
                 "Remove the surface, or this type needs an extensions allowlist."
      end

      test "#{surface}: @known_gaps has no stale entries (implemented names must be removed)" do
        pyex = pyex_public_dir(@surface)
        acknowledged = Map.keys(Map.fetch!(@known_gaps, @surface))
        stale = acknowledged -- (acknowledged -- pyex)

        assert stale == [],
               "#{@surface}: #{inspect(stale)} are listed in @known_gaps but pyex now " <>
                 "implements them. Delete the entries — that's the burn-down."
      end
    end
  end

  describe "builtin namespace parity vs CPython dir(builtins)" do
    test "every public builtin is implemented or acknowledged" do
      cpython = @manifest["builtins"]["functions"] ++ @manifest["builtins"]["exceptions"]
      pyex = Pyex.Builtins.names()
      acknowledged = Map.keys(@known_gaps["builtins"])

      missing = (cpython -- pyex) -- acknowledged

      assert missing == [],
             "builtins: CPython exposes #{inspect(missing)} but pyex does not. " <>
               "Implement them, or add each to @known_gaps[\"builtins\"] with a category."
    end

    test "pyex exposes no unacknowledged extra builtins" do
      cpython = @manifest["builtins"]["functions"] ++ @manifest["builtins"]["exceptions"]
      pyex = Pyex.Builtins.names()

      extra = ((pyex -- cpython) -- @builtin_extensions) -- ["type", "Ellipsis", "NotImplemented"]

      assert extra == [],
             "builtins: pyex binds #{inspect(extra)} which CPython does not. " <>
               "Add to @builtin_extensions with a reason, or stop binding them."
    end

    test "@known_gaps[\"builtins\"] has no stale entries" do
      pyex = Pyex.Builtins.names()
      acknowledged = Map.keys(@known_gaps["builtins"])
      # language literals are intentionally never bindings; exclude from stale check
      literals = for {n, :language_literal} <- @known_gaps["builtins"], do: n
      stale = (acknowledged -- (acknowledged -- pyex)) -- literals

      assert stale == [],
             "builtins: #{inspect(stale)} are in @known_gaps but pyex now binds them. " <>
               "Delete the entries — that's the burn-down."
    end
  end
end
