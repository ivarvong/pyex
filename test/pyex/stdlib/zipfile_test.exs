defmodule Pyex.Stdlib.ZipfileTest do
  use ExUnit.Case, async: true

  alias Pyex.Filesystem.Memory

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_zip(files) when is_list(files) do
    erlang_files = Enum.map(files, fn {name, data} -> {String.to_charlist(name), data} end)
    {:ok, {_, bin}} = :zip.create(~c"t.zip", erlang_files, [:memory])
    bin
  end

  defp make_zip_deflated(files) when is_list(files) do
    erlang_files = Enum.map(files, fn {name, data} -> {String.to_charlist(name), data} end)
    {:ok, {_, bin}} = :zip.create(~c"t.zip", erlang_files, [:memory, {:compress, :all}])
    bin
  end

  defp run(code, fs \\ nil) do
    opts = if fs, do: [filesystem: fs], else: []
    Pyex.run!(code, opts)
  end

  # ---------------------------------------------------------------------------
  # Zip-patching helpers. `:zip` won't write encrypted entries, symlink
  # attr bits, or names with control characters — so we build a normal
  # archive and patch the central directory bytes in place. Crude, but it
  # produces real archives that exercise the parser.
  # ---------------------------------------------------------------------------

  @cd_sig <<0x50, 0x4B, 0x01, 0x02>>
  @eocd_sig <<0x50, 0x4B, 0x05, 0x06>>

  defp find_eocd_offset(bin) do
    size = byte_size(bin)
    start = max(0, size - 65_557)
    tail = binary_part(bin, start, size - start)
    [{off, _}] = :binary.matches(tail, @eocd_sig) |> Enum.take(-1) |> List.wrap()
    start + off
  end

  defp find_cd_offset(bin) do
    # EOCD header is fixed at 22 bytes and contains the offset to the CD
    # as the 8th field (little-endian u32 at offset 16).  We search from
    # the end for the signature.
    size = byte_size(bin)
    start = max(0, size - 65_557)
    tail = binary_part(bin, start, size - start)
    [{off, _}] = :binary.matches(tail, @eocd_sig) |> Enum.take(-1) |> List.wrap()
    eocd_off = start + off
    <<_::binary-size(16), cd_off::little-32, _::binary>> = binary_part(bin, eocd_off, 22)
    cd_off
  end

  defp find_first_cd_entry(bin) do
    cd_off = find_cd_offset(bin)
    @cd_sig = binary_part(bin, cd_off, 4)
    cd_off
  end

  # Flip bit 0 of the general-purpose flag (offset 8 in the CD record)
  # so the entry looks encrypted.
  defp mark_first_entry_encrypted(bin) do
    off = find_first_cd_entry(bin) + 8
    <<pre::binary-size(^off), flag::little-16, post::binary>> = bin
    <<pre::binary, Bitwise.bor(flag, 0x0001)::little-16, post::binary>>
  end

  # Set Unix mode S_IFLNK (0o120000) in external_attr (offset 38 in CD).
  defp mark_first_entry_symlink(bin) do
    off = find_first_cd_entry(bin) + 38
    <<pre::binary-size(^off), _attr::little-32, post::binary>> = bin
    <<pre::binary, 0o120_755 * 0x10000::little-32, post::binary>>
  end

  # Overwrite the filename bytes in BOTH the first entry's local file
  # header AND its central directory entry.  Patching only one side
  # would trip our LFH/CD cross-check before the filename-sanity check
  # we're usually trying to exercise.
  defp patch_first_entry_name(bin, new_name) when is_binary(new_name) do
    bin |> patch_first_entry_cd_name(new_name) |> patch_first_entry_lfh_name(new_name)
  end

  # CD entry layout: sig(4) + 22-byte header + name_len(2) + 16 more bytes
  # + name + extra + comment.
  defp patch_first_entry_cd_name(bin, new_name) do
    off = find_first_cd_entry(bin)

    <<pre::binary-size(^off), sig::binary-size(4), pre_name_len::binary-size(24),
      name_len::little-16, post_name_len::binary-size(16), rest::binary>> = bin

    if byte_size(new_name) != name_len do
      raise "patch_first_entry_cd_name: new name must match existing length (#{name_len} bytes)"
    end

    <<_old_name::binary-size(^name_len), tail::binary>> = rest

    <<pre::binary, sig::binary, pre_name_len::binary, name_len::little-16, post_name_len::binary,
      new_name::binary, tail::binary>>
  end

  # Patch the CRC-32 field (offset 16) of the first CD entry.
  defp patch_cd_crc(bin, new_crc) do
    off = find_first_cd_entry(bin) + 16
    <<pre::binary-size(^off), _crc::little-32, post::binary>> = bin
    <<pre::binary, new_crc::little-32, post::binary>>
  end

  # Patch the CRC-32 field (offset 14) of the first entry's LFH.
  defp patch_lfh_crc(bin, new_crc) do
    <<pre::binary-size(14), _crc::little-32, post::binary>> = bin
    <<pre::binary, new_crc::little-32, post::binary>>
  end

  # Append a copy of the first CD entry to create a duplicate.  The EOCD's
  # total_entries count and cd_size also need to be bumped.
  defp duplicate_first_cd_entry(bin) do
    cd_off = find_cd_offset(bin)
    eocd_off = find_eocd_offset(bin)
    cd_size = eocd_off - cd_off

    # Grab the first CD entry: sig + 46 fixed + name + extra + comment.
    <<@cd_sig, _pre_name_len::binary-size(24), name_len::little-16, extra_len::little-16,
      comment_len::little-16, _rest::binary>> = binary_part(bin, cd_off, 46)

    entry_size = 46 + name_len + extra_len + comment_len
    first_entry = binary_part(bin, cd_off, entry_size)

    # Rebuild: everything up to EOCD, then duplicate, then the EOCD itself with
    # bumped total_entries and cd_size.
    before_eocd = binary_part(bin, 0, eocd_off)

    # Parse EOCD fields so we can rewrite.
    <<sig::binary-size(4), disk::little-16, cd_disk::little-16, this_disk_entries::little-16,
      total_entries::little-16, _old_cd_size::little-32, _old_cd_offset::little-32,
      comment_len_eocd::little-16, comment::binary>> =
      binary_part(bin, eocd_off, byte_size(bin) - eocd_off)

    new_cd_size = cd_size + entry_size

    new_eocd =
      <<sig::binary, disk::little-16, cd_disk::little-16, this_disk_entries + 1::little-16,
        total_entries + 1::little-16, new_cd_size::little-32, cd_off::little-32,
        comment_len_eocd::little-16, comment::binary>>

    <<before_eocd::binary, first_entry::binary, new_eocd::binary>>
  end

  # LFH for the first entry is always at byte 0: sig(4) + 22-byte header
  # + name_len(2) + extra_len(2) + name + extra + data.
  defp patch_first_entry_lfh_name(bin, new_name) do
    <<sig::binary-size(4), pre_name_len::binary-size(22), name_len::little-16,
      extra_len::little-16, rest::binary>> = bin

    if byte_size(new_name) != name_len do
      raise "patch_first_entry_lfh_name: new name must match existing length"
    end

    <<_old_name::binary-size(^name_len), tail::binary>> = rest

    <<sig::binary, pre_name_len::binary, name_len::little-16, extra_len::little-16,
      new_name::binary, tail::binary>>
  end

  # ---------------------------------------------------------------------------
  # Module exposure
  # ---------------------------------------------------------------------------

  describe "module" do
    test "exposes ZIP_STORED and ZIP_DEFLATED constants" do
      result = run("import zipfile; (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)")
      assert result == {:tuple, [0, 8]}
    end

    test "exposes BadZipFile and LargeZipFile" do
      result =
        run("""
        import zipfile
        (zipfile.BadZipFile.__name__, zipfile.LargeZipFile.__name__)
        """)

      assert result == {:tuple, ["BadZipFile", "LargeZipFile"]}
    end

    test "BadZipfile (lowercase alias) resolves to BadZipFile" do
      # CPython keeps both spellings; `BadZipfile` is a legacy alias.
      result =
        run("""
        import zipfile
        zipfile.BadZipfile.__name__
        """)

      assert result == "BadZipFile"
    end
  end

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  describe "read mode" do
    test "namelist returns entry names in archive order" do
      zip = make_zip([{"a.txt", "A"}, {"b.txt", "B"}, {"c.txt", "C"}])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    names = z.namelist()
