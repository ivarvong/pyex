defmodule Pyex.Stdlib.SandboxGapsTest do
  use ExUnit.Case, async: true

  @fs_opts [filesystem: Pyex.Filesystem.Memory.new()]

  # ---------------------------------------------------------------------------
  # Gap 1: json.load(f) / json.dump(obj, f)
  # ---------------------------------------------------------------------------
  describe "json.load/1 — deserialize file handle contents as JSON" do
    test "json.load(f) reads a file handle and parses the JSON string into a dict" do
      code = """
      import json
      with open("data.json", "w") as f:
          f.write('{"name": "Alice", "age": 30}')
      with open("data.json", "r") as f:
          data = json.load(f)
      data["name"]
      """

      assert Pyex.run!(code, @fs_opts) == "Alice"
    end

    test "json.load(f) raises ValueError when the file contains invalid JSON" do
      code = """
      import json
      with open("bad.json", "w") as f:
          f.write("not json")
      with open("bad.json", "r") as f:
          json.load(f)
      """

      assert_raise RuntimeError, ~r/JSONDecodeError/, fn ->
        Pyex.run!(code, @fs_opts)
      end
    end
  end

  describe "json.dump/2 — serialize a Python object as JSON into a file handle" do
    test "json.dump(obj, f) writes JSON string to the file that can be read back" do
      code = """
      import json
      data = {"key": "value", "num": 42}
      with open("out.json", "w") as f:
          json.dump(data, f)
      with open("out.json", "r") as f:
          result = f.read()
      result
      """

      result = Pyex.run!(code, @fs_opts)
      assert result =~ "key"
      assert result =~ "value"
      assert result =~ "42"
    end

    test "json.dump(obj, f, indent=2) writes pretty-printed JSON with newlines and indentation" do
      code = """
      import json
      data = {"a": 1}
      with open("pretty.json", "w") as f:
          json.dump(data, f, indent=2)
      with open("pretty.json", "r") as f:
          result = f.read()
      result
      """

      result = Pyex.run!(code, @fs_opts)
      assert result =~ "\n"
      assert result =~ "  "
    end
  end

  # ---------------------------------------------------------------------------
  # Gap 2: open(f, errors="ignore")
  # ---------------------------------------------------------------------------
  describe "open() errors kwarg — accept and ignore the encoding error handler" do
    test "open(path, mode, errors='ignore') does not raise TypeError for unsupported kwarg" do
      code = """
      with open("test.txt", "w") as f:
          f.write("hello")
      with open("test.txt", "r", errors="ignore") as f:
          data = f.read()
      data
      """

      assert Pyex.run!(code, @fs_opts) == "hello"
    end

    test "open(path, mode, errors='replace') is also accepted without raising" do
      code = """
      with open("test.txt", "w") as f:
          f.write("hello")
      with open("test.txt", "r", errors="replace") as f:
          data = f.read()
      data
      """

      assert Pyex.run!(code, @fs_opts) == "hello"
    end
  end

  # ---------------------------------------------------------------------------
  # Gap 3: open(f, "wb") / "rb" / "ab" — binary mode flags
  # ---------------------------------------------------------------------------
  describe "open() binary mode flags — strip 'b' and map to text equivalents" do
    test "open(path, 'rb') strips the b flag and reads the file as if mode were 'r'" do
      code = """
      with open("test.txt", "w") as f:
          f.write("binary read")
      with open("test.txt", "rb") as f:
          data = f.read()
      data
      """

      assert Pyex.run!(code, @fs_opts) == "binary read"
    end

    test "open(path, 'wb') strips the b flag and writes the file as if mode were 'w'" do
      code = """
      with open("out.txt", "wb") as f:
          f.write("binary write")
      with open("out.txt", "r") as f:
          data = f.read()
      data
      """

      assert Pyex.run!(code, @fs_opts) == "binary write"
    end

    test "open(path, 'ab') strips the b flag and appends to the file as if mode were 'a'" do
      code = """
      with open("app.txt", "w") as f:
          f.write("first")
      with open("app.txt", "ab") as f:
          f.write(" second")
      with open("app.txt", "r") as f:
          data = f.read()
      data
      """

      assert Pyex.run!(code, @fs_opts) == "first second"
    end
  end

  # ---------------------------------------------------------------------------
  # Gap 4: import sys — minimal sys module
  # ---------------------------------------------------------------------------
  describe "sys module — minimal stub so 'import sys' does not raise ModuleNotFoundError" do
    test "sys.argv returns an empty list since there are no CLI arguments in the sandbox" do
      assert Pyex.run!("import sys\nsys.argv") == []
    end

    test "sys.version returns a Python-style version string containing 'Python'" do
      result = Pyex.run!("import sys\nsys.version")
      assert is_binary(result)
      assert result =~ "Python"
    end

    test "sys.maxsize returns a large integer matching Python's 64-bit sys.maxsize" do
      result = Pyex.run!("import sys\nsys.maxsize")
      assert is_integer(result)
      assert result > 1_000_000_000
    end

    test "sys.stdout is accessible without raising AttributeError" do
      code = """
      import sys
      sys.stdout
      """

      Pyex.run!(code)
    end

    test "sys.stdin is accessible without raising AttributeError" do
      code = """
      import sys
      sys.stdin
      """

      Pyex.run!(code)
    end
  end

  # ---------------------------------------------------------------------------
  # Dict attribute access must resolve to methods, never shadowed by dict keys
  # ---------------------------------------------------------------------------
  describe "dict attribute lookup does not treat dict keys as attributes" do
    test "d.items() returns method even when dict has a key named 'items'" do
      code = """
      d = {"items": [1, 2, 3], "other": 4}
      list(d.items())
      """

      # Python: [('items', [1,2,3]), ('other', 4)]
      result = Pyex.run!(code)
      assert is_list(result)
      assert length(result) == 2
    end

    test "recursive walk over nested dict/list does not fail when a key is named 'items'" do
      code = """
      def walk(d):
          if isinstance(d, dict):
              for k, v in d.items():
                  walk(v)
          elif isinstance(d, list):
              for item in d:
                  walk(item)
      walk({"venue": {"name": "Bar"}, "items": [{"name": "x"}]})
      """

      Pyex.run!(code)
    end

    test "d.keys() returns method even when dict has a key named 'keys'" do
      code = """
      d = {"keys": "stringvalue"}
      list(d.keys())
      """

      assert Pyex.run!(code) == ["keys"]
    end
  end

  # ---------------------------------------------------------------------------
  # Gap 5: sys.path is a mutable list, not a dict
  # ---------------------------------------------------------------------------
  describe "sys.path — list of import search paths" do
    test "sys.path.insert(0, p) prepends and sys.path[0] returns the inserted value" do
      code = """
      import sys
      sys.path.insert(0, "/app")
      sys.path.insert(0, "/first")
      (sys.path[0], sys.path[1])
      """

      assert Pyex.run!(code) == {:tuple, ["/first", "/app"]}
    end

    test "sys.path.append adds to the end and len() reflects the new length" do
      code = """
      import sys
      before = len(sys.path)
      sys.path.append("/lib/one")
      sys.path.append("/lib/two")
      (len(sys.path) - before, sys.path[-2], sys.path[-1])
      """

      assert Pyex.run!(code) == {:tuple, [2, "/lib/one", "/lib/two"]}
    end

    test "sys.argv[1] parsing under `if __name__ == '__main__'` matches a CLI-style script epilogue" do
      # Mirrors the epilogue of an LLM-generated API-client script:
      #   if __name__ == "__main__":
      #       import sys
      #       vid = int(sys.argv[1]) if len(sys.argv) > 1 else 50227
      # We pre-populate sys.argv to simulate `python3 /api.py 50227`.
      code = """
      import sys
      sys.argv.append("/api.py")
      sys.argv.append("50227")

      parsed = None
      default_used = None
      if __name__ == "__main__":
          vid = int(sys.argv[1]) if len(sys.argv) > 1 else 50227
          parsed = vid
          default_used = len(sys.argv) <= 1
      (parsed, default_used)
      """

      assert Pyex.run!(code) == {:tuple, [50227, false]}
    end

    test "sys.argv default branch: len(sys.argv) <= 1 falls through to the literal default" do
      code = """
      import sys
      vid = int(sys.argv[1]) if len(sys.argv) > 1 else 50227
      vid
      """

      assert Pyex.run!(code) == 50227
    end

    test "sys.path mutations persist across statements within a single run" do
      code = """
      import sys
      sys.path.append("/persisted")
      "/persisted" in sys.path
      """

      assert Pyex.run!(code) == true
    end
  end

  # ---------------------------------------------------------------------------
  # Gap 6: module dunder attributes resolve via attribute access
  # ---------------------------------------------------------------------------
  describe "imported modules expose dunder attributes via attribute access" do
    test "requests.__version__ is a non-empty dotted version string" do
      code = """
      import requests
      v = requests.__version__
      (isinstance(v, str), len(v) > 0, "." in v)
      """

      assert Pyex.run!(code) == {:tuple, [true, true, true]}
    end
  end

  # ---------------------------------------------------------------------------
  # Gap 7: urllib.request — urlopen returns a response with read() and status
  # ---------------------------------------------------------------------------
  describe "urllib.request.urlopen — HTTP GET returning a response object" do
    @describetag :external_http
    @describetag timeout: 30_000

    test "urlopen(url).read() returns a body that echoes the query arg and status is 200" do
      code = """
      from urllib.request import urlopen
      resp = urlopen("https://postman-echo.com/get?source=pyex")
      body = resp.read()
      (resp.status, "pyex" in body)
      """

      assert Pyex.run!(code,
               network: [%{allowed_url_prefix: "https://postman-echo.com/get"}]
             ) == {:tuple, [200, true]}
    end

    test "urlopen response exposes getheader('Content-Type') matching the server-reported type" do
      code = """
      from urllib.request import urlopen
      resp = urlopen("https://postman-echo.com/get")
      ctype = resp.getheader("Content-Type")
      # Req returns header values as a list; take the first entry.
      first = ctype[0] if isinstance(ctype, list) else ctype
      (resp.status, first.startswith("application/json"))
      """

      assert Pyex.run!(code,
               network: [%{allowed_url_prefix: "https://postman-echo.com/get"}]
             ) == {:tuple, [200, true]}
    end
  end

  # ---------------------------------------------------------------------------
  # Regex evaluation on large inputs with bounded quantifiers
  # ---------------------------------------------------------------------------
  describe "re.search with bounded quantifiers on large inputs" do
    test "re.search with bounded quantifier on a large input completes without ReDoS timeout" do
      # Size chosen so the match completes under the 10s guard even on
      # slower CI (OTP 28 recompiles regexes per call). The 1s pre-fix
      # timeout still fails at this size, so the regression remains covered.
      code = """
      import re
      big = "var x=function(){return 1;};" * 15000
      m = re.search(r'.{0,300}venue.{0,300}', big)
      m is None
      """

      assert Pyex.run!(code) == true
    end
  end
end
