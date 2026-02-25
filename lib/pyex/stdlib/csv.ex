defmodule Pyex.Stdlib.Csv do
  @moduledoc """
  Python `csv` module for reading and writing CSV data.

  Provides `csv.reader`, `csv.DictReader`, `csv.writer`, `csv.DictWriter`,
  and the quoting constants `QUOTE_ALL`, `QUOTE_MINIMAL`, `QUOTE_NONNUMERIC`,
  and `QUOTE_NONE`.

  `csv.reader(iterable)` accepts any iterable of strings (a list of strings
  or an open file handle). Returns a list of rows where each row is a list
  of field strings.

  `csv.writer(file)` accepts an open file handle or no argument. When given
  a file handle, `writerow(row)` writes the formatted CSV line to the file
  and returns it. Without a file handle, `writerow(row)` simply returns the
  formatted string.

  Supports the `delimiter` and `quotechar` keyword arguments on reader/writer.
  """

  @behaviour Pyex.Stdlib.Module

  @quote_minimal 0
  @quote_all 1
  @quote_nonnumeric 2
  @quote_none 3

  @doc """
  Returns the module value map with all csv functions and constants.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "reader" => {:builtin_kw, &do_reader/2},
      "writer" => {:builtin_kw, &do_writer/2},
      "DictReader" => {:builtin_kw, &do_dict_reader/2},
      "DictWriter" => {:builtin_kw, &do_dict_writer/2},
      "QUOTE_ALL" => @quote_all,
      "QUOTE_MINIMAL" => @quote_minimal,
      "QUOTE_NONNUMERIC" => @quote_nonnumeric,
      "QUOTE_NONE" => @quote_none
    }
  end

  @spec do_reader([Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) ::
          Pyex.Interpreter.pyvalue()
  defp do_reader([{:py_list, reversed, _}], kwargs),
    do: do_reader([Enum.reverse(reversed)], kwargs)

  defp do_reader([lines], kwargs) when is_list(lines) do
    delimiter = Map.get(kwargs, "delimiter", ",")
    quotechar = Map.get(kwargs, "quotechar", "\"")
    parse_lines(lines, delimiter, quotechar)
  end

  defp do_reader([{:file_handle, id}], kwargs) do
    delimiter = Map.get(kwargs, "delimiter", ",")
    quotechar = Map.get(kwargs, "quotechar", "\"")

    {:io_call,
     fn env, ctx ->
       case Pyex.Ctx.read_handle(ctx, id) do
         {:ok, content, ctx} ->
           lines = split_file_lines(content)
           {parse_lines(lines, delimiter, quotechar), env, ctx}

         {:error, msg} ->
           {{:exception, msg}, env, ctx}
       end
     end}
  end

  defp do_reader(_, _kwargs) do
    {:exception,
     "TypeError: csv.reader() argument 1 must be an iterable of strings or a file object"}
  end

  @spec do_dict_reader([Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) ::
          Pyex.Interpreter.pyvalue()
  defp do_dict_reader([{:py_list, reversed, _}], kwargs),
    do: do_dict_reader([Enum.reverse(reversed)], kwargs)

  defp do_dict_reader([lines], kwargs) when is_list(lines) do
    delimiter = Map.get(kwargs, "delimiter", ",")
    quotechar = Map.get(kwargs, "quotechar", "\"")
    fieldnames = Map.get(kwargs, "fieldnames")
    restkey = Map.get(kwargs, "restkey")
    restval = Map.get(kwargs, "restval")
    build_dict_reader(lines, delimiter, quotechar, fieldnames, restkey, restval)
  end

  defp do_dict_reader([{:file_handle, id}], kwargs) do
    delimiter = Map.get(kwargs, "delimiter", ",")
    quotechar = Map.get(kwargs, "quotechar", "\"")
    fieldnames = Map.get(kwargs, "fieldnames")
    restkey = Map.get(kwargs, "restkey")
    restval = Map.get(kwargs, "restval")

    {:io_call,
     fn env, ctx ->
       case Pyex.Ctx.read_handle(ctx, id) do
         {:ok, content, ctx} ->
           lines = split_file_lines(content)

           {build_dict_reader(lines, delimiter, quotechar, fieldnames, restkey, restval), env,
            ctx}

         {:error, msg} ->
           {{:exception, msg}, env, ctx}
       end
     end}
  end

  defp do_dict_reader(_, _kwargs) do
    {:exception,
     "TypeError: csv.DictReader() argument 1 must be an iterable of strings or a file object"}
  end

  @spec build_dict_reader(
          [Pyex.Interpreter.pyvalue()],
          String.t(),
          String.t(),
          Pyex.Interpreter.pyvalue(),
          Pyex.Interpreter.pyvalue(),
          Pyex.Interpreter.pyvalue()
        ) :: Pyex.Interpreter.pyvalue()
  defp build_dict_reader(lines, delimiter, quotechar, fieldnames, restkey, restval) do
    case fieldnames do
      nil ->
        do_dict_reader_auto_headers(lines, delimiter, quotechar, restkey, restval)

      {:py_list, reversed, _} ->
        do_dict_reader_with_headers(
          lines,
          Enum.reverse(reversed),
          delimiter,
          quotechar,
          restkey,
          restval
        )

      names when is_list(names) ->
        do_dict_reader_with_headers(lines, names, delimiter, quotechar, restkey, restval)

      _ ->
        {:exception, "TypeError: fieldnames must be a list of strings"}
    end
  end

  @spec do_dict_reader_auto_headers(
          [Pyex.Interpreter.pyvalue()],
          String.t(),
          String.t(),
          Pyex.Interpreter.pyvalue(),
          Pyex.Interpreter.pyvalue()
        ) :: Pyex.Interpreter.pyvalue()
  defp do_dict_reader_auto_headers([], _delimiter, _quotechar, _restkey, _restval), do: []

  defp do_dict_reader_auto_headers(
         [header_line | data_lines],
         delimiter,
         quotechar,
         restkey,
         restval
       ) do
    case parse_csv_line(header_line, delimiter, quotechar) do
      {:exception, _} = err ->
        err

      headers ->
        do_dict_reader_with_headers(data_lines, headers, delimiter, quotechar, restkey, restval)
    end
  end

  @spec do_dict_reader_with_headers(
          [Pyex.Interpreter.pyvalue()],
          [String.t()],
          String.t(),
          String.t(),
          Pyex.Interpreter.pyvalue(),
          Pyex.Interpreter.pyvalue()
        ) :: Pyex.Interpreter.pyvalue()
  defp do_dict_reader_with_headers(lines, headers, delimiter, quotechar, restkey, restval) do
    lines
    |> Enum.map(fn
      line when is_binary(line) ->
        case parse_csv_line(line, delimiter, quotechar) do
          {:exception, _} = err ->
            err

          fields ->
            row_to_dict(headers, fields, restkey, restval)
        end

      _ ->
        {:exception, "csv.Error: iterator should return strings"}
    end)
    |> collect_or_exception()
  end

  @spec row_to_dict(
          [String.t()],
          [String.t()],
          Pyex.Interpreter.pyvalue(),
          Pyex.Interpreter.pyvalue()
        ) ::
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
  defp row_to_dict(headers, fields, restkey, restval) do
    header_count = length(headers)
    field_count = length(fields)

    base =
      Enum.zip(headers, fields)
      |> Map.new()

    cond do
      field_count > header_count ->
        extra = Enum.drop(fields, header_count)
        Map.put(base, restkey, extra)

      field_count < header_count ->
        missing_headers = Enum.drop(headers, field_count)
        Enum.reduce(missing_headers, base, fn h, acc -> Map.put(acc, h, restval) end)

      true ->
        base
    end
  end

  @spec do_writer([Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) ::
          Pyex.Interpreter.pyvalue()
  defp do_writer([], kwargs) do
    build_writer(nil, kwargs)
  end

  defp do_writer([{:file_handle, id}], kwargs) do
    build_writer(id, kwargs)
  end

  defp do_writer(_, _kwargs) do
    {:exception, "TypeError: csv.writer() argument 1 must be a file object"}
  end

  @spec build_writer(non_neg_integer() | nil, %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) ::
          Pyex.Interpreter.pyvalue()
  defp build_writer(handle_id, kwargs) do
    delimiter = Map.get(kwargs, "delimiter", ",")
    quotechar = Map.get(kwargs, "quotechar", "\"")
    quoting = Map.get(kwargs, "quoting", @quote_minimal)
    lineterminator = Map.get(kwargs, "lineterminator", "\r\n")

    writerow_fn = fn
      [{:py_list, reversed, _}] ->
        format_and_maybe_write(
          Enum.reverse(reversed),
          handle_id,
          delimiter,
          quotechar,
          quoting,
          lineterminator
        )

      [row] when is_list(row) ->
        format_and_maybe_write(row, handle_id, delimiter, quotechar, quoting, lineterminator)

      [{:tuple, items}] ->
        format_and_maybe_write(items, handle_id, delimiter, quotechar, quoting, lineterminator)

      _ ->
        {:exception, "csv.Error: iterable expected"}
    end

    writerows_fn = fn
      [{:py_list, reversed, _}] ->
        do_writerows_fn = fn rows ->
          items_list =
            Enum.map(rows, fn
              {:py_list, r, _} -> Enum.reverse(r)
              row when is_list(row) -> row
              {:tuple, items} -> items
              _ -> :bad
            end)

          if Enum.any?(items_list, &(&1 == :bad)) do
            {:exception, "csv.Error: iterable expected"}
          else
            lines =
              Enum.map(items_list, fn items ->
                format_csv_row(items, delimiter, quotechar, quoting, lineterminator)
              end)

            combined = Enum.join(lines)

            case handle_id do
              nil ->
                combined

              id ->
                {:ctx_call,
                 fn env, ctx ->
                   case Pyex.Ctx.write_handle(ctx, id, combined) do
                     {:ok, ctx} -> {combined, env, ctx}
                     {:error, msg} -> {{:exception, msg}, env, ctx}
                   end
                 end}
            end
          end
        end

        do_writerows_fn.(Enum.reverse(reversed))

      [rows] when is_list(rows) ->
        items_list =
          Enum.map(rows, fn
            {:py_list, r, _} -> Enum.reverse(r)
            row when is_list(row) -> row
            {:tuple, items} -> items
            _ -> :bad
          end)

        if Enum.any?(items_list, &(&1 == :bad)) do
          {:exception, "csv.Error: iterable expected"}
        else
          lines =
            Enum.map(items_list, fn items ->
              format_csv_row(items, delimiter, quotechar, quoting, lineterminator)
            end)

          combined = Enum.join(lines)

          case handle_id do
            nil ->
              combined

            id ->
              {:ctx_call,
               fn env, ctx ->
                 case Pyex.Ctx.write_handle(ctx, id, combined) do
                   {:ok, ctx} -> {combined, env, ctx}
                   {:error, msg} -> {{:exception, msg}, env, ctx}
                 end
               end}
          end
        end

      _ ->
        {:exception, "csv.Error: iterable expected"}
    end

    %{
      "writerow" => {:builtin, writerow_fn},
      "writerows" => {:builtin, writerows_fn}
    }
  end

  @spec format_and_maybe_write(
          [Pyex.Interpreter.pyvalue()],
          non_neg_integer() | nil,
          String.t(),
          String.t(),
          integer(),
          String.t()
        ) :: Pyex.Interpreter.pyvalue()
  defp format_and_maybe_write(items, handle_id, delimiter, quotechar, quoting, lineterminator) do
    line = format_csv_row(items, delimiter, quotechar, quoting, lineterminator)

    case handle_id do
      nil ->
        line

      id ->
        {:ctx_call,
         fn env, ctx ->
           case Pyex.Ctx.write_handle(ctx, id, line) do
             {:ok, ctx} -> {line, env, ctx}
             {:error, msg} -> {{:exception, msg}, env, ctx}
           end
         end}
    end
  end

  @spec do_dict_writer([Pyex.Interpreter.pyvalue()], %{
          optional(String.t()) => Pyex.Interpreter.pyvalue()
        }) ::
          Pyex.Interpreter.pyvalue()
  defp do_dict_writer([{:py_list, reversed, _}], kwargs),
    do: do_dict_writer([Enum.reverse(reversed)], kwargs)

  defp do_dict_writer([{:file_handle, _} = fh, {:py_list, reversed, _}], kwargs),
    do: do_dict_writer([fh, Enum.reverse(reversed)], kwargs)

  defp do_dict_writer([{:py_list, reversed, _}, {:file_handle, _} = fh], kwargs),
    do: do_dict_writer([Enum.reverse(reversed), fh], kwargs)

  defp do_dict_writer([fieldnames], kwargs) when is_list(fieldnames) do
    build_dict_writer(nil, fieldnames, kwargs)
  end

  defp do_dict_writer([{:file_handle, _} = fh, fieldnames], kwargs) when is_list(fieldnames) do
    build_dict_writer(fh, fieldnames, kwargs)
  end

  defp do_dict_writer([fieldnames, {:file_handle, _} = fh], kwargs) when is_list(fieldnames) do
    build_dict_writer(fh, fieldnames, kwargs)
  end

  defp do_dict_writer(_, _kwargs) do
    {:exception, "TypeError: csv.DictWriter() requires a file object and a fieldnames list"}
  end

  @spec build_dict_writer(
          {:file_handle, non_neg_integer()} | nil,
          [String.t()],
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()}
        ) :: Pyex.Interpreter.pyvalue()
  defp build_dict_writer(file_handle, fieldnames, kwargs) do
    delimiter = Map.get(kwargs, "delimiter", ",")
    quotechar = Map.get(kwargs, "quotechar", "\"")
    quoting = Map.get(kwargs, "quoting", @quote_minimal)
    lineterminator = Map.get(kwargs, "lineterminator", "\r\n")
    restval = Map.get(kwargs, "restval", "")
    extrasaction = Map.get(kwargs, "extrasaction", "raise")

    handle_id =
      case file_handle do
        {:file_handle, id} -> id
        nil -> nil
      end

    writeheader_fn = fn
      [] ->
        format_and_maybe_write(
          fieldnames,
          handle_id,
          delimiter,
          quotechar,
          quoting,
          lineterminator
        )
    end

    writerow_fn = fn
      [%{} = dict] ->
        case check_extras(dict, fieldnames, extrasaction) do
          {:exception, _} = err ->
            err

          :ok ->
            values =
              Enum.map(fieldnames, fn name ->
                Map.get(dict, name, restval)
              end)

            format_and_maybe_write(
              values,
              handle_id,
              delimiter,
              quotechar,
              quoting,
              lineterminator
            )
        end

      _ ->
        {:exception, "csv.Error: dict expected"}
    end

    writerows_fn = fn
      [{:py_list, _reversed, _} = py_list] ->
        rows = Pyex.Interpreter.Helpers.to_python_view(py_list)

        result =
          rows
          |> Enum.map(fn
            {:py_list, _, _} = inner ->
              dict_rows = Pyex.Interpreter.Helpers.to_python_view(inner)

              case check_extras(dict_rows, fieldnames, extrasaction) do
                {:exception, _} = err -> err
                :ok -> Enum.map(fieldnames, fn name -> Map.get(dict_rows, name, restval) end)
              end

            %{} = dict ->
              case check_extras(dict, fieldnames, extrasaction) do
                {:exception, _} = err -> err
                :ok -> Enum.map(fieldnames, fn name -> Map.get(dict, name, restval) end)
              end

            _ ->
              {:exception, "csv.Error: dict expected"}
          end)

        case Enum.find(result, &match?({:exception, _}, &1)) do
          {:exception, _} = err ->
            err

          nil ->
            lines =
              Enum.map(result, fn values ->
                format_csv_row(values, delimiter, quotechar, quoting, lineterminator)
              end)

            combined = Enum.join(lines)

            case handle_id do
              nil ->
                combined

              id ->
                {:ctx_call,
                 fn env, ctx ->
                   case Pyex.Ctx.write_handle(ctx, id, combined) do
                     {:ok, ctx} -> {combined, env, ctx}
                     {:error, msg} -> {{:exception, msg}, env, ctx}
                   end
                 end}
            end
        end

      [rows] when is_list(rows) ->
        result =
          rows
          |> Enum.map(fn
            %{} = dict ->
              case check_extras(dict, fieldnames, extrasaction) do
                {:exception, _} = err ->
                  err

                :ok ->
                  Enum.map(fieldnames, fn name ->
                    Map.get(dict, name, restval)
                  end)
              end

            _ ->
              {:exception, "csv.Error: dict expected"}
          end)

        case Enum.find(result, &match?({:exception, _}, &1)) do
          {:exception, _} = err ->
            err

          nil ->
            lines =
              Enum.map(result, fn values ->
                format_csv_row(values, delimiter, quotechar, quoting, lineterminator)
              end)

            combined = Enum.join(lines)

            case handle_id do
              nil ->
                combined

              id ->
                {:ctx_call,
                 fn env, ctx ->
                   case Pyex.Ctx.write_handle(ctx, id, combined) do
                     {:ok, ctx} -> {combined, env, ctx}
                     {:error, msg} -> {{:exception, msg}, env, ctx}
                   end
                 end}
            end
        end

      _ ->
        {:exception, "csv.Error: iterable expected"}
    end

    %{
      "writeheader" => {:builtin, writeheader_fn},
      "writerow" => {:builtin, writerow_fn},
      "writerows" => {:builtin, writerows_fn}
    }
  end

  @spec check_extras(
          %{optional(String.t()) => Pyex.Interpreter.pyvalue()},
          [String.t()],
          String.t()
        ) ::
          :ok | {:exception, String.t()}
  defp check_extras(dict, fieldnames, extrasaction) do
    if extrasaction == "raise" do
      field_set = MapSet.new(fieldnames)

      extras =
        dict
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(field_set, &1))

      case extras do
        [] ->
          :ok

        keys ->
          {:exception,
           "ValueError: dict contains fields not in fieldnames: #{Enum.join(keys, ", ")}"}
      end
    else
      :ok
    end
  end

  @spec format_csv_row(
          [Pyex.Interpreter.pyvalue()],
          String.t(),
          String.t(),
          integer(),
          String.t()
        ) :: String.t()
  defp format_csv_row(fields, delimiter, quotechar, quoting, lineterminator) do
    formatted =
      fields
      |> Enum.map(&format_field(&1, delimiter, quotechar, quoting))
      |> Enum.join(delimiter)

    formatted <> lineterminator
  end

  @spec format_field(Pyex.Interpreter.pyvalue(), String.t(), String.t(), integer()) :: String.t()
  defp format_field(value, delimiter, quotechar, quoting) do
    str = to_string_value(value)

    case quoting do
      @quote_all ->
        quote_field(str, quotechar)

      @quote_nonnumeric ->
        if is_number(value) do
          str
        else
          quote_field(str, quotechar)
        end

      @quote_none ->
        str

      _ ->
        if needs_quoting?(str, delimiter, quotechar) do
          quote_field(str, quotechar)
        else
          str
        end
    end
  end

  @spec to_string_value(Pyex.Interpreter.pyvalue()) :: String.t()
  defp to_string_value(nil), do: ""
  defp to_string_value(s) when is_binary(s), do: s
  defp to_string_value(true), do: "True"
  defp to_string_value(false), do: "False"
  defp to_string_value(n) when is_integer(n), do: Integer.to_string(n)

  defp to_string_value(f) when is_float(f) do
    if f == Float.round(f, 0) and abs(f) < 1.0e15 do
      :erlang.float_to_binary(f, [:compact, decimals: 1])
    else
      :erlang.float_to_binary(f, [:compact, decimals: 12])
    end
  end

  defp to_string_value(_other), do: ""

  @spec needs_quoting?(String.t(), String.t(), String.t()) :: boolean()
  defp needs_quoting?(str, delimiter, quotechar) do
    String.contains?(str, delimiter) or
      String.contains?(str, quotechar) or
      String.contains?(str, "\n") or
      String.contains?(str, "\r")
  end

  @spec quote_field(String.t(), String.t()) :: String.t()
  defp quote_field(str, quotechar) do
    escaped = String.replace(str, quotechar, quotechar <> quotechar)
    quotechar <> escaped <> quotechar
  end

  @spec parse_lines([String.t()], String.t(), String.t()) ::
          [Pyex.Interpreter.pyvalue()] | {:exception, String.t()}
  defp parse_lines(lines, delimiter, quotechar) do
    Enum.map(lines, fn
      line when is_binary(line) -> parse_csv_line(line, delimiter, quotechar)
      _ -> {:exception, "csv.Error: iterator should return strings"}
    end)
    |> collect_or_exception()
  end

  @spec split_file_lines(String.t()) :: [String.t()]
  defp split_file_lines(content) do
    content
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.reject(&(&1 == ""))
  end

  @spec parse_csv_line(String.t(), String.t(), String.t()) ::
          [String.t()] | {:exception, String.t()}
  defp parse_csv_line(line, delimiter, quotechar) do
    line =
      String.trim_trailing(line, "\r\n")
      |> String.trim_trailing("\n")
      |> String.trim_trailing("\r")

    parse_fields(line, delimiter, quotechar, [], "")
  end

  @spec parse_fields(String.t(), String.t(), String.t(), [String.t()], String.t()) ::
          [String.t()] | {:exception, String.t()}
  defp parse_fields("", _delimiter, _quotechar, acc, current) do
    Enum.reverse([current | acc])
  end

  defp parse_fields(input, delimiter, quotechar, acc, current) do
    delim_size = byte_size(delimiter)
    quote_size = byte_size(quotechar)

    cond do
      current == "" and String.starts_with?(input, quotechar) ->
        rest = binary_part(input, quote_size, byte_size(input) - quote_size)
        parse_quoted_field(rest, delimiter, quotechar, acc)

      String.starts_with?(input, delimiter) ->
        rest = binary_part(input, delim_size, byte_size(input) - delim_size)
        parse_fields(rest, delimiter, quotechar, [current | acc], "")

      true ->
        <<ch::utf8, rest::binary>> = input
        parse_fields(rest, delimiter, quotechar, acc, current <> <<ch::utf8>>)
    end
  end

  @spec parse_quoted_field(String.t(), String.t(), String.t(), [String.t()]) ::
          [String.t()] | {:exception, String.t()}
  defp parse_quoted_field(input, delimiter, quotechar, acc) do
    parse_quoted_content(input, delimiter, quotechar, acc, "")
  end

  @spec parse_quoted_content(String.t(), String.t(), String.t(), [String.t()], String.t()) ::
          [String.t()] | {:exception, String.t()}
  defp parse_quoted_content("", _delimiter, _quotechar, _acc, _current) do
    {:exception, "csv.Error: unexpected end of data in quoted field"}
  end

  defp parse_quoted_content(input, delimiter, quotechar, acc, current) do
    quote_size = byte_size(quotechar)
    doubled_quote = quotechar <> quotechar
    doubled_size = byte_size(doubled_quote)

    cond do
      String.starts_with?(input, doubled_quote) ->
        rest = binary_part(input, doubled_size, byte_size(input) - doubled_size)
        parse_quoted_content(rest, delimiter, quotechar, acc, current <> quotechar)

      String.starts_with?(input, quotechar) ->
        rest = binary_part(input, quote_size, byte_size(input) - quote_size)
        after_quoted_field(rest, delimiter, quotechar, acc, current)

      true ->
        <<ch::utf8, rest::binary>> = input
        parse_quoted_content(rest, delimiter, quotechar, acc, current <> <<ch::utf8>>)
    end
  end

  @spec after_quoted_field(String.t(), String.t(), String.t(), [String.t()], String.t()) ::
          [String.t()] | {:exception, String.t()}
  defp after_quoted_field("", _delimiter, _quotechar, acc, current) do
    Enum.reverse([current | acc])
  end

  defp after_quoted_field(input, delimiter, quotechar, acc, current) do
    delim_size = byte_size(delimiter)

    if String.starts_with?(input, delimiter) do
      rest = binary_part(input, delim_size, byte_size(input) - delim_size)
      parse_fields(rest, delimiter, quotechar, [current | acc], "")
    else
      {:exception, "csv.Error: unexpected character after close quote"}
    end
  end

  @spec collect_or_exception([Pyex.Interpreter.pyvalue()]) ::
          [Pyex.Interpreter.pyvalue()] | {:exception, String.t()}
  defp collect_or_exception(results) do
    case Enum.find(results, fn
           {:exception, _} -> true
           _ -> false
         end) do
      {:exception, _} = err -> err
      nil -> results
    end
  end
end
