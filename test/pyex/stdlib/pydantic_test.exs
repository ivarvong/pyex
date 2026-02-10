defmodule Pyex.Stdlib.PydanticTest do
  use ExUnit.Case, async: true

  defp run!(source) do
    Pyex.run!(source)
  end

  defp run_error(source) do
    case Pyex.run(source) do
      {:error, err} -> err.message
      {:ok, val, _} -> {:unexpected_ok, val}
    end
  end

  describe "BaseModel basics" do
    test "simple model with required fields" do
      result =
        run!("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            age: int

        user = User(name="Alice", age=30)
        [user.name, user.age]
        """)

      assert result == ["Alice", 30]
    end

    test "model with default values" do
      result =
        run!("""
        from pydantic import BaseModel

        class Item(BaseModel):
            name: str
            quantity: int = 1
            active: bool = True

        item = Item(name="Widget")
        [item.name, item.quantity, item.active]
        """)

      assert result == ["Widget", 1, true]
    end

    test "missing required field raises ValidationError" do
      msg =
        run_error("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            age: int

        User(name="Alice")
        """)

      assert msg =~ "ValidationError"
      assert msg =~ "age"
      assert msg =~ "field required"
    end

    test "multiple missing fields" do
      msg =
        run_error("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            age: int
            email: str

        User()
        """)

      assert msg =~ "ValidationError"
      assert msg =~ "name"
      assert msg =~ "age"
      assert msg =~ "email"
    end
  end

  describe "type coercion" do
    test "int to float" do
      result =
        run!("""
        from pydantic import BaseModel

        class Item(BaseModel):
            price: float

        item = Item(price=9)
        [item.price, type(item.price).__name__]
        """)

      assert result == [9.0, "float"]
    end

    test "string to int" do
      result =
        run!("""
        from pydantic import BaseModel

        class Config(BaseModel):
            port: int

        c = Config(port="8080")
        c.port
        """)

      assert result == 8080
    end

    test "string to float" do
      result =
        run!("""
        from pydantic import BaseModel

        class Config(BaseModel):
            rate: float

        c = Config(rate="3.14")
        c.rate
        """)

      assert result == 3.14
    end

    test "invalid coercion raises" do
      msg =
        run_error("""
        from pydantic import BaseModel

        class Config(BaseModel):
            port: int

        Config(port="not_a_number")
        """)

      assert msg =~ "ValidationError"
      assert msg =~ "port"
    end
  end

  describe "Optional fields" do
    test "Optional field defaults to None" do
      result =
        run!("""
        from pydantic import BaseModel

        class Profile(BaseModel):
            username: str
            bio: Optional[str] = None

        p = Profile(username="alice")
        [p.username, p.bio]
        """)

      assert result == ["alice", nil]
    end

    test "Optional field accepts value" do
      result =
        run!("""
        from pydantic import BaseModel

        class Profile(BaseModel):
            username: str
            bio: Optional[str] = None

        p = Profile(username="alice", bio="Hello!")
        p.bio
        """)

      assert result == "Hello!"
    end
  end

  describe "List and Dict typed fields" do
    test "List[str] field" do
      result =
        run!("""
        from pydantic import BaseModel

        class Config(BaseModel):
            tags: List[str] = []

        c = Config(tags=["a", "b", "c"])
        c.tags
        """)

      assert result == ["a", "b", "c"]
    end

    test "Dict[str, int] field" do
      result =
        run!("""
        from pydantic import BaseModel

        class Config(BaseModel):
            settings: Dict[str, int] = {}

        c = Config(settings={"x": 1, "y": 2})
        c.settings
        """)

      assert result == %{"x" => 1, "y" => 2}
    end

    test "List[int] coerces elements" do
      result =
        run!("""
        from pydantic import BaseModel

        class Data(BaseModel):
            values: List[float]

        d = Data(values=[1, 2, 3])
        d.values
        """)

      assert result == [1.0, 2.0, 3.0]
    end
  end

  describe "model_dump" do
    test "basic model_dump" do
      result =
        run!("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            age: int

        user = User(name="Alice", age=30)
        user.model_dump()
        """)

      assert result == %{"name" => "Alice", "age" => 30}
    end

    test "model_dump with exclude_none" do
      result =
        run!("""
        from pydantic import BaseModel

        class Profile(BaseModel):
            name: str
            bio: Optional[str] = None
            age: Optional[int] = None

        p = Profile(name="Alice")
        p.model_dump(exclude_none=True)
        """)

      assert result == %{"name" => "Alice"}
    end

    test "model_dump with include" do
      result =
        run!("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            age: int
            email: str

        user = User(name="Alice", age=30, email="a@b.com")
        user.model_dump(include={"name"})
        """)

      assert result == %{"name" => "Alice"}
    end

    test "model_dump with exclude" do
      result =
        run!("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            age: int
            email: str

        user = User(name="Alice", age=30, email="a@b.com")
        user.model_dump(exclude={"email"})
        """)

      assert result == %{"name" => "Alice", "age" => 30}
    end
  end

  describe "model_validate" do
    test "validates dict to model" do
      result =
        run!("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            age: int

        data = {"name": "Bob", "age": 25}
        user = User.model_validate(data)
        [user.name, user.age]
        """)

      assert result == ["Bob", 25]
    end

    test "model_validate with type coercion" do
      result =
        run!("""
        from pydantic import BaseModel

        class Item(BaseModel):
            name: str
            price: float

        item = Item.model_validate({"name": "Widget", "price": 10})
        item.price
        """)

      assert result == 10.0
    end

    test "model_validate raises on invalid data" do
      msg =
        run_error("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            age: int

        User.model_validate({"name": "Alice"})
        """)

      assert msg =~ "ValidationError"
      assert msg =~ "age"
    end

    test "model_validate on instance also works" do
      result =
        run!("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            age: int

        u = User(name="x", age=1)
        u2 = u.model_validate({"name": "Bob", "age": 25})
        u2.name
        """)

      assert result == "Bob"
    end
  end

  describe "Field with constraints" do
    test "gt constraint" do
      msg =
        run_error("""
        from pydantic import BaseModel, Field

        class Product(BaseModel):
            price: float = Field(gt=0)

        Product(price=-1.0)
        """)

      assert msg =~ "ValidationError"
      assert msg =~ "must be > 0"
    end

    test "ge constraint" do
      result =
        run!("""
        from pydantic import BaseModel, Field

        class Product(BaseModel):
            quantity: int = Field(ge=0)

        p = Product(quantity=0)
        p.quantity
        """)

      assert result == 0
    end

    test "le constraint" do
      msg =
        run_error("""
        from pydantic import BaseModel, Field

        class Rating(BaseModel):
            score: float = Field(ge=0.0, le=5.0)

        Rating(score=6.0)
        """)

      assert msg =~ "must be <= 5.0"
    end

    test "min_length constraint" do
      msg =
        run_error("""
        from pydantic import BaseModel, Field

        class User(BaseModel):
            name: str = Field(min_length=1)

        User(name="")
        """)

      assert msg =~ "length must be >= 1"
    end

    test "max_length constraint" do
      msg =
        run_error("""
        from pydantic import BaseModel, Field

        class User(BaseModel):
            name: str = Field(max_length=5)

        User(name="toolongname")
        """)

      assert msg =~ "length must be <= 5"
    end

    test "Field with default value" do
      result =
        run!("""
        from pydantic import BaseModel, Field

        class Config(BaseModel):
            timeout: int = Field(default=30, ge=1)

        c = Config()
        c.timeout
        """)

      assert result == 30
    end

    test "pattern constraint" do
      msg =
        run_error("""
        from pydantic import BaseModel, Field

        class Product(BaseModel):
            sku: str = Field(pattern="^[A-Z]{2}-[0-9]{4}$")

        Product(sku="invalid")
        """)

      assert msg =~ "must match"
    end

    test "pattern constraint passes on valid input" do
      result =
        run!("""
        from pydantic import BaseModel, Field

        class Product(BaseModel):
            sku: str = Field(pattern="^[A-Z]{2}-[0-9]{4}$")

        p = Product(sku="AB-1234")
        p.sku
        """)

      assert result == "AB-1234"
    end

    test "multiple constraints" do
      result =
        run!("""
        from pydantic import BaseModel, Field

        class Product(BaseModel):
            name: str = Field(min_length=1, max_length=100)
            price: float = Field(gt=0)
            quantity: int = Field(ge=0, le=10000)

        p = Product(name="Bolt", price=1.50, quantity=100)
        p.model_dump()
        """)

      assert result == %{"name" => "Bolt", "price" => 1.5, "quantity" => 100}
    end
  end

  describe "model_json_schema" do
    test "basic schema" do
      result =
        run!("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            age: int

        User.model_json_schema()
        """)

      assert result["title"] == "User"
      assert result["type"] == "object"
      assert result["properties"]["name"] == %{"type" => "string"}
      assert result["properties"]["age"] == %{"type" => "integer"}
      assert "name" in result["required"]
      assert "age" in result["required"]
    end

    test "schema with defaults and constraints" do
      result =
        run!("""
        from pydantic import BaseModel, Field

        class Task(BaseModel):
            title: str = Field(min_length=1, max_length=200)
            done: bool = False
            priority: int = Field(ge=1, le=5, default=3)

        Task.model_json_schema()
        """)

      assert result["properties"]["title"]["minLength"] == 1
      assert result["properties"]["title"]["maxLength"] == 200
      assert result["properties"]["done"]["default"] == false
      assert result["properties"]["priority"]["minimum"] == 1
      assert result["properties"]["priority"]["maximum"] == 5
      assert result["properties"]["priority"]["default"] == 3
      assert result["required"] == ["title"]
    end

    test "schema with Optional" do
      result =
        run!("""
        from pydantic import BaseModel

        class Profile(BaseModel):
            name: str
            bio: Optional[str] = None

        Profile.model_json_schema()
        """)

      assert result["properties"]["bio"]["anyOf"] == [
               %{"type" => "string"},
               %{"type" => "null"}
             ]

      assert result["required"] == ["name"]
    end

    test "schema with List" do
      result =
        run!("""
        from pydantic import BaseModel

        class Config(BaseModel):
            tags: List[str] = []

        Config.model_json_schema()
        """)

      assert result["properties"]["tags"] == %{
               "type" => "array",
               "items" => %{"type" => "string"},
               "default" => []
             }
    end

    test "schema called on instance" do
      result =
        run!("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str

        u = User(name="Alice")
        u.model_json_schema()
        """)

      assert result["title"] == "User"
    end
  end

  describe "isinstance" do
    test "isinstance works with pydantic models" do
      result =
        run!("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str

        user = User(name="Alice")
        isinstance(user, User)
        """)

      assert result == true
    end
  end

  describe "str representation" do
    test "str of model instance" do
      result =
        run!("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            age: int

        user = User(name="Alice", age=30)
        str(user)
        """)

      assert result =~ "User"
    end
  end

  describe "real-world patterns" do
    test "API request/response models" do
      result =
        run!("""
        from pydantic import BaseModel, Field

        class CreateUserRequest(BaseModel):
            name: str = Field(min_length=1, max_length=100)
            email: str
            age: int = Field(ge=0, le=150)

        class UserResponse(BaseModel):
            id: int
            name: str
            email: str

        req = CreateUserRequest(name="Alice", email="a@b.com", age=30)
        resp = UserResponse(id=1, name=req.name, email=req.email)
        resp.model_dump()
        """)

      assert result == %{"id" => 1, "name" => "Alice", "email" => "a@b.com"}
    end

    test "config with all field types" do
      result =
        run!("""
        from pydantic import BaseModel, Field

        class AppConfig(BaseModel):
            app_name: str = "MyApp"
            debug: bool = False
            port: int = Field(default=8000, ge=1, le=65535)
            workers: int = Field(default=4, ge=1)
            allowed_hosts: List[str] = []
            rate_limit: float = 100.0

        config = AppConfig(allowed_hosts=["localhost", "example.com"])
        d = config.model_dump()
        [d["app_name"], d["port"], d["workers"], d["allowed_hosts"]]
        """)

      assert result == ["MyApp", 8000, 4, ["localhost", "example.com"]]
    end
  end

  describe "JSON parsing integration" do
    test "parse JSON API response into model" do
      result =
        run!("""
        import json
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            age: int
            email: str

        raw = '{"name": "Alice", "age": 30, "email": "alice@example.com"}'
        data = json.loads(raw)
        user = User(**data)
        [user.name, user.age, user.email]
        """)

      assert result == ["Alice", 30, "alice@example.com"]
    end

    test "parse JSON array into list of models" do
      result =
        run!("""
        import json
        from pydantic import BaseModel

        class Product(BaseModel):
            name: str
            price: float

        raw = '[{"name": "Widget", "price": 9.99}, {"name": "Gadget", "price": 24.50}]'
        items = json.loads(raw)
        products = [Product(**item) for item in items]
        [[p.name, p.price] for p in products]
        """)

      assert result == [["Widget", 9.99], ["Gadget", 24.5]]
    end

    test "parse JSON with type coercion (string numbers)" do
      result =
        run!("""
        import json
        from pydantic import BaseModel

        class Measurement(BaseModel):
            sensor_id: str
            value: float
            timestamp: int

        raw = '{"sensor_id": "temp-01", "value": "23.5", "timestamp": "1700000000"}'
        data = json.loads(raw)
        m = Measurement(**data)
        [m.sensor_id, m.value, m.timestamp]
        """)

      assert result == ["temp-01", 23.5, 1_700_000_000]
    end

    test "parse nested JSON and model_dump round-trip" do
      result =
        run!("""
        import json
        from pydantic import BaseModel

        class Config(BaseModel):
            host: str
            port: int
            debug: bool = False

        raw = '{"host": "localhost", "port": "8080"}'
        config = Config(**json.loads(raw))
        dumped = config.model_dump()
        json.dumps(dumped)
        """)

      parsed = Jason.decode!(result)
      assert parsed == %{"host" => "localhost", "port" => 8080, "debug" => false}
    end

    test "model_validate from json.loads" do
      result =
        run!("""
        import json
        from pydantic import BaseModel

        class Event(BaseModel):
            type: str
            payload: str
            seq: int

        raw = '{"type": "click", "payload": "btn-submit", "seq": "42"}'
        event = Event.model_validate(json.loads(raw))
        [event.type, event.payload, event.seq]
        """)

      assert result == ["click", "btn-submit", 42]
    end

    test "validation error from bad JSON data" do
      msg =
        run_error("""
        import json
        from pydantic import BaseModel, Field

        class Score(BaseModel):
            player: str
            points: int = Field(ge=0)

        raw = '{"player": "Alice", "points": -5}'
        score = Score(**json.loads(raw))
        """)

      assert msg =~ "ValidationError"
      assert msg =~ "points"
    end
  end

  describe "CSV parsing integration" do
    test "parse CSV rows into models with coercion" do
      result =
        run!("""
        import csv
        from pydantic import BaseModel

        class Employee(BaseModel):
            name: str
            age: int
            salary: float

        rows = csv.DictReader(["name,age,salary", "Alice,30,75000.50", "Bob,25,62000"])
        employees = [Employee(**row) for row in rows]
        [[e.name, e.age, e.salary] for e in employees]
        """)

      assert result == [["Alice", 30, 75000.5], ["Bob", 25, 62000.0]]
    end

    test "CSV with missing optional fields uses defaults" do
      result =
        run!("""
        import csv
        from pydantic import BaseModel

        class Record(BaseModel):
            id: int
            label: str
            active: bool = True

        rows = csv.DictReader(["id,label", "1,first", "2,second"])
        records = [Record(**row) for row in rows]
        [[r.id, r.label, r.active] for r in records]
        """)

      assert result == [[1, "first", true], [2, "second", true]]
    end

    test "CSV validation error on bad data" do
      msg =
        run_error("""
        import csv
        from pydantic import BaseModel

        class Row(BaseModel):
            name: str
            count: int

        rows = csv.DictReader(["name,count", "Alice,not_a_number"])
        parsed = [Row(**row) for row in rows]
        """)

      assert msg =~ "ValidationError"
    end

    test "CSV reader with manual header mapping" do
      result =
        run!("""
        import csv
        from pydantic import BaseModel

        class Point(BaseModel):
            x: float
            y: float

        lines = ["1.5,2.3", "4.0,5.5"]
        reader = csv.reader(lines)
        points = [Point(x=row[0], y=row[1]) for row in reader]
        [[p.x, p.y] for p in points]
        """)

      assert result == [[1.5, 2.3], [4.0, 5.5]]
    end

    test "large CSV batch processing with model_validate" do
      result =
        run!("""
        from pydantic import BaseModel

        class Metric(BaseModel):
            ts: int
            value: float

        rows = [{"ts": str(i), "value": str(i * 1.5)} for i in range(100)]
        metrics = [Metric.model_validate(row) for row in rows]
        [metrics[0].ts, metrics[0].value, metrics[99].ts, metrics[99].value, len(metrics)]
        """)

      assert result == [0, 0.0, 99, 148.5, 100]
    end
  end

  describe "application data processing" do
    test "filter and transform with model" do
      result =
        run!("""
        from pydantic import BaseModel, Field

        class Order(BaseModel):
            customer: str
            amount: float = Field(gt=0)
            priority: int = 0

        orders_raw = [
            {"customer": "Alice", "amount": "150.00", "priority": "2"},
            {"customer": "Bob", "amount": "75.50", "priority": "1"},
            {"customer": "Carol", "amount": "200.00", "priority": "3"},
        ]

        orders = [Order(**o) for o in orders_raw]
        high_priority = [o for o in orders if o.priority >= 2]
        total = sum([o.amount for o in high_priority])
        [len(high_priority), total]
        """)

      assert result == [2, 350.0]
    end

    test "model as function argument" do
      result =
        run!("""
        from pydantic import BaseModel

        class Item(BaseModel):
            name: str
            qty: int
            price: float

        def total_cost(item: Item):
            return item.qty * item.price

        def format_item(item: Item):
            return item.name + ": $" + str(total_cost(item))

        item = Item(name="Widget", qty=3, price=9.99)
        format_item(item)
        """)

      assert result == "Widget: $29.97"
    end

    test "model with list field from aggregated data" do
      result =
        run!("""
        from pydantic import BaseModel

        class Report(BaseModel):
            title: str
            values: List[int]

        data = {"title": "Q1 Sales", "values": ["100", "200", "300"]}
        report = Report(**data)
        [report.title, report.values, sum(report.values)]
        """)

      assert result == ["Q1 Sales", [100, 200, 300], 600]
    end

    test "dict of models keyed by id" do
      result =
        run!("""
        from pydantic import BaseModel

        class User(BaseModel):
            name: str
            role: str

        raw_users = [
            {"id": "u1", "name": "Alice", "role": "admin"},
            {"id": "u2", "name": "Bob", "role": "viewer"},
        ]

        users_by_id = {}
        for raw in raw_users:
            uid = raw["id"]
            users_by_id[uid] = User(name=raw["name"], role=raw["role"])

        [users_by_id["u1"].name, users_by_id["u1"].role, users_by_id["u2"].name]
        """)

      assert result == ["Alice", "admin", "Bob"]
    end

    test "model_dump to prepare API response" do
      result =
        run!("""
        import json
        from pydantic import BaseModel

        class UserResponse(BaseModel):
            id: int
            name: str
            email: str

        user = UserResponse(id=1, name="Alice", email="alice@example.com")
        json.dumps(user.model_dump())
        """)

      parsed = Jason.decode!(result)
      assert parsed == %{"id" => 1, "name" => "Alice", "email" => "alice@example.com"}
    end

    test "chained validation pipeline" do
      result =
        run!("""
        import json
        from pydantic import BaseModel, Field

        class RawInput(BaseModel):
            text: str
            score: float = Field(ge=0, le=1)

        class ProcessedOutput(BaseModel):
            label: str
            confidence: float
            accepted: bool

        inputs = [
            {"text": "good product", "score": "0.95"},
            {"text": "bad product", "score": "0.3"},
            {"text": "great product", "score": "0.88"},
        ]

        results = []
        for raw in inputs:
            inp = RawInput(**raw)
            out = ProcessedOutput(
                label=inp.text,
                confidence=inp.score,
                accepted=inp.score >= 0.5
            )
            results.append(out.model_dump())

        [r["accepted"] for r in results]
        """)

      assert result == [true, false, true]
    end

    test "inheritance with shared base model" do
      result =
        run!("""
        from pydantic import BaseModel

        class TimestampMixin(BaseModel):
            created_at: str = "2024-01-01"

        class User(TimestampMixin):
            name: str
            email: str

        class Post(TimestampMixin):
            title: str
            body: str

        user = User(name="Alice", email="alice@example.com")
        post = Post(title="Hello", body="World", created_at="2024-06-15")
        [user.name, user.created_at, post.title, post.created_at]
        """)

      assert result == ["Alice", "2024-01-01", "Hello", "2024-06-15"]
    end
  end

  describe "nested model coercion" do
    test "dict auto-coerced to nested model" do
      result =
        run!("""
        from pydantic import BaseModel

        class Address(BaseModel):
            city: str
            zip: str

        class User(BaseModel):
            name: str
            address: Address

        data = {"name": "Alice", "address": {"city": "NYC", "zip": "10001"}}
        user = User(**data)
        [user.name, user.address.city, user.address.zip]
        """)

      assert result == ["Alice", "NYC", "10001"]
    end

    test "nested model via model_validate" do
      result =
        run!("""
        from pydantic import BaseModel

        class Coord(BaseModel):
            lat: float
            lng: float

        class Station(BaseModel):
            id: str
            location: Coord

        data = {"id": "KJFK", "location": {"lat": "40.6392", "lng": "-73.7639"}}
        s = Station.model_validate(data)
        [s.id, s.location.lat, s.location.lng]
        """)

      assert result == ["KJFK", 40.6392, -73.7639]
    end

    test "nested model validation error propagates" do
      msg =
        run_error("""
        from pydantic import BaseModel

        class Inner(BaseModel):
            value: int

        class Outer(BaseModel):
            name: str
            inner: Inner

        Outer(name="test", inner={"value": "not_a_number"})
        """)

      assert msg =~ "ValidationError"
    end

    test "model_dump with nested models produces nested dicts" do
      result =
        run!("""
        from pydantic import BaseModel

        class Address(BaseModel):
            city: str

        class Person(BaseModel):
            name: str
            address: Address

        p = Person(name="Bob", address={"city": "LA"})
        d = p.model_dump()
        [d["name"], d["address"]["city"]]
        """)

      assert result == ["Bob", "LA"]
    end

    test "deeply nested models (3 levels)" do
      result =
        run!("""
        from pydantic import BaseModel

        class GPS(BaseModel):
            lat: float
            lng: float

        class Airport(BaseModel):
            code: str
            gps: GPS

        class Flight(BaseModel):
            number: str
            origin: Airport
            destination: Airport

        data = {
            "number": "AA100",
            "origin": {"code": "KJFK", "gps": {"lat": 40.6, "lng": -73.8}},
            "destination": {"code": "KLAX", "gps": {"lat": 33.9, "lng": -118.4}},
        }
        f = Flight(**data)
        [f.number, f.origin.code, f.origin.gps.lat, f.destination.code, f.destination.gps.lng]
        """)

      assert result == ["AA100", "KJFK", 40.6, "KLAX", -118.4]
    end

    test "nested model already an instance passes through" do
      result =
        run!("""
        from pydantic import BaseModel

        class Address(BaseModel):
            city: str

        class User(BaseModel):
            name: str
            address: Address

        addr = Address(city="NYC")
        user = User(name="Alice", address=addr)
        user.address.city
        """)

      assert result == "NYC"
    end

    test "nested model from JSON API response" do
      result =
        run!("""
        import json
        from pydantic import BaseModel

        class Author(BaseModel):
            name: str
            email: str

        class Post(BaseModel):
            title: str
            author: Author

        raw = '{"title": "Hello World", "author": {"name": "Alice", "email": "a@b.com"}}'
        post = Post(**json.loads(raw))
        [post.title, post.author.name, post.author.email]
        """)

      assert result == ["Hello World", "Alice", "a@b.com"]
    end
  end
end
