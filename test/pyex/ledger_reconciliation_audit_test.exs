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

    summary = Jason.decode!(Map.fetch!(result.files, "summary.json"))
    balances = Jason.decode!(Map.fetch!(result.files, "balances.json"))
    audit = Jason.decode!(Map.fetch!(result.files, "audit.json"))
    exceptions = parse_exceptions(Map.fetch!(result.files, "exceptions.csv"))

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