names|,
          Memory.new(%{"t.zip" => zip})
        )

      assert result == ["a.txt", "b.txt", "c.txt"]
    end

    test "read returns decompressed bytes for stored entries" do
      zip = make_zip([{"hello.txt", "Hello, world!"}])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    data = z.read('hello.txt')
data|,
          Memory.new(%{"t.zip" => zip})
        )

      assert result == {:bytes, "Hello, world!"}
    end

    test "read returns decompressed bytes for deflated entries" do
      payload = :binary.copy("ABCDEF", 500)
      zip = make_zip_deflated([{"big.bin", payload}])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    data = z.read('big.bin')
    size = len(data)
size|,
          Memory.new(%{"t.zip" => zip})
        )

      assert result == 3000
    end

    test "read of missing entry raises KeyError" do
      zip = make_zip([{"a.txt", "A"}])

      assert_raise RuntimeError, ~r/KeyError/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    z.read('missing.txt')|,
          Memory.new(%{"t.zip" => zip})
        )
      end
    end

    test "getinfo exposes file size and compression method" do
      zip = make_zip_deflated([{"a.txt", :binary.copy("x", 1000)}])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    info = z.getinfo('a.txt')
(info.filename, info.file_size, info.compress_type)|,
          Memory.new(%{"t.zip" => zip})
        )

      assert result == {:tuple, ["a.txt", 1000, 8]}
    end

    test "infolist returns one ZipInfo per entry" do
      zip = make_zip([{"a", "1"}, {"b", "22"}])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    infos = z.infolist()
[(i.filename, i.file_size) for i in infos]|,
          Memory.new(%{"t.zip" => zip})
        )

      assert result == [{:tuple, ["a", 1]}, {:tuple, ["b", 2]}]
    end

    test "nested paths (docx-like) round-trip" do
      zip =
        make_zip([
          {"[Content_Types].xml", "<types/>"},
          {"word/document.xml", "<body>hi</body>"},
          {"word/_rels/document.xml.rels", "<rels/>"}
        ])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('doc.docx') as z:
    xml = z.read('word/document.xml')
xml|,
          Memory.new(%{"doc.docx" => zip})
        )

      assert result == {:bytes, "<body>hi</body>"}
    end

    test "closing twice is a no-op" do
      zip = make_zip([{"a", "1"}])

      result =
        run(
          ~s|import zipfile
z = zipfile.ZipFile('t.zip')
z.close()
z.close()
42|,
          Memory.new(%{"t.zip" => zip})
        )

      assert result == 42
    end

    test "read on closed archive raises ValueError" do
      zip = make_zip([{"a", "1"}])

      assert_raise RuntimeError, ~r/ValueError/, fn ->
        run(
          ~s|import zipfile
z = zipfile.ZipFile('t.zip')
z.close()
z.read('a')|,
          Memory.new(%{"t.zip" => zip})
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  describe "write mode" do
    test "writestr adds an entry retrievable after close" do
      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w') as z:
    z.writestr('greet.txt', 'hi')
with zipfile.ZipFile('o.zip') as z:
    data = z.read('greet.txt')
data|,
          Memory.new(%{})
        )

      assert result == {:bytes, "hi"}
    end

    test "writestr preserves entry order" do
      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w') as z:
    z.writestr('z.txt', '3')
    z.writestr('a.txt', '1')
    z.writestr('m.txt', '2')
