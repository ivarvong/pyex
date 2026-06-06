defmodule Pyex.LexerStringPrefixDifferentialTest do
  @moduledoc """
  Differential test of string-literal lexing against CPython 3.14.

  The full Python *str* prefix matrix — every prefix (`''`, `r`/`R`, `f`/`F`,
  `u`/`U`, and the `rf`/`fr` combos in all case/order variants) crossed with
  all four quote styles (`"`, `'`, `\"\"\"`, `'''`) and a battery of bodies
  (escapes, braces, embedded quotes, real newlines) — was evaluated by
  CPython once at fixture-build time and committed to
  `test/fixtures/string_prefix_diff.json`. CPython is also the legality
  oracle: any prefix/quote/body triple that is not valid Python was dropped
  at generation time, so every committed vector is real, valid Python.

  This test re-evaluates each literal in pyex and asserts `repr()` matches
  CPython byte-for-byte. `repr` is a single uniform comparator that pins down
  both the value AND its exact bytes — it catches the failure mode that a
  token-kind check misses, e.g. a raw string that lexes to the right *kind*
  of token but silently interprets a `\\n` it should have kept literal.

  To regenerate:

      python3 test/fixtures/string_prefix_diff_gen.py

  The generator is a fixed cross-product (no RNG), so a fresh fixture is
  byte-identical to the committed one unless the generator changes.

  Bytes literals (`b"..."`, `rb"..."`, ...) are intentionally out of scope
  here: they are a separate lexing subsystem with their own pre-existing
  CPython divergences (raw bytes are cooked, `\\u`/`\\N` are wrongly
  interpreted, `repr(bytes)` quoting differs). They warrant a focused
  follow-up; the generator documents exactly how to extend to them.
  """

  use ExUnit.Case, async: true

  @fixture_path Path.join([__DIR__, "..", "fixtures", "string_prefix_diff.json"])
  @external_resource @fixture_path

  @vectors @fixture_path |> File.read!() |> Jason.decode!()

  test "every CPython-evaluated string literal reprs identically in pyex" do
    failures =
      @vectors
      |> Enum.reduce_while([], fn vector, acc ->
        case run_vector(vector) do
          :ok -> {:cont, acc}
          {:fail, reason} -> {:halt, [{vector, reason} | acc]}
        end
      end)

    case failures do
      [] ->
        :ok

      [{vector, reason} | _] ->
        flunk("""
        Differential mismatch on vector #{inspect(vector["id"])}.

        Source:   #{inspect(vector["src"])}
        Prefix:   #{inspect(vector["prefix"])}   Quote: #{inspect(vector["quote"])}
        Expected: #{inspect(vector["expected"])}  (CPython repr)
        Actual:   #{reason}

        Vectors evaluated before failure: #{length(@vectors) - length(failures) + 1}
        """)
    end
  end

  test "vector count matches what the generator emits (don't ship a stale fixture)" do
    assert length(@vectors) == 750
  end

  test "fixture spans every str prefix family and quote style we claim to cover" do
    prefixes = @vectors |> Enum.map(& &1["prefix"]) |> MapSet.new()
    quotes = @vectors |> Enum.map(& &1["quote"]) |> MapSet.new()

    # Empty prefix plus every case/order variant of r, f, u and rf/fr.
    for p <- ~w(r R f F u U rf fr Rf rF Fr fR RF FR) do
      assert p in prefixes, "fixture is missing prefix #{inspect(p)}"
    end

    assert "" in prefixes, "fixture is missing the no-prefix case"
    assert MapSet.equal?(quotes, MapSet.new(["\"", "'", "\"\"\"", "'''"]))
  end

  test "the matrix actually exercises the semantics that distinguish prefixes" do
    # Guard against a fixture that technically covers the prefixes but only
    # with inert bodies (e.g. someone regenerates with `ab`-only payloads).
    # We assert the distinguishing CONTRASTS rather than hardcoding repr
    # strings, so the check stays robust to escaping subtleties.
    by_src = Map.new(@vectors, &{&1["src"], &1["expected"]})

    require_keys = [~S|r"a\nb"|, ~S|"a\nb"|, ~S|f"{x}"|, ~S|"{x}"|, ~S|rf"\d+"|]

    for k <- require_keys do
      assert Map.has_key?(by_src, k), "fixture is missing distinguishing vector #{inspect(k)}"
    end

    # Raw keeps the backslash; cooked turns `\n` into a newline. The two
    # must differ, or raw-vs-cooked isn't being tested.
    assert by_src[~S|r"a\nb"|] != by_src[~S|"a\nb"|]

    # f-strings interpolate `{x}` -> "5"; plain strings keep it literal.
    assert by_src[~S|f"{x}"|] == "'5'"
    assert by_src[~S|"{x}"|] != by_src[~S|f"{x}"|]
  end

  # =========================================================================
  # Per-vector run + compare
  # =========================================================================

  # Each vector's literal is evaluated with `x` bound to 5 so f-string
  # interpolation is exercised, then compared via repr().
  defp run_vector(%{"src" => src, "expected" => expected}) do
    case Pyex.run("x = 5\nrepr(" <> src <> ")") do
      {:ok, actual, _ctx} when is_binary(actual) ->
        if actual == expected,
          do: :ok,
          else: {:fail, "got #{inspect(actual)}"}

      {:ok, actual, _ctx} ->
        {:fail, "non-string result: #{inspect(actual)}"}

      {:error, %Pyex.Error{message: msg}} ->
        {:fail, "raised: #{msg}"}
    end
  end
end
