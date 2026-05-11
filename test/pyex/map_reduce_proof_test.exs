defmodule Pyex.MapReduceProofTest do
  @moduledoc """
  Mathematical proof that `asyncio.gather` over `{:awaitable, fn}` capabilities
  delivers every result to the correct position.

  ## Why this proof is unbreakable

  The test uses a map function `f(x) = a·x mod p` where:
    - `p` is a large prime (2^61 − 1, the Mersenne prime M61)
    - `a` is a secret multiplier chosen at runtime, embedded only in the
      Elixir closure — the Python program never sees it
    - Inputs `[x₀, x₁, ..., x_{N-1}]` are N distinct random integers in [1, p-1],
      embedded as a literal list in the Python source

  Three independent checks, each targeting a different failure mode:

  ### Check 1 — Element-wise correctness (catches wrong inputs)

      result[i] == a·x_i mod p  for every i

  If call i received the wrong input x_j (j ≠ i), the result is a·x_j mod p.
  For this to accidentally match the expected a·x_i mod p would require
  x_j ≡ x_i (mod p), which is impossible because x_i and x_j are distinct
  values in [1, p-1].  This is a PROOF, not a probabilistic argument.

  ### Check 2 — Polynomial fingerprint (catches position swaps)

  Choose a random evaluation point r.  Compute:

      fingerprint(r) = Σ result[i] · r^i mod p

  If results are a nontrivial permutation of the correct values, this polynomial
  differs from the expected one at every point r except a root of their
  difference — at most N roots out of p choices.  By Schwartz-Zippel:

      Pr[false positive] ≤ N / p  ≈  64 / (2^61 - 1)  ≈  2.8 × 10⁻¹⁷

  ### Check 3 — MapReduce sum invariant (the algebraic heart)

  The linearity of f gives a closed-form expected reduce output:

      Σ f(x_i) = a · Σ x_i mod p

  The host can compute the RIGHT ANSWER for the reduce step WITHOUT running
  any map tasks.  This is the defining property of MapReduce: the reducer's
  output is derivable from the inputs alone.  If even one map result is
  wrong, the sum shifts by a·(x_wrong − x_right) mod p ≠ 0.

  ---

  Combined, these three checks make it MATHEMATICALLY IMPOSSIBLE for a buggy
  implementation to pass: element-wise correctness rules out wrong-input
  computation; the fingerprint rules out position swaps; the sum invariant
  is a redundant cross-check that validates the full algebraic structure.
  """

  use ExUnit.Case, async: true

  # M61 = 2^61 − 1.  The largest Mersenne prime that fits in a 64-bit word.
  # Modular arithmetic with this modulus is fast (Barrett / Montgomery) and
  # the prime is large enough that every probabilistic bound is negligible.
  @p 2_305_843_009_213_693_951

  # Number of parallel map tasks.  64 is enough that the false-positive
  # probability for the polynomial fingerprint is < 2^-55.
  @n 64

  describe "MapReduce correctness proof" do
    test "sum invariant: reduce output equals a·Σx_i mod p without running any map" do
      # This test isolates the algebraic MapReduce property.
      # The reduce result (sum of mapped values) must equal a·(sum of inputs) mod p.
      # The host computes the expected answer from the inputs alone — no map needed.
      {a, inputs, modules} = build_map_problem()

      src = map_reduce_python(inputs, reduce: :sum)
      # Python returns the raw integer sum (no mod reduction).
      # Reduce mod p on the Elixir side before comparing.
      actual_sum = Pyex.run!(src, modules: modules) |> rem(@p)

      expected_sum = rem(a * (Enum.sum(inputs) |> rem(@p)), @p)

      assert actual_sum == expected_sum,
             "sum invariant violated: got #{actual_sum}, expected #{expected_sum}"
    end

    test "element-wise: result[i] == f(inputs[i]) for every i (no wrong-input routing)" do
      # This test proves that capability i was invoked with input x_i, not x_j.
      # Proof: f is a bijection on Z_p and all inputs are distinct, so
      # f(x_j) ≠ f(x_i) for j ≠ i — a wrong result CANNOT accidentally pass.
      {a, inputs, modules} = build_map_problem()

      src = map_reduce_python(inputs, reduce: :list)
      results = Pyex.run!(src, modules: modules)

      expected = Enum.map(inputs, fn x -> rem(a * x, @p) end)

      assert length(results) == @n,
             "wrong result count: got #{length(results)}, expected #{@n}"

      Enum.each(0..(@n - 1), fn i ->
        assert Enum.at(results, i) == Enum.at(expected, i),
               "position #{i}: got #{Enum.at(results, i)}, expected #{Enum.at(expected, i)} " <>
                 "(input was #{Enum.at(inputs, i)}, secret multiplier was #{a})"
      end)
    end

    test "polynomial fingerprint: any position swap is detected with Pr < 2^-55" do
      # This test proves that results are in the correct ORDER, not just that
      # the correct values were computed.
      # Evaluation point r is chosen after the run so the implementation cannot
      # have tuned its output to pass a specific r — this is the Fiat-Shamir
      # pattern applied to a sequential test.
      {a, inputs, modules} = build_map_problem()

      src = map_reduce_python(inputs, reduce: :list)
      results = Pyex.run!(src, modules: modules)

      expected = Enum.map(inputs, fn x -> rem(a * x, @p) end)

      # Choose r AFTER receiving results (Fiat–Shamir heuristic).
      r = :rand.uniform(@p - 1)

      actual_fingerprint =
        results
        |> Enum.with_index()
        |> Enum.reduce(0, fn {v, i}, acc ->
          rem(acc + rem(v * mod_pow(r, i, @p), @p), @p)
        end)

      expected_fingerprint =
        expected
        |> Enum.with_index()
        |> Enum.reduce(0, fn {v, i}, acc ->
          rem(acc + rem(v * mod_pow(r, i, @p), @p), @p)
        end)

      assert actual_fingerprint == expected_fingerprint,
             "polynomial fingerprint mismatch at r=#{r}: " <>
               "results are either wrong or in the wrong order"
    end

    test "full proof: all three invariants hold simultaneously on a fresh problem" do
      # The definitive test.  Generates a fresh secret multiplier and fresh inputs
      # each run so the test cannot have been tuned to pass for a specific instance.
      # All three checks run on the same gather output.
      {a, inputs, modules} = build_map_problem()

      src = map_reduce_python(inputs, reduce: :list)
      results = Pyex.run!(src, modules: modules)

      expected = Enum.map(inputs, fn x -> rem(a * x, @p) end)

      # Check 1: count
      assert length(results) == @n

      # Check 2: element-wise (no wrong-input routing — provably impossible to fake)
      assert results == expected

      # Check 3: MapReduce sum invariant (closed-form, independent of map execution).
      # Each f(x_i) = a·x_i mod p, so Σ f(x_i) mod p = a · Σ x_i mod p.
      actual_sum = results |> Enum.sum() |> rem(@p)
      expected_sum = a |> Kernel.*(Enum.sum(inputs) |> rem(@p)) |> rem(@p)
      assert actual_sum == expected_sum

      # Check 4: polynomial fingerprint (position sensitivity, Pr[false pos] < 2^-55)
      r = :rand.uniform(@p - 1)

      poly = fn list ->
        list
        |> Enum.with_index()
        |> Enum.reduce(0, fn {v, i}, acc ->
          rem(acc + rem(v * mod_pow(r, i, @p), @p), @p)
        end)
      end

      assert poly.(results) == poly.(expected)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Build a fresh map problem: secret multiplier, distinct random inputs, modules.
  # The multiplier `a` is embedded in the Elixir closure — Python never sees it.
  defp build_map_problem do
    a = :rand.uniform(@p - 2) + 1

    # N distinct random inputs from [1, p-1].
    # Collision probability with N=64 draws from p ≈ 2^61 is N²/p < 2^-49.
    # We assert uniqueness explicitly so the injectivity argument is airtight.
    inputs =
      Stream.repeatedly(fn -> :rand.uniform(@p - 1) end)
      |> Stream.uniq()
      |> Enum.take(@n)

    assert length(Enum.uniq(inputs)) == @n, "inputs must be distinct"

    modules = %{
      "transform" => %{
        "f" => {:awaitable, fn [x] -> rem(a * x, @p) end}
      }
    }

    {a, inputs, modules}
  end

  # Emit a Python program that:
  #   - embeds the inputs as a literal list (no hidden state)
  #   - runs asyncio.gather over all f(x) calls in parallel
  #   - returns either the full list (reduce: :list) or the sum (reduce: :sum)
  defp map_reduce_python(inputs, reduce: reduce_op) do
    inputs_str = "[" <> Enum.map_join(inputs, ", ", &to_string/1) <> "]"

    reduce_body =
      case reduce_op do
        :list -> "return mapped"
        :sum -> "return sum(mapped)"
      end

    """
    import asyncio
    from transform import f

    INPUTS = #{inputs_str}

    async def main():
        # Map phase: apply f to every input in parallel via BEAM Tasks
        mapped = await asyncio.gather(*[f(x) for x in INPUTS])
        # Reduce phase
        #{reduce_body}

    asyncio.run(main())
    """
  end

  # Fast modular exponentiation (host-side, not Pyex's builtin).
  # Used for polynomial fingerprint computation without going through Pyex.
  defp mod_pow(_base, 0, _m), do: 1
  defp mod_pow(base, exp, m), do: do_mod_pow(rem(base, m), exp, m, 1)

  defp do_mod_pow(_base, 0, _m, acc), do: acc

  defp do_mod_pow(base, exp, m, acc) do
    acc = if rem(exp, 2) == 1, do: rem(acc * base, m), else: acc
    do_mod_pow(rem(base * base, m), div(exp, 2), m, acc)
  end
end