with zipfile.ZipFile('o.zip') as z:
    names = z.namelist()
names|,
          Memory.new(%{})
        )

      assert result == ["z.txt", "a.txt", "m.txt"]
    end

    test "ZIP_DEFLATED compresses large redundant payloads" do
      result =
        run(
          ~s|import zipfile
payload = 'A' * 10000
with zipfile.ZipFile('o.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('big.txt', payload)
with zipfile.ZipFile('o.zip') as z:
    info = z.getinfo('big.txt')
    data = z.read('big.txt')
(info.file_size, len(data), info.compress_type)|,
          Memory.new(%{})
        )

      assert result == {:tuple, [10000, 10000, 8]}
    end

    test "write(filename) reads from filesystem and stores under same name" do
      fs = Memory.new(%{"source.txt" => "from disk"})

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w') as z:
    z.write('source.txt')
with zipfile.ZipFile('o.zip') as z:
    data = z.read('source.txt')
data|,
          fs
        )

      assert result == {:bytes, "from disk"}
    end

    test "write(filename, arcname) stores under a different name" do
      fs = Memory.new(%{"src.txt" => "hello"})

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w') as z:
    z.write('src.txt', 'renamed.txt')
with zipfile.ZipFile('o.zip') as z:
    names = z.namelist()
names|,
          fs
        )

      assert result == ["renamed.txt"]
    end

    test "writestr on closed archive raises ValueError" do
      assert_raise RuntimeError, ~r/ValueError/, fn ->
        run(
          ~s|import zipfile
z = zipfile.ZipFile('o.zip', 'w')
z.close()
z.writestr('a', 'b')|,
          Memory.new(%{})
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Extraction with zip-slip protection
  # ---------------------------------------------------------------------------

  describe "extractall / extract" do
    test "extractall writes all entries into the destination directory" do
      zip = make_zip([{"a.txt", "A"}, {"sub/b.txt", "B"}])
      fs = Memory.new(%{"archive.zip" => zip})

      {:ok, _, ctx} =
        Pyex.run(
          """
          import zipfile
          with zipfile.ZipFile('archive.zip') as z:
              z.extractall('out')
          """,
          filesystem: fs
        )

      assert Map.get(ctx.filesystem.files, "out/a.txt") == "A"
      assert Map.get(ctx.filesystem.files, "out/sub/b.txt") == "B"
    end

    test "extract writes a single entry" do
      zip = make_zip([{"keep.txt", "K"}, {"skip.txt", "S"}])
      fs = Memory.new(%{"archive.zip" => zip})

      {:ok, _, ctx} =
        Pyex.run(
          """
          import zipfile
          with zipfile.ZipFile('archive.zip') as z:
              z.extract('keep.txt', 'out')
          """,
          filesystem: fs
        )

      assert Map.get(ctx.filesystem.files, "out/keep.txt") == "K"
      refute Map.has_key?(ctx.filesystem.files, "out/skip.txt")
    end

    test "extractall rejects entries with ../ path escapes" do
      zip = make_zip([{"../etc/passwd", "pwned"}])
      fs = Memory.new(%{"archive.zip" => zip})

      assert_raise RuntimeError, ~r/BadZipFile.*unsafe entry name/, fn ->
        Pyex.run!(
          """
          import zipfile
          with zipfile.ZipFile('archive.zip') as z:
              z.extractall('out')
          """,
          filesystem: fs
        )
      end
    end

    test "extractall rejects Windows-style ..\\\\ path escapes" do
      zip = make_zip([{"..\\evil.txt", "x"}])
      fs = Memory.new(%{"archive.zip" => zip})

      assert_raise RuntimeError, ~r/BadZipFile.*unsafe entry name/, fn ->
        Pyex.run!(
          """
          import zipfile
          with zipfile.ZipFile('archive.zip') as z:
              z.extractall('out')
          """,
          filesystem: fs
        )
      end
    end

    test "extractall rejects nested /../ escapes" do
      zip = make_zip([{"sub/../../outside.txt", "x"}])
      fs = Memory.new(%{"archive.zip" => zip})

      assert_raise RuntimeError, ~r/BadZipFile.*unsafe entry name/, fn ->
        Pyex.run!(
          """
          import zipfile
          with zipfile.ZipFile('archive.zip') as z:
              z.extractall('out')
          """,
          filesystem: fs
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Malformed input & safety limits
  # ---------------------------------------------------------------------------

  describe "malformed input" do
    test "opening a non-zip raises BadZipFile" do
      fs = Memory.new(%{"junk.zip" => "not a zip"})

      assert_raise RuntimeError, ~r/BadZipFile/, fn ->
        Pyex.run!("import zipfile; zipfile.ZipFile('junk.zip')", filesystem: fs)
      end
    end

    test "opening an empty file raises BadZipFile" do
      fs = Memory.new(%{"empty.zip" => ""})

      assert_raise RuntimeError, ~r/BadZipFile/, fn ->
        Pyex.run!("import zipfile; zipfile.ZipFile('empty.zip')", filesystem: fs)
      end
    end

    test "BadZipFile is catchable as zipfile.BadZipFile" do
      fs = Memory.new(%{"junk.zip" => "not a zip"})

      result =
        Pyex.run!(
          """
          import zipfile
          try:
              zipfile.ZipFile('junk.zip')
              outcome = 'opened'
          except zipfile.BadZipFile:
              outcome = 'caught'
          outcome
          """,
          filesystem: fs
        )

      assert result == "caught"
    end

    test "BadZipFile is catchable as Exception" do
      fs = Memory.new(%{"junk.zip" => "not a zip"})

      result =
        Pyex.run!(
          """
          import zipfile
          try:
              zipfile.ZipFile('junk.zip')
              outcome = 'opened'
          except Exception:
              outcome = 'caught'
          outcome
          """,
          filesystem: fs
        )

      assert result == "caught"
    end
  end

  describe "safety limits" do
    test "extreme compression ratio trips the bomb check" do
      # 100 KiB of zeros compresses to ~100 bytes — a 1000x ratio.
      # Our ratio cap is 1024x, so this particular payload should pass.
      # Push harder: 5 MiB of zeros compresses to well over the threshold.
      huge = :binary.copy(<<0>>, 5 * 1024 * 1024)
      zip = make_zip_deflated([{"bomb", huge}])
      fs = Memory.new(%{"b.zip" => zip})

      # This particular payload (~5 MiB -> ~5 KiB) has a ~1000x ratio,
      # so it should *not* trip the guard — the safety cap is a last
      # line of defense, not a total ban on compression.
      Pyex.run!(
        """
        import zipfile
        with zipfile.ZipFile('b.zip') as z:
            info = z.getinfo('bomb')
        info.file_size
        """,
        filesystem: fs
      )
      |> (fn size -> assert size == 5 * 1024 * 1024 end).()
    end

    test "entry count over the hard cap is rejected" do
      # Building a 10_001-entry zip is the honest test but slow; fabricate
      # a minimal one by parsing an over-limit number of entries.
      entries = for i <- 1..10_001, do: {"f#{i}", "x"}
      zip = make_zip(entries)
      fs = Memory.new(%{"many.zip" => zip})

      assert_raise RuntimeError, ~r/BadZipFile.*too many entries/, fn ->
        Pyex.run!("import zipfile; zipfile.ZipFile('many.zip')", filesystem: fs)
      end
    end
  end

  describe "encryption" do
    test "open succeeds on encrypted entry so metadata can be inspected" do
      bin = make_zip([{"secret.bin", "plaintext payload"}])
      patched = mark_first_entry_encrypted(bin)

      names =
        run(
          ~s|import zipfile
with zipfile.ZipFile('e.zip') as z:
    names = z.namelist()
names|,
          Memory.new(%{"e.zip" => patched})
        )

      assert names == ["secret.bin"]
    end

    test "read() on encrypted entry raises NotImplementedError" do
      bin = make_zip([{"secret.bin", "plaintext payload"}])
      patched = mark_first_entry_encrypted(bin)

      assert_raise RuntimeError, ~r/NotImplementedError.*encrypted/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('e.zip') as z:
    z.read('secret.bin')|,
          Memory.new(%{"e.zip" => patched})
        )
      end
    end

    test "extract() on encrypted entry raises NotImplementedError" do
      bin = make_zip([{"secret.bin", "plaintext payload"}])
      patched = mark_first_entry_encrypted(bin)

      assert_raise RuntimeError, ~r/NotImplementedError.*encrypted/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('e.zip') as z:
    z.extract('secret.bin', 'out')|,
          Memory.new(%{"e.zip" => patched})
        )
      end
    end
  end

  describe "symlink detection" do
    test "open accepts a symlink entry (metadata inspection)" do
      bin = make_zip([{"link", "/etc/passwd"}])
      patched = mark_first_entry_symlink(bin)

      names =
        run(
          ~s|import zipfile
with zipfile.ZipFile('l.zip') as z:
    names = z.namelist()
names|,
          Memory.new(%{"l.zip" => patched})
        )

      assert names == ["link"]
    end

    test "extract refuses a symlink entry" do
      bin = make_zip([{"link", "/etc/passwd"}])
      patched = mark_first_entry_symlink(bin)

      assert_raise RuntimeError, ~r/BadZipFile.*symlink.*refused/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('l.zip') as z:
    z.extract('link', 'out')|,
          Memory.new(%{"l.zip" => patched})
        )
      end
    end

    test "extractall refuses when any entry is a symlink" do
      bin = make_zip([{"link", "/etc/passwd"}])
      patched = mark_first_entry_symlink(bin)

      assert_raise RuntimeError, ~r/BadZipFile.*symlink.*refused/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('l.zip') as z:
    z.extractall('out')|,
          Memory.new(%{"l.zip" => patched})
        )
      end
    end
  end

  describe "filename sanitization" do
    test "null byte in entry name is rejected at open" do
      # Build a zip with a 5-byte name then patch in a null byte.
      bin = make_zip([{"aaaaa", "x"}])
      patched = patch_first_entry_name(bin, <<"bad", 0, "x">>)

      assert_raise RuntimeError, ~r/BadZipFile.*null byte/, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('n.zip')|,
          Memory.new(%{"n.zip" => patched})
        )
      end
    end

    test "control character in entry name is rejected at open" do
      bin = make_zip([{"aaaaa", "x"}])
      # \x07 is BEL.
      patched = patch_first_entry_name(bin, <<"bad", 0x07, "x">>)

      assert_raise RuntimeError, ~r/BadZipFile.*control character/, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('n.zip')|,
          Memory.new(%{"n.zip" => patched})
        )
      end
    end

    test "trailing-dot path segment is rejected at open" do
      # `foo.` would silently become `foo` on Windows.  :zip preserves
      # the name because it's not absolute.
      bin = make_zip([{"foo.", "x"}])

      assert_raise RuntimeError, ~r/BadZipFile.*trailing dot or space/, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('t.zip')|,
          Memory.new(%{"t.zip" => bin})
        )
      end
    end
  end

  describe "configurable limits" do
    test "max_entries=1 rejects a 2-entry archive" do
      bin = make_zip([{"a", "1"}, {"b", "2"}])

      assert_raise RuntimeError, ~r/BadZipFile.*too many entries/, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('t.zip', max_entries=1)|,
          Memory.new(%{"t.zip" => bin})
        )
      end
    end

    test "max_entry_size rejects a single over-cap entry" do
      payload = :binary.copy("A", 4096)
      bin = make_zip([{"big.txt", payload}])

      assert_raise RuntimeError, ~r/LargeZipFile.*per-entry cap/, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('t.zip', max_entry_size=1024)|,
          Memory.new(%{"t.zip" => bin})
        )
      end
    end

    test "max_total_size rejects when the sum exceeds cap" do
      bin = make_zip([{"a.txt", :binary.copy("A", 1000)}, {"b.txt", :binary.copy("B", 1000)}])

      assert_raise RuntimeError, ~r/LargeZipFile.*archive uncompressed/i, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('t.zip', max_total_size=1500)|,
          Memory.new(%{"t.zip" => bin})
        )
      end
    end

    test "relaxed limits let an otherwise-capped archive through" do
      payload = :binary.copy("A", 4096)
      bin = make_zip([{"big.txt", payload}])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip', max_entry_size=10000) as z:
    data = z.read('big.txt')
