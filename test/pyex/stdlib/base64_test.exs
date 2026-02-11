defmodule Pyex.Stdlib.Base64Test do
  use ExUnit.Case, async: true

  describe "base64.b64encode" do
    test "encodes string" do
      assert Pyex.run!("import base64\nbase64.b64encode('hello')") == "aGVsbG8="
    end

    test "encodes empty string" do
      assert Pyex.run!("import base64\nbase64.b64encode('')") == ""
    end

    test "encodes binary data with special chars" do
      result =
        Pyex.run!("""
        import base64
        base64.b64encode("Hello, World!")
        """)

      assert result == "SGVsbG8sIFdvcmxkIQ=="
    end

    test "non-string raises TypeError" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!("import base64\nbase64.b64encode(42)")
      end
    end
  end

  describe "base64.b64decode" do
    test "decodes valid base64" do
      assert Pyex.run!("import base64\nbase64.b64decode('aGVsbG8=')") == "hello"
    end

    test "decodes empty string" do
      assert Pyex.run!("import base64\nbase64.b64decode('')") == ""
    end

    test "roundtrip" do
      result =
        Pyex.run!("""
        import base64
        base64.b64decode(base64.b64encode("test data 123"))
        """)

      assert result == "test data 123"
    end

    test "invalid base64 raises error" do
      assert_raise RuntimeError, ~r/binascii.Error/, fn ->
        Pyex.run!("import base64\nbase64.b64decode('!!!invalid!!!')")
      end
    end
  end

  describe "base64.urlsafe_b64encode" do
    test "encodes with URL-safe alphabet" do
      result =
        Pyex.run!("""
        import base64
        base64.urlsafe_b64encode("subjects?_d")
        """)

      decoded = Base.url_decode64!(result)
      assert decoded == "subjects?_d"
    end

    test "uses - and _ instead of + and /" do
      result =
        Pyex.run!("""
        import base64
        encoded = base64.urlsafe_b64encode("subjects?_d")
        "+" not in encoded and "/" not in encoded
        """)

      assert result == true
    end
  end

  describe "base64.urlsafe_b64decode" do
    test "decodes URL-safe base64" do
      encoded = Base.url_encode64("hello world")

      result =
        Pyex.run!("""
        import base64
        base64.urlsafe_b64decode("#{encoded}")
        """)

      assert result == "hello world"
    end

    test "handles missing padding" do
      encoded = Base.url_encode64("test", padding: false)

      result =
        Pyex.run!("""
        import base64
        base64.urlsafe_b64decode("#{encoded}")
        """)

      assert result == "test"
    end

    test "roundtrip" do
      result =
        Pyex.run!("""
        import base64
        base64.urlsafe_b64decode(base64.urlsafe_b64encode("OAuth token data!"))
        """)

      assert result == "OAuth token data!"
    end
  end

  describe "base64.b16encode / b16decode" do
    test "hex encode" do
      assert Pyex.run!("import base64\nbase64.b16encode('hello')") == "68656C6C6F"
    end

    test "hex decode" do
      assert Pyex.run!("import base64\nbase64.b16decode('68656C6C6F')") == "hello"
    end

    test "case-insensitive decode" do
      assert Pyex.run!("import base64\nbase64.b16decode('68656c6c6f')") == "hello"
    end

    test "roundtrip" do
      result =
        Pyex.run!("""
        import base64
        base64.b16decode(base64.b16encode("test"))
        """)

      assert result == "test"
    end
  end

  describe "base64.b32encode / b32decode" do
    test "encode" do
      assert Pyex.run!("import base64\nbase64.b32encode('hello')") == "NBSWY3DP"
    end

    test "decode" do
      assert Pyex.run!("import base64\nbase64.b32decode('NBSWY3DP')") == "hello"
    end

    test "roundtrip" do
      result =
        Pyex.run!("""
        import base64
        base64.b32decode(base64.b32encode("test data"))
        """)

      assert result == "test data"
    end
  end

  describe "from_import" do
    test "from base64 import b64encode" do
      assert Pyex.run!("from base64 import b64encode\nb64encode('hi')") == "aGk="
    end

    test "from base64 import urlsafe_b64encode" do
      result =
        Pyex.run!("""
        from base64 import urlsafe_b64encode, urlsafe_b64decode
        urlsafe_b64decode(urlsafe_b64encode("test"))
        """)

      assert result == "test"
    end
  end

  describe "OAuth Basic auth pattern" do
    test "encode client credentials" do
      result =
        Pyex.run!("""
        import base64
        client_id = "my_client_id"
        client_secret = "my_client_secret"
        credentials = client_id + ":" + client_secret
        encoded = base64.b64encode(credentials)
        "Basic " + encoded
        """)

      assert result == "Basic bXlfY2xpZW50X2lkOm15X2NsaWVudF9zZWNyZXQ="
    end
  end
end
