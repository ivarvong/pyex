defmodule Pyex.Conformance.ZipfileTest do
  @moduledoc """
  Live CPython conformance tests for the `zipfile` module.

  We compare Pyex against CPython in two modes:

  1. **Pure snippets** that don't touch the filesystem (ZipInfo,
     constants, class hierarchy). Handled by `check!/1` from the
     shared oracle.

  2. **File-backed snippets** where the test writes a zip under a
     generated path. CPython runs inside a fresh temp directory; Pyex
     runs with an in-memory filesystem pre-populated from the same
     source bytes. We compare stdout byte-for-byte.

  Nondeterministic fields (`date_time`, raw zip bytes) are never
  printed — only names, sizes, compression methods, extracted payloads,
  and exception class names.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  alias Pyex.Filesystem.Memory

  # ---------------------------------------------------------------------------
  # File-backed parity helper
  # ---------------------------------------------------------------------------

  defp check_with_files!(source, files) do
    import ExUnit.Assertions

    tmp_dir = Path.join(System.tmp_dir!(), "pyex_zf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    try do
      Enum.each(files, fn {path, content} ->
        full = Path.join(tmp_dir, path)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
      end)

      cpython_out = run_cpython_in_dir(source, tmp_dir)
      pyex_out = run_pyex_with_fs(source, files)

      assert cpython_out == pyex_out,
             """
             Conformance mismatch.

             source:
             #{indent(source)}

             CPython:
             #{indent(cpython_out)}

             Pyex:
             #{indent(pyex_out)}
             """
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp run_cpython_in_dir(source, dir) do
    {out, 0} =
      System.cmd("python3", ["-c", source],
        cd: dir,
        stderr_to_stdout: true
      )

    out
  end

  defp run_pyex_with_fs(source, files) do
    fs = Memory.new(Map.new(files))

    case Pyex.run(source, filesystem: fs) do
      {:ok, _val, ctx} -> Pyex.output(ctx) |> IO.iodata_to_binary()
      {:error, err} -> raise "Pyex failed: #{err.message}"
    end
  end

  defp indent(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end

  # ---------------------------------------------------------------------------
  # Pure (no-filesystem) conformance
  # ---------------------------------------------------------------------------

  describe "module surface" do
    test "ZIP_STORED and ZIP_DEFLATED constants" do
      check!("""
      import zipfile
      print(zipfile.ZIP_STORED)
      print(zipfile.ZIP_DEFLATED)
      """)
    end

    test "BadZipFile is a subclass of Exception" do
      check!("""
      import zipfile
      print(issubclass(zipfile.BadZipFile, Exception))
      """)
    end

    test "LargeZipFile is a subclass of Exception" do
      check!("""
      import zipfile
      print(issubclass(zipfile.LargeZipFile, Exception))
      """)
    end
  end

  describe "ZipInfo" do
    test "default attributes for a regular filename" do
      check!("""
      import zipfile
      info = zipfile.ZipInfo('foo.txt')
      print(info.filename)
      print(info.file_size)
      print(info.compress_size)
      print(info.compress_type)
      """)
    end

    test "is_dir is True for trailing-slash names" do
      check!("""
      import zipfile
      print(zipfile.ZipInfo('sub/').is_dir())
      print(zipfile.ZipInfo('sub').is_dir())
      """)
    end
  end

  # ---------------------------------------------------------------------------
  # File-backed conformance
  # ---------------------------------------------------------------------------

  describe "round-trip writestr / read (via filesystem)" do
    test "multiple entries preserve insertion order" do
      check_with_files!(
        """
        import zipfile
        with zipfile.ZipFile('o.zip', 'w') as z:
            z.writestr('z.txt', 'last')
            z.writestr('a.txt', 'first')
            z.writestr('m.txt', 'middle')
        with zipfile.ZipFile('o.zip', 'r') as z:
            for name in z.namelist():
                print(name)
            print(z.read('a.txt'))
        """,
        []
      )
    end

    test "stored entry reports compress_type=0 after round-trip" do
      check_with_files!(
        """
        import zipfile
        with zipfile.ZipFile('o.zip', 'w', zipfile.ZIP_STORED) as z:
            z.writestr('s.txt', 'xyz')
        with zipfile.ZipFile('o.zip', 'r') as z:
            info = z.getinfo('s.txt')
            print(info.compress_type)
            print(info.file_size)
        """,
        []
      )
    end

    test "deflated entry recovers file_size and payload" do
      check_with_files!(
        """
        import zipfile
        payload = 'ABCDEF' * 500
        with zipfile.ZipFile('o.zip', 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr('big.txt', payload)
        with zipfile.ZipFile('o.zip', 'r') as z:
            info = z.getinfo('big.txt')
            print(info.file_size)
            print(info.compress_type)
            print(len(z.read('big.txt')))
            print(z.read('big.txt') == payload.encode())
        """,
        []
      )
    end

    test "nested docx-like paths round-trip" do
      check_with_files!(
        """
        import zipfile
        with zipfile.ZipFile('doc.docx', 'w') as z:
            z.writestr('[Content_Types].xml', '<Types/>')
            z.writestr('word/document.xml', '<Body/>')
            z.writestr('word/_rels/document.xml.rels', '<Relationships/>')
        with zipfile.ZipFile('doc.docx', 'r') as z:
            for name in z.namelist():
                print(name)
            print(z.read('word/document.xml'))
        """,
        []
      )
    end
  end

  describe "error handling (via filesystem)" do
    test "opening a non-zip raises BadZipFile" do
      check_with_files!(
        """
        import zipfile
        try:
            zipfile.ZipFile('junk.zip')
            print('no raise')
        except zipfile.BadZipFile:
            print('BadZipFile raised')
        """,
        [{"junk.zip", "not a zip"}]
      )
    end

    test "BadZipFile is catchable as Exception" do
      check_with_files!(
        """
        import zipfile
        try:
            zipfile.ZipFile('junk.zip')
        except Exception as e:
            print(type(e).__name__)
        """,
        [{"junk.zip", "garbage"}]
      )
    end

    test "read(missing) raises KeyError" do
      check_with_files!(
        """
        import zipfile
        with zipfile.ZipFile('o.zip', 'w') as z:
            z.writestr('only', 'x')
        with zipfile.ZipFile('o.zip', 'r') as z:
            try:
                z.read('nope')
                print('no raise')
            except KeyError:
                print('KeyError raised')
        """,
        []
      )
    end

    test "getinfo(missing) raises KeyError" do
      check_with_files!(
        """
        import zipfile
        with zipfile.ZipFile('o.zip', 'w') as z:
            z.writestr('only', 'x')
        with zipfile.ZipFile('o.zip', 'r') as z:
            try:
                z.getinfo('nope')
                print('no raise')
            except KeyError:
                print('KeyError raised')
        """,
        []
      )
    end
  end

  describe "is_zipfile (via filesystem)" do
    test "returns True for a valid zip path" do
      check_with_files!(
        """
        import zipfile
        with zipfile.ZipFile('v.zip', 'w') as z:
            z.writestr('x', 'y')
        print(zipfile.is_zipfile('v.zip'))
        """,
        []
      )
    end

    test "returns False for a non-zip file" do
      check_with_files!(
        """
        import zipfile
        print(zipfile.is_zipfile('plain.txt'))
        """,
        [{"plain.txt", "nope"}]
      )
    end
  end

  describe "introspection (via filesystem)" do
    test "infolist exposes filename and file_size" do
      check_with_files!(
        """
        import zipfile
        with zipfile.ZipFile('o.zip', 'w') as z:
            z.writestr('a', '1')
            z.writestr('bb', '22')
            z.writestr('ccc', '333')
        with zipfile.ZipFile('o.zip', 'r') as z:
            for info in z.infolist():
                print(info.filename, info.file_size)
        """,
        []
      )
    end
  end

  describe "ZipFile.open (via filesystem)" do
    test "file-like read() returns entry bytes" do
      check_with_files!(
        """
        import zipfile
        with zipfile.ZipFile('o.zip', 'w') as z:
            z.writestr('data.txt', 'Hello, world!')
        with zipfile.ZipFile('o.zip', 'r') as z:
            with z.open('data.txt') as f:
                print(f.read())
        """,
        []
      )
    end

    test "chunked reads advance the cursor correctly" do
      check_with_files!(
        """
        import zipfile
        with zipfile.ZipFile('o.zip', 'w') as z:
            z.writestr('f', 'abcdefghij')
        with zipfile.ZipFile('o.zip', 'r') as z:
            with z.open('f') as f:
                print(f.read(3))
                print(f.read(4))
                print(f.read())
                print(f.read())
        """,
        []
      )
    end
  end

  # Note: CPython's `zipfile.ZipFile` is NOT iterable — you have to call
  # `.namelist()` explicitly.  Pyex allows `for name in z:` as a small
  # ergonomic extension; there's no conformance test for it because the
  # two would diverge by design.

  describe "writer features (via filesystem)" do
    test "mixed STORED + DEFLATED archive readable by CPython" do
      check_with_files!(
        """
        import zipfile
        with zipfile.ZipFile('o.zip', 'w', zipfile.ZIP_STORED) as z:
            z.writestr('plain.txt', 'short')
            big = zipfile.ZipInfo('big.txt')
            big.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(big, 'A' * 5000)
        with zipfile.ZipFile('o.zip', 'r') as z:
            for info in z.infolist():
                print(info.filename, info.compress_type, info.file_size)
        """,
        []
      )
    end

    test "ZipInfo date_time round-trips" do
      check_with_files!(
        """
        import zipfile
        info = zipfile.ZipInfo('t.txt', (2024, 6, 15, 12, 30, 0))
        with zipfile.ZipFile('o.zip', 'w') as z:
            z.writestr(info, 'hi')
        with zipfile.ZipFile('o.zip', 'r') as z:
            print(z.getinfo('t.txt').date_time)
        """,
        []
      )
    end

    test "directory entry is reported as such by CPython" do
      check_with_files!(
        """
        import zipfile
        with zipfile.ZipFile('o.zip', 'w') as z:
            z.mkdir('sub')
            z.writestr('sub/f', 'x')
        with zipfile.ZipFile('o.zip', 'r') as z:
            print(z.getinfo('sub/').is_dir())
            print(z.getinfo('sub/f').is_dir())
        """,
        []
      )
    end
  end

  describe "archive comment (via filesystem)" do
    test "comment round-trips through write + read" do
      check_with_files!(
        """
        import zipfile
        with zipfile.ZipFile('o.zip', 'w') as z:
            z.writestr('a', 'x')
            z.comment = b'some archive comment'
        with zipfile.ZipFile('o.zip', 'r') as z:
            print(z.comment)
        """,
        []
      )
    end
  end
end
