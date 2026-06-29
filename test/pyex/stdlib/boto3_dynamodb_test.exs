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
