defmodule Pyex.Stdlib.HmacTest do
  use ExUnit.Case, async: true

  describe "hmac.new" do
    test "HMAC-SHA256 with known values" do
      result =
        Pyex.run!("""
        import hmac
        h = hmac.new("secret", "hello", "sha256")
        h.hexdigest()
        """)

      expected =
        :crypto.mac(:hmac, :sha256, "secret", "hello") |> Base.encode16(case: :lower)

      assert result == expected
    end

    test "HMAC-SHA1" do
      result =
        Pyex.run!("""
        import hmac
        h = hmac.new("key", "message", "sha1")
        h.hexdigest()
        """)

      expected =
        :crypto.mac(:hmac, :sha, "key", "message") |> Base.encode16(case: :lower)

      assert result == expected
    end

    test "HMAC-MD5" do
      result =
        Pyex.run!("""
        import hmac
        h = hmac.new("key", "msg", "md5")
        h.hexdigest()
        """)

      expected =
        :crypto.mac(:hmac, :md5, "key", "msg") |> Base.encode16(case: :lower)

      assert result == expected
    end

    test "name attribute" do
      assert Pyex.run!("import hmac\nhmac.new('k', 'm', 'sha256').name") == "sha256"
    end

    test "digest_size attribute" do
      assert Pyex.run!("import hmac\nhmac.new('k', 'm', 'sha256').digest_size") == 32
    end

    test "missing digestmod raises TypeError" do
      assert_raise RuntimeError, ~r/TypeError.*digestmod/, fn ->
        Pyex.run!("import hmac\nhmac.new('key', 'msg')")
      end
    end
  end

  describe "hmac.new with update" do
    test "update accumulates message data" do
      result =
        Pyex.run!("""
        import hmac
        h = hmac.new("secret", "", "sha256")
        h = h.update("hello")
        h = h.update(" world")
        h.hexdigest()
        """)

      expected =
        Pyex.run!("""
        import hmac
        hmac.new("secret", "hello world", "sha256").hexdigest()
        """)

      assert result == expected
    end
  end

  describe "hmac.digest" do
    test "one-shot HMAC computation" do
      result =
        Pyex.run!("""
        import hmac
        hmac.digest("secret", "hello", "sha256")
        """)

      expected =
        :crypto.mac(:hmac, :sha256, "secret", "hello") |> Base.encode16(case: :lower)

      assert result == expected
    end
  end

  describe "hmac.compare_digest" do
    test "equal strings return True" do
      assert Pyex.run!("import hmac\nhmac.compare_digest('abc', 'abc')") == true
    end

    test "different strings return False" do
      assert Pyex.run!("import hmac\nhmac.compare_digest('abc', 'def')") == false
    end

    test "different length strings return False" do
      assert Pyex.run!("import hmac\nhmac.compare_digest('abc', 'ab')") == false
    end
  end

  describe "hmac.new with hashlib digestmod" do
    test "accepts hashlib.sha256 as digestmod" do
      result =
        Pyex.run!("""
        import hmac
        import hashlib
        h = hmac.new("secret", "hello", hashlib.sha256)
        h.hexdigest()
        """)

      expected =
        :crypto.mac(:hmac, :sha256, "secret", "hello") |> Base.encode16(case: :lower)

      assert result == expected
    end
  end

  describe "from_import" do
    test "from hmac import new" do
      result =
        Pyex.run!("""
        from hmac import new
        h = new("key", "data", "sha256")
        h.hexdigest()
        """)

      expected =
        :crypto.mac(:hmac, :sha256, "key", "data") |> Base.encode16(case: :lower)

      assert result == expected
    end
  end

  describe "copy method" do
    test "copy produces independent HMAC object" do
      result =
        Pyex.run!("""
        import hmac
        h1 = hmac.new("key", "hello", "sha256")
        h2 = h1.copy()
        h2 = h2.update(" world")
        h1.hexdigest() != h2.hexdigest()
        """)

      assert result == true
    end
  end

  describe "webhook verification pattern" do
    test "verify webhook signature" do
      result =
        Pyex.run!("""
        import hmac
        import hashlib

        secret = "webhook_secret_key"
        payload = '{"event": "payment.completed", "amount": 100}'

        signature = hmac.new(secret, payload, "sha256").hexdigest()
        expected = hmac.new(secret, payload, "sha256").hexdigest()

        hmac.compare_digest(signature, expected)
        """)

      assert result == true
    end
  end

  describe "error handling" do
    test "unsupported algorithm raises ValueError" do
      assert_raise RuntimeError, ~r/ValueError.*unsupported hash type/, fn ->
        Pyex.run!("import hmac\nhmac.new('key', 'msg', 'bogus')")
      end
    end

    test "non-string key raises TypeError" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!("import hmac\nhmac.new(42, 'msg', 'sha256')")
      end
    end
  end
end
