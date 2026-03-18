defmodule Pyex.FixtureTest do
  @moduledoc """
  Conformance tests that compare Pyex output against recorded CPython
  ground truth.  Each fixture in `test/fixtures/programs/<name>/` gets
  its own test case, auto-generated at compile time.

  To add a new fixture:

      1. Create `test/fixtures/programs/<name>/main.py`
      2. Optionally add input files under `test/fixtures/programs/<name>/fs/`
      3. Run `mix pyex.fixture record <name>`
      4. Tests are picked up automatically on next `mix test`

  If a fixture's source changes, the test will fail with a message
  telling you to re-record.  Run `mix pyex.fixture check` in CI to
  catch stale recordings early.
  """

  use ExUnit.Case, async: true

  alias Pyex.Test.Fixture

  for name <- Fixture.list_all() do
    describe "fixture: #{name}" do
      @fixture_name name

      test "matches CPython ground truth" do
        fixture = Fixture.load!(@fixture_name)
        result = Fixture.run_pyex(fixture)
        Fixture.assert_conforms(fixture, result)
      end
    end
  end
end
