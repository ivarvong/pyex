defmodule Pyex.Stdlib.Zipfile do
  @moduledoc """
  Python `zipfile` module.

  Reads and writes ZIP archives via `zipfile.ZipFile`.  Central-directory
  parsing is done natively (so we can see encryption flags and Unix mode
  bits that `:zip` hides); decompression is delegated to Erlang's `:zip`
  module on demand.

  ## Supported surface

  - `ZipFile(file, mode="r")` — accepts str path, `bytes`, or file handle
  - `ZipFile(file, mode="w" | "x")` — writes to path or file handle on close
  - `namelist()`, `infolist()`, `getinfo(name)`, `read(name)`
  - `write(filename, arcname=None)`, `writestr(name, data)`
  - `extract(member, path)`, `extractall(path)`
  - `close()`, context manager (`with ... as z:`)
  - `is_zipfile(file)`
  - `ZipInfo` with `filename`, `file_size`, `compress_size`, `date_time`,
    `compress_type`, `CRC`, `is_dir()`
  - Exceptions: `BadZipFile`, `LargeZipFile`
  - Compression: `ZIP_STORED`, `ZIP_DEFLATED`

  ## Safety model for untrusted archives

  Every archive opened for reading goes through a preflight pass that
  inspects the central directory **without decompressing any data**.
  The preflight enforces:

  - `max_entries` (default 10 000) — entry count cap
  - `max_total_size` (default 512 MiB) — sum of declared uncompressed sizes
  - `max_entry_size` (default 64 MiB) — single-entry uncompressed cap
  - `max_ratio` (default 1024×) — per-entry compression-ratio cap
    (skipped for entries with compressed size < 1 KiB to avoid false
    positives on tiny files)
  - Filename sanity (at parse time): reject null bytes, control
    characters (0x01–0x1F), trailing spaces or dots on path components,
    empty intermediate components, names longer than 4 096 bytes

  Path-traversal patterns (`../`, absolute paths, Windows drive letters)
  pass the parse-time gate so callers can inspect a suspicious archive's
  `namelist()`, but `extract()` / `extractall()` refuse to materialize
  any entry whose name would escape the destination directory.

  Encrypted entries are detected via the general-purpose bit flag and
  surfaced when the caller attempts to `read()` or `extract()` them
  (not on open) so metadata can still be inspected.

  Symlink entries are detected via the `external_attr` Unix-mode bits
  (`S_IFLNK`); `extract()` / `extractall()` refuse to materialize them.

  All of `max_entries`, `max_total_size`, `max_entry_size`, and
  `max_ratio` are overridable per `ZipFile()` call as keyword arguments.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Ctx
  alias Pyex.Interpreter

  # Compression method codes
  @zip_stored 0
  @zip_deflated 8

  # ZIP signatures
  @cd_entry_sig <<0x50, 0x4B, 0x01, 0x02>>
  @eocd_sig <<0x50, 0x4B, 0x05, 0x06>>
  @zip64_eocd_locator_sig <<0x50, 0x4B, 0x06, 0x07>>

  # Unix file type bits (high nibble of stat mode)
  @s_ifmt 0o170000
  @s_iflnk 0o120000

  # General-purpose bit flag
  @gp_encrypted 0x0001

  # Default safety limits (staff-tunable via kwargs)
  @default_max_entries 10_000
  @default_max_total_size 512 * 1024 * 1024
  @default_max_entry_size 64 * 1024 * 1024
  @default_max_ratio 1024
  @min_compressed_for_ratio_check 1024
  @max_filename_length 4096

  @doc """
  Returns the module value for `import zipfile`.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "ZipFile" => {:builtin_kw, &zipfile_constructor/2},
      "ZipInfo" => {:builtin_kw, &zipinfo_constructor/2},
      "is_zipfile" => {:builtin, &is_zipfile/1},
      "BadZipFile" => {:exception_class, "BadZipFile"},
      "BadZipfile" => {:exception_class, "BadZipFile"},
      "LargeZipFile" => {:exception_class, "LargeZipFile"},
      "ZIP_STORED" => @zip_stored,
      "ZIP_DEFLATED" => @zip_deflated,
      "ZIP_BZIP2" => 12,
      "ZIP_LZMA" => 14
    }
  end

  @doc "Default safety limit values — exposed for docs and tuning."
  def defaults do
    %{
      max_entries: @default_max_entries,
      max_total_size: @default_max_total_size,
      max_entry_size: @default_max_entry_size,
      max_ratio: @default_max_ratio
    }
  end

  # ==========================================================================
  # Constructor
  # ==========================================================================

  @spec zipfile_constructor([Interpreter.pyvalue()], %{optional(String.t()) => term()}) ::
          Interpreter.pyvalue()
  defp zipfile_constructor(args, kwargs) do
    with {:ok, file, mode, compression} <- parse_constructor_args(args, kwargs),
         {:ok, limits} <- parse_limits(kwargs) do
      open_zipfile(file, mode, compression, limits)
    else
      {:exception, _} = err -> err
    end
  end

  defp parse_constructor_args(args, kwargs) do
    file = Enum.at(args, 0) || Map.get(kwargs, "file")

    mode =
      case Enum.at(args, 1) || Map.get(kwargs, "mode", "r") do
        m when is_binary(m) -> m
        _ -> "r"
      end

    compression =
      case Enum.at(args, 2) || Map.get(kwargs, "compression", @zip_stored) do
        m when is_integer(m) -> m
        _ -> @zip_stored
      end

    cond do
      is_nil(file) ->
        {:exception, "TypeError: ZipFile() missing required argument: 'file'"}

      mode not in ["r", "w", "a", "x"] ->
        {:exception, "ValueError: ZipFile requires mode 'r', 'w', 'x', or 'a'"}

      compression not in [@zip_stored, @zip_deflated] ->
        {:exception,
         "NotImplementedError: #{compression_method_label(compression)} — Pyex supports ZIP_STORED and ZIP_DEFLATED only"}

      true ->
        {:ok, file, mode, compression}
    end
  end

  defp parse_limits(kwargs) do
    limits = %{
      max_entries: int_kwarg(kwargs, "max_entries", @default_max_entries),
      max_total_size: int_kwarg(kwargs, "max_total_size", @default_max_total_size),
      max_entry_size: int_kwarg(kwargs, "max_entry_size", @default_max_entry_size),
      max_ratio: int_kwarg(kwargs, "max_ratio", @default_max_ratio)
    }

    cond do
      not is_integer(limits.max_entries) or limits.max_entries < 1 ->
        {:exception, "ValueError: max_entries must be a positive integer"}

      not is_integer(limits.max_total_size) or limits.max_total_size < 0 ->
        {:exception, "ValueError: max_total_size must be a non-negative integer"}

      not is_integer(limits.max_entry_size) or limits.max_entry_size < 0 ->
        {:exception, "ValueError: max_entry_size must be a non-negative integer"}

      not is_integer(limits.max_ratio) or limits.max_ratio < 1 ->
        {:exception, "ValueError: max_ratio must be a positive integer"}

      true ->
        {:ok, limits}
    end
  end

  defp int_kwarg(kwargs, key, default) do
    case Map.get(kwargs, key) do
      nil -> default
      val -> val
    end
  end

  # Human-readable labels for ZIP compression method codes so callers
  # get a meaningful error rather than "compression type 14".
  defp compression_method_label(@zip_stored), do: "ZIP_STORED"
  defp compression_method_label(@zip_deflated), do: "ZIP_DEFLATED"
  defp compression_method_label(6), do: "implode (method 6) not supported"
  defp compression_method_label(9), do: "deflate64 (method 9) not supported"
  defp compression_method_label(12), do: "bzip2 (method 12) not supported"
  defp compression_method_label(14), do: "lzma (method 14) not supported"
  defp compression_method_label(93), do: "zstd (method 93) not supported"
  defp compression_method_label(95), do: "xz (method 95) not supported"
  defp compression_method_label(98), do: "ppmd (method 98) not supported"
  defp compression_method_label(n), do: "compression method #{n} not supported"

  # ==========================================================================
  # Open / close dispatch
  # ==========================================================================

  defp open_zipfile(file, "r", compression, limits) do
    {:ctx_call,
     fn env, ctx ->
       case load_source_bytes(file, env, ctx) do
         {:ok, binary, source, env, ctx} ->
           case parse_archive(binary, limits) do
             {:ok, entries, comment} ->
               state = %{
                 mode: :r,
                 filename: source.filename,
                 source_kind: source.kind,
                 write_back_path: nil,
                 write_back_handle: nil,
                 raw: binary,
                 entries: entries,
                 entry_index: index_entries(entries),
                 default_method: compression,
                 comment: comment,
                 closed: false,
                 limits: limits
               }

               build_instance(state, env, ctx)

             {:exception, _} = exc ->
               {exc, env, ctx}
           end

         {{:exception, _} = exc, env, ctx} ->
           {exc, env, ctx}
       end
     end}
  end

  defp open_zipfile(file, mode, compression, limits) when mode in ["w", "x"] do
    {:ctx_call,
     fn env, ctx ->
       case resolve_write_target(file, mode, ctx) do
         {:ok, target, ctx} ->
           state = %{
             mode: :w,
             filename: target.filename,
             source_kind: target.kind,
             write_back_path: target.path,
             write_back_handle: target.handle,
             raw: <<>>,
             entries: [],
             entry_index: %{},
             default_method: compression,
             comment: <<>>,
             closed: false,
             limits: limits
           }

           build_instance(state, env, ctx)

         {:exception, msg} ->
           {{:exception, msg}, env, ctx}
       end
     end}
  end

  defp open_zipfile(_file, "a", _compression, _limits) do
    {:exception, "NotImplementedError: ZipFile mode 'a' not supported"}
  end

  # ==========================================================================
  # Source loading (read mode): filesystem path or file_handle or bytes
  # ==========================================================================

  defp load_source_bytes({:bytes, binary}, env, ctx),
    do: {:ok, binary, %{kind: :bytes, filename: nil}, env, ctx}

  defp load_source_bytes({:bytearray, binary}, env, ctx),
    do: {:ok, binary, %{kind: :bytes, filename: nil}, env, ctx}

  defp load_source_bytes({:file_handle, id}, env, ctx) do
    case Ctx.read_handle(ctx, id) do
      {:ok, content, ctx} -> {:ok, content, %{kind: :handle, filename: nil}, env, ctx}
      {:error, msg} -> {{:exception, msg}, env, ctx}
    end
  end

  defp load_source_bytes(path, env, ctx) when is_binary(path) do
    case Ctx.open_handle(ctx, path, :read) do
      {:ok, id, ctx} ->
        case Ctx.read_handle(ctx, id) do
          {:ok, content, ctx} ->
            {:ok, ctx} = Ctx.close_handle(ctx, id)
            {:ok, content, %{kind: :path, filename: path}, env, ctx}

          {:error, msg} ->
            {:ok, ctx} = Ctx.close_handle(ctx, id)
            {{:exception, msg}, env, ctx}
        end

      {:error, msg} ->
        {{:exception, msg}, env, ctx}
    end
  end

  defp load_source_bytes(_other, env, ctx) do
    {{:exception, "TypeError: ZipFile file must be a path string, bytes, or file handle"}, env,
     ctx}
  end

  # ==========================================================================
  # Write target resolution
  # ==========================================================================

  defp resolve_write_target(path, "x", ctx) when is_binary(path) do
    %{filesystem: fs} = ctx

    if fs && fs.__struct__.exists?(fs, path) do
      {:exception, "FileExistsError: [Errno 17] File exists: '#{path}'"}
    else
      {:ok, %{kind: :path, filename: path, path: path, handle: nil}, ctx}
    end
  end

  defp resolve_write_target(path, _mode, ctx) when is_binary(path) do
    {:ok, %{kind: :path, filename: path, path: path, handle: nil}, ctx}
  end

  defp resolve_write_target({:file_handle, id}, _mode, ctx) do
    {:ok, %{kind: :handle, filename: nil, path: nil, handle: id}, ctx}
  end

  defp resolve_write_target(_other, _mode, _ctx) do
    {:exception, "TypeError: ZipFile file must be a path string or file handle"}
  end

  # ==========================================================================
  # Archive parsing (preflight + central directory)
  # ==========================================================================

  defp parse_archive(<<>>, _limits), do: {:exception, "BadZipFile: File is not a zip file"}

  defp parse_archive(bin, _limits) when byte_size(bin) < 22,
    do: {:exception, "BadZipFile: File is not a zip file"}

  defp parse_archive(bin, limits) do
    with :ok <- reject_zip64(bin),
         {:ok, eocd_offset} <- find_eocd(bin),
         {:ok, eocd} <- parse_eocd(bin, eocd_offset),
         {:ok, cd_entries} <- parse_cd(bin, eocd.cd_offset, eocd.cd_size),
         :ok <- check_eocd_count(eocd, cd_entries),
         :ok <- check_local_offsets(cd_entries, eocd.cd_offset),
         :ok <- check_duplicate_names(cd_entries),
         :ok <- check_local_headers(bin, cd_entries),
         {:ok, table} <- safe_zip_table(bin),
         {:ok, entries} <- merge_and_validate(cd_entries, table, limits) do
      comment = read_comment(bin, eocd_offset, eocd.comment_len)
      {:ok, entries, comment}
    end
  end

  # The EOCD advertises the total number of entries; compare it against
  # the number we actually parsed from the central directory.  A mismatch
  # is a strong signal of tampering or truncation.
  defp check_eocd_count(eocd, cd_entries) do
    if eocd.total_entries == length(cd_entries) do
      :ok
    else
      {:exception,
       "BadZipFile: EOCD declared #{eocd.total_entries} entries but central directory contains #{length(cd_entries)}"}
    end
  end

  # Each CD entry points at a local file header; the LFH must live before
  # the CD starts and leave room for its fixed 30-byte preamble.
  defp check_local_offsets(cd_entries, cd_offset) do
    Enum.reduce_while(cd_entries, :ok, fn cd, :ok ->
      cond do
        cd.local_offset < 0 ->
          {:halt,
           {:exception,
            "BadZipFile: entry '#{printable(cd.name)}' has a negative local header offset"}}

        cd.local_offset + 30 > cd_offset ->
          {:halt,
           {:exception,
            "BadZipFile: entry '#{printable(cd.name)}' local header offset #{cd.local_offset} overlaps or follows the central directory"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  # Two CD entries with the same name make later lookups ambiguous; one
  # would silently shadow the other.  Refuse to open such archives.
  defp check_duplicate_names(cd_entries) do
    {_seen, dup} =
      Enum.reduce_while(cd_entries, {MapSet.new(), nil}, fn cd, {seen, _} ->
        if MapSet.member?(seen, cd.name) do
          {:halt, {seen, cd.name}}
        else
          {:cont, {MapSet.put(seen, cd.name), nil}}
        end
      end)

    case dup do
      nil -> :ok
      name -> {:exception, "BadZipFile: duplicate entry name '#{printable(name)}'"}
    end
  end

  # Cross-check each central-directory entry against its local file
  # header.  Catches "zip confusion" attacks where the two headers
  # disagree and different tools pick different files.
  defp check_local_headers(bin, cd_entries) do
    Enum.reduce_while(cd_entries, :ok, fn cd, :ok ->
      result =
        case parse_lfh(bin, cd.local_offset) do
          {:ok, lfh} -> compare_lfh(cd, lfh)
          {:exception, _} = exc -> exc
        end

      case result do
        :ok -> {:cont, :ok}
        {:exception, _} = exc -> {:halt, exc}
      end
    end)
  end

  # Parse only the fields of the LFH we need for the CD comparison.
  # LFH layout (30 bytes fixed): sig(4) ver(2) gp(2) method(2) mtime(2)
  # mdate(2) crc(4) csize(4) usize(4) name_len(2) extra_len(2) name(name_len).
  defp parse_lfh(bin, offset) do
    if offset + 30 > byte_size(bin) do
      {:exception, "BadZipFile: local header past end of archive at offset #{offset}"}
    else
      <<sig::binary-size(4), _ver::little-16, gp_flag::little-16, method::little-16,
        _mtime::little-16, _mdate::little-16, crc::little-32, csize::little-32, usize::little-32,
        name_len::little-16, _extra_len::little-16>> = binary_part(bin, offset, 30)

      cond do
        sig != <<0x50, 0x4B, 0x03, 0x04>> ->
          {:exception, "BadZipFile: bad local header signature at offset #{offset}"}

        offset + 30 + name_len > byte_size(bin) ->
          {:exception, "BadZipFile: local header name runs past end of archive"}

        true ->
          name = binary_part(bin, offset + 30, name_len)

          {:ok,
           %{
             name: name,
             gp_flag: gp_flag,
             method: method,
             crc: crc,
             compressed_size: csize,
             uncompressed_size: usize
           }}
      end
    end
  end

  # When GP bit 3 is set, csize/usize/crc live in a data descriptor
  # after the compressed data, not in the LFH — all three are zero in
  # the LFH itself.  We skip the numeric comparisons for those entries
  # but still require name and method to match.
  defp compare_lfh(cd, lfh) do
    streaming? = Bitwise.band(cd.gp_flag, 0x0008) != 0

    cond do
      cd.name != lfh.name ->
        {:exception,
         "BadZipFile: LFH/CD name mismatch ('#{printable(lfh.name)}' vs '#{printable(cd.name)}')"}

      cd.method != lfh.method ->
        {:exception,
         "BadZipFile: LFH/CD method mismatch for entry '#{printable(cd.name)}' (LFH #{lfh.method} vs CD #{cd.method})"}

      not streaming? and lfh.crc != cd.crc ->
        {:exception, "BadZipFile: LFH/CD CRC mismatch for entry '#{printable(cd.name)}'"}

      not streaming? and lfh.compressed_size != cd.compressed_size ->
        {:exception,
         "BadZipFile: LFH/CD compressed size mismatch for entry '#{printable(cd.name)}'"}

      not streaming? and lfh.uncompressed_size != cd.uncompressed_size ->
        {:exception,
         "BadZipFile: LFH/CD uncompressed size mismatch for entry '#{printable(cd.name)}'"}

      true ->
        :ok
    end
  end

  # Zip64 archives advertise a locator record just before the EOCD.  We
  # don't support them yet because our safety caps keep us well below
  # the 4 GiB / 64k-entry thresholds anyway.  Fail explicitly so callers
  # aren't surprised by a partial read.
  defp reject_zip64(bin) do
    if :binary.match(bin, @zip64_eocd_locator_sig) == :nomatch do
      :ok
    else
      {:exception, "NotImplementedError: ZIP64 archives are not supported"}
    end
  end

  # Scan the last 65 KiB + 22 bytes for the EOCD signature (the ZIP
  # comment can be up to 64 KiB).  We take the last occurrence.
  defp find_eocd(bin) do
    size = byte_size(bin)
    search_start = max(0, size - (65_535 + 22))
    tail = binary_part(bin, search_start, size - search_start)

    case :binary.matches(tail, @eocd_sig) do
      [] ->
        {:exception, "BadZipFile: File is not a zip file"}

      matches ->
        {off, _len} = List.last(matches)
        {:ok, search_start + off}
    end
  end

  defp parse_eocd(bin, off) do
    case binary_part(bin, off, min(22, byte_size(bin) - off)) do
      <<_sig::binary-size(4), _disk::little-16, _cd_disk::little-16,
        _this_disk_entries::little-16, total_entries::little-16, cd_size::little-32,
        cd_offset::little-32, comment_len::little-16>> ->
        {:ok,
         %{
           total_entries: total_entries,
           cd_size: cd_size,
           cd_offset: cd_offset,
           comment_len: comment_len
         }}

      _ ->
        {:exception, "BadZipFile: truncated end-of-central-directory record"}
    end
  end

  defp parse_cd(bin, offset, size) do
    cond do
      offset + size > byte_size(bin) ->
        {:exception, "BadZipFile: central directory extends past end of archive"}

      size == 0 ->
        {:ok, []}

      true ->
        try do
          cd_bin = binary_part(bin, offset, size)
          {:ok, parse_cd_entries(cd_bin, [])}
        rescue
          _ -> {:exception, "BadZipFile: malformed central directory"}
        end
    end
  end

  defp parse_cd_entries(
         <<@cd_entry_sig, _ver_made::little-16, _ver_needed::little-16, gp_flag::little-16,
           method::little-16, mtime::little-16, mdate::little-16, crc::little-32,
           csize::little-32, usize::little-32, name_len::little-16, extra_len::little-16,
           comment_len::little-16, _disk::little-16, _internal_attr::little-16,
           external_attr::little-32, local_offset::little-32, rest::binary>>,
         acc
       ) do
    <<raw_name::binary-size(^name_len), _extra::binary-size(^extra_len),
      _comment::binary-size(^comment_len), more::binary>> = rest

    unix_mode = Bitwise.bsr(external_attr, 16)

    entry = %{
      name: decode_entry_name(raw_name, gp_flag),
      raw_name: raw_name,
      gp_flag: gp_flag,
      method: method,
      mtime_dos: mtime,
      mdate_dos: mdate,
      crc: crc,
      compressed_size: csize,
      uncompressed_size: usize,
      external_attr: external_attr,
      unix_mode: unix_mode,
      local_offset: local_offset,
      encrypted: Bitwise.band(gp_flag, @gp_encrypted) != 0,
      is_symlink: Bitwise.band(unix_mode, @s_ifmt) == @s_iflnk
    }

    parse_cd_entries(more, [entry | acc])
  end

  defp parse_cd_entries(<<>>, acc), do: Enum.reverse(acc)

  defp parse_cd_entries(_junk, _acc) do
    raise "malformed central directory"
  end

  # Second opinion from :zip — catches cases where our CD parse is OK
  # but the archive is still structurally broken (e.g. local headers
  # don't line up).  We cross-check the entry count afterwards.
  defp safe_zip_table(bin) do
    try do
      case :zip.table(bin) do
        {:ok, table} -> {:ok, table}
        {:error, :bad_eocd} -> {:exception, "BadZipFile: File is not a zip file"}
        {:error, {:EXIT, _}} -> {:exception, "BadZipFile: File is not a zip file"}
        {:error, reason} -> {:exception, "BadZipFile: #{inspect(reason)}"}
      end
    catch
      _, _ -> {:exception, "BadZipFile: File is not a zip file"}
    end
  end

  # Merge what we learned from the CD (encryption, symlink bits) with what
  # `:zip.table` tells us (file_info.type, mtime).  Enforce all safety
  # limits in a single pass before we hand entries back to the caller.
  defp merge_and_validate(cd_entries, table, limits) do
    # `:zip.table` may return either a byte charlist or a Unicode-
    # codepoint charlist depending on EFS.  Normalize to a binary key
    # so the lookup works either way.
    zip_by_name =
      table
      |> Enum.flat_map(fn
        {:zip_file, name_chars, file_info, _extra, _offset, _csize} ->
          [{name_charlist_to_lookup_key(name_chars), file_info}]

        _ ->
          []
      end)
      |> Map.new()

    cond do
      length(cd_entries) > limits.max_entries ->
        {:exception,
         "BadZipFile: too many entries (#{length(cd_entries)} > #{limits.max_entries})"}

      true ->
        entries =
          Enum.reduce_while(cd_entries, {:ok, [], 0}, fn cd, {:ok, acc, total} ->
            case validate_entry(cd, zip_by_name, limits, total) do
              {:ok, entry} ->
                {:cont, {:ok, [entry | acc], total + entry.uncompressed_size}}

              {:exception, _} = exc ->
                {:halt, exc}
            end
          end)

        case entries do
          {:ok, acc, _total} -> {:ok, Enum.reverse(acc)}
          {:exception, _} = exc -> exc
        end
    end
  end

  defp validate_entry(cd, zip_by_name, limits, total_so_far) do
    name = cd.name
    zip_info = Map.get(zip_by_name, cd.raw_name) || Map.get(zip_by_name, name)
    is_dir = is_directory_entry?(cd, zip_info)

    date_time =
      case zip_info do
        {:file_info, _, _, _, _, mtime, _, _, _, _, _, _, _, _} -> mtime_to_tuple(mtime)
        _ -> dos_date_time(cd.mdate_dos, cd.mtime_dos)
      end

    cond do
      byte_size(name) > @max_filename_length ->
        {:exception,
         "BadZipFile: entry name exceeds #{@max_filename_length} bytes (got #{byte_size(name)})"}

      reason = filename_reject_reason(name) ->
        {:exception, "BadZipFile: entry name '#{printable(name)}' #{reason}"}

      cd.uncompressed_size > limits.max_entry_size ->
        {:exception,
         "LargeZipFile: entry '#{printable(name)}' uncompressed size #{cd.uncompressed_size} exceeds per-entry cap #{limits.max_entry_size}"}

      total_so_far + cd.uncompressed_size > limits.max_total_size ->
        {:exception,
         "LargeZipFile: archive uncompressed size exceeds #{limits.max_total_size} bytes after entry '#{printable(name)}'"}

      ratio_dangerous?(cd, limits.max_ratio) ->
        {:exception,
         "BadZipFile: entry '#{printable(name)}' compression ratio exceeds #{limits.max_ratio}× (possible zip bomb)"}

      true ->
        entry = %{
          name: name,
          raw_name: cd.raw_name,
          uncompressed_size: cd.uncompressed_size,
          compressed_size: cd.compressed_size,
          date_time: date_time,
          is_dir: is_dir,
          method: cd.method,
          crc: cd.crc,
          encrypted: cd.encrypted,
          external_attr: cd.external_attr,
          unix_mode: cd.unix_mode,
          is_symlink: cd.is_symlink
        }

        {:ok, entry}
    end
  end

  defp is_directory_entry?(cd, zip_info) do
    String.ends_with?(cd.name, "/") or
      match?({:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}, zip_info)
  end

  defp ratio_dangerous?(%{compressed_size: cs, uncompressed_size: us}, max_ratio) do
    cs >= @min_compressed_for_ratio_check and us > cs * max_ratio
  end

  # Reject filenames that can't be safely displayed, indexed, or logged.
  # Path-traversal patterns are allowed at parse time (so callers can
  # inspect suspicious archives) but rejected later at extract time.
  defp filename_reject_reason(name) do
    cond do
      name == "" -> "is empty"
      String.contains?(name, <<0>>) -> "contains a null byte"
      Regex.match?(~r/[\x01-\x1f\x7f]/, name) -> "contains a control character"
      unsafe_segment?(name) -> "has a path segment with a trailing dot or space"
      true -> nil
    end
  end

  # Writer-side guard: the same sanity checks we apply on read, plus the
  # length cap and path-traversal rejection (callers writing `../foo`
  # are either making a mistake or trying to build an exploit payload —
  # either way we refuse).
  defp writer_name_reject_reason(name) do
    cond do
      not is_binary(name) -> "must be a string"
      byte_size(name) > @max_filename_length -> "exceeds #{@max_filename_length} bytes"
      unsafe_member_path?(name) -> "is absolute or escapes the archive root"
      reason = filename_reject_reason(name) -> reason
      true -> nil
    end
  end

  defp unsafe_segment?(name) do
    segments =
      name
      |> String.replace("\\", "/")
      |> String.split("/")

    Enum.any?(segments, fn seg ->
      seg != "" and seg != "." and seg != ".." and
        (String.ends_with?(seg, " ") or String.ends_with?(seg, "."))
    end) or
      Enum.any?(segments |> Enum.drop(-1), fn seg -> seg == "" end)
  end

  defp unsafe_member_path?(name) do
    cond do
      String.starts_with?(name, "/") -> true
      String.starts_with?(name, "\\") -> true
      String.length(name) >= 2 and String.at(name, 1) == ":" -> true
      name == ".." -> true
      String.starts_with?(name, "../") -> true
      String.starts_with?(name, "..\\") -> true
      String.contains?(name, "/../") -> true
      String.contains?(name, "\\..\\") -> true
      String.ends_with?(name, "/..") -> true
      String.ends_with?(name, "\\..") -> true
      true -> false
    end
  end

  defp printable(name) do
    name
    |> String.replace(~r/[\x00-\x1f\x7f]/, "?")
  end

  defp mtime_to_tuple({{y, m, d}, {hh, mm, ss}}), do: {y, m, d, hh, mm, ss}
  defp mtime_to_tuple(_), do: {1980, 1, 1, 0, 0, 0}

  # DOS date/time (used as a fallback when :zip doesn't recognize the mtime).
  defp dos_date_time(dos_date, dos_time) do
    year = 1980 + Bitwise.bsr(dos_date, 9)
    month = Bitwise.band(Bitwise.bsr(dos_date, 5), 0x0F)
    day = Bitwise.band(dos_date, 0x1F)
    hour = Bitwise.bsr(dos_time, 11)
    minute = Bitwise.band(Bitwise.bsr(dos_time, 5), 0x3F)
    second = Bitwise.band(dos_time, 0x1F) * 2
    {year, month, day, hour, minute, second}
  end

  defp read_comment(_bin, _eocd_offset, 0), do: <<>>

  defp read_comment(bin, eocd_offset, len) do
    start = eocd_offset + 22

    if start + len <= byte_size(bin) do
      binary_part(bin, start, len)
    else
      <<>>
    end
  end

  defp index_entries(entries) do
    entries
    |> Enum.with_index()
    |> Map.new(fn {e, idx} -> {e.name, idx} end)
  end

  # ==========================================================================
  # Lazy decompression (read mode)
  # ==========================================================================

  defp decompress_entry(%{is_dir: true}, _raw), do: {:ok, <<>>}

  defp decompress_entry(%{encrypted: true, name: name}, _raw) do
    {:exception,
     "NotImplementedError: File '#{printable(name)}' is encrypted, password required for extraction"}
  end

  # Per-entry compression method check.  We support 0 (stored) and 8
  # (deflated); everything else gets a human-readable error.
  defp decompress_entry(%{method: method, name: name}, _raw)
       when method != @zip_stored and method != @zip_deflated do
    {:exception,
     "NotImplementedError: entry '#{printable(name)}' uses #{compression_method_label(method)}"}
  end

  defp decompress_entry(%{uncompressed_size: 0}, _raw), do: {:ok, <<>>}

  defp decompress_entry(%{name: name} = entry, raw) do
    raw_name = Map.get(entry, :raw_name, name)

    try do
      case :zip.zip_open(raw, [:memory]) do
        {:ok, pid} ->
          try do
            case :zip.zip_get(:binary.bin_to_list(raw_name), pid) do
              {:ok, {_, data}} ->
                data_bin = ensure_binary(data)
                verify_decompressed(entry, data_bin)

              {:error, :file_not_found} ->
                {:exception, "KeyError: entry '#{printable(name)}' missing from archive"}

              {:error, {:bad_crc, _}} ->
                {:exception, "BadZipFile: CRC32 mismatch on entry '#{printable(name)}'"}

              {:error, reason} ->
                {:exception, "BadZipFile: #{inspect(reason)}"}
            end
          after
            :zip.zip_close(pid)
          end

        {:error, reason} ->
          {:exception, "BadZipFile: #{inspect(reason)}"}
      end
    catch
      _, _ -> {:exception, "BadZipFile: failed to decompress entry"}
    end
  end

  # After decompression, verify that (1) the size matches what the CD
  # declared and (2) the CRC32 matches.  A malicious archive can lie
  # about its payload; this is the cheapest way to catch it.
  defp verify_decompressed(entry, data) do
    actual_size = byte_size(data)
    actual_crc = :erlang.crc32(data)

    cond do
      actual_size != entry.uncompressed_size ->
        {:exception,
         "BadZipFile: entry '#{printable(entry.name)}' decompressed to #{actual_size} bytes, central directory declared #{entry.uncompressed_size}"}

      actual_crc != entry.crc ->
        {:exception,
         "BadZipFile: CRC32 mismatch on entry '#{printable(entry.name)}' (expected #{entry.crc}, got #{actual_crc})"}

      true ->
        {:ok, data}
    end
  end

  # `:zip.zip_get` returns iodata; coerce to a flat binary regardless of shape.
  defp ensure_binary(data), do: IO.iodata_to_binary(data)

  # `:zip.table` may return either a byte-charlist or a Unicode-codepoint
  # charlist depending on whether the EFS bit was set.  Normalize to a
  # binary so we can use it as a map key.
  defp name_charlist_to_lookup_key(chars) when is_list(chars) do
    if Enum.all?(chars, &(&1 < 256)) do
      :binary.list_to_bin(chars)
    else
      :unicode.characters_to_binary(chars, :unicode, :utf8)
    end
  end

  defp name_charlist_to_lookup_key(other) when is_binary(other), do: other

  # Decode an entry name according to GP bit 11 (EFS).  Set → UTF-8;
  # clear → CP437 (the pre-2006 default for DOS/Windows tools).  Pure
  # ASCII round-trips unchanged either way.
  defp decode_entry_name(bytes, gp_flag) do
    cond do
      all_ascii?(bytes) ->
        bytes

      Bitwise.band(gp_flag, 0x0800) != 0 ->
        if String.valid?(bytes), do: bytes, else: cp437_to_utf8(bytes)

      true ->
        cp437_to_utf8(bytes)
    end
  end

  defp all_ascii?(<<>>), do: true
  defp all_ascii?(<<c, rest::binary>>) when c < 0x80, do: all_ascii?(rest)
  defp all_ascii?(_), do: false

  # Standard CP437 → Unicode mapping for bytes 0x80–0xFF.  The low half
  # (0x00–0x7F) is identical to ASCII and doesn't need translation.
  @cp437_high [
    0x00C7,
    0x00FC,
    0x00E9,
    0x00E2,
    0x00E4,
    0x00E0,
    0x00E5,
    0x00E7,
    0x00EA,
    0x00EB,
    0x00E8,
    0x00EF,
    0x00EE,
    0x00EC,
    0x00C4,
    0x00C5,
    0x00C9,
    0x00E6,
    0x00C6,
    0x00F4,
    0x00F6,
    0x00F2,
    0x00FB,
    0x00F9,
    0x00FF,
    0x00D6,
    0x00DC,
    0x00A2,
    0x00A3,
    0x00A5,
    0x20A7,
    0x0192,
    0x00E1,
    0x00ED,
    0x00F3,
    0x00FA,
    0x00F1,
    0x00D1,
    0x00AA,
    0x00BA,
    0x00BF,
    0x2310,
    0x00AC,
    0x00BD,
    0x00BC,
    0x00A1,
    0x00AB,
    0x00BB,
    0x2591,
    0x2592,
    0x2593,
    0x2502,
    0x2524,
    0x2561,
    0x2562,
    0x2556,
    0x2555,
    0x2563,
    0x2551,
    0x2557,
    0x255D,
    0x255C,
    0x255B,
    0x2510,
    0x2514,
    0x2534,
    0x252C,
    0x251C,
    0x2500,
    0x253C,
    0x255E,
    0x255F,
    0x255A,
    0x2554,
    0x2569,
    0x2566,
    0x2560,
    0x2550,
    0x256C,
    0x2567,
    0x2568,
    0x2564,
    0x2565,
    0x2559,
    0x2558,
    0x2552,
    0x2553,
    0x256B,
    0x256A,
    0x2518,
    0x250C,
    0x2588,
    0x2584,
    0x258C,
    0x2590,
    0x2580,
    0x03B1,
    0x00DF,
    0x0393,
    0x03C0,
    0x03A3,
    0x03C3,
    0x00B5,
    0x03C4,
    0x03A6,
    0x0398,
    0x03A9,
    0x03B4,
    0x221E,
    0x03C6,
    0x03B5,
    0x2229,
    0x2261,
    0x00B1,
    0x2265,
    0x2264,
    0x2320,
    0x2321,
    0x00F7,
    0x2248,
    0x00B0,
    0x2219,
    0x00B7,
    0x221A,
    0x207F,
    0x00B2,
    0x25A0,
    0x00A0
  ]

  defp cp437_to_utf8(bytes) do
    for <<byte <- bytes>>, into: "" do
      if byte < 0x80 do
        <<byte>>
      else
        codepoint = Enum.at(@cp437_high, byte - 0x80)
        <<codepoint::utf8>>
      end
    end
  end

  # ==========================================================================
  # Instance construction
  # ==========================================================================

  defp build_instance(state, env, ctx) do
    {{:ref, ref_id}, ctx} = Ctx.heap_alloc(ctx, state)

    instance =
      {:instance, zipfile_class(),
       %{
         "__state_ref_id__" => ref_id,
         "filename" => state.filename,
         "mode" => state_mode_str(state.mode),
         "compression" => state.default_method,
         "debug" => 0,
         "namelist" => method_namelist(ref_id),
         "infolist" => method_infolist(ref_id),
         "getinfo" => method_getinfo(ref_id),
         "read" => method_read(ref_id),
         "open" => method_open(ref_id),
         "write" => method_write(ref_id),
         "writestr" => method_writestr(ref_id),
         "extract" => method_extract(ref_id),
         "extractall" => method_extractall(ref_id),
         "testzip" => method_testzip(ref_id),
         "printdir" => method_printdir(ref_id),
         "mkdir" => method_mkdir(ref_id)
       }}

    # Heap-allocate the instance too.  Without this, attribute assignment
    # (`z.comment = b"..."`) rebinds the local name to a fresh instance
    # but leaves the original — which is what `with ... as z:` captures
    # for `__exit__` — unchanged.  Ref-wrapping makes the mutation visible
    # across all aliases, the way CPython objects behave.
    {inst_ref, ctx} = Ctx.heap_alloc(ctx, instance)
    {inst_ref, env, ctx}
  end

  # Only `:r` and `:w` are reachable here — append mode short-circuits with
  # NotImplementedError before state is ever constructed.
  defp state_mode_str(:r), do: "r"
  defp state_mode_str(:w), do: "w"

  defp zipfile_class do
    {:class, "ZipFile", [],
     %{
       "__enter__" => {:builtin, &class_enter/1},
       "__exit__" => {:builtin, &class_exit/1},
       "__iter__" => {:builtin, &class_iter/1},
       "close" => {:builtin, &class_close/1},
       # `comment` is a property so assignment (`z.comment = b"..."`) can
       # reach the heap state — attribute assignment on the bound `as`
       # variable doesn't propagate back to the `with` statement's saved
       # context_val, but property setters do.
       "comment" =>
         {:property, {:builtin, &class_comment_get/1}, {:builtin, &class_comment_set/1}, nil}
     }}
  end

  defp class_comment_get([self | _]) do
    case self do
      {:instance, _, %{"__state_ref_id__" => ref_id}} ->
        {:ctx_call,
         fn env, ctx ->
           state = Ctx.deref(ctx, {:ref, ref_id})
           {{:bytes, state.comment || <<>>}, env, ctx}
         end}

      _ ->
        {:bytes, <<>>}
    end
  end

  defp class_comment_set([self, value | _]) do
    case self do
      {:instance, _, %{"__state_ref_id__" => ref_id}} ->
        {:ctx_call,
         fn env, ctx ->
           state = Ctx.deref(ctx, {:ref, ref_id})
           new_state = %{state | comment: coerce_comment(value)}
           ctx = Ctx.heap_put(ctx, ref_id, new_state)
           {nil, env, ctx}
         end}

      _ ->
        {:exception, "AttributeError: no ZipFile state"}
    end
  end

  defp class_enter([self | _]), do: self

  defp class_iter([self | _]) do
    case self do
      {:instance, _, %{"__state_ref_id__" => ref_id}} ->
        {:ctx_call,
         fn env, ctx ->
           state = Ctx.deref(ctx, {:ref, ref_id})
           names = Enum.map(state.entries, & &1.name)
           {{:py_list, Enum.reverse(names), length(names)}, env, ctx}
         end}

      _ ->
        {:exception, "TypeError: __iter__ called on non-ZipFile"}
    end
  end

  defp class_close([self | _]) do
    case self do
      {:instance, _, attrs} ->
        ref_id = Map.get(attrs, "__state_ref_id__")

        if is_integer(ref_id) do
          do_close(ref_id)
        else
          {:exception, "TypeError: close() called on non-ZipFile"}
        end

      _ ->
        {:exception, "TypeError: close() called on non-ZipFile"}
    end
  end

  # Run close() on __exit__ and propagate any exception it raises.
  defp class_exit([self | _]) do
    case class_close([self]) do
      {:ctx_call, f} ->
        {:ctx_call,
         fn env, ctx ->
           case f.(env, ctx) do
             {{:exception, _} = exc, env, ctx} -> {exc, env, ctx}
             {_val, env, ctx} -> {false, env, ctx}
           end
         end}

      _ ->
        false
    end
  end

  defp coerce_comment({:bytes, b}) when is_binary(b), do: b
  defp coerce_comment({:bytearray, b}) when is_binary(b), do: b
  defp coerce_comment(b) when is_binary(b), do: b
  defp coerce_comment(_), do: <<>>

  # ==========================================================================
  # Methods
  # ==========================================================================

  defp method_namelist(ref_id) do
    {:builtin,
     fn
       [] ->
         {:ctx_call,
          fn env, ctx ->
            with_open_state(ref_id, env, ctx, fn state, env, ctx ->
              names = Enum.map(state.entries, & &1.name)
              {{:py_list, Enum.reverse(names), length(names)}, env, ctx}
            end)
          end}

       _ ->
         {:exception, "TypeError: namelist() takes no arguments"}
     end}
  end

  defp method_infolist(ref_id) do
    {:builtin,
     fn
       [] ->
         {:ctx_call,
          fn env, ctx ->
            with_open_state(ref_id, env, ctx, fn state, env, ctx ->
              infos = Enum.map(state.entries, &make_zipinfo/1)
              {{:py_list, Enum.reverse(infos), length(infos)}, env, ctx}
            end)
          end}

       _ ->
         {:exception, "TypeError: infolist() takes no arguments"}
     end}
  end

  defp method_getinfo(ref_id) do
    {:builtin,
     fn
       [name] when is_binary(name) ->
         {:ctx_call,
          fn env, ctx ->
            with_open_state(ref_id, env, ctx, fn state, env, ctx ->
              case lookup_entry(state, name) do
                {:ok, entry} -> {make_zipinfo(entry), env, ctx}
                {:exception, msg} -> {{:exception, msg}, env, ctx}
              end
            end)
          end}

       [_] ->
         {:exception, "TypeError: getinfo() argument must be a string"}

       _ ->
         {:exception, "TypeError: getinfo() takes exactly one argument"}
     end}
  end

  defp method_read(ref_id) do
    {:builtin,
     fn
       [name] -> read_call(ref_id, name)
       [name, _pwd] -> read_call(ref_id, name)
       _ -> {:exception, "TypeError: read() takes 1 or 2 arguments"}
     end}
  end

  # `z.open(name)` returns a file-like object.  Equivalent to CPython's
  # ZipExtFile — supports .read([n]), context manager, .close().
  defp method_open(ref_id) do
    {:builtin,
     fn
       [name] -> open_call(ref_id, name, "r")
       [name, mode] when is_binary(mode) -> open_call(ref_id, name, mode)
       [name, nil] -> open_call(ref_id, name, "r")
       _ -> {:exception, "TypeError: open() requires a member name"}
     end}
  end

  defp open_call(ref_id, name_or_info, mode) do
    name = member_name(name_or_info)

    cond do
      mode not in ["r", "rb"] ->
        {:exception, "NotImplementedError: ZipFile.open() only supports read mode"}

      true ->
        {:ctx_call,
         fn env, ctx ->
           with_open_state(ref_id, env, ctx, fn state, env, ctx ->
             with {:ok, entry} <- lookup_entry(state, name),
                  {:ok, data} <- entry_bytes(state, entry) do
               build_zip_ext_file(name, data, env, ctx)
             else
               {:exception, msg} -> {{:exception, msg}, env, ctx}
             end
           end)
         end}
    end
  end

  # ==========================================================================
  # ZipExtFile — the file-like object returned by ZipFile.open()
  # ==========================================================================

  defp build_zip_ext_file(name, data, env, ctx) do
    zef_state = %{data: data, pos: 0, closed: false, name: name}
    {{:ref, ref_id}, ctx} = Ctx.heap_alloc(ctx, zef_state)

    instance =
      {:instance, zip_ext_file_class(),
       %{
         "__state_ref_id__" => ref_id,
         "name" => name,
         "closed" => false,
         "read" => zef_method_read(ref_id),
         "readable" => zef_method_readable(),
         "seekable" => zef_method_false(),
         "writable" => zef_method_false(),
         "tell" => zef_method_tell(ref_id),
         "close" => zef_method_close(ref_id)
       }}

    {instance, env, ctx}
  end

  defp zip_ext_file_class do
    {:class, "ZipExtFile", [],
     %{
       "__enter__" => {:builtin, fn [self | _] -> self end},
       "__exit__" => {:builtin, &zef_class_exit/1}
     }}
  end

  defp zef_class_exit([self | _]) do
    case self do
      {:instance, _, %{"__state_ref_id__" => ref_id}} ->
        {:ctx_call,
         fn env, ctx ->
           state = Ctx.deref(ctx, {:ref, ref_id})
           ctx = Ctx.heap_put(ctx, ref_id, %{state | closed: true, data: <<>>})
           {false, env, ctx}
         end}

      _ ->
        false
    end
  end

  defp zef_method_read(ref_id) do
    {:builtin,
     fn
       [] -> zef_read_call(ref_id, :all)
       [n] when is_integer(n) and n < 0 -> zef_read_call(ref_id, :all)
       [n] when is_integer(n) -> zef_read_call(ref_id, n)
       [nil] -> zef_read_call(ref_id, :all)
       _ -> {:exception, "TypeError: read() takes an optional integer size"}
     end}
  end

  defp zef_read_call(ref_id, how_much) do
    {:ctx_call,
     fn env, ctx ->
       state = Ctx.deref(ctx, {:ref, ref_id})

       cond do
         state.closed ->
           {{:exception, "ValueError: I/O operation on closed file"}, env, ctx}

         true ->
           remaining = byte_size(state.data) - state.pos

           take =
             case how_much do
               :all -> remaining
               n -> min(n, remaining)
             end

           chunk = binary_part(state.data, state.pos, take)
           ctx = Ctx.heap_put(ctx, ref_id, %{state | pos: state.pos + take})
           {{:bytes, chunk}, env, ctx}
       end
     end}
  end

  defp zef_method_readable, do: {:builtin, fn _ -> true end}
  defp zef_method_false, do: {:builtin, fn _ -> false end}

  defp zef_method_tell(ref_id) do
    {:builtin,
     fn _ ->
       {:ctx_call,
        fn env, ctx ->
          state = Ctx.deref(ctx, {:ref, ref_id})
          {state.pos, env, ctx}
        end}
     end}
  end

  defp zef_method_close(ref_id) do
    {:builtin,
     fn _ ->
       {:ctx_call,
        fn env, ctx ->
          state = Ctx.deref(ctx, {:ref, ref_id})
          ctx = Ctx.heap_put(ctx, ref_id, %{state | closed: true, data: <<>>})
          {nil, env, ctx}
        end}
     end}
  end

  defp read_call(ref_id, name_or_info) do
    name = member_name(name_or_info)

    {:ctx_call,
     fn env, ctx ->
       with_open_state(ref_id, env, ctx, fn state, env, ctx ->
         with {:ok, entry} <- lookup_entry(state, name),
              {:ok, data} <- entry_bytes(state, entry) do
           {{:bytes, data}, env, ctx}
         else
           {:exception, msg} -> {{:exception, msg}, env, ctx}
         end
       end)
     end}
  end

  defp entry_bytes(%{mode: :r} = state, entry), do: decompress_entry(entry, state.raw)
  defp entry_bytes(_state, %{is_dir: true}), do: {:ok, <<>>}
  # In write mode, `entry.data` holds the pending uncompressed bytes.
  defp entry_bytes(_state, entry), do: {:ok, Map.get(entry, :data, <<>>)}

  defp lookup_entry(state, name) do
    case Map.fetch(state.entry_index, name) do
      {:ok, idx} ->
        {:ok, Enum.at(state.entries, idx)}

      :error ->
        {:exception, "KeyError: \"There is no item named '#{printable(name)}' in the archive\""}
    end
  end

  defp with_open_state(ref_id, env, ctx, fun) do
    state = Ctx.deref(ctx, {:ref, ref_id})

    if state.closed do
      {{:exception, "ValueError: Attempt to use ZIP archive that was already closed"}, env, ctx}
    else
      fun.(state, env, ctx)
    end
  end

  defp method_writestr(ref_id) do
    {:builtin,
     fn
       [name, data] ->
         writestr_call(ref_id, name, data)

       [name, data, _compress_type] ->
         writestr_call(ref_id, name, data)

       _ ->
         {:exception, "TypeError: writestr() takes at least 2 arguments"}
     end}
  end

  defp writestr_call(ref_id, name_or_info, data) do
    arcname = zipinfo_filename(name_or_info)
    data_bin = to_binary_data(data)
    overrides = zipinfo_overrides(name_or_info)

    case {arcname, data_bin} do
      {{:exception, _} = e, _} ->
        e

      {_, {:exception, _} = e} ->
        e

      {name, data_bin} ->
        {:ctx_call,
         fn env, ctx ->
           state = Ctx.deref(ctx, {:ref, ref_id})

           cond do
             state.closed ->
               {{:exception, "ValueError: Attempt to use ZIP archive that was already closed"},
                env, ctx}

             state.mode != :w ->
               {{:exception, "ValueError: write() requires mode 'w', 'x', or 'a'"}, env, ctx}

             reason = writer_name_reject_reason(name) ->
               {{:exception,
                 "ValueError: entry name '#{printable(name)}' #{reason} — refused by writer"},
                env, ctx}

             Map.has_key?(state.entry_index, name) ->
               {{:exception,
                 "UserWarning: Duplicate name: '#{printable(name)}' — writestr rejected"}, env,
                ctx}

             true ->
               entry = %{
                 name: name,
                 data: data_bin,
                 method: overrides[:method] || state.default_method,
                 date_time: overrides[:date_time] || now_tuple(),
                 crc: :erlang.crc32(data_bin),
                 uncompressed_size: byte_size(data_bin),
                 compressed_size: byte_size(data_bin),
                 is_dir: String.ends_with?(name, "/"),
                 encrypted: false,
                 external_attr: overrides[:external_attr] || 0,
                 unix_mode: 0o644,
                 is_symlink: false
               }

               entries = state.entries ++ [entry]
               new_state = %{state | entries: entries, entry_index: index_entries(entries)}
               ctx = Ctx.heap_put(ctx, ref_id, new_state)
               {nil, env, ctx}
           end
         end}
    end
  end

  # When writestr receives a ZipInfo, pull the fields that influence the
  # entry header (compression, timestamp, external_attr).  A plain string
  # arcname yields an empty override map and we fall back to defaults.
  defp zipinfo_overrides({:instance, {:class, "ZipInfo", _, _}, attrs}) do
    method =
      case Map.get(attrs, "compress_type") do
        n when is_integer(n) -> n
        _ -> nil
      end

    date_time =
      case Map.get(attrs, "date_time") do
        {:tuple, [y, m, d, hh, mm, ss]} when is_integer(y) -> {y, m, d, hh, mm, ss}
        _ -> nil
      end

    external_attr =
      case Map.get(attrs, "external_attr") do
        n when is_integer(n) -> n
        _ -> nil
      end

    %{method: method, date_time: date_time, external_attr: external_attr}
  end

  defp zipinfo_overrides(_), do: %{}

  defp method_write(ref_id) do
    {:builtin,
     fn
       [filename] when is_binary(filename) ->
         write_file_call(ref_id, filename, filename)

       [filename, arcname] when is_binary(filename) and is_binary(arcname) ->
         write_file_call(ref_id, filename, arcname)

       [filename, nil] when is_binary(filename) ->
         write_file_call(ref_id, filename, filename)

       _ ->
         {:exception, "TypeError: write() requires a filename"}
     end}
  end

  defp write_file_call(ref_id, filename, arcname) do
    {:ctx_call,
     fn env, ctx ->
       state = Ctx.deref(ctx, {:ref, ref_id})

       cond do
         state.closed ->
           {{:exception, "ValueError: Attempt to use ZIP archive that was already closed"}, env,
            ctx}

         state.mode != :w ->
           {{:exception, "ValueError: write() requires mode 'w', 'x', or 'a'"}, env, ctx}

         reason = writer_name_reject_reason(arcname) ->
           {{:exception,
             "ValueError: entry name '#{printable(arcname)}' #{reason} — refused by writer"}, env,
            ctx}

         Map.has_key?(state.entry_index, arcname) ->
           {{:exception, "UserWarning: Duplicate name: '#{printable(arcname)}' — write rejected"},
            env, ctx}

         true ->
           case Ctx.open_handle(ctx, filename, :read) do
             {:ok, id, ctx} ->
               case Ctx.read_handle(ctx, id) do
                 {:ok, content, ctx} ->
                   {:ok, ctx} = Ctx.close_handle(ctx, id)

                   entry = %{
                     name: arcname,
                     data: content,
                     method: state.default_method,
                     date_time: now_tuple(),
                     crc: :erlang.crc32(content),
                     uncompressed_size: byte_size(content),
                     compressed_size: byte_size(content),
                     is_dir: false,
                     encrypted: false,
                     external_attr: 0,
                     unix_mode: 0o644,
                     is_symlink: false
                   }

                   entries = state.entries ++ [entry]

                   new_state = %{
                     state
                     | entries: entries,
                       entry_index: index_entries(entries)
                   }

                   ctx = Ctx.heap_put(ctx, ref_id, new_state)
                   {nil, env, ctx}

                 {:error, msg} ->
                   {:ok, ctx} = Ctx.close_handle(ctx, id)
                   {{:exception, msg}, env, ctx}
               end

             {:error, msg} ->
               {{:exception, msg}, env, ctx}
           end
       end
     end}
  end

  defp method_extract(ref_id) do
    {:builtin,
     fn
       [member] -> extract_call(ref_id, member, ".")
       [member, path] when is_binary(path) -> extract_call(ref_id, member, path)
       [member, nil] -> extract_call(ref_id, member, ".")
       _ -> {:exception, "TypeError: extract() requires a member name"}
     end}
  end

  defp extract_call(ref_id, member, path) do
    name = member_name(member)

    {:ctx_call,
     fn env, ctx ->
       with_open_state(ref_id, env, ctx, fn state, env, ctx ->
         case lookup_entry(state, name) do
           {:ok, entry} ->
             case safe_extract_single(entry, state, path, ctx) do
               {:ok, dest, ctx} -> {dest, env, ctx}
               {:exception, msg} -> {{:exception, msg}, env, ctx}
             end

           {:exception, msg} ->
             {{:exception, msg}, env, ctx}
         end
       end)
     end}
  end

  defp method_extractall(ref_id) do
    {:builtin,
     fn
       [] -> extractall_call(ref_id, ".", :all)
       [path] when is_binary(path) -> extractall_call(ref_id, path, :all)
       [nil] -> extractall_call(ref_id, ".", :all)
       [path, members] when is_binary(path) -> extractall_call(ref_id, path, members)
       [nil, members] -> extractall_call(ref_id, ".", members)
       _ -> {:exception, "TypeError: extractall(path=None, members=None)"}
     end}
  end

  defp extractall_call(ref_id, path, members) do
    {:ctx_call,
     fn env, ctx ->
       with_open_state(ref_id, env, ctx, fn state, env, ctx ->
         case select_members(state, members) do
           {:ok, entries} ->
             result =
               Enum.reduce_while(entries, {:ok, ctx}, fn entry, {:ok, ctx} ->
                 case safe_extract_single(entry, state, path, ctx) do
                   {:ok, _dest, ctx} -> {:cont, {:ok, ctx}}
                   {:exception, msg} -> {:halt, {:exception, msg}}
                 end
               end)

             case result do
               {:ok, ctx} -> {nil, env, ctx}
               {:exception, msg} -> {{:exception, msg}, env, ctx}
             end

           {:exception, msg} ->
             {{:exception, msg}, env, ctx}
         end
       end)
     end}
  end

  # `members` accepts None/:all (extract everything) or an iterable of
  # names / ZipInfo objects.  Unknown names raise KeyError to match
  # CPython.  Order follows the caller-supplied list when given.
  defp select_members(state, :all), do: {:ok, state.entries}

  defp select_members(state, members) do
    list =
      case members do
        {:py_list, rev, _} -> Enum.reverse(rev)
        items when is_list(items) -> items
        {:tuple, items} -> items
        {:set, s} -> MapSet.to_list(s)
        _ -> []
      end

    Enum.reduce_while(list, {:ok, []}, fn member, {:ok, acc} ->
      name = member_name(member)

      case Map.fetch(state.entry_index, name) do
        {:ok, idx} ->
          {:cont, {:ok, [Enum.at(state.entries, idx) | acc]}}

        :error ->
          {:halt,
           {:exception,
            "KeyError: \"There is no item named '#{printable(name)}' in the archive\""}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:exception, _} = exc -> exc
    end
  end

  # Full extract path with zip-slip, symlink, and encryption guards.
  defp safe_extract_single(entry, state, base_path, ctx) do
    cond do
      entry.is_symlink ->
        {:exception,
         "BadZipFile: symlink entry '#{printable(entry.name)}' refused during extraction"}

      entry.encrypted ->
        {:exception,
         "NotImplementedError: File '#{printable(entry.name)}' is encrypted, cannot extract"}

      # Every filename was already validated at parse time, but recheck
      # here against base_path combinations to belt-and-suspenders.
      unsafe_member_path?(entry.name) ->
        {:exception,
         "BadZipFile: unsafe entry name '#{printable(entry.name)}' (absolute or escaping path)"}

      true ->
        dest = Path.join(base_path, entry.name)

        if entry.is_dir do
          {:ok, dest, ctx}
        else
          case entry_bytes(state, entry) do
            {:ok, data} -> write_extract(dest, data, ctx)
            {:exception, msg} -> {:exception, msg}
          end
        end
    end
  end

  defp write_extract(dest, data, ctx) do
    case Ctx.open_handle(ctx, dest, :write) do
      {:ok, id, ctx} ->
        case Ctx.write_handle(ctx, id, data) do
          {:ok, ctx} ->
            case Ctx.close_handle(ctx, id) do
              {:ok, ctx} -> {:ok, dest, ctx}
              {:error, msg} -> {:exception, msg}
            end

          {:error, msg} ->
            {:exception, msg}
        end

      {:error, msg} ->
        {:exception, msg}
    end
  end

  defp method_testzip(ref_id) do
    {:builtin,
     fn [] ->
       {:ctx_call,
        fn env, ctx ->
          with_open_state(ref_id, env, ctx, fn state, env, ctx ->
            case Enum.reduce_while(state.entries, :ok, fn entry, :ok ->
                   if entry.is_dir or entry.encrypted do
                     {:cont, :ok}
                   else
                     case decompress_entry(entry, state.raw) do
                       {:ok, _} -> {:cont, :ok}
                       {:exception, _} -> {:halt, {:bad, entry.name}}
                     end
                   end
                 end) do
              :ok -> {nil, env, ctx}
              {:bad, name} -> {name, env, ctx}
            end
          end)
        end}
     end}
  end

  defp method_printdir(ref_id) do
    {:builtin,
     fn [] ->
       {:ctx_call,
        fn env, ctx ->
          with_open_state(ref_id, env, ctx, fn state, env, ctx ->
            header =
              "File Name                                             Modified             Size\n"

            lines =
              Enum.map_join(state.entries, "", fn e ->
                {y, m, d, hh, mm, ss} = e.date_time

                ts =
                  :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B", [
                    y,
                    m,
                    d,
                    hh,
                    mm,
                    ss
                  ])
                  |> IO.iodata_to_binary()

                :io_lib.format("~-52s  ~s  ~10B~n", [
                  String.to_charlist(e.name),
                  String.to_charlist(ts),
                  e.uncompressed_size
                ])
                |> IO.iodata_to_binary()
              end)

            ctx = Pyex.Ctx.record(ctx, :output, header <> lines)
            {nil, env, ctx}
          end)
        end}
     end}
  end

  # `z.mkdir(name)` — adds a directory entry to the archive in write
  # mode.  CPython's signature is `mkdir(zinfo_or_arcname, mode=0o777)`;
  # we accept a name (with or without trailing slash) or a ZipInfo.
  defp method_mkdir(ref_id) do
    {:builtin,
     fn
       [name] -> mkdir_call(ref_id, name, 0o755)
       [name, mode] when is_integer(mode) -> mkdir_call(ref_id, name, mode)
       _ -> {:exception, "TypeError: mkdir() requires a directory name"}
     end}
  end

  defp mkdir_call(ref_id, name_or_info, mode) do
    arcname = zipinfo_filename(name_or_info)

    case arcname do
      {:exception, _} = e ->
        e

      name ->
        dir_name = if String.ends_with?(name, "/"), do: name, else: name <> "/"

        {:ctx_call,
         fn env, ctx ->
           state = Ctx.deref(ctx, {:ref, ref_id})

           cond do
             state.closed ->
               {{:exception, "ValueError: Attempt to use ZIP archive that was already closed"},
                env, ctx}

             state.mode != :w ->
               {{:exception, "ValueError: mkdir() requires mode 'w', 'x', or 'a'"}, env, ctx}

             reason = writer_name_reject_reason(dir_name) ->
               {{:exception,
                 "ValueError: directory name '#{printable(dir_name)}' #{reason} — refused by writer"},
                env, ctx}

             Map.has_key?(state.entry_index, dir_name) ->
               {{:exception,
                 "FileExistsError: directory '#{printable(dir_name)}' already exists"}, env, ctx}

             true ->
               mode_bits = Bitwise.bor(0o040000, Bitwise.band(mode, 0o777))

               entry = %{
                 name: dir_name,
                 raw_name: dir_name,
                 data: <<>>,
                 method: @zip_stored,
                 date_time: now_tuple(),
                 crc: 0,
                 uncompressed_size: 0,
                 compressed_size: 0,
                 is_dir: true,
                 encrypted: false,
                 external_attr: Bitwise.bsl(mode_bits, 16),
                 unix_mode: mode_bits,
                 is_symlink: false
               }

               entries = state.entries ++ [entry]
               new_state = %{state | entries: entries, entry_index: index_entries(entries)}
               ctx = Ctx.heap_put(ctx, ref_id, new_state)
               {nil, env, ctx}
           end
         end}
    end
  end

  defp do_close(ref_id) do
    {:ctx_call,
     fn env, ctx ->
       state = Ctx.deref(ctx, {:ref, ref_id})

       cond do
         state.closed ->
           {nil, env, ctx}

         state.mode == :w ->
           flush_and_close(state, ref_id, env, ctx)

         true ->
           new_state = %{state | closed: true, raw: <<>>}
           ctx = Ctx.heap_put(ctx, ref_id, new_state)
           {nil, env, ctx}
       end
     end}
  end

  defp flush_and_close(state, ref_id, env, ctx) do
    case build_zip_binary(state) do
      {:ok, binary} ->
        case write_out(state, binary, ctx) do
          {:ok, ctx} ->
            new_state = %{state | closed: true}
            ctx = Ctx.heap_put(ctx, ref_id, new_state)
            {nil, env, ctx}

          {:exception, msg} ->
            {{:exception, msg}, env, ctx}
        end

      {:exception, msg} ->
        {{:exception, msg}, env, ctx}
    end
  end

  defp write_out(%{write_back_path: path}, binary, ctx) when is_binary(path) do
    case Ctx.open_handle(ctx, path, :write) do
      {:ok, id, ctx} ->
        case Ctx.write_handle(ctx, id, binary) do
          {:ok, ctx} ->
            case Ctx.close_handle(ctx, id) do
              {:ok, ctx} -> {:ok, ctx}
              {:error, msg} -> {:exception, msg}
            end

          {:error, msg} ->
            {:exception, msg}
        end

      {:error, msg} ->
        {:exception, msg}
    end
  end

  defp write_out(%{write_back_handle: id}, binary, ctx) when is_integer(id) do
    case Ctx.write_handle(ctx, id, binary) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, msg} -> {:exception, msg}
    end
  end

  defp write_out(_state, _binary, ctx), do: {:ok, ctx}

  # Hand-rolled writer.  Builds the archive byte-by-byte (LFH+data per
  # entry, then CD, then EOCD) instead of going through `:zip.create`.
  # Why: `:zip.create` ignores per-entry mtime, can't mix STORED and
  # DEFLATED in one archive, and doesn't expose external_attr — all
  # things callers reasonably expect to control.
  defp build_zip_binary(state) do
    try do
      {lfh_pieces, cd_pieces, _final_offset} =
        Enum.reduce(state.entries, {[], [], 0}, fn entry, {lfhs, cdes, off} ->
          {compressed, csize} = compress_for_zip(entry)
          gp_flag = compute_gp_flag(entry)
          lfh_block = build_lfh(entry, compressed, csize, gp_flag)
          cde = build_cde(entry, off, csize, gp_flag)
          {[lfh_block | lfhs], [cde | cdes], off + byte_size(lfh_block)}
        end)

      lfh_blob = lfh_pieces |> Enum.reverse() |> IO.iodata_to_binary()
      cd_blob = cd_pieces |> Enum.reverse() |> IO.iodata_to_binary()
      cd_offset = byte_size(lfh_blob)
      cd_size = byte_size(cd_blob)

      comment = state.comment || <<>>

      comment =
        if byte_size(comment) > 65_535,
          do: binary_part(comment, 0, 65_535),
          else: comment

      eocd = build_eocd(length(state.entries), cd_size, cd_offset, comment)
      {:ok, lfh_blob <> cd_blob <> eocd}
    catch
      kind, reason ->
        {:exception, "BadZipFile: writer crashed (#{inspect({kind, reason})})"}
    end
  end

  # GP bit 11 (EFS) flags UTF-8 names; we set it whenever any byte is
  # outside ASCII so readers know not to fall back to CP437.
  defp compute_gp_flag(entry) do
    name = Map.get(entry, :raw_name) || entry.name
    if all_ascii?(name), do: 0, else: 0x0800
  end

  # Compress an entry's payload according to its method.  STORED is a
  # no-op; DEFLATED uses raw deflate (RFC 1951, no zlib wrapper).
  defp compress_for_zip(%{is_dir: true}), do: {<<>>, 0}

  defp compress_for_zip(entry) do
    data = Map.get(entry, :data) || <<>>

    case entry.method do
      @zip_stored ->
        {data, byte_size(data)}

      @zip_deflated ->
        z = :zlib.open()
        :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
        compressed = :zlib.deflate(z, data, :finish) |> IO.iodata_to_binary()
        :zlib.deflateEnd(z)
        :zlib.close(z)
        {compressed, byte_size(compressed)}

      _ ->
        # Caller validated method earlier; fall back to STORED to be safe.
        {data, byte_size(data)}
    end
  end

  # Local file header (30 fixed bytes + name) followed by the compressed
  # data for one entry.
  defp build_lfh(entry, compressed, csize, gp_flag) do
    {dos_date, dos_time} = dos_datetime(entry.date_time)
    name = Map.get(entry, :raw_name) || entry.name
    name_len = byte_size(name)
    usize = entry.uncompressed_size || byte_size(Map.get(entry, :data) || <<>>)

    header =
      <<0x50, 0x4B, 0x03, 0x04, 20::little-16, gp_flag::little-16, entry.method::little-16,
        dos_time::little-16, dos_date::little-16, entry.crc::little-32, csize::little-32,
        usize::little-32, name_len::little-16, 0::little-16, name::binary>>

    <<header::binary, compressed::binary>>
  end

  # Central directory entry (46 fixed bytes + name).  Claim Unix
  # version-made-by so external_attr Unix mode bits round-trip with
  # their stat-style meaning.
  defp build_cde(entry, lfh_offset, compressed_size, gp_flag) do
    {dos_date, dos_time} = dos_datetime(entry.date_time)
    name = Map.get(entry, :raw_name) || entry.name
    name_len = byte_size(name)
    usize = entry.uncompressed_size || byte_size(Map.get(entry, :data) || <<>>)

    external_attr =
      case Map.get(entry, :external_attr) do
        n when is_integer(n) and n > 0 -> n
        _ -> default_external_attr(entry)
      end

    # Version made by: Unix host (3) << 8 | spec 2.0 (20).
    version_made_by = 3 * 256 + 20

    <<0x50, 0x4B, 0x01, 0x02, version_made_by::little-16, 20::little-16, gp_flag::little-16,
      entry.method::little-16, dos_time::little-16, dos_date::little-16, entry.crc::little-32,
      compressed_size::little-32, usize::little-32, name_len::little-16, 0::little-16,
      0::little-16, 0::little-16, 0::little-16, external_attr::little-32, lfh_offset::little-32,
      name::binary>>
  end

  defp default_external_attr(%{is_dir: true}),
    do: Bitwise.bor(Bitwise.bsl(0o040755, 16), 0x10)

  defp default_external_attr(_), do: Bitwise.bsl(0o100644, 16)

  # End of central directory record.
  defp build_eocd(num_entries, cd_size, cd_offset, comment) do
    comment_len = byte_size(comment)

    <<0x50, 0x4B, 0x05, 0x06, 0::little-16, 0::little-16, num_entries::little-16,
      num_entries::little-16, cd_size::little-32, cd_offset::little-32, comment_len::little-16,
      comment::binary>>
  end

  # MS-DOS date/time encoding.  Year is biased from 1980, seconds
  # halved (only even seconds are representable), all fields clamp to
  # their representable range.
  defp dos_datetime({year, month, day, hour, minute, second}) do
    yr = clamp(year - 1980, 0, 127)
    month = clamp(month, 1, 12)
    day = clamp(day, 1, 31)
    hour = clamp(hour, 0, 23)
    minute = clamp(minute, 0, 59)
    sec_half = clamp(div(second, 2), 0, 29)

    date = Bitwise.bor(Bitwise.bor(Bitwise.bsl(yr, 9), Bitwise.bsl(month, 5)), day)
    time = Bitwise.bor(Bitwise.bor(Bitwise.bsl(hour, 11), Bitwise.bsl(minute, 5)), sec_half)
    {date, time}
  end

  defp dos_datetime(_), do: {0x21, 0}

  defp clamp(n, lo, _hi) when n < lo, do: lo
  defp clamp(n, _lo, hi) when n > hi, do: hi
  defp clamp(n, _lo, _hi), do: n

  # ==========================================================================
  # is_zipfile
  # ==========================================================================

  defp is_zipfile([{:bytes, binary}]), do: quick_is_zip(binary)
  defp is_zipfile([{:bytearray, binary}]), do: quick_is_zip(binary)

  defp is_zipfile([path]) when is_binary(path) do
    {:ctx_call,
     fn env, ctx ->
       case Ctx.open_handle(ctx, path, :read) do
         {:ok, id, ctx} ->
           case Ctx.read_handle(ctx, id) do
             {:ok, content, ctx} ->
               {:ok, ctx} = Ctx.close_handle(ctx, id)
               {quick_is_zip(content), env, ctx}

             {:error, _} ->
               {:ok, ctx} = Ctx.close_handle(ctx, id)
               {false, env, ctx}
           end

         {:error, _} ->
           {false, env, ctx}
       end
     end}
  end

  defp is_zipfile([{:file_handle, id}]) do
    {:ctx_call,
     fn env, ctx ->
       case Ctx.read_handle(ctx, id) do
         {:ok, content, ctx} -> {quick_is_zip(content), env, ctx}
         {:error, _} -> {false, env, ctx}
       end
     end}
  end

  defp is_zipfile(_), do: false

  defp quick_is_zip(binary) when is_binary(binary) do
    case find_eocd(binary) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp quick_is_zip(_), do: false

  # ==========================================================================
  # ZipInfo
  # ==========================================================================

  defp zipinfo_constructor(args, kwargs) do
    filename = Enum.at(args, 0) || Map.get(kwargs, "filename") || ""

    date_time =
      case Enum.at(args, 1) || Map.get(kwargs, "date_time") do
        {:tuple, [y, m, d, hh, mm, ss]} when is_integer(y) -> {y, m, d, hh, mm, ss}
        _ -> {1980, 1, 1, 0, 0, 0}
      end

    make_zipinfo(%{
      name: filename,
      data: <<>>,
      method: @zip_stored,
      date_time: date_time,
      crc: 0,
      uncompressed_size: 0,
      compressed_size: 0,
      is_dir: String.ends_with?(filename, "/"),
      encrypted: false,
      external_attr: 0,
      unix_mode: 0,
      is_symlink: false
    })
  end

  defp make_zipinfo(entry) do
    {y, m, d, hh, mm, ss} = entry.date_time

    dt_tuple = {:tuple, [y, m, d, hh, mm, ss]}

    is_dir_fn =
      {:builtin,
       fn
         [] -> entry.is_dir
         [_self] -> entry.is_dir
       end}

    {:instance, {:class, "ZipInfo", [], %{}},
     %{
       "filename" => entry.name,
       "date_time" => dt_tuple,
       "compress_type" => entry.method || @zip_stored,
       "compress_size" => entry.compressed_size,
       "file_size" => entry.uncompressed_size,
       "CRC" => entry.crc,
       "external_attr" => Map.get(entry, :external_attr, 0),
       "comment" => "",
       "extra" => {:bytes, <<>>},
       "is_dir" => is_dir_fn
     }}
  end

  defp zipinfo_filename({:instance, {:class, "ZipInfo", _, _}, attrs}),
    do: Map.get(attrs, "filename", "")

  defp zipinfo_filename(name) when is_binary(name), do: name
  defp zipinfo_filename(_), do: {:exception, "TypeError: name must be string or ZipInfo"}

  defp member_name({:instance, {:class, "ZipInfo", _, _}, attrs}),
    do: Map.get(attrs, "filename", "")

  defp member_name(name) when is_binary(name), do: name
  defp member_name(_), do: ""

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp to_binary_data({:bytes, b}) when is_binary(b), do: b
  defp to_binary_data({:bytearray, b}) when is_binary(b), do: b
  defp to_binary_data(b) when is_binary(b), do: b
  defp to_binary_data(_), do: {:exception, "TypeError: data must be str or bytes"}

  defp now_tuple do
    {{y, m, d}, {hh, mm, ss}} = :calendar.local_time()
    {y, m, d, hh, mm, ss}
  end
end