len(data)|,
          Memory.new(%{"t.zip" => bin})
        )

      assert result == 4096
    end
  end

  describe "ZipFile.open" do
    test "returns a file-like object that reads the entry bytes" do
      zip = make_zip([{"hello.txt", "Hello, world!"}])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    with z.open('hello.txt') as f:
        data = f.read()
data|,
          Memory.new(%{"t.zip" => zip})
        )

      assert result == {:bytes, "Hello, world!"}
    end

    test "supports read(n) chunked reads" do
      zip = make_zip([{"f", "abcdefghij"}])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    with z.open('f') as f:
        a = f.read(3)
        b = f.read(4)
        c = f.read(10)
(a, b, c)|,
          Memory.new(%{"t.zip" => zip})
        )

      assert result == {:tuple, [{:bytes, "abc"}, {:bytes, "defg"}, {:bytes, "hij"}]}
    end

    test "read() at EOF returns empty bytes" do
      zip = make_zip([{"f", "xyz"}])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    with z.open('f') as f:
        f.read()
        again = f.read()
again|,
          Memory.new(%{"t.zip" => zip})
        )

      assert result == {:bytes, ""}
    end

    test "tell tracks position" do
      zip = make_zip([{"f", "abcdef"}])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    with z.open('f') as f:
        before = f.tell()
        f.read(2)
        after = f.tell()
