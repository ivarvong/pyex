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
end
