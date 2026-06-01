defmodule Pyex.BannedCallTracerTest do
  @moduledoc """
  Verifies that the Pyex library itself never calls banned system functions.

  This test loads the compiled `.beam` files and walks the abstract code
  (Erlang debug info) looking for calls into File, Process, System.cmd,
  Port, Node, Agent, etc. — the same approach as JustBash.BannedCallTracer.

  Pyex is a purely functional library that must not own global state or
  escape the sandbox it provides. Any violation here is a real bug.
  """

  use ExUnit.Case, async: false

  alias Pyex.BannedCallTracer

  @beam_dir "_build/test/lib/pyex/ebin"

  # Modules that are explicitly permitted to touch real filesystem/system
  # resources — either dev tooling that runs on the developer's machine,
  # or test infrastructure that must read fixture files from disk.
  @excluded_modules ~w[
    Elixir.Mix.Tasks.Pyex
    Elixir.Mix.Tasks.Pyex.Fixture
    Elixir.Mix.Tasks.Pyex.Trace
    Elixir.Mix.Tasks.Pyex.Bench.Budget
    Elixir.Mix.Tasks.Pyex.Bench.Coordinator
    Elixir.Mix.Tasks.Pyex.Bench.Worker
    Elixir.Pyex.Test.Fixture
    Elixir.Pyex.Test.Oracle
    Elixir.Pyex.Test.DifferentialFuzz
    Elixir.Pyex.Test.LibraryConformance
  ]

  test "no banned calls in the Pyex library" do
    violations =
      BannedCallTracer.check_app(@beam_dir)
      |> Enum.reject(fn %{beam: beam} ->
        basename = Path.basename(beam, ".beam")
        basename in @excluded_modules
      end)

    if violations != [] do
      lines =
        violations
        |> Enum.map(fn
          %{call: :no_debug_info, beam: beam} ->
            short = beam |> Path.basename() |> Path.rootname()
            "  #{short}  (no debug info — tracer cannot inspect this beam)"

          %{call: {mod, fun, arity}, beam: beam, line: line} ->
            short = beam |> Path.basename() |> Path.rootname()
            "  #{short}:#{line}  #{inspect(mod)}.#{fun}/#{arity}"
        end)
        |> Enum.join("\n")

      flunk("""
      #{length(violations)} banned call(s) found in Pyex library BEAM files.

      Pyex must not own global state, spawn processes, or call real OS/filesystem
      functions. See Pyex.BannedCallTracer for the full security model.

      Violations:
      #{lines}

      Fix each violation, or — if the call is genuinely necessary — add it to
      the @allowed list in Pyex.BannedCallTracer with a clear justification.
      """)
    end
  end

  test "tracer reports a beam without abstract code as a violation, not a silent pass" do
    # If a beam ever lacks abstract code (e.g. a stripped release with
    # `strip_beams: true`), the tracer must fail loudly — otherwise the
    # whole security gate is vacuous: an uninspectable module is reported
    # clean.  Synthesize a stripped beam and verify the tracer flags it.
    tmp = Path.join(System.tmp_dir!(), "pyex_no_debug_info_test")
    File.mkdir_p!(tmp)

    src_beam = Path.join(@beam_dir, "Elixir.Pyex.Stdlib.Time.beam")
    stripped_beam = Path.join(tmp, "Elixir.Pyex.Stdlib.Time.beam")

    try do
      # `:beam_lib.strip/1` removes the Dbgi/Abst chunk but keeps the
      # module loadable.  After stripping, `:beam_lib.chunks/2` returns
      # `:no_abstract_code` (vs `:no_debug_info` for never-built-with-it).
      {:ok, bin} = File.read(src_beam)
      {:ok, {_mod, stripped_bin}} = :beam_lib.strip(bin)
      File.write!(stripped_beam, stripped_bin)

      # Sanity: confirm the strip actually removed abstract code.
      {:ok, {_mod, [{:abstract_code, kind}]}} =
        :beam_lib.chunks(String.to_charlist(stripped_beam), [:abstract_code])

      assert kind in [:no_abstract_code, :no_debug_info],
             "Expected strip to remove abstract code; got #{inspect(kind)}"

      violations = BannedCallTracer.check_beam(stripped_beam)

      assert [%{call: :no_debug_info, beam: ^stripped_beam, line: 0}] = violations
    after
      File.rm_rf!(tmp)
    end
  end

  test "tracer finds violations in a beam that contains them" do
    # Verify the tracer correctly identifies banned calls by inspecting the
    # Mix task beams, which are explicitly in the exclusion list but do
    # contain real File.* calls we can assert on.
    mix_task_beam =
      Path.join(@beam_dir, "Elixir.Mix.Tasks.Pyex.Fixture.beam")

    assert File.exists?(mix_task_beam),
           "Expected #{mix_task_beam} to exist. Run `mix compile` first."

    violations = BannedCallTracer.check_beam(mix_task_beam)
    calls = Enum.map(violations, fn %{call: c} -> c end)

    assert Enum.any?(calls, fn {mod, _fun, _arity} -> mod == File end),
           "Expected File.* calls in Mix.Tasks.Pyex.Fixture, got: #{inspect(calls)}"

    assert Enum.any?(calls, fn {mod, _fun, _arity} -> mod == System end),
           "Expected System.* calls in Mix.Tasks.Pyex.Fixture, got: #{inspect(calls)}"
  end

  test "tracer reports zero violations for a clean beam" do
    # The time stdlib module is explicitly in the library and calls
    # only :os.system_time/1 (which is in the allowlist) and Process.sleep/1
    # (also allowlisted). It should be completely clean.
    time_beam = Path.join(@beam_dir, "Elixir.Pyex.Stdlib.Time.beam")

    assert File.exists?(time_beam),
           "Expected #{time_beam} to exist. Run `mix compile` first."

    violations = BannedCallTracer.check_beam(time_beam)

    assert violations == [],
           "Pyex.Stdlib.Time should be clean (allowlisted calls only), got: #{inspect(violations)}"
  end
end