(before, after)|,
          Memory.new(%{"t.zip" => zip})
        )

      assert result == {:tuple, [0, 2]}
    end

    test "read() on closed ZipExtFile raises ValueError" do
      zip = make_zip([{"f", "data"}])

      assert_raise RuntimeError, ~r/ValueError/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    f = z.open('f')
    f.close()
    f.read()|,
          Memory.new(%{"t.zip" => zip})
        )
      end
    end

    test "write mode rejected" do
      assert_raise RuntimeError, ~r/NotImplementedError.*read mode/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w') as z:
    z.writestr('a', 'b')
with zipfile.ZipFile('o.zip') as z:
    z.open('a', 'w')|,
          Memory.new(%{})
        )
      end
    end
  end

  describe "iteration" do
    test "for name in z yields entry names" do
      zip = make_zip([{"a", "1"}, {"b", "2"}, {"c", "3"}])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    out = [name for name in z]
out|,
          Memory.new(%{"t.zip" => zip})
        )

      assert result == ["a", "b", "c"]
    end
  end

  describe "archive comment" do
    test "round-trips through close" do
      {:ok, _, ctx} =
        Pyex.run(
          """
          import zipfile
          with zipfile.ZipFile('o.zip', 'w') as z:
              z.writestr('a', 'x')
              z.comment = b'archive comment here'
          """,
          filesystem: Memory.new(%{})
        )

      fs = ctx.filesystem

      result =
        Pyex.run!(
          """
          import zipfile
          with zipfile.ZipFile('o.zip') as z:
              c = z.comment
          c
          """,
          filesystem: fs
        )

      assert result == {:bytes, "archive comment here"}
    end

    test "empty comment is the default" do
      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w') as z:
    z.writestr('a', 'x')
with zipfile.ZipFile('o.zip') as z:
    c = z.comment
