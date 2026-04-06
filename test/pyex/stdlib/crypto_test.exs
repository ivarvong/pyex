defmodule Pyex.Stdlib.CryptoTest do
  use ExUnit.Case, async: true

  # RSA 2048-bit test key (generated for testing only, not used anywhere else)
  @test_pem "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCtdMhx1TccKGLh\ntxJa/4CJfl1kcp1Vj/HTAfjF+lEK/6mLpSGmlQgccairT37kZSpPmUFYWo+Pjp9E\nGTydui0IUWrN7JDb6rRTwRXqWr6kaDuTiBvx2kHVAEFTyqH50T8q/3ziH3Pz/pRv\nbqA05WGGJfW/MoWKdMluReFY7HkesREdl6JtMqF5ZBRMdve5DM+CDs/l5D4IBHcs\na/Z7okQzvCA+Be+/KiGEaeej/omtPU7/c9VtT6Cw6CTMgC2CiXSN+JMn/B5gbHds\nFNHxZJbgjVe7EfgsNn78HXPSHb1YvSr0pLOSXwSwkYgwfVWElEO4WmnuVNS6OLpk\n6Bjl+BERAgMBAAECggEABM9IcJmeL9Zx2XrrVCEiFg3uNocUFEeLx9NV691zSlgJ\nAkGHs5gN08YWDHwFk303pWHlRTcrpGoqwedmPiRns8OYL9IXuTVinzDrM+akwyfN\nwRtE1Rm9ehPJ+/ISODxkYUOY2adQHouoX4ekgxr6L49VZ2IWAF8ZJ8jhxQa3nBF2\nrYtY6r1YKlaSCXDoaqR3b0og8OnVZYsnaTWDF8t8cKOHOYXHMZa5iiXGGLRroH8f\n0/YcyDeQDNKN5MEgLCgTh9KSifITb7a+ajQz3NCYXByCfrv39TipGNbPR9GGaKqE\nrE/b+ZuuMX29V+EloGWIzol1gra0QGBSyx6a7r1JjQKBgQDTpqC1OoCdpyzVdFil\n1FQgarw8X5CUN/DqY94wmBcM7CQf4IvvYoInurZjzCVOl9EAccD3hWhA9OxHj9CW\nxZequdSTF6v1foYlCy1FopuAxjbPkAOndis5rAPWF/1PbYhTs0ZXHGkHlcPqx9Ma\njrK7o8a9Ijfbe9M7HLlJD7LxnQKBgQDRzVDO9/w7lLEeFv2NTJiN4S75On+2cCul\nPnmD6tun9bddXm1T4ffMBb0zaHyYh2N05NYn/lMIeuvhR2O0SA5S6VzTlK59gXuF\nxN86LUOM1Dy8v+R8AKeGCzEE7uAf2UFmr+nayuKKhCZaOzMoQOhw3JPzNYaY8j6X\nsjQWVIftBQKBgQCjQPjfMWP5tvR/JUInj1LgulO9od0MZuX+dc/x3a6R+ieXKwXl\nPS+143BCJDp2l+XPmO7GPfH/gKwsOsMjOQBW4QYV+4FZWCGyux9NgjK+LqYijiwz\nZJPM5WEEJ/bs6EjqfvL3yGM/RYccNswfxQgaciaexqEdPDLferV0pJZbhQKBgHTh\nvHZBo60Rzobj6gfxN0A7xq6kj4f0/+vEXXBHxG3TL3993syPpDxuqhRczqUvMBJs\ndn67akjcKlNMMVi7l/dK+SMKvxc+rrE8l9xSYUKw7tF82m7W8n1z+LA14Hj90TjD\nIjZ5NzJSIwe72WlAl/5gdLBXDpBgzMw4RFp4Z219AoGATUTZquRBsN2KqKv4toee\naRLPvGMPouhNHvpzXulkkhb/FY3jM3dxRCzEEZBHZufQUVdEqQ1uWOLD7g2baisz\nNwd/MP+gEVTr+KL2v+o0N5Q8RxFlGnUJdRzojGhg3N6h3q9lhLMy2KWl2NWAkUEY\nU5HwdWE0UZm/x1GWIi29WgU=\n-----END PRIVATE KEY-----\n"

  # Python string literal with escaped newlines for embedding in test code
  @pem_python_literal ~s|"-----BEGIN PRIVATE KEY-----\\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCtdMhx1TccKGLh\\ntxJa/4CJfl1kcp1Vj/HTAfjF+lEK/6mLpSGmlQgccairT37kZSpPmUFYWo+Pjp9E\\nGTydui0IUWrN7JDb6rRTwRXqWr6kaDuTiBvx2kHVAEFTyqH50T8q/3ziH3Pz/pRv\\nbqA05WGGJfW/MoWKdMluReFY7HkesREdl6JtMqF5ZBRMdve5DM+CDs/l5D4IBHcs\\na/Z7okQzvCA+Be+/KiGEaeej/omtPU7/c9VtT6Cw6CTMgC2CiXSN+JMn/B5gbHds\\nFNHxZJbgjVe7EfgsNn78HXPSHb1YvSr0pLOSXwSwkYgwfVWElEO4WmnuVNS6OLpk\\n6Bjl+BERAgMBAAECggEABM9IcJmeL9Zx2XrrVCEiFg3uNocUFEeLx9NV691zSlgJ\\nAkGHs5gN08YWDHwFk303pWHlRTcrpGoqwedmPiRns8OYL9IXuTVinzDrM+akwyfN\\nwRtE1Rm9ehPJ+/ISODxkYUOY2adQHouoX4ekgxr6L49VZ2IWAF8ZJ8jhxQa3nBF2\\nrYtY6r1YKlaSCXDoaqR3b0og8OnVZYsnaTWDF8t8cKOHOYXHMZa5iiXGGLRroH8f\\n0/YcyDeQDNKN5MEgLCgTh9KSifITb7a+ajQz3NCYXByCfrv39TipGNbPR9GGaKqE\\nrE/b+ZuuMX29V+EloGWIzol1gra0QGBSyx6a7r1JjQKBgQDTpqC1OoCdpyzVdFil\\n1FQgarw8X5CUN/DqY94wmBcM7CQf4IvvYoInurZjzCVOl9EAccD3hWhA9OxHj9CW\\nxZequdSTF6v1foYlCy1FopuAxjbPkAOndis5rAPWF/1PbYhTs0ZXHGkHlcPqx9Ma\\njrK7o8a9Ijfbe9M7HLlJD7LxnQKBgQDRzVDO9/w7lLEeFv2NTJiN4S75On+2cCul\\nPnmD6tun9bddXm1T4ffMBb0zaHyYh2N05NYn/lMIeuvhR2O0SA5S6VzTlK59gXuF\\nxN86LUOM1Dy8v+R8AKeGCzEE7uAf2UFmr+nayuKKhCZaOzMoQOhw3JPzNYaY8j6X\\nsjQWVIftBQKBgQCjQPjfMWP5tvR/JUInj1LgulO9od0MZuX+dc/x3a6R+ieXKwXl\\nPS+143BCJDp2l+XPmO7GPfH/gKwsOsMjOQBW4QYV+4FZWCGyux9NgjK+LqYijiwz\\nZJPM5WEEJ/bs6EjqfvL3yGM/RYccNswfxQgaciaexqEdPDLferV0pJZbhQKBgHTh\\nvHZBo60Rzobj6gfxN0A7xq6kj4f0/+vEXXBHxG3TL3993syPpDxuqhRczqUvMBJs\\ndn67akjcKlNMMVi7l/dK+SMKvxc+rrE8l9xSYUKw7tF82m7W8n1z+LA14Hj90TjD\\nIjZ5NzJSIwe72WlAl/5gdLBXDpBgzMw4RFp4Z219AoGATUTZquRBsN2KqKv4toee\\naRLPvGMPouhNHvpzXulkkhb/FY3jM3dxRCzEEZBHZufQUVdEqQ1uWOLD7g2baisz\\nNwd/MP+gEVTr+KL2v+o0N5Q8RxFlGnUJdRzojGhg3N6h3q9lhLMy2KWl2NWAkUEY\\nU5HwdWE0UZm/x1GWIi29WgU=\\n-----END PRIVATE KEY-----\\n"|

  defp pem_setup do
    ~s|pem_key = #{@pem_python_literal}\n|
  end

  describe "crypto.sign_rs256" do
    test "signs data and returns a binary signature" do
      result =
        Pyex.run!("""
        import crypto
        #{pem_setup()}
        sig = crypto.sign_rs256("hello world", pem_key)
        len(sig) > 0
        """)

      assert result == true
    end

    test "signature is 256 bytes for RSA 2048-bit key" do
      sig =
        Pyex.run!("""
        import crypto
        #{pem_setup()}
        crypto.sign_rs256("test data", pem_key)
        """)

      # Raw binary should be exactly 256 bytes for RSA-2048
      assert byte_size(sig) == 256
    end

    test "same input produces same signature (deterministic for PKCS1v15)" do
      result =
        Pyex.run!("""
        import crypto
        #{pem_setup()}
        sig1 = crypto.sign_rs256("deterministic test", pem_key)
        sig2 = crypto.sign_rs256("deterministic test", pem_key)
        sig1 == sig2
        """)

      assert result == true
    end

    test "different data produces different signatures" do
      result =
        Pyex.run!("""
        import crypto
        #{pem_setup()}
        sig1 = crypto.sign_rs256("message one", pem_key)
        sig2 = crypto.sign_rs256("message two", pem_key)
        sig1 != sig2
        """)

      assert result == true
    end

    test "signature can be base64url-encoded" do
      result =
        Pyex.run!("""
        import crypto, base64
        #{pem_setup()}
        sig = crypto.sign_rs256("hello", pem_key)
        encoded = base64.urlsafe_b64encode(sig)
        len(encoded) > 0
        """)

      assert result == true
    end

    test "produces a verifiable RS256 signature" do
      sig =
        Pyex.run!("""
        import crypto
        #{pem_setup()}
        crypto.sign_rs256("verify me", pem_key)
        """)

      # Verify with Erlang's :public_key
      [entry] = :public_key.pem_decode(@test_pem)
      private_key = :public_key.pem_entry_decode(entry)
      public_key = extract_public_key(private_key)

      assert :public_key.verify("verify me", :sha256, sig, public_key)
    end

    test "signs empty string" do
      sig =
        Pyex.run!("""
        import crypto
        #{pem_setup()}
        crypto.sign_rs256("", pem_key)
        """)

      assert byte_size(sig) == 256
    end

    test "signs long data" do
      sig =
        Pyex.run!("""
        import crypto
        #{pem_setup()}
        data = "a" * 10000
        crypto.sign_rs256(data, pem_key)
        """)

      assert byte_size(sig) == 256
    end

    test "signs data containing special characters" do
      result =
        Pyex.run!("""
        import crypto
        #{pem_setup()}
        sig = crypto.sign_rs256("hello\\nworld\\t!@#$%^&*()", pem_key)
        len(sig) > 0
        """)

      assert result == true
    end
  end

  describe "crypto.sign_rs256 error handling" do
    test "raises ValueError for invalid PEM data" do
      assert_raise RuntimeError, ~r/ValueError.*could not decode PEM/, fn ->
        Pyex.run!("""
        import crypto
        crypto.sign_rs256("data", "not a pem key")
        """)
      end
    end

    test "raises ValueError for empty PEM string" do
      assert_raise RuntimeError, ~r/ValueError.*could not decode PEM/, fn ->
        Pyex.run!("""
        import crypto
        crypto.sign_rs256("data", "")
        """)
      end
    end

    test "raises TypeError when data is not a string" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!("""
        import crypto
        #{pem_setup()}
        crypto.sign_rs256(123, pem_key)
        """)
      end
    end

    test "raises TypeError when pem_key is not a string" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!("""
        import crypto
        crypto.sign_rs256("data", 123)
        """)
      end
    end

    test "raises TypeError with no arguments" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!("""
        import crypto
        crypto.sign_rs256()
        """)
      end
    end

    test "raises TypeError with one argument" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!("""
        import crypto
        crypto.sign_rs256("data")
        """)
      end
    end
  end

  describe "JWT signing flow (end-to-end)" do
    test "builds a complete JWT with valid structure" do
      result =
        Pyex.run!("""
        import crypto, base64, json
        #{pem_setup()}

        def b64url(s):
            return base64.urlsafe_b64encode(s).replace("=", "")

        header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}))
        payload = b64url(json.dumps({
            "iss": "test@example.com",
            "scope": "https://www.googleapis.com/auth/spreadsheets",
            "aud": "https://oauth2.googleapis.com/token",
            "iat": 1000000,
            "exp": 1003600,
        }))

        signing_input = header + "." + payload
        signature = b64url(crypto.sign_rs256(signing_input, pem_key))
        jwt = signing_input + "." + signature

        parts = jwt.split(".")
        len(parts)
        """)

      assert result == 3
    end

    test "JWT parts are all non-empty" do
      result =
        Pyex.run!("""
        import crypto, base64, json
        #{pem_setup()}

        def b64url(s):
            return base64.urlsafe_b64encode(s).replace("=", "")

        header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}))
        payload = b64url(json.dumps({"iss": "test@example.com", "iat": 1000000, "exp": 1003600}))

        signing_input = header + "." + payload
        signature = b64url(crypto.sign_rs256(signing_input, pem_key))
        jwt = signing_input + "." + signature

        parts = jwt.split(".")
        all(len(p) > 0 for p in parts)
        """)

      assert result == true
    end

    test "JWT header decodes to correct JSON" do
      result =
        Pyex.run!("""
        import crypto, base64, json
        #{pem_setup()}

        def b64url(s):
            return base64.urlsafe_b64encode(s).replace("=", "")

        header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}))
        payload = b64url(json.dumps({"iss": "test@example.com"}))

        signing_input = header + "." + payload
        signature = b64url(crypto.sign_rs256(signing_input, pem_key))
        jwt = signing_input + "." + signature

        header_part = jwt.split(".")[0]
        decoded = json.loads(base64.urlsafe_b64decode(header_part))
        decoded["alg"]
        """)

      assert result == "RS256"
    end

    test "JWT signature is verifiable" do
      jwt =
        Pyex.run!("""
        import crypto, base64, json
        #{pem_setup()}

        def b64url(s):
            return base64.urlsafe_b64encode(s).replace("=", "")

        header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}))
        payload = b64url(json.dumps({"sub": "test"}))

        signing_input = header + "." + payload
        signature = b64url(crypto.sign_rs256(signing_input, pem_key))
        signing_input + "." + signature
        """)

      [header, payload, signature] = String.split(jwt, ".")
      signing_input = header <> "." <> payload

      # Decode the base64url signature
      padded =
        case rem(byte_size(signature), 4) do
          0 -> signature
          2 -> signature <> "=="
          3 -> signature <> "="
          _ -> signature
        end

      {:ok, sig_bytes} = Base.url_decode64(padded)

      # Verify with public key
      [entry] = :public_key.pem_decode(@test_pem)
      private_key = :public_key.pem_entry_decode(entry)
      public_key = extract_public_key(private_key)

      assert :public_key.verify(signing_input, :sha256, sig_bytes, public_key)
    end

    test "full Google Sheets auth flow structure" do
      result =
        Pyex.run!("""
        import crypto, base64, json, time
        #{pem_setup()}

        def b64url(s):
            return base64.urlsafe_b64encode(s).replace("=", "")

        def get_jwt(sa_email, private_key, token_uri):
            now = int(time.time())
            header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}))
            payload = b64url(json.dumps({
                "iss": sa_email,
                "scope": "https://www.googleapis.com/auth/spreadsheets",
                "aud": token_uri,
                "iat": now,
                "exp": now + 3600,
            }))

            signing_input = header + "." + payload
            signature = b64url(crypto.sign_rs256(signing_input, private_key))
            return signing_input + "." + signature

        jwt = get_jwt("sa@project.iam.gserviceaccount.com", pem_key, "https://oauth2.googleapis.com/token")
        parts = jwt.split(".")
        len(parts) == 3 and all(len(p) > 0 for p in parts)
        """)

      assert result == true
    end
  end

  describe "module registration" do
    test "crypto module is listed in stdlib" do
      assert "crypto" in Pyex.Stdlib.module_names()
    end

    test "crypto module can be imported" do
      # Should not raise
      Pyex.run!("""
      import crypto
      """)
    end
  end

  # Helper to extract public key from RSA private key
  defp extract_public_key({:RSAPrivateKey, :"two-prime", n, e, _d, _p, _q, _dp, _dq, _qi, _other}) do
    {:RSAPublicKey, n, e}
  end
end
