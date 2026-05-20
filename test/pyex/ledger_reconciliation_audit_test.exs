defmodule Pyex.LedgerReconciliationAuditTest do
  @moduledoc """
  Independent audit checks for the ledger reconciliation gauntlet.

  The fixture already compares Pyex output to CPython. These tests add a second
  line of defense by recomputing accounting invariants from Pyex's emitted files
  without trusting the Python program's internal assertions.
  """

  use ExUnit.Case, async: true

  alias Pyex.Test.Fixture

  test "ledger gauntlet output satisfies independent accounting invariants" do
    fixture = Fixture.load!("ledger_reconciliation_gauntlet")
    result = Fixture.run_pyex(fixture)

    Fixture.assert_conforms(fixture, result)
    audit_files!(result.files)
  end

  test "ledger audit rejects corrupted proof artifacts" do
    fixture = Fixture.load!("ledger_reconciliation_gauntlet")
    result = Fixture.run_pyex(fixture)
    Fixture.assert_conforms(fixture, result)

    mutations = [
      {:accepted_count,
       fn files ->
         mutate_summary(files, fn summary -> Map.update!(summary, "accepted", &(&1 + 1)) end)
       end},
      {:movement_total,
       fn files ->
         mutate_summary(files, fn summary -> Map.update!(summary, "movement", &(&1 + 1)) end)
       end},
      {:balance_sign,
       fn files ->
         mutate_balances(files, fn [[account, amount] | rest] -> [[account, -amount] | rest] end)
       end},
      {:balance_order,
       fn files ->
         mutate_balances(files, fn [first, second | rest] -> [second, first | rest] end)
       end},
      {:audit_drop, fn files -> mutate_audit(files, fn [_first | rest] -> rest end) end},
      {:audit_duplicate,
       fn files -> mutate_audit(files, fn [first | _] = rows -> [first | rows] end) end},
      {:audit_amount,
       fn files ->
         mutate_audit(files, fn [[event, src, dst, amount] | rest] ->
           [[event, src, dst, amount + 1] | rest]
         end)
       end},
      {:audit_shape,
       fn files ->
         mutate_audit(files, fn [[event, src, _dst, amount] | rest] ->
           [[event, src, src, amount] | rest]
         end)
       end},
      {:exception_reason,
       fn files ->
         mutate_exceptions(files, fn [[event_id, _reason] | rest] ->
           [[event_id, "wrong"] | rest]
         end)
       end},
      {:exception_order,
       fn files ->
         mutate_exceptions(files, fn [first, second | rest] -> [second, first | rest] end)
       end}
    ]

    for {name, mutate} <- mutations do
      try do
        result.files
        |> mutate.()
        |> audit_files!()

        flunk("mutation #{name} should fail the independent ledger audit")
      rescue
        ExUnit.AssertionError -> :ok
      end
    end
  end

  defp audit_files!(files) do
    summary = Jason.decode!(Map.fetch!(files, "summary.json"))
    balances = Jason.decode!(Map.fetch!(files, "balances.json"))
    audit = Jason.decode!(Map.fetch!(files, "audit.json"))
    exceptions = parse_exceptions(Map.fetch!(files, "exceptions.csv"))

    assert length(audit) == summary["accepted"]
    assert length(exceptions) == summary["exceptions"]

    assert summary["accepted"] + summary["duplicates"] + summary["exceptions"] ==
             summary["events"]

    assert sum_balances(balances) == 0
    assert sum_audit_movement(audit) == summary["movement"]
    assert reconstructed_balances(audit) == balance_map(balances)

    assert Enum.all?(audit, fn [event_id, src, dst, amount] ->
             is_binary(event_id) and is_binary(src) and is_binary(dst) and
               is_integer(amount) and amount > 0 and src != dst
           end)

    assert exceptions == Enum.sort(exceptions)
    assert balances == Enum.sort_by(balances, fn [account, _amount] -> account end)

    assert Enum.all?(exceptions, fn [event_id, reason] ->
             is_binary(event_id) and
               reason in ["inactive-account", "missing-account", "non-positive"]
           end)
  end

  defp mutate_summary(files, fun) do
    Map.update!(files, "summary.json", fn json ->
      json
      |> Jason.decode!()
      |> fun.()
      |> Jason.encode!(pretty: false)
    end)
  end

  defp mutate_balances(files, fun) do
    Map.update!(files, "balances.json", fn json ->
      json
      |> Jason.decode!()
      |> fun.()
      |> Jason.encode!(pretty: false)
    end)
  end

  defp mutate_audit(files, fun) do
    Map.update!(files, "audit.json", fn json ->
      json
      |> Jason.decode!()
      |> fun.()
      |> Jason.encode!(pretty: false)
    end)
  end

  defp mutate_exceptions(files, fun) do
    Map.update!(files, "exceptions.csv", fn csv ->
      csv
      |> parse_exceptions()
      |> fun.()
      |> encode_exceptions()
    end)
  end

  defp encode_exceptions(rows) do
    body = Enum.map_join(rows, "\n", fn [event_id, reason] -> event_id <> "," <> reason end)
    "event_id,reason\n" <> body <> "\n"
  end

  defp parse_exceptions(csv) do
    csv
    |> String.split("\n", trim: true)
    |> tl()
    |> Enum.map(fn line ->
      [event_id, reason] = String.split(line, ",", parts: 2)
      [event_id, reason]
    end)
  end

  defp sum_balances(balances) do
    Enum.reduce(balances, 0, fn [_account, amount], total -> total + amount end)
  end

  defp sum_audit_movement(audit) do
    Enum.reduce(audit, 0, fn [_event_id, _src, _dst, amount], total -> total + amount end)
  end

  defp balance_map(balances) do
    Map.new(balances, fn [account, amount] -> {account, amount} end)
  end

  defp reconstructed_balances(audit) do
    Enum.reduce(audit, %{}, fn [_event_id, src, dst, amount], balances ->
      balances
      |> Map.update(src, -amount, &(&1 - amount))
      |> Map.update(dst, amount, &(&1 + amount))
    end)
  end
end