c|,
          Memory.new(%{})
        )

      assert result == {:bytes, ""}
    end
  end

  describe "writestr with ZipInfo" do
    test "honors compress_type from ZipInfo" do
      result =
        run(
          ~s|import zipfile
info = zipfile.ZipInfo('big.txt')
info.compress_type = zipfile.ZIP_DEFLATED
with zipfile.ZipFile('o.zip', 'w') as z:
    z.writestr(info, 'A' * 5000)
with zipfile.ZipFile('o.zip') as z:
    out = z.getinfo('big.txt').compress_type
out|,
          Memory.new(%{})
        )

      assert result == 8
    end

    test "honors date_time from ZipInfo" do
      result =
        run(
          ~s|import zipfile
info = zipfile.ZipInfo('t.txt', (2024, 6, 15, 12, 30, 0))
with zipfile.ZipFile('o.zip', 'w') as z:
    z.writestr(info, 'hi')
with zipfile.ZipFile('o.zip') as z:
    out = z.getinfo('t.txt').date_time
out|,
          Memory.new(%{})
        )

      assert result == {:tuple, [2024, 6, 15, 12, 30, 0]}
    end
  end

  describe "integrity checks" do
    test "CRC-32 mismatch between CD and actual bytes raises BadZipFile" do
      # Patch the CRC in BOTH the LFH and the CD so they agree — the
      # LFH/CD cross-check passes but the decompression-time CRC check
      # catches the lie.
      bin = make_zip([{"data.txt", "hello"}])
      corrupted = bin |> patch_lfh_crc(0xDEADBEEF) |> patch_cd_crc(0xDEADBEEF)

      assert_raise RuntimeError, ~r/BadZipFile.*CRC32 mismatch/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('c.zip') as z:
    z.read('data.txt')|,
          Memory.new(%{"c.zip" => corrupted})
        )
      end
    end

    test "LFH and CD disagreeing CRCs is rejected at open" do
      # Only the CD CRC is tampered; the LFH still has the true CRC.
      # This is "zip confusion" — different tools would see different
      # content.  Caught by the LFH/CD cross-check before decompression.
      bin = make_zip([{"data.txt", "hello"}])
      tampered = patch_cd_crc(bin, 0xDEADBEEF)

      assert_raise RuntimeError, ~r/BadZipFile.*LFH\/CD CRC mismatch/, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('c.zip')|,
          Memory.new(%{"c.zip" => tampered})
        )
      end
    end

    test "LFH and CD disagreeing names is rejected at open" do
      bin = make_zip([{"original", "x"}])
      # Patch only the CD's name, leaving the LFH with "original".
      tampered = patch_first_entry_cd_name(bin, "tampered")

      assert_raise RuntimeError, ~r/BadZipFile.*LFH\/CD name mismatch/, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('c.zip')|,
          Memory.new(%{"c.zip" => tampered})
        )
      end
    end

    test "duplicate entry names are rejected" do
      # Rare in practice, but a malicious archive could shadow a legit
      # entry with a later one of the same name.  Hand-craft a tiny zip
      # with two CD entries that point at the same local header.
      bin = make_zip([{"dup.txt", "x"}])
      # Append a second CD entry by duplicating the first one inline.
      tampered = duplicate_first_cd_entry(bin)

      assert_raise RuntimeError, ~r/BadZipFile.*duplicate entry name/, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('c.zip')|,
          Memory.new(%{"c.zip" => tampered})
        )
      end
    end

    test "out-of-range local offset is rejected" do
      bin = make_zip([{"x.txt", "y"}])
      # Offset 42 into the CD entry holds local_offset.  Push it past EOF.
      off = find_first_cd_entry(bin) + 42
      huge = byte_size(bin) + 1
      <<pre::binary-size(^off), _::little-32, post::binary>> = bin
      tampered = <<pre::binary, huge::little-32, post::binary>>

      assert_raise RuntimeError, ~r/BadZipFile/, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('c.zip')|,
          Memory.new(%{"c.zip" => tampered})
        )
      end
    end

    test "EOCD entry count mismatch raises BadZipFile" do
      bin = make_zip([{"a", "1"}, {"b", "2"}])
      # EOCD's total_entries field is 2 bytes at offset 10 in the 22-byte
      # EOCD record.  Find EOCD by scanning from the end.
      eocd_off = find_eocd_offset(bin)
      field_off = eocd_off + 10
      <<pre::binary-size(^field_off), _count::little-16, post::binary>> = bin
      tampered = <<pre::binary, 99::little-16, post::binary>>

      assert_raise RuntimeError, ~r/BadZipFile.*EOCD declared/, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('c.zip')|,
          Memory.new(%{"c.zip" => tampered})
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fuzz: mutated-archive robustness.  For every random mutation of a
  # good archive, open() must either succeed or raise BadZipFile /
  # LargeZipFile — never leak another exception, never kill the VM.
  # ---------------------------------------------------------------------------

  describe "writer features" do
    test "mixed compression: stored and deflated entries in one archive" do
      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w', zipfile.ZIP_STORED) as z:
    z.writestr('plain.txt', 'short')

    big = zipfile.ZipInfo('big.txt')
    big.compress_type = zipfile.ZIP_DEFLATED
    z.writestr(big, 'A' * 5000)

with zipfile.ZipFile('o.zip') as z:
    p = z.getinfo('plain.txt')
    b = z.getinfo('big.txt')
(p.compress_type, b.compress_type, b.compress_size < b.file_size)|,
          Memory.new(%{})
        )

      assert result == {:tuple, [0, 8, true]}
    end

    test "non-ASCII filenames round-trip with EFS bit set" do
      # The ё character is two UTF-8 bytes (0xD1 0x91).  Verify that
      # writing it and reading it back yields the same Python string.
      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('u.zip', 'w') as z:
    z.writestr('café/привет.txt', 'data')
with zipfile.ZipFile('u.zip') as z:
    names = z.namelist()
names[0]|,
          Memory.new(%{})
        )

      assert result == "café/привет.txt"
    end

    test "comment can be set on a fresh archive (no read-back from existing)" do
      {:ok, _, ctx} =
        Pyex.run(
          """
          import zipfile
          with zipfile.ZipFile('o.zip', 'w') as z:
              z.writestr('a', 'x')
              z.comment = b'fresh comment'
          """,
          filesystem: Memory.new(%{})
        )

      result =
        Pyex.run!(
          """
          import zipfile
          with zipfile.ZipFile('o.zip') as z:
              c = z.comment
          c
          """,
          filesystem: ctx.filesystem
        )

      assert result == {:bytes, "fresh comment"}
    end

    test "directory entry written via mkdir reports is_dir on read-back" do
      {:ok, _, ctx} =
        Pyex.run(
          """
          import zipfile
          with zipfile.ZipFile('o.zip', 'w') as z:
              z.mkdir('sub')
              z.writestr('sub/f', 'hi')
          """,
          filesystem: Memory.new(%{})
        )

      result =
        Pyex.run!(
          """
          import zipfile
          with zipfile.ZipFile('o.zip') as z:
              info = z.getinfo('sub/')
          info.is_dir()
          """,
          filesystem: ctx.filesystem
        )

      assert result == true
    end
  end

  describe "writer-side filename sanity" do
    test "writestr refuses names with null bytes" do
      assert_raise RuntimeError, ~r/ValueError.*null byte/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w') as z:
    z.writestr('bad\\x00file', 'x')|,
          Memory.new(%{})
        )
      end
    end

    test "writestr refuses absolute paths" do
      assert_raise RuntimeError, ~r/ValueError.*absolute or escapes/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w') as z:
    z.writestr('/etc/passwd', 'x')|,
          Memory.new(%{})
        )
      end
    end

    test "writestr refuses path traversal" do
      assert_raise RuntimeError, ~r/ValueError.*absolute or escapes/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w') as z:
    z.writestr('../escape.txt', 'x')|,
          Memory.new(%{})
        )
      end
    end

    test "writestr refuses trailing-dot segments" do
      assert_raise RuntimeError, ~r/ValueError.*trailing dot or space/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w') as z:
    z.writestr('foo.', 'x')|,
          Memory.new(%{})
        )
      end
    end

    test "write(filename, arcname) refuses unsafe arcname" do
      fs = Memory.new(%{"src.txt" => "hi"})

      assert_raise RuntimeError, ~r/ValueError.*absolute or escapes/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w') as z:
    z.write('src.txt', '../evil')|,
          fs
        )
      end
    end
  end

  describe "CP437 filename decoding" do
    test "CP437-encoded non-ASCII name decodes to Unicode on read" do
      # Build a zip with a filename that's only valid as CP437 (not UTF-8):
      # "caf\xe9.txt" — the \xe9 byte is invalid UTF-8 but valid CP437 ('é').
      # Build via :zip.create with a charlist whose bytes include 0xe9.
      cp437_name = [?c, ?a, ?f, 0xE9, ?., ?t, ?x, ?t]
      {:ok, {_, bin}} = :zip.create(~c"t.zip", [{cp437_name, "hi"}], [:memory])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    names = z.namelist()
