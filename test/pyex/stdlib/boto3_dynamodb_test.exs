defmodule Pyex.Stdlib.Boto3.DynamoDBTest do
  @moduledoc """
  The local DynamoDB backend for `boto3.resource("dynamodb")`: typed-value
  marshalling (Decimal exactness, the float-not-supported gotcha), the item
  CRUD surface, composite keys, and the denied-by-default storage posture.
  """

  use ExUnit.Case, async: true

  defp run(src, opts \\ [storage: Pyex.Storage.Memory.new()]) do
    {:ok, _value, ctx} = Pyex.run(src, opts)
    String.trim(Pyex.output(ctx))
  end

  @table ~S'''
  import boto3
  dynamodb = boto3.resource("dynamodb")
  dynamodb.create_table(
      TableName="t",
      KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
      AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
      BillingMode="PAY_PER_REQUEST",
  )
  table = dynamodb.Table("t")
  '''

  test "put_item / get_item round-trips with Decimal numbers returned exactly" do
    out =
      run(
        @table <>
          ~S'''
          from decimal import Decimal
          table.put_item(Item={"pk": "a", "amount": Decimal("9.99"), "qty": 3, "ok": True, "note": None})
          item = table.get_item(Key={"pk": "a"})["Item"]
          print(item["amount"], type(item["amount"]).__name__)
          print(item["qty"], type(item["qty"]).__name__)
          print(item["ok"], item["note"])
          print(item["amount"] + Decimal("0.01"))
          '''
      )

    # Numbers come back as Decimal (DynamoDB semantics); 9.99 + 0.01 == 10.00 exactly.
    assert out == "9.99 Decimal\n3 Decimal\nTrue None\n10.00"
  end

  test "floats are rejected, as in real boto3" do
    out =
      run(
        @table <>
          ~S'''
          try:
              table.put_item(Item={"pk": "a", "amount": 9.99})
          except TypeError as e:
              print("rejected")
          '''
      )

    assert out == "rejected"
  end

  test "get_item on a missing key omits Item" do
    out =
      run(
        @table <>
          ~S'''
          print("Item" in table.get_item(Key={"pk": "missing"}))
          '''
      )

    assert out == "False"
  end

  test "scan returns all items with a Count" do
    out =
      run(
        @table <>
          ~S'''
          from decimal import Decimal
          table.put_item(Item={"pk": "a", "v": Decimal("1")})
          table.put_item(Item={"pk": "b", "v": Decimal("2")})
          resp = table.scan()
          print(resp["Count"])
          print(sorted(i["pk"] for i in resp["Items"]))
          '''
      )

    assert out == "2\n['a', 'b']"
  end

  test "delete_item removes an item" do
    out =
      run(
        @table <>
          ~S'''
          table.put_item(Item={"pk": "a", "v": "x"})
          table.delete_item(Key={"pk": "a"})
          print("Item" in table.get_item(Key={"pk": "a"}))
          print(table.scan()["Count"])
          '''
      )

    assert out == "False\n0"
  end

  test "nested maps and lists round-trip" do
    out =
      run(
        @table <>
          ~S'''
          from decimal import Decimal
          table.put_item(Item={
              "pk": "a",
              "tags": ["food", "lunch"],
              "meta": {"vendor": "cafe", "rating": Decimal("4")},
          })
          item = table.get_item(Key={"pk": "a"})["Item"]
          print(item["tags"])
          print(item["meta"]["vendor"], item["meta"]["rating"])
          '''
      )

    assert out == "['food', 'lunch']\ncafe 4"
  end

  test "composite (hash + range) keys address distinct items" do
    out =
      run(~S'''
      import boto3
      dynamodb = boto3.resource("dynamodb")
      dynamodb.create_table(
          TableName="events",
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
      table = dynamodb.Table("events")
      table.put_item(Item={"pk": "u1", "sk": "2024-01", "n": "jan"})
      table.put_item(Item={"pk": "u1", "sk": "2024-02", "n": "feb"})
      print(table.get_item(Key={"pk": "u1", "sk": "2024-02"})["Item"]["n"])
      print(table.scan()["Count"])
      ''')

    assert out == "feb\n2"
  end

  test "operating on an unknown table raises ResourceNotFoundException" do
    out =
      run(~S'''
      import boto3
      table = boto3.resource("dynamodb").Table("nope")
      try:
          table.put_item(Item={"id": "1"})
      except Exception as e:
          print(type(e).__name__)
      ''')

    assert out == "ResourceNotFoundException"
  end

  @composite ~S'''
  import boto3
  from boto3.dynamodb.conditions import Key
  dynamodb = boto3.resource("dynamodb")
  dynamodb.create_table(
      TableName="t",
      KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"},
                 {"AttributeName": "sk", "KeyType": "RANGE"}],
      AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"},
                            {"AttributeName": "sk", "AttributeType": "S"}],
      BillingMode="PAY_PER_REQUEST",
  )
  table = dynamodb.Table("t")
  '''

  test "query with a Key partition-equality and sort begins_with filters the partition" do
    out =
      run(
        @composite <>
          ~S'''
          for sk in ["LOG#1", "LOG#2", "META#x", "LOG#3"]:
              table.put_item(Item={"pk": "p", "sk": sk})
          table.put_item(Item={"pk": "other", "sk": "LOG#1"})
          resp = table.query(KeyConditionExpression=Key("pk").eq("p") & Key("sk").begins_with("LOG#"))
          print(resp["Count"], [i["sk"] for i in resp["Items"]])
          '''
      )

    assert out == "3 ['LOG#1', 'LOG#2', 'LOG#3']"
  end

  test "query ScanIndexForward=False reverses the sort order and Limit truncates" do
    out =
      run(
        @composite <>
          ~S'''
          for sk in ["a", "b", "c", "d"]:
              table.put_item(Item={"pk": "p", "sk": sk})
          resp = table.query(KeyConditionExpression=Key("pk").eq("p"), ScanIndexForward=False, Limit=2)
          print([i["sk"] for i in resp["Items"]])
          '''
      )

    assert out == "['d', 'c']"
  end

  test "a partition prefix never bleeds into a longer sibling partition" do
    out =
      run(
        @composite <>
          ~S'''
          table.put_item(Item={"pk": "1", "sk": "x"})
          table.put_item(Item={"pk": "10", "sk": "y"})
          print(table.query(KeyConditionExpression=Key("pk").eq("1"))["Count"])
          '''
      )

    assert out == "1"
  end

  test "put_item ConditionExpression attribute_not_exists makes a create idempotent" do
    out =
      run(
        @composite <>
          ~S'''
          table.put_item(Item={"pk": "p", "sk": "A", "v": 1})
          try:
              table.put_item(Item={"pk": "p", "sk": "A", "v": 2}, ConditionExpression="attribute_not_exists(pk)")
              print("OVERWROTE")
          except Exception as e:
              print(type(e).__name__, int(table.get_item(Key={"pk": "p", "sk": "A"})["Item"]["v"]))
          '''
      )

    assert out == "ConditionalCheckFailedException 1"
  end

  test "update_item SET and ADD mutate an existing item; ADD is an atomic delta" do
    out =
      run(
        @composite <>
          ~S'''
          table.put_item(Item={"pk": "p", "sk": "A", "n": 10, "label": "old"})
          table.update_item(
              Key={"pk": "p", "sk": "A"},
              UpdateExpression="SET label = :l ADD n :d",
              ExpressionAttributeValues={":l": "new", ":d": 5},
          )
          item = table.get_item(Key={"pk": "p", "sk": "A"})["Item"]
          print(item["label"], int(item["n"]))
          '''
      )

    assert out == "new 15"
  end

  test "update_item with a failing ConditionExpression leaves the item unchanged" do
    out =
      run(
        @composite <>
          ~S'''
          table.put_item(Item={"pk": "p", "sk": "A", "version": 1})
          try:
              table.update_item(
                  Key={"pk": "p", "sk": "A"},
                  UpdateExpression="SET version = :two",
                  ConditionExpression="version = :stale",
                  ExpressionAttributeValues={":two": 2, ":stale": 99},
              )
              print("UPDATED")
          except Exception as e:
              print(type(e).__name__, int(table.get_item(Key={"pk": "p", "sk": "A"})["Item"]["version"]))
          '''
      )

    assert out == "ConditionalCheckFailedException 1"
  end

  test "without a storage backend, DynamoDB is denied" do
    {:ok, _v, ctx} =
      Pyex.run(~S'''
      import boto3
      dynamodb = boto3.resource("dynamodb")
      try:
          dynamodb.create_table(
              TableName="t",
              KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
              AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
              BillingMode="PAY_PER_REQUEST",
          )
      except Exception as e:
          print(type(e).__name__)
      ''')

    assert String.trim(Pyex.output(ctx)) == "StorageError"
  end
end
