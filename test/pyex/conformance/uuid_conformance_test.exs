defmodule Pyex.Conformance.UuidTest do
  @moduledoc """
  Conformance tests for the `uuid` module.

  UUID values are random so we can't compare against CPython directly;
  instead we verify format, types, and constraints that must hold for
  any valid UUID.
  """

  use ExUnit.Case, async: true

  describe "uuid4" do
    test "returns a UUID-like object whose str matches the canonical format" do
      result =
        Pyex.run!("""
        import uuid
        u = uuid.uuid4()
        s = str(u)
        [len(s), s[8], s[13], s[18], s[23], s[14]]
        """)

      assert [36, "-", "-", "-", "-", "4"] = result
    end

    test "successive uuid4 values are distinct" do
      result =
        Pyex.run!("""
        import uuid
        s = set(str(uuid.uuid4()) for _ in range(50))
        len(s)
        """)

      assert result == 50
    end

    test "all hex and hyphens in the canonical form" do
      result =
        Pyex.run!("""
        import uuid
        import re
        s = str(uuid.uuid4())
        bool(re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", s))
        """)

      assert result == true
    end
  end

  describe "uuid.UUID from string" do
    test "roundtrips canonical form" do
      result =
        Pyex.run!("""
        import uuid
        s = "12345678-1234-5678-1234-567812345678"
        u = uuid.UUID(s)
        str(u) == s
        """)

      assert result == true
    end
  end

  describe "uuid attribute access" do
    test "hex attribute returns 32 hex chars" do
      result =
        Pyex.run!("""
        import uuid
        u = uuid.uuid4()
        h = u.hex
        [len(h), "-" not in h]
        """)

      assert result == [32, true]
    end
  end
end