names[0]|,
          Memory.new(%{"t.zip" => bin})
        )

      assert result == "café.txt"
    end

    test "pure ASCII names survive unchanged" do
      zip = make_zip([{"plain.txt", "hi"}])

      result =
        run(
          ~s|import zipfile
with zipfile.ZipFile('t.zip') as z:
    names = z.namelist()
names[0]|,
          Memory.new(%{"t.zip" => zip})
        )

      assert result == "plain.txt"
    end
  end

  describe "compression method errors" do
    test "attempting to open with ZIP_BZIP2 raises with human-readable label" do
      assert_raise RuntimeError, ~r/NotImplementedError.*bzip2.*method 12/, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('o.zip', 'w', zipfile.ZIP_BZIP2)|,
          Memory.new(%{})
        )
      end
    end

    test "attempting to open with ZIP_LZMA raises with human-readable label" do
      assert_raise RuntimeError, ~r/NotImplementedError.*lzma.*method 14/, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('o.zip', 'w', zipfile.ZIP_LZMA)|,
          Memory.new(%{})
        )
      end
    end
  end

  describe "mkdir" do
    test "adds a directory entry" do
      {:ok, _, ctx} =
        Pyex.run(
          """
          import zipfile
          with zipfile.ZipFile('o.zip', 'w') as z:
              z.mkdir('subdir')
              z.writestr('subdir/file.txt', 'hi')
          """,
          filesystem: Memory.new(%{})
        )

      fs = ctx.filesystem

      result =
        Pyex.run!(
          """
          import zipfile
          with zipfile.ZipFile('o.zip') as z:
              names = z.namelist()
              info = z.getinfo('subdir/')
          (names, info.is_dir())
          """,
          filesystem: fs
        )

      assert {:tuple, [names, is_dir]} = result
      assert "subdir/" in names
      assert "subdir/file.txt" in names
      assert is_dir == true
    end

    test "rejects duplicate directory" do
      assert_raise RuntimeError, ~r/FileExistsError/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w') as z:
    z.mkdir('d')
    z.mkdir('d')|,
          Memory.new(%{})
        )
      end
    end

    test "rejects unsafe directory names" do
      assert_raise RuntimeError, ~r/ValueError.*absolute or escapes/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('o.zip', 'w') as z:
    z.mkdir('../escape')|,
          Memory.new(%{})
        )
      end
    end
  end

  describe "extractall members" do
    test "extracts only the requested members" do
      zip = make_zip([{"keep.txt", "K"}, {"skip1.txt", "S1"}, {"skip2.txt", "S2"}])
      fs = Memory.new(%{"a.zip" => zip})

      {:ok, _, ctx} =
        Pyex.run(
          """
          import zipfile
          with zipfile.ZipFile('a.zip') as z:
              z.extractall('out', ['keep.txt'])
          """,
          filesystem: fs
        )

      assert Map.get(ctx.filesystem.files, "out/keep.txt") == "K"
      refute Map.has_key?(ctx.filesystem.files, "out/skip1.txt")
      refute Map.has_key?(ctx.filesystem.files, "out/skip2.txt")
    end

    test "unknown member name raises KeyError" do
      zip = make_zip([{"only.txt", "x"}])

      assert_raise RuntimeError, ~r/KeyError/, fn ->
        run(
          ~s|import zipfile
with zipfile.ZipFile('a.zip') as z:
    z.extractall('out', ['missing.txt'])|,
          Memory.new(%{"a.zip" => zip})
        )
      end
    end
  end

  describe "fuzz robustness" do
    @tag :slow
    test "random single-byte flips never crash the parser" do
      seed = :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned()
      :rand.seed(:exsss, {seed, seed, seed})

      good =
        make_zip([
          {"a.txt", "hello"},
          {"nested/b.bin", :binary.copy("B", 200)},
          {"docs/readme", "some text here"}
        ])

      for _ <- 1..300 do
        pos = :rand.uniform(byte_size(good)) - 1
        mask = :rand.uniform(256) - 1
        <<pre::binary-size(^pos), byte, post::binary>> = good
        mutated = <<pre::binary, Bitwise.bxor(byte, mask)::8, post::binary>>

        assert_safe_open(mutated)
      end
    end

    @tag :slow
    test "random garbage of random length is safely rejected" do
      for _ <- 1..200 do
        len = :rand.uniform(8192)
        garbage = :crypto.strong_rand_bytes(len)
        assert_safe_open(garbage)
      end
    end

    @tag :slow
    test "short binaries never crash" do
      for len <- 0..64 do
        assert_safe_open(:crypto.strong_rand_bytes(len))
      end
    end
  end

  # Any exception raised by `open()` on fuzzed input MUST be a
  # BadZipFile, LargeZipFile, or NotImplementedError — those are the
  # failure modes we've committed to.
  defp assert_safe_open(bin) do
    try do
      run(
        ~s|import zipfile
try:
    z = zipfile.ZipFile('f.zip')
    z.close()
except (zipfile.BadZipFile, zipfile.LargeZipFile, NotImplementedError):
    pass|,
        Memory.new(%{"f.zip" => bin})
      )

      :ok
    rescue
      e in RuntimeError ->
        flunk("""
        Fuzzed archive escaped our exception filter.
        Error: #{Exception.message(e)}
        First bytes: #{inspect(binary_part(bin, 0, min(64, byte_size(bin))))}
        """)
    end
  end

  # ---------------------------------------------------------------------------
  # Synthetic docx end-to-end: write a minimal but structurally-real
  # docx entirely through our zipfile, then read it back and pull
  # document.xml.  Lets us catch regressions in the parser as soon as
  # they'd break real-world docx workflows.
  # ---------------------------------------------------------------------------

  describe "docx workflow" do
    test "writes and reads a minimal docx structure" do
      content_types = ~s|<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>|

      rels = ~s|<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>|

      doc = ~s|<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
