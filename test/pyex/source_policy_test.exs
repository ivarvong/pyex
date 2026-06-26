defmodule Pyex.SourcePolicyTest do
  @moduledoc """
  Executable source policy: bans patterns that review keeps having to
  catch, by making them fail the build instead.

  Process-global mutable state (`:persistent_term`) has no place in a
  per-run sandbox — it leaks across evaluations and every write triggers a
  global GC. The trouble with such patterns is that one blessed example
  invites the next copy, so the only sanctioned uses are the explicit,
  justified entries below. Adding a use without an entry fails this test;
  copying an existing one is not a justification.

  Same forcing-function shape as the parity manifest: a deviation is loud
  and asserted, not a thing a reviewer must remember to object to.
  """

  use ExUnit.Case, async: true

  # path => why this specific use is justified (and why not to copy it).
  @persistent_term_allowlist %{
    "lib/pyex/builtins.ex" =>
      "Builtins env cache: a large map identical across every run, read on " <>
        "each program start. A deliberate startup optimization, not per-run state."
  }

  test "no :persistent_term outside the justified allowlist" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&String.contains?(File.read!(&1), ":persistent_term"))
      |> Enum.map(&Path.relative_to_cwd/1)
      |> Enum.sort()

    unexpected = offenders -- Map.keys(@persistent_term_allowlist)

    assert unexpected == [],
           "New :persistent_term in #{inspect(unexpected)}. Process-global mutable " <>
             "state is banned in the sandbox — remove it, or (rarely) add a justified " <>
             "entry to @persistent_term_allowlist explaining why this one is safe."

    stale = Map.keys(@persistent_term_allowlist) -- offenders

    assert stale == [],
           "Allowlisted files no longer use :persistent_term: #{inspect(stale)}. " <>
             "Delete the stale entries — the allowlist must reflect reality."
  end
end
