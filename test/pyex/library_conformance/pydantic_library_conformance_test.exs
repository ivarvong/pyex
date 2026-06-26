defmodule Pyex.LibraryConformance.PydanticTest do
  @moduledoc """
  Conformance tests for the `pydantic` shim against the pinned
  reference `pydantic` library.

  Each test runs the same Python snippet against pyex's in-tree
  `pydantic` shim and against the pinned reference version (see
  `test/python_env/requirements.txt`), asserting byte-equal output.
  Failures here surface divergence — usually fixed by updating the
  shim, occasionally by documenting intentional divergence.

  Tagged `:library_conformance` so they're excluded by default. Run
  with:

      mix test --include library_conformance

  Requires `uv` on PATH. Skipped at suite-start if missing.
  """

  use ExUnit.Case, async: true

  @moduletag :library_conformance

  import Pyex.Test.LibraryConformance

  # Skip the whole module when `uv` is absent. A `{:skip, _}` return from
  # `setup` is not a valid ExUnit callback result (it raises in ExUnit 1.19+);
  # `@moduletag skip:`, evaluated at compile time off the `uv_available?/0`
  # module attribute, is the supported way to skip conditionally.
  unless uv_available?() do
    @moduletag skip: "uv not found on PATH"
  end

  describe "BaseModel construction" do
    test "basic int + str fields with model_dump" do
      assert_matches_library("""
      from pydantic import BaseModel

      class User(BaseModel):
          name: str
          age: int

      u = User(name="ivar", age=30)
      print(u.model_dump())
      """)
    end

    test "field attribute access" do
      assert_matches_library("""
      from pydantic import BaseModel

      class User(BaseModel):
          name: str
          age: int

      u = User(name="ivar", age=30)
      print(u.name)
      print(u.age)
      """)
    end
  end

  describe "type coercion" do
    test "string to int" do
      assert_matches_library("""
      from pydantic import BaseModel

      class M(BaseModel):
          n: int

      print(M(n="42").model_dump())
      """)
    end

    test "int to float" do
      assert_matches_library("""
      from pydantic import BaseModel

      class M(BaseModel):
          x: float

      print(M(x=3).model_dump())
      """)
    end
  end

  describe "Field constraints" do
    test "ge passes when value meets bound" do
      assert_matches_library("""
      from pydantic import BaseModel, Field

      class M(BaseModel):
          n: int = Field(ge=10)

      print(M(n=10).model_dump())
      """)
    end

    test "ge fails when value below bound" do
      assert_matches_library("""
      from pydantic import BaseModel, Field, ValidationError

      class M(BaseModel):
          n: int = Field(ge=10)

      try:
          M(n=5)
          print("no error")
      except ValidationError:
          print("validation error")
      """)
    end
  end

  describe "defaults and Optional" do
    test "default value applied when field omitted" do
      assert_matches_library("""
      from pydantic import BaseModel

      class M(BaseModel):
          n: int = 7

      print(M().model_dump())
      """)
    end

    test "Optional field defaults to None" do
      assert_matches_library("""
      from pydantic import BaseModel
      from typing import Optional

      class M(BaseModel):
          n: Optional[int] = None

      print(M().model_dump())
      """)
    end
  end

  describe "model_validate" do
    test "from dict succeeds" do
      assert_matches_library("""
      from pydantic import BaseModel

      class User(BaseModel):
          name: str
          age: int

      u = User.model_validate({"name": "ivar", "age": 30})
      print(u.model_dump())
      """)
    end
  end

  describe "model_dump_json" do
    test "compact JSON by default" do
      assert_matches_library("""
      from pydantic import BaseModel

      class C(BaseModel):
          a: int
          b: str
          items: list

      print(C(a=1, b="x", items=[1, 2, 3]).model_dump_json())
      """)
    end

    test "nested models serialize recursively" do
      assert_matches_library("""
      from pydantic import BaseModel

      class Inner(BaseModel):
          v: int

      class Outer(BaseModel):
          name: str
          inner: Inner

      print(Outer(name="o", inner=Inner(v=7)).model_dump_json())
      """)
    end

    test "indent produces a pretty document" do
      assert_matches_library("""
      from pydantic import BaseModel

      class C(BaseModel):
          a: int
          b: str

      print(C(a=1, b="x").model_dump_json(indent=2))
      """)
    end
  end

  describe "field_validator" do
    test "transforms the field value" do
      assert_matches_library("""
      from pydantic import BaseModel, field_validator

      class C(BaseModel):
          x: int

          @field_validator("x")
          @classmethod
          def scale(cls, v):
              return v * 10

      print(C(x=5).x)
      """)
    end

    test "raising ValueError surfaces as a ValidationError" do
      assert_matches_library("""
      from pydantic import BaseModel, field_validator

      class C(BaseModel):
          x: int

          @field_validator("x")
          @classmethod
          def non_negative(cls, v):
              if v < 0:
                  raise ValueError("must be non-negative")
              return v

      try:
          C(x=-1)
      except Exception as e:
          print(type(e).__name__)
      """)
    end

    test "one validator covering multiple fields" do
      assert_matches_library("""
      from pydantic import BaseModel, field_validator

      class C(BaseModel):
          a: int
          b: int

          @field_validator("a", "b")
          @classmethod
          def double(cls, v):
              return v * 2

      c = C(a=1, b=2)
      print(c.a, c.b)
      """)
    end
  end
end