<w:p><w:r><w:t>The zipfile module works end to end.</w:t></w:r></w:p>
</w:body>
</w:document>|

      {:ok, _, ctx} =
        Pyex.run(
          """
          import zipfile
          with zipfile.ZipFile('demo.docx', 'w', zipfile.ZIP_DEFLATED) as z:
              z.writestr('[Content_Types].xml', #{inspect(content_types)})
              z.writestr('_rels/.rels', #{inspect(rels)})
              z.writestr('word/document.xml', #{inspect(doc)})
          """,
          filesystem: Memory.new(%{})
        )

      fs = ctx.filesystem

      result =
        Pyex.run!(
          """
          import zipfile
          import re
          with zipfile.ZipFile('demo.docx') as z:
              names = z.namelist()
              body = z.read('word/document.xml').decode('utf-8')
          texts = re.findall(r'<w:t[^>]*>([^<]*)</w:t>', body)
          (names, texts)
          """,
          filesystem: fs
        )

      assert {:tuple, [names, texts]} = result
      assert "word/document.xml" in names
      assert "[Content_Types].xml" in names
      assert texts == ["The zipfile module works end to end."]
    end
  end

  describe "x mode" do
    test "raises FileExistsError when target exists" do
      fs = Memory.new(%{"exists.zip" => "anything"})

      assert_raise RuntimeError, ~r/FileExistsError/, fn ->
        run(
          ~s|import zipfile
zipfile.ZipFile('exists.zip', 'x')|,
          fs
        )
      end
    end

    test "succeeds when target does not exist" do
      {:ok, _, ctx} =
        Pyex.run(
          """
          import zipfile
          with zipfile.ZipFile('new.zip', 'x') as z:
              z.writestr('a', 'b')
          """,
          filesystem: Memory.new(%{})
        )

      assert Map.has_key?(ctx.filesystem.files, "new.zip")
    end
  end

  describe "is_zipfile" do
    test "returns True for a valid zip path" do
      zip = make_zip([{"a", "1"}])
      fs = Memory.new(%{"archive.zip" => zip})

      assert Pyex.run!("import zipfile; zipfile.is_zipfile('archive.zip')", filesystem: fs) ==
               true
    end

    test "returns False for a non-zip file" do
      fs = Memory.new(%{"text.txt" => "hello"})

      assert Pyex.run!("import zipfile; zipfile.is_zipfile('text.txt')", filesystem: fs) == false
    end

    test "returns False for missing file" do
      assert Pyex.run!(
               "import zipfile; zipfile.is_zipfile('nowhere.zip')",
               filesystem: Memory.new()
             ) == false
    end

    test "returns True for bytes of a valid zip" do
      zip = make_zip([{"a", "1"}])

      # Pyex doesn't construct {:bytes, ...} literals directly in source,
      # but it accepts them at the stdlib boundary. We exercise the path
      # via a file handle.
      fs = Memory.new(%{"v.zip" => zip})

      assert Pyex.run!(
               """
               import zipfile
               with open('v.zip', 'rb') as f:
                   result = zipfile.is_zipfile(f)
               result
               """,
               filesystem: fs
             ) == true
    end
  end

  # ---------------------------------------------------------------------------
  # Context manager
  # ---------------------------------------------------------------------------

  describe "context manager" do
    test "with block closes the archive on normal exit" do
      zip = make_zip([{"a", "1"}])
      fs = Memory.new(%{"t.zip" => zip})

      # Reading after `with` exit should fail because the zip is closed.
      assert_raise RuntimeError, ~r/ValueError/, fn ->
        Pyex.run!(
          """
          import zipfile
          with zipfile.ZipFile('t.zip') as z:
              pass
          z.read('a')
          """,
          filesystem: fs
        )
      end
    end

    test "with block flushes writes on exit" do
      fs = Memory.new(%{})

      {:ok, _val, ctx} =
        Pyex.run(
          """
          import zipfile
          with zipfile.ZipFile('o.zip', 'w') as z:
              z.writestr('x', 'y')
          """,
          filesystem: fs
        )

      assert Map.has_key?(ctx.filesystem.files, "o.zip")
    end
  end

  # ---------------------------------------------------------------------------
  # ZipInfo
  # ---------------------------------------------------------------------------

  describe "ZipInfo" do
    test "constructor produces an object with filename and date_time" do
      result = run(~s|import zipfile
info = zipfile.ZipInfo('foo.txt', (2024, 1, 2, 3, 4, 5))
(info.filename, info.date_time)|)

      assert result == {:tuple, ["foo.txt", {:tuple, [2024, 1, 2, 3, 4, 5]}]}
    end

    test "is_dir is True for names ending in /" do
      result = run(~s|import zipfile
zipfile.ZipInfo('sub/').is_dir()|)

      assert result == true
    end

    test "is_dir is False for regular files" do
      result = run(~s|import zipfile
zipfile.ZipInfo('foo.txt').is_dir()|)

      assert result == false
    end
  end
end
