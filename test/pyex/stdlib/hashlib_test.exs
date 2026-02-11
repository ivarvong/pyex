defmodule Pyex.Stdlib.HashlibTest do
  use ExUnit.Case, async: true

  describe "hashlib.sha256" do
    test "empty string digest" do
      result =
        Pyex.run!("""
        import hashlib
        hashlib.sha256("").hexdigest()
        """)

      assert result == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    end

    test "known input digest" do
      result =
        Pyex.run!("""
        import hashlib
        hashlib.sha256("hello").hexdigest()
        """)

      assert result == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    end

    test "constructor with initial data" do
      result =
        Pyex.run!("""
        import hashlib
        h = hashlib.sha256("hello world")
        h.hexdigest()
        """)

      assert result == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    end

    test "digest_size attribute" do
      assert Pyex.run!("import hashlib\nhashlib.sha256().digest_size") == 32
    end

    test "block_size attribute" do
      assert Pyex.run!("import hashlib\nhashlib.sha256().block_size") == 64
    end

    test "name attribute" do
      assert Pyex.run!("import hashlib\nhashlib.sha256().name") == "sha256"
    end

    test "update method accumulates data" do
      result =
        Pyex.run!("""
        import hashlib
        h = hashlib.sha256()
        h = h.update("hello")
        h = h.update(" world")
        h.hexdigest()
        """)

      expected =
        Pyex.run!("""
        import hashlib
        hashlib.sha256("hello world").hexdigest()
        """)

      assert result == expected
    end
  end

  describe "hashlib.sha1" do
    test "known input" do
      result =
        Pyex.run!("""
        import hashlib
        hashlib.sha1("hello").hexdigest()
        """)

      assert result == "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d"
    end

    test "digest_size" do
      assert Pyex.run!("import hashlib\nhashlib.sha1().digest_size") == 20
    end
  end

  describe "hashlib.md5" do
    test "known input" do
      result =
        Pyex.run!("""
        import hashlib
        hashlib.md5("hello").hexdigest()
        """)

      assert result == "5d41402abc4b2a76b9719d911017c592"
    end

    test "digest_size" do
      assert Pyex.run!("import hashlib\nhashlib.md5().digest_size") == 16
    end
  end

  describe "hashlib.sha384" do
    test "empty string digest" do
      result =
        Pyex.run!("""
        import hashlib
        hashlib.sha384("").hexdigest()
        """)

      assert result ==
               "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b"
    end

    test "digest_size" do
      assert Pyex.run!("import hashlib\nhashlib.sha384().digest_size") == 48
    end

    test "block_size" do
      assert Pyex.run!("import hashlib\nhashlib.sha384().block_size") == 128
    end
  end

  describe "hashlib.sha512" do
    test "empty string digest" do
      result =
        Pyex.run!("""
        import hashlib
        hashlib.sha512("").hexdigest()
        """)

      assert result ==
               "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
    end

    test "digest_size" do
      assert Pyex.run!("import hashlib\nhashlib.sha512().digest_size") == 64
    end

    test "block_size" do
      assert Pyex.run!("import hashlib\nhashlib.sha512().block_size") == 128
    end
  end

  describe "hashlib.sha224" do
    test "empty string digest" do
      result =
        Pyex.run!("""
        import hashlib
        hashlib.sha224("").hexdigest()
        """)

      assert result == "d14a028c2a3a2bc9476102bb288234c415a2b01f828ea62ac5b3e42f"
    end

    test "digest_size" do
      assert Pyex.run!("import hashlib\nhashlib.sha224().digest_size") == 28
    end
  end

  describe "hashlib.new" do
    test "generic constructor with sha256" do
      result =
        Pyex.run!("""
        import hashlib
        hashlib.new("sha256", "hello").hexdigest()
        """)

      assert result == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    end

    test "generic constructor without data" do
      result =
        Pyex.run!("""
        import hashlib
        hashlib.new("md5").hexdigest()
        """)

      assert result == "d41d8cd98f00b204e9800998ecf8427e"
    end

    test "unsupported algorithm raises ValueError" do
      assert_raise RuntimeError, ~r/ValueError.*unsupported hash type/, fn ->
        Pyex.run!("import hashlib\nhashlib.new('foo')")
      end
    end
  end

  describe "from_import" do
    test "from hashlib import sha256" do
      result =
        Pyex.run!("""
        from hashlib import sha256
        sha256("test").hexdigest()
        """)

      assert result == "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    end
  end

  describe "copy method" do
    test "copy produces independent hash object" do
      result =
        Pyex.run!("""
        import hashlib
        h1 = hashlib.sha256("hello")
        h2 = h1.copy()
        h2 = h2.update(" world")
        [h1.hexdigest(), h2.hexdigest()]
        """)

      assert result == [
               "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
               "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
             ]
    end
  end

  describe "PKCE code challenge" do
    test "sha256 + hex for PKCE-like flow" do
      result =
        Pyex.run!("""
        import hashlib
        verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        challenge = hashlib.sha256(verifier).hexdigest()
        len(challenge)
        """)

      assert result == 64
    end
  end

  describe "error handling" do
    test "non-string argument raises TypeError" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!("import hashlib\nhashlib.sha256(42)")
      end
    end
  end
end
