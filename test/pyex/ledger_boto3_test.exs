defmodule Pyex.LedgerBoto3Test do
  @moduledoc """
  An end-to-end money-movement ledger written the way a developer (or an LLM)
  actually writes one against DynamoDB: a single physical table, atomic
  transfers via `client.transact_write_items`, overdraft + idempotency enforced
  by condition expressions, optimistic-locked metadata, and a partition-local
  `Query` for history. The Python here is unmodified application code — the test
  exercises that pyex runs it, not a pyex-flavoured rewrite of it.
  """

  use ExUnit.Case, async: true

  # The ledger library — the unit under test runs this verbatim, then appends a
  # scenario. Kept identical to what an app would ship in `ledger.py`.
  @ledger ~S'''
  import uuid
  from decimal import Decimal
  from datetime import datetime, timezone

  import boto3
  from boto3.dynamodb.conditions import Key

  dynamodb = boto3.resource("dynamodb")
  dynamodb.create_table(
      TableName="ledger",
      KeySchema=[
          {"AttributeName": "pk", "KeyType": "HASH"},
          {"AttributeName": "sk", "KeyType": "RANGE"},
      ],
      AttributeDefinitions=[
          {"AttributeName": "pk", "AttributeType": "S"},
          {"AttributeName": "sk", "AttributeType": "S"},
      ],
      BillingMode="PAY_PER_REQUEST",
  )
  table = dynamodb.Table("ledger")
  client = boto3.client("dynamodb")


  def _acct(account_id):
      return f"ACCT#{account_id}"


  class OverdraftError(Exception): ...
  class DuplicateTransfer(Exception): ...


  def open_account(account_id, currency="USD"):
      table.put_item(
          Item={"pk": _acct(account_id), "sk": "A", "kind": "Account",
                "balance_minor": 0, "currency": currency, "version": 1},
          ConditionExpression="attribute_not_exists(pk)",
      )


  def set_currency(account_id, currency):
      acct = table.get_item(Key={"pk": _acct(account_id), "sk": "A"})["Item"]
      table.update_item(
          Key={"pk": _acct(account_id), "sk": "A"},
          UpdateExpression="SET currency = :c, version = version + :one",
          ConditionExpression="version = :v",
          ExpressionAttributeValues={":c": currency, ":v": acct["version"], ":one": 1},
      )


  def transfer(src_id, dst_id, amount_minor, idem_key):
      if amount_minor <= 0:
          raise ValueError("amount must be positive")
      transfer_id = uuid.uuid4().hex
      now = datetime.now(timezone.utc).isoformat()
      src, dst = _acct(src_id), _acct(dst_id)
      try:
          client.transact_write_items(TransactItems=[
              {"Update": {"TableName": "ledger",
                          "Key": {"pk": {"S": src}, "sk": {"S": "A"}},
                          "UpdateExpression": "ADD balance_minor :neg",
                          "ConditionExpression": "balance_minor >= :amt",
                          "ExpressionAttributeValues": {":neg": {"N": str(-amount_minor)},
                                                        ":amt": {"N": str(amount_minor)}}}},
              {"Update": {"TableName": "ledger",
                          "Key": {"pk": {"S": dst}, "sk": {"S": "A"}},
                          "UpdateExpression": "ADD balance_minor :pos",
                          "ExpressionAttributeValues": {":pos": {"N": str(amount_minor)}}}},
              {"Put": {"TableName": "ledger",
                       "Item": {"pk": {"S": src}, "sk": {"S": f"ENTRY#{now}#{transfer_id}"},
                                "kind": {"S": "Entry"}, "amount_minor": {"N": str(-amount_minor)},
                                "transfer_id": {"S": transfer_id}, "counterparty": {"S": dst_id}}}},
              {"Put": {"TableName": "ledger",
                       "Item": {"pk": {"S": dst}, "sk": {"S": f"ENTRY#{now}#{transfer_id}"},
                                "kind": {"S": "Entry"}, "amount_minor": {"N": str(amount_minor)},
                                "transfer_id": {"S": transfer_id}, "counterparty": {"S": src_id}}}},
              {"Put": {"TableName": "ledger",
                       "Item": {"pk": {"S": f"IDEM#{idem_key}"}, "sk": {"S": "I"},
                                "transfer_id": {"S": transfer_id}},
                       "ConditionExpression": "attribute_not_exists(pk)"}},
          ])
      except client.exceptions.TransactionCanceledException as e:
          codes = [r.get("Code") for r in e.response["CancellationReasons"]]
          if codes[0] == "ConditionalCheckFailed":
              raise OverdraftError(src_id)
          if codes[4] == "ConditionalCheckFailed":
              raise DuplicateTransfer(idem_key)
          raise
      return transfer_id


  def balance(account_id):
      return int(table.get_item(Key={"pk": _acct(account_id), "sk": "A"})["Item"]["balance_minor"])


  def account_entries(account_id, limit=50):
      resp = table.query(
          KeyConditionExpression=Key("pk").eq(_acct(account_id)) & Key("sk").begins_with("ENTRY#"),
          ScanIndexForward=False,
          Limit=limit,
      )
      return resp["Items"]


  def _fund(account_id, amount_minor):
      client.transact_write_items(TransactItems=[
          {"Update": {"TableName": "ledger",
                      "Key": {"pk": {"S": _acct(account_id)}, "sk": {"S": "A"}},
                      "UpdateExpression": "ADD balance_minor :pos",
                      "ExpressionAttributeValues": {":pos": {"N": str(amount_minor)}}}},
      ])
  '''

  defp run(scenario) do
    {:ok, _value, ctx} = Pyex.run(@ledger <> scenario, storage: Pyex.Storage.Memory.new())
    String.trim(Pyex.output(ctx))
  end

  test "opening an account starts it at a zero balance" do
    out =
      run(~S'''
      open_account("alice")
      print(balance("alice"))
      ''')

    assert out == "0"
  end

  test "a transfer atomically debits the source and credits the destination" do
    out =
      run(~S'''
      open_account("alice")
      open_account("bob")
      _fund("alice", 10000)
      transfer("alice", "bob", 2500, "t1")
      print(balance("alice"), balance("bob"))
      ''')

    assert out == "7500 2500"
  end

  test "a transfer writes a signed double-entry on both account partitions" do
    out =
      run(~S'''
      open_account("alice")
      open_account("bob")
      _fund("alice", 10000)
      transfer("alice", "bob", 2500, "t1")
      print(account_entries("alice")[0]["amount_minor"], account_entries("alice")[0]["counterparty"])
      print(account_entries("bob")[0]["amount_minor"], account_entries("bob")[0]["counterparty"])
      ''')

    assert out == "-2500 bob\n2500 alice"
  end

  test "query returns a partition's history newest-first and honours Limit" do
    out =
      run(~S'''
      open_account("alice")
      open_account("bob")
      _fund("alice", 10000)
      transfer("alice", "bob", 100, "a")
      transfer("alice", "bob", 200, "b")
      transfer("alice", "bob", 300, "c")
      entries = account_entries("alice")
      sks = [e["sk"] for e in entries]
      print(len(entries), sks == sorted(sks, reverse=True), sorted(int(e["amount_minor"]) for e in entries))
      limited = account_entries("alice", limit=2)
      print(len(limited), [e["sk"] for e in limited] == sks[:2])
      ''')

    # All three present, returned in descending sort-key order (newest-first),
    # and Limit=2 is the leading window of that same descending list.
    assert out == "3 True [-300, -200, -100]\n2 True"
  end

  test "query scopes strictly to its partition and never bleeds a sibling prefix" do
    # ACCT#1 must not match ACCT#10 — the prefix-collision the key separator guards.
    out =
      run(~S'''
      open_account("1")
      open_account("10")
      _fund("1", 5000)
      _fund("10", 5000)
      open_account("dst")
      transfer("1", "dst", 100, "x")
      transfer("10", "dst", 200, "y")
      print(len(account_entries("1")), len(account_entries("10")))
      ''')

    assert out == "1 1"
  end

  test "re-opening an existing account fails the attribute_not_exists guard" do
    out =
      run(~S'''
      open_account("alice")
      try:
          open_account("alice", "EUR")
          print("NOT BLOCKED")
      except Exception as e:
          print(type(e).__name__)
      ''')

    assert out == "ConditionalCheckFailedException"
  end

  test "an overdrafting transfer is cancelled and leaves both balances untouched" do
    out =
      run(~S'''
      open_account("alice")
      open_account("bob")
      _fund("alice", 1000)
      try:
          transfer("alice", "bob", 999999, "od")
          print("NOT CAUGHT")
      except OverdraftError as e:
          print("overdraft", str(e), balance("alice"), balance("bob"))
      ''')

    assert out == "overdraft alice 1000 0"
  end

  test "replaying a transfer with the same idempotency key raises DuplicateTransfer" do
    out =
      run(~S'''
      open_account("alice")
      open_account("bob")
      _fund("alice", 10000)
      transfer("alice", "bob", 100, "same-key")
      try:
          transfer("alice", "bob", 100, "same-key")
          print("NOT CAUGHT")
      except DuplicateTransfer as e:
          print("dup", str(e), balance("alice"), balance("bob"))
      ''')

    # Second attempt is rejected: balances reflect exactly one transfer.
    assert out == "dup same-key 9900 100"
  end

  test "a stale optimistic-lock version loses the conditional update" do
    out =
      run(~S'''
      open_account("alice")
      # A first writer bumps version 1 -> 2 underneath us.
      table.update_item(
          Key={"pk": _acct("alice"), "sk": "A"},
          UpdateExpression="SET version = version + :one",
          ConditionExpression="version = :v",
          ExpressionAttributeValues={":v": 1, ":one": 1},
      )
      # set_currency read version 1 earlier; its conditional write must now fail.
      try:
          table.update_item(
              Key={"pk": _acct("alice"), "sk": "A"},
              UpdateExpression="SET currency = :c, version = version + :one",
              ConditionExpression="version = :v",
              ExpressionAttributeValues={":c": "EUR", ":v": 1, ":one": 1},
          )
          print("NOT BLOCKED")
      except Exception as e:
          print(type(e).__name__)
      ''')

    assert out == "ConditionalCheckFailedException"
  end

  test "a non-positive transfer amount is rejected before any write happens" do
    out =
      run(~S'''
      open_account("alice")
      open_account("bob")
      _fund("alice", 1000)
      try:
          transfer("alice", "bob", 0, "z")
          print("NOT CAUGHT")
      except ValueError as e:
          print(str(e), balance("alice"))
      ''')

    assert out == "amount must be positive 1000"
  end

  test "set_currency commits through the optimistic lock and bumps the version" do
    out =
      run(~S'''
      open_account("alice")
      set_currency("alice", "EUR")
      acct = table.get_item(Key={"pk": _acct("alice"), "sk": "A"})["Item"]
      print(acct["currency"], int(acct["version"]))
      ''')

    assert out == "EUR 2"
  end
end
