defmodule Pyex.Stdlib.SecretsTest do
  use ExUnit.Case, async: true

  describe "secrets.token_hex" do
    test "default length returns 64 hex chars (32 bytes)" do
      result =
        Pyex.run!("""
        import secrets
        len(secrets.token_hex())
        """)

      assert result == 64
    end

    test "specified length" do
      result =
        Pyex.run!("""
        import secrets
        len(secrets.token_hex(16))
        """)

      assert result == 32
    end

    test "returns only hex characters" do
      result =
        Pyex.run!("""
        import secrets
        token = secrets.token_hex(16)
        all(c in "0123456789abcdef" for c in token)
        """)

      assert result == true
    end

    test "zero bytes returns empty string" do
      assert Pyex.run!("import secrets\nsecrets.token_hex(0)") == ""
    end

    test "each call returns different token" do
      result =
        Pyex.run!("""
        import secrets
        secrets.token_hex(16) != secrets.token_hex(16)
        """)

      assert result == true
    end

    test "None argument uses default" do
      result =
        Pyex.run!("""
        import secrets
        len(secrets.token_hex(None))
        """)

      assert result == 64
    end

    test "negative raises TypeError" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!("import secrets\nsecrets.token_hex(-1)")
      end
    end
  end

  describe "secrets.token_urlsafe" do
    test "default length" do
      result =
        Pyex.run!("""
        import secrets
        token = secrets.token_urlsafe()
        len(token) > 0
        """)

      assert result == true
    end

    test "specified length" do
      result =
        Pyex.run!("""
        import secrets
        token = secrets.token_urlsafe(32)
        len(token) > 0
        """)

      assert result == true
    end

    test "contains only URL-safe characters" do
      result =
        Pyex.run!("""
        import secrets
        token = secrets.token_urlsafe(32)
        safe_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        all(c in safe_chars for c in token)
        """)

      assert result == true
    end

    test "no padding characters" do
      result =
        Pyex.run!("""
        import secrets
        token = secrets.token_urlsafe(32)
        "=" not in token
        """)

      assert result == true
    end

    test "each call returns different token" do
      result =
        Pyex.run!("""
        import secrets
        secrets.token_urlsafe(32) != secrets.token_urlsafe(32)
        """)

      assert result == true
    end
  end

  describe "secrets.token_bytes" do
    test "default returns 32 raw bytes" do
      result = Pyex.run!("import secrets\nsecrets.token_bytes()")
      assert is_binary(result)
      assert byte_size(result) == 32
    end

    test "specified length returns that many bytes" do
      result = Pyex.run!("import secrets\nsecrets.token_bytes(16)")
      assert is_binary(result)
      assert byte_size(result) == 16
    end

    test "zero bytes returns empty binary" do
      assert Pyex.run!("import secrets\nsecrets.token_bytes(0)") == ""
    end

    test "can be hex-encoded via hashlib or base64" do
      result =
        Pyex.run!("""
        import secrets
        import base64
        token = secrets.token_bytes(16)
        encoded = base64.b16encode(token)
        len(encoded) == 32
        """)

      assert result == true
    end
  end

  describe "secrets.randbelow" do
    test "returns value in range [0, n)" do
      result =
        Pyex.run!("""
        import secrets
        x = secrets.randbelow(10)
        0 <= x and x < 10
        """)

      assert result == true
    end

    test "randbelow(1) always returns 0" do
      assert Pyex.run!("import secrets\nsecrets.randbelow(1)") == 0
    end

    test "zero raises ValueError" do
      assert_raise RuntimeError, ~r/ValueError/, fn ->
        Pyex.run!("import secrets\nsecrets.randbelow(0)")
      end
    end

    test "negative raises ValueError" do
      assert_raise RuntimeError, ~r/ValueError/, fn ->
        Pyex.run!("import secrets\nsecrets.randbelow(-5)")
      end
    end
  end

  describe "secrets.compare_digest" do
    test "equal strings" do
      assert Pyex.run!("import secrets\nsecrets.compare_digest('abc', 'abc')") == true
    end

    test "different strings" do
      assert Pyex.run!("import secrets\nsecrets.compare_digest('abc', 'xyz')") == false
    end

    test "different lengths" do
      assert Pyex.run!("import secrets\nsecrets.compare_digest('abc', 'ab')") == false
    end
  end

  describe "secrets.choice" do
    test "picks from list" do
      result =
        Pyex.run!("""
        import secrets
        choices = ["a", "b", "c"]
        secrets.choice(choices) in choices
        """)

      assert result == true
    end

    test "picks from string" do
      result =
        Pyex.run!("""
        import secrets
        secrets.choice("abc") in "abc"
        """)

      assert result == true
    end

    test "empty sequence raises IndexError" do
      assert_raise RuntimeError, ~r/IndexError/, fn ->
        Pyex.run!("import secrets\nsecrets.choice([])")
      end
    end
  end

  describe "from_import" do
    test "from secrets import token_hex" do
      result =
        Pyex.run!("""
        from secrets import token_hex
        len(token_hex(16))
        """)

      assert result == 32
    end

    test "from secrets import token_urlsafe, token_hex" do
      result =
        Pyex.run!("""
        from secrets import token_urlsafe, token_hex
        len(token_hex(8)) > 0 and len(token_urlsafe(8)) > 0
        """)

      assert result == true
    end
  end

  describe "OAuth state generation pattern" do
    test "generate state parameter" do
      result =
        Pyex.run!("""
        import secrets
        state = secrets.token_urlsafe(32)
        len(state) > 0
        """)

      assert result == true
    end

    test "generate PKCE code verifier" do
      result =
        Pyex.run!("""
        import secrets
        code_verifier = secrets.token_urlsafe(32)
        length = len(code_verifier)
        length >= 43 and length <= 128
        """)

      assert result == true
    end
  end
end
