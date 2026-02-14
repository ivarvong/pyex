defmodule Pyex.Lexer do
  @moduledoc """
  NimbleParsec-based tokenizer for a subset of Python 3.

  Produces a flat list of tokens that the parser consumes.
  Handles significant whitespace by emitting :indent, :dedent,
  and :newline tokens. Each value-carrying token includes a
  line number for error reporting.
  """

  import NimbleParsec

  @type operator ::
          :plus
          | :minus
          | :star
          | :slash
          | :floor_div
          | :percent
          | :double_star
          | :plus_assign
          | :minus_assign
          | :star_assign
          | :slash_assign
          | :floor_div_assign
          | :percent_assign
          | :double_star_assign
          | :lparen
          | :rparen
          | :lbracket
          | :rbracket
          | :lbrace
          | :rbrace
          | :comma
          | :walrus
          | :colon
          | :dot
          | :eq
          | :neq
          | :lt
          | :gt
          | :lte
          | :gte
          | :assign
          | :at
          | :amp
          | :pipe
          | :caret
          | :tilde
          | :lshift
          | :rshift
          | :amp_assign
          | :pipe_assign
          | :caret_assign
          | :lshift_assign
          | :rshift_assign

  @type line :: pos_integer()

  @type token ::
          {:integer, line(), integer()}
          | {:float, line(), float()}
          | {:string, line(), String.t()}
          | {:fstring, line(), String.t()}
          | {:name, line(), String.t()}
          | {:keyword, line(), String.t()}
          | {:op, line(), operator()}
          | :newline
          | :indent
          | :dedent

  @typep raw_token ::
           {:integer, integer()}
           | {:float, float()}
           | {:string, String.t()}
           | {:fstring, String.t()}
           | {:name, String.t()}
           | {:keyword, String.t()}
           | {:op, operator()}
           | {:newline_raw, non_neg_integer() | {non_neg_integer(), non_neg_integer()}}

  whitespace = ignore(ascii_string([?\s, ?\t], min: 1))

  newline =
    ascii_char([?\n])
    |> repeat(ascii_char([?\n, ?\s, ?\t]))
    |> reduce(:__newline__)
    |> unwrap_and_tag(:newline_raw)

  hex_integer =
    string("0x")
    |> ascii_string([?0..?9, ?a..?f, ?A..?F, ?_], min: 1)
    |> reduce(:__hex_integer__)
    |> unwrap_and_tag(:integer)

  octal_integer =
    string("0o")
    |> ascii_string([?0..?7, ?_], min: 1)
    |> reduce(:__octal_integer__)
    |> unwrap_and_tag(:integer)

  binary_integer =
    string("0b")
    |> ascii_string([?0, ?1, ?_], min: 1)
    |> reduce(:__binary_integer__)
    |> unwrap_and_tag(:integer)

  integer =
    ascii_char([?0..?9])
    |> optional(ascii_string([?0..?9, ?_], min: 1))
    |> reduce(:__integer__)
    |> unwrap_and_tag(:integer)

  exponent_suffix =
    ascii_char([?e, ?E])
    |> optional(ascii_char([?+, ?-]))
    |> ascii_string([?0..?9], min: 1)

  float_literal =
    ascii_char([?0..?9])
    |> optional(ascii_string([?0..?9, ?_], min: 1))
    |> string(".")
    |> ascii_char([?0..?9])
    |> optional(ascii_string([?0..?9, ?_], min: 1))
    |> optional(exponent_suffix)
    |> reduce(:__float__)
    |> unwrap_and_tag(:float)

  exponent_float =
    ascii_char([?0..?9])
    |> optional(ascii_string([?0..?9, ?_], min: 1))
    |> concat(exponent_suffix)
    |> reduce(:__exponent_float__)
    |> unwrap_and_tag(:float)

  hex_char = ascii_char([?0..?9, ?a..?f, ?A..?F])

  hex_2_escape =
    ignore(string("\\x"))
    |> concat(hex_char)
    |> concat(hex_char)
    |> reduce(:__hex2_escape__)

  unicode_4_escape =
    ignore(string("\\u"))
    |> concat(hex_char)
    |> concat(hex_char)
    |> concat(hex_char)
    |> concat(hex_char)
    |> reduce(:__hex4_escape__)

  unicode_8_escape =
    ignore(string("\\U"))
    |> concat(hex_char)
    |> concat(hex_char)
    |> concat(hex_char)
    |> concat(hex_char)
    |> concat(hex_char)
    |> concat(hex_char)
    |> concat(hex_char)
    |> concat(hex_char)
    |> reduce(:__hex8_escape__)

  common_escapes = [
    string("\\n") |> replace(?\n),
    string("\\t") |> replace(?\t),
    string("\\r") |> replace(?\r),
    string("\\0") |> replace(0),
    string("\\a") |> replace(?\a),
    string("\\b") |> replace(?\b),
    string("\\f") |> replace(?\f),
    string("\\v") |> replace(?\v),
    string("\\\\") |> replace(?\\),
    unicode_8_escape,
    unicode_4_escape,
    hex_2_escape
  ]

  triple_double_string =
    ignore(string(~S["""]))
    |> repeat(
      choice(
        [string("\\\"") |> replace(?")] ++
          common_escapes ++
          [
            string("\\") |> concat(ascii_char([])) |> reduce(:__unknown_escape__),
            lookahead_not(string(~S["""])) |> ascii_char([])
          ]
      )
    )
    |> ignore(string(~S["""]))
    |> reduce(:__string__)
    |> unwrap_and_tag(:string)

  triple_single_string =
    ignore(string("'''"))
    |> repeat(
      choice(
        [string("\\'") |> replace(?')] ++
          common_escapes ++
          [
            string("\\") |> concat(ascii_char([])) |> reduce(:__unknown_escape__),
            lookahead_not(string("'''")) |> ascii_char([])
          ]
      )
    )
    |> ignore(string("'''"))
    |> reduce(:__string__)
    |> unwrap_and_tag(:string)

  fstring_triple_double =
    string(~S[f"""])
    |> repeat(
      choice(
        [string("\\\"") |> replace(?")] ++
          common_escapes ++
          [
            string("\\") |> concat(ascii_char([])) |> reduce(:__unknown_escape__),
            lookahead_not(string(~S["""])) |> ascii_char([])
          ]
      )
    )
    |> ignore(string(~S["""]))
    |> reduce(:__fstring_triple__)
    |> unwrap_and_tag(:fstring)

  fstring_triple_single =
    string("f'''")
    |> repeat(
      choice(
        [string("\\'") |> replace(?')] ++
          common_escapes ++
          [
            string("\\") |> concat(ascii_char([])) |> reduce(:__unknown_escape__),
            lookahead_not(string("'''")) |> ascii_char([])
          ]
      )
    )
    |> ignore(string("'''"))
    |> reduce(:__fstring_triple__)
    |> unwrap_and_tag(:fstring)

  double_quoted_string =
    ignore(string("\""))
    |> repeat(
      choice(
        [string("\\\"") |> replace(?")] ++
          common_escapes ++
          [
            string("\\") |> concat(ascii_char(not: ?\n)) |> reduce(:__unknown_escape__),
            ascii_char(not: ?", not: ?\\, not: ?\n)
          ]
      )
    )
    |> ignore(string("\""))
    |> reduce(:__string__)
    |> unwrap_and_tag(:string)

  single_quoted_string =
    ignore(string("'"))
    |> repeat(
      choice(
        [string("\\'") |> replace(?')] ++
          common_escapes ++
          [
            string("\\") |> concat(ascii_char(not: ?\n)) |> reduce(:__unknown_escape__),
            ascii_char(not: ?', not: ?\\, not: ?\n)
          ]
      )
    )
    |> ignore(string("'"))
    |> reduce(:__string__)
    |> unwrap_and_tag(:string)

  fstring_double =
    string("f\"")
    |> repeat(
      choice(
        [string("\\\"") |> replace(?")] ++
          common_escapes ++
          [
            string("\\") |> concat(ascii_char(not: ?\n)) |> reduce(:__unknown_escape__),
            ascii_char(not: ?", not: ?\\, not: ?\n)
          ]
      )
    )
    |> ignore(string("\""))
    |> reduce(:__fstring__)
    |> unwrap_and_tag(:fstring)

  fstring_single =
    string("f'")
    |> repeat(
      choice(
        [string("\\'") |> replace(?')] ++
          common_escapes ++
          [
            string("\\") |> concat(ascii_char(not: ?\n)) |> reduce(:__unknown_escape__),
            ascii_char(not: ?', not: ?\\, not: ?\n)
          ]
      )
    )
    |> ignore(string("'"))
    |> reduce(:__fstring__)
    |> unwrap_and_tag(:fstring)

  raw_double_string =
    ignore(string(~S|r"|))
    |> repeat(
      choice([
        string("\\\"") |> reduce(:__raw_escape__),
        string("\\\\") |> reduce(:__raw_escape__),
        string("\\") |> concat(ascii_char(not: ?\n)) |> reduce(:__raw_escape__),
        ascii_char(not: ?", not: ?\n)
      ])
    )
    |> ignore(string("\""))
    |> reduce(:__string__)
    |> unwrap_and_tag(:string)

  raw_single_string =
    ignore(string("r'"))
    |> repeat(
      choice([
        string("\\'") |> reduce(:__raw_escape__),
        string("\\\\") |> reduce(:__raw_escape__),
        string("\\") |> concat(ascii_char(not: ?\n)) |> reduce(:__raw_escape__),
        ascii_char(not: ?', not: ?\n)
      ])
    )
    |> ignore(string("'"))
    |> reduce(:__string__)
    |> unwrap_and_tag(:string)

  identifier_or_keyword =
    ascii_char([?a..?z, ?A..?Z, ?_])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))
    |> reduce(:__identifier__)
    |> unwrap_and_tag(:name)

  double_star_assign = string("**=") |> replace(:double_star_assign)
  double_star = string("**") |> replace(:double_star)
  floor_div_assign = string("//=") |> replace(:floor_div_assign)
  floor_div = string("//") |> replace(:floor_div)
  plus_assign = string("+=") |> replace(:plus_assign)
  plus = string("+") |> replace(:plus)
  minus_assign = string("-=") |> replace(:minus_assign)
  minus = string("-") |> replace(:minus)
  star_assign = string("*=") |> replace(:star_assign)
  star = string("*") |> replace(:star)
  slash_assign = string("/=") |> replace(:slash_assign)
  slash = string("/") |> replace(:slash)
  percent_assign = string("%=") |> replace(:percent_assign)
  percent = string("%") |> replace(:percent)
  lparen = string("(") |> replace(:lparen)
  rparen = string(")") |> replace(:rparen)
  lbracket = string("[") |> replace(:lbracket)
  rbracket = string("]") |> replace(:rbracket)
  lbrace = string("{") |> replace(:lbrace)
  rbrace = string("}") |> replace(:rbrace)
  comma = string(",") |> replace(:comma)
  walrus = string(":=") |> replace(:walrus)
  colon = string(":") |> replace(:colon)
  dot = string(".") |> replace(:dot)
  eq = string("==") |> replace(:eq)
  neq = string("!=") |> replace(:neq)
  lshift_assign = string("<<=") |> replace(:lshift_assign)
  rshift_assign = string(">>=") |> replace(:rshift_assign)
  lshift = string("<<") |> replace(:lshift)
  rshift = string(">>") |> replace(:rshift)
  lte = string("<=") |> replace(:lte)
  gte = string(">=") |> replace(:gte)
  lt = string("<") |> replace(:lt)
  gt = string(">") |> replace(:gt)
  amp_assign = string("&=") |> replace(:amp_assign)
  amp = string("&") |> replace(:amp)
  pipe_assign = string("|=") |> replace(:pipe_assign)
  pipe = string("|") |> replace(:pipe)
  caret_assign = string("^=") |> replace(:caret_assign)
  caret = string("^") |> replace(:caret)
  tilde = string("~") |> replace(:tilde)
  assign = string("=") |> replace(:assign)
  at = string("@") |> replace(:at)

  operator =
    choice([
      double_star_assign,
      double_star,
      floor_div_assign,
      floor_div,
      lshift_assign,
      rshift_assign,
      lshift,
      rshift,
      eq,
      neq,
      lte,
      gte,
      lt,
      gt,
      plus_assign,
      plus,
      minus_assign,
      minus,
      star_assign,
      star,
      slash_assign,
      slash,
      percent_assign,
      percent,
      amp_assign,
      amp,
      pipe_assign,
      pipe,
      caret_assign,
      caret,
      tilde,
      lparen,
      rparen,
      lbracket,
      rbracket,
      lbrace,
      rbrace,
      comma,
      walrus,
      colon,
      dot,
      assign,
      at
    ])
    |> unwrap_and_tag(:op)

  token =
    choice([
      newline,
      whitespace,
      fstring_triple_double,
      fstring_triple_single,
      triple_double_string,
      triple_single_string,
      fstring_double,
      fstring_single,
      raw_double_string,
      raw_single_string,
      double_quoted_string,
      single_quoted_string,
      hex_integer,
      octal_integer,
      binary_integer,
      float_literal,
      exponent_float,
      integer,
      identifier_or_keyword,
      operator
    ])

  @doc false
  defparsec(:tokenize_raw, repeat(token) |> eos())

  @keywords ~w(def return if elif else and or not True False None while for in break continue pass import from try except finally raise as is lambda del assert global nonlocal class with yield async await)

  @doc """
  Tokenizes a Python source string into a list of tokens.

  Returns `{:ok, tokens}` or `{:error, message}`.
  """
  @spec tokenize(String.t()) :: {:ok, [token()]} | {:error, String.t()}
  def tokenize(source) do
    if not String.valid?(source) do
      {:error, "SyntaxError: source contains invalid UTF-8"}
    else
      source = String.replace(source, "\r\n", "\n")
      source = String.replace(source, "\r", "\n")

      with {:ok, source} <- strip_comments(source),
           source = join_continued_lines(source),
           {:ok, source} <- replace_semicolons(source),
           source = String.trim_trailing(source) do
        case tokenize_raw(source) do
          {:ok, raw_tokens, "", _, _, _} ->
            tokens =
              raw_tokens
              |> rewrite_keywords()
              |> assign_lines()

            case detect_unsupported_syntax(tokens) do
              :ok ->
                tokens =
                  tokens
                  |> suppress_bracketed_newlines()
                  |> process_indentation()

                {:ok, tokens}

              {:error, _} = err ->
                err
            end

          {:error, message, rest, _, _, _} ->
            {:error, "Lexer error: #{message} near: #{String.slice(rest, 0, 20)}"}
        end
      end
    end
  end

  @spec join_continued_lines(String.t()) :: String.t()
  defp join_continued_lines(source) do
    String.replace(source, "\\\n", "")
  end

  @spec replace_semicolons(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp replace_semicolons(source), do: replace_semicolons(source, <<>>)

  @spec replace_semicolons(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp replace_semicolons(<<>>, acc), do: {:ok, acc}

  defp replace_semicolons(<<"r\"", rest::binary>>, acc) do
    case consume_string(rest, ?") do
      {:ok, rest, content} ->
        replace_semicolons(rest, <<acc::binary, "r\"", content::binary, ?">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated string literal"}
    end
  end

  defp replace_semicolons(<<"r'", rest::binary>>, acc) do
    case consume_string(rest, ?') do
      {:ok, rest, content} ->
        replace_semicolons(rest, <<acc::binary, "r'", content::binary, ?'>>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated string literal"}
    end
  end

  defp replace_semicolons(<<"f\"\"\"", rest::binary>>, acc) do
    case consume_triple(rest, ?") do
      {:ok, rest, content} ->
        replace_semicolons(rest, <<acc::binary, "f\"\"\"", content::binary, "\"\"\"">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated triple-quoted string literal"}
    end
  end

  defp replace_semicolons(<<"f'''", rest::binary>>, acc) do
    case consume_triple(rest, ?') do
      {:ok, rest, content} ->
        replace_semicolons(rest, <<acc::binary, "f'''", content::binary, "'''">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated triple-quoted string literal"}
    end
  end

  defp replace_semicolons(<<"f\"", rest::binary>>, acc) do
    case consume_string(rest, ?") do
      {:ok, rest, content} ->
        replace_semicolons(rest, <<acc::binary, "f\"", content::binary, ?">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated string literal"}
    end
  end

  defp replace_semicolons(<<"f'", rest::binary>>, acc) do
    case consume_string(rest, ?') do
      {:ok, rest, content} ->
        replace_semicolons(rest, <<acc::binary, "f'", content::binary, ?'>>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated string literal"}
    end
  end

  defp replace_semicolons(<<"\"\"\"", rest::binary>>, acc) do
    case consume_triple(rest, ?") do
      {:ok, rest, content} ->
        replace_semicolons(rest, <<acc::binary, "\"\"\"", content::binary, "\"\"\"">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated triple-quoted string literal"}
    end
  end

  defp replace_semicolons(<<"'''", rest::binary>>, acc) do
    case consume_triple(rest, ?') do
      {:ok, rest, content} ->
        replace_semicolons(rest, <<acc::binary, "'''", content::binary, "'''">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated triple-quoted string literal"}
    end
  end

  defp replace_semicolons(<<?", rest::binary>>, acc) do
    case consume_string(rest, ?") do
      {:ok, rest, content} ->
        replace_semicolons(rest, <<acc::binary, ?", content::binary, ?">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated string literal"}
    end
  end

  defp replace_semicolons(<<?', rest::binary>>, acc) do
    case consume_string(rest, ?') do
      {:ok, rest, content} ->
        replace_semicolons(rest, <<acc::binary, ?', content::binary, ?'>>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated string literal"}
    end
  end

  defp replace_semicolons(<<?;, rest::binary>>, acc) do
    indent = current_line_indent(acc)
    replace_semicolons(skip_horizontal_whitespace(rest), <<acc::binary, ?\n, indent::binary>>)
  end

  defp replace_semicolons(<<ch, rest::binary>>, acc) do
    replace_semicolons(rest, <<acc::binary, ch>>)
  end

  @spec current_line_indent(String.t()) :: String.t()
  defp current_line_indent(acc) do
    acc
    |> String.split("\n")
    |> List.last("")
    |> extract_leading_whitespace()
  end

  @spec extract_leading_whitespace(String.t()) :: String.t()
  defp extract_leading_whitespace(<<?\s, rest::binary>>),
    do: <<?\s, extract_leading_whitespace(rest)::binary>>

  defp extract_leading_whitespace(<<?\t, rest::binary>>),
    do: <<?\t, extract_leading_whitespace(rest)::binary>>

  defp extract_leading_whitespace(_), do: <<>>

  @spec skip_horizontal_whitespace(String.t()) :: String.t()
  defp skip_horizontal_whitespace(<<?\s, rest::binary>>), do: skip_horizontal_whitespace(rest)
  defp skip_horizontal_whitespace(<<?\t, rest::binary>>), do: skip_horizontal_whitespace(rest)
  defp skip_horizontal_whitespace(rest), do: rest

  @spec strip_comments(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp strip_comments(source) do
    strip_comments(source, <<>>)
  end

  @spec strip_comments(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp strip_comments(<<>>, acc), do: {:ok, acc}

  defp strip_comments(<<?#, rest::binary>>, acc) do
    {rest, _} = skip_to_newline(rest)
    strip_comments(rest, acc)
  end

  defp strip_comments(<<"r\"", rest::binary>>, acc) do
    case consume_string(rest, ?") do
      {:ok, rest, content} ->
        strip_comments(rest, <<acc::binary, "r\"", content::binary, ?">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated string literal"}
    end
  end

  defp strip_comments(<<"r'", rest::binary>>, acc) do
    case consume_string(rest, ?') do
      {:ok, rest, content} ->
        strip_comments(rest, <<acc::binary, "r'", content::binary, ?'>>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated string literal"}
    end
  end

  defp strip_comments(<<"f\"\"\"", rest::binary>>, acc) do
    case consume_triple(rest, ?") do
      {:ok, rest, content} ->
        strip_comments(rest, <<acc::binary, "f\"\"\"", content::binary, "\"\"\"">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated triple-quoted string literal"}
    end
  end

  defp strip_comments(<<"f'''", rest::binary>>, acc) do
    case consume_triple(rest, ?') do
      {:ok, rest, content} ->
        strip_comments(rest, <<acc::binary, "f'''", content::binary, "'''">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated triple-quoted string literal"}
    end
  end

  defp strip_comments(<<"f\"", rest::binary>>, acc) do
    case consume_string(rest, ?") do
      {:ok, rest, content} ->
        strip_comments(rest, <<acc::binary, "f\"", content::binary, ?">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated string literal"}
    end
  end

  defp strip_comments(<<"f'", rest::binary>>, acc) do
    case consume_string(rest, ?') do
      {:ok, rest, content} ->
        strip_comments(rest, <<acc::binary, "f'", content::binary, ?'>>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated string literal"}
    end
  end

  defp strip_comments(<<"\"\"\"", rest::binary>>, acc) do
    case consume_triple(rest, ?") do
      {:ok, rest, content} ->
        strip_comments(rest, <<acc::binary, "\"\"\"", content::binary, "\"\"\"">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated triple-quoted string literal"}
    end
  end

  defp strip_comments(<<"'''", rest::binary>>, acc) do
    case consume_triple(rest, ?') do
      {:ok, rest, content} ->
        strip_comments(rest, <<acc::binary, "'''", content::binary, "'''">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated triple-quoted string literal"}
    end
  end

  defp strip_comments(<<?", rest::binary>>, acc) do
    case consume_string(rest, ?") do
      {:ok, rest, content} ->
        strip_comments(rest, <<acc::binary, ?", content::binary, ?">>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated string literal"}
    end
  end

  defp strip_comments(<<?', rest::binary>>, acc) do
    case consume_string(rest, ?') do
      {:ok, rest, content} ->
        strip_comments(rest, <<acc::binary, ?', content::binary, ?'>>)

      {:error, :unterminated} ->
        {:error, "SyntaxError: unterminated string literal"}
    end
  end

  defp strip_comments(<<c, rest::binary>>, acc) do
    strip_comments(rest, <<acc::binary, c>>)
  end

  @spec skip_to_newline(String.t()) :: {String.t(), :ok}
  defp skip_to_newline(<<>>), do: {<<>>, :ok}
  defp skip_to_newline(<<?\n, _::binary>> = rest), do: {rest, :ok}
  defp skip_to_newline(<<_, rest::binary>>), do: skip_to_newline(rest)

  @spec consume_string(String.t(), char()) ::
          {:ok, String.t(), String.t()} | {:error, :unterminated}
  defp consume_string(rest, quote), do: consume_string(rest, quote, <<>>)

  @spec consume_string(String.t(), char(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :unterminated}
  defp consume_string(<<>>, _quote, _acc), do: {:error, :unterminated}
  defp consume_string(<<q, rest::binary>>, q, acc), do: {:ok, rest, acc}

  defp consume_string(<<?\\, c, rest::binary>>, quote, acc),
    do: consume_string(rest, quote, <<acc::binary, ?\\, c>>)

  defp consume_string(<<c, rest::binary>>, quote, acc),
    do: consume_string(rest, quote, <<acc::binary, c>>)

  @spec consume_triple(String.t(), char()) ::
          {:ok, String.t(), String.t()} | {:error, :unterminated}
  defp consume_triple(rest, quote), do: consume_triple(rest, quote, <<>>)

  @spec consume_triple(String.t(), char(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :unterminated}
  defp consume_triple(<<>>, _quote, _acc), do: {:error, :unterminated}

  defp consume_triple(<<q, q, q, rest::binary>>, q, acc), do: {:ok, rest, acc}

  defp consume_triple(<<?\\, c, rest::binary>>, quote, acc),
    do: consume_triple(rest, quote, <<acc::binary, ?\\, c>>)

  defp consume_triple(<<c, rest::binary>>, quote, acc),
    do: consume_triple(rest, quote, <<acc::binary, c>>)

  @spec detect_unsupported_syntax([raw_token() | token()]) :: :ok | {:error, String.t()}
  defp detect_unsupported_syntax(tokens), do: check_tokens(tokens)

  @spec check_tokens([raw_token() | token()]) :: :ok | {:error, String.t()}
  defp check_tokens([{:name, line, "b"}, {:string, _, _} | _]) do
    {:error,
     "NotImplementedError: bytes literals (b\"...\") are not supported. " <>
       "Use strings instead (line #{line})"}
  end

  defp check_tokens([{:name, line, "rb"}, {:string, _, _} | _]) do
    {:error,
     "NotImplementedError: bytes literals (rb\"...\") are not supported. " <>
       "Use strings instead (line #{line})"}
  end

  defp check_tokens([{:name, line, "br"}, {:string, _, _} | _]) do
    {:error,
     "NotImplementedError: bytes literals (br\"...\") are not supported. " <>
       "Use strings instead (line #{line})"}
  end

  defp check_tokens([{:integer, line, _}, {:name, _, suffix} | _])
       when suffix in ["j", "J"] do
    {:error,
     "NotImplementedError: complex number literals (e.g. 2j) are not supported. " <>
       "Use separate variables for real and imaginary parts (line #{line})"}
  end

  defp check_tokens([{:float, line, _}, {:name, _, suffix} | _])
       when suffix in ["j", "J"] do
    {:error,
     "NotImplementedError: complex number literals (e.g. 2.5j) are not supported. " <>
       "Use separate variables for real and imaginary parts (line #{line})"}
  end

  defp check_tokens([_ | rest]), do: check_tokens(rest)
  defp check_tokens([]), do: :ok

  @spec rewrite_keywords([raw_token()]) :: [raw_token()]
  defp rewrite_keywords(tokens) do
    Enum.map(tokens, fn
      {:name, word} when word in @keywords -> {:keyword, word}
      token -> token
    end)
  end

  @spec assign_lines([raw_token()]) :: [raw_token() | token()]
  defp assign_lines(tokens) do
    {result, _line} =
      Enum.reduce(tokens, {[], 1}, fn
        {:newline_raw, {indent_level, newline_count}}, {acc, line} ->
          {[{:newline_raw, indent_level} | acc], line + newline_count}

        {tag, value}, {acc, line} ->
          {[{tag, line, value} | acc], line}
      end)

    Enum.reverse(result)
  end

  @open_brackets [:lparen, :lbracket, :lbrace]
  @close_brackets [:rparen, :rbracket, :rbrace]

  @spec suppress_bracketed_newlines([raw_token() | token()]) :: [raw_token() | token()]
  defp suppress_bracketed_newlines(tokens) do
    suppress_bracketed_newlines(tokens, 0, [])
  end

  defp suppress_bracketed_newlines([], _depth, acc), do: Enum.reverse(acc)

  defp suppress_bracketed_newlines([{:newline_raw, _} | rest], depth, acc) when depth > 0 do
    suppress_bracketed_newlines(rest, depth, acc)
  end

  defp suppress_bracketed_newlines([{:op, line, op} | rest], depth, acc)
       when op in @open_brackets do
    suppress_bracketed_newlines(rest, depth + 1, [{:op, line, op} | acc])
  end

  defp suppress_bracketed_newlines([{:op, line, op} | rest], depth, acc)
       when op in @close_brackets and depth > 0 do
    suppress_bracketed_newlines(rest, depth - 1, [{:op, line, op} | acc])
  end

  defp suppress_bracketed_newlines([token | rest], depth, acc) do
    suppress_bracketed_newlines(rest, depth, [token | acc])
  end

  @spec process_indentation([raw_token() | token()]) :: [token()]
  defp process_indentation(tokens) do
    {result, indent_stack} = emit_indentation(tokens, [0], [])
    dedents = length(indent_stack) - 1
    result = Enum.reverse(result)
    result ++ List.duplicate(:dedent, dedents)
  end

  @spec emit_indentation([raw_token() | token()], [non_neg_integer()], [token()]) ::
          {[token()], [non_neg_integer()]}
  defp emit_indentation([], indent_stack, acc) do
    {acc, indent_stack}
  end

  defp emit_indentation([{:newline_raw, level} | rest], [current | _] = stack, acc)
       when level > current do
    emit_indentation(rest, [level | stack], [:indent, :newline | acc])
  end

  defp emit_indentation([{:newline_raw, level} | rest], [current | _] = stack, acc)
       when level < current do
    {new_stack, dedents} = pop_indents(stack, level)
    new_acc = List.duplicate(:dedent, dedents) ++ [:newline | acc]
    emit_indentation(rest, new_stack, new_acc)
  end

  defp emit_indentation([{:newline_raw, _level} | rest], stack, acc) do
    emit_indentation(rest, stack, [:newline | acc])
  end

  defp emit_indentation([token | rest], stack, acc) do
    emit_indentation(rest, stack, [token | acc])
  end

  @spec pop_indents([non_neg_integer()], non_neg_integer()) ::
          {[non_neg_integer()], non_neg_integer()}
  defp pop_indents([current | rest], target) when current > target do
    {new_stack, count} = pop_indents(rest, target)
    {new_stack, count + 1}
  end

  defp pop_indents(stack, _target), do: {stack, 0}

  @doc false
  @spec __newline__([non_neg_integer()]) :: {non_neg_integer(), non_neg_integer()}
  def __newline__(chars) do
    indent =
      chars
      |> Enum.reverse()
      |> Enum.take_while(&(&1 != ?\n))
      |> length()

    newline_count = Enum.count(chars, &(&1 == ?\n))
    {indent, newline_count}
  end

  @doc false
  @spec __integer__([String.t() | non_neg_integer()]) :: integer()
  def __integer__(parts) do
    parts
    |> Enum.map(fn
      c when is_integer(c) -> <<c>>
      s -> s
    end)
    |> Enum.join()
    |> String.replace("_", "")
    |> String.to_integer()
  end

  @doc false
  @spec __float__([String.t() | non_neg_integer()]) :: float()
  def __float__(parts) do
    parts
    |> Enum.map(fn
      c when is_integer(c) -> <<c>>
      s -> s
    end)
    |> Enum.join()
    |> String.replace("_", "")
    |> String.to_float()
  end

  @doc false
  @spec __exponent_float__([String.t() | non_neg_integer()]) :: float()
  def __exponent_float__(parts) do
    str =
      parts
      |> Enum.map(fn
        c when is_integer(c) -> <<c>>
        s -> s
      end)
      |> Enum.join()
      |> String.replace("_", "")

    {f, ""} = Float.parse(str)
    f
  end

  @doc false
  @spec __hex_integer__([String.t()]) :: integer()
  def __hex_integer__([_prefix, digits]) do
    cleaned = String.replace(digits, "_", "")
    if cleaned == "", do: 0, else: String.to_integer(cleaned, 16)
  end

  @doc false
  @spec __octal_integer__([String.t()]) :: integer()
  def __octal_integer__([_prefix, digits]) do
    cleaned = String.replace(digits, "_", "")
    if cleaned == "", do: 0, else: String.to_integer(cleaned, 8)
  end

  @doc false
  @spec __binary_integer__([String.t()]) :: integer()
  def __binary_integer__([_prefix, digits]) do
    cleaned = String.replace(digits, "_", "")
    if cleaned == "", do: 0, else: String.to_integer(cleaned, 2)
  end

  @doc false
  @spec __identifier__([non_neg_integer()]) :: String.t()
  def __identifier__(chars), do: List.to_string(chars)

  @doc false
  @spec __fstring__([String.t() | non_neg_integer()]) :: String.t()
  def __fstring__(["f\"" | chars]) do
    __string__(chars)
  end

  def __fstring__(["f'" | chars]) do
    __string__(chars)
  end

  @doc false
  @spec __fstring_triple__([String.t() | non_neg_integer()]) :: String.t()
  def __fstring_triple__([prefix | chars]) when prefix in [~S[f"""], "f'''"] do
    __string__(chars)
  end

  @doc false
  @spec __hex2_escape__([non_neg_integer()]) :: non_neg_integer()
  def __hex2_escape__(hex_chars) do
    hex_chars |> List.to_string() |> String.to_integer(16)
  end

  @doc false
  @spec __hex4_escape__([non_neg_integer()]) :: non_neg_integer()
  def __hex4_escape__(hex_chars) do
    hex_chars |> List.to_string() |> String.to_integer(16)
  end

  @doc false
  @spec __hex8_escape__([non_neg_integer()]) :: non_neg_integer()
  def __hex8_escape__(hex_chars) do
    hex_chars |> List.to_string() |> String.to_integer(16)
  end

  @doc false
  @spec __raw_escape__([String.t() | non_neg_integer()]) :: String.t()
  def __raw_escape__(parts) do
    parts
    |> Enum.map(fn
      c when is_integer(c) -> <<c::utf8>>
      s when is_binary(s) -> s
    end)
    |> IO.iodata_to_binary()
  end

  @doc false
  @spec __unknown_escape__([String.t() | non_neg_integer()]) :: String.t()
  def __unknown_escape__(parts) do
    parts
    |> Enum.map(fn
      c when is_integer(c) -> <<c::utf8>>
      s when is_binary(s) -> s
    end)
    |> IO.iodata_to_binary()
  end

  @doc false
  @spec __string__([non_neg_integer() | String.t()]) :: String.t()
  def __string__(chars) do
    chars
    |> Enum.map(fn
      c when is_integer(c) -> <<c::utf8>>
      s when is_binary(s) -> s
    end)
    |> IO.iodata_to_binary()
  end
end
