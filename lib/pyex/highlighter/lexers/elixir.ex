defmodule Pyex.Highlighter.Lexers.Elixir do
  @moduledoc """
  Elixir lexer.

  Covers `def`/`defp`/`defmodule` families, atoms, sigils
  (`~r`, `~w`, `~s`, `~S`, `~D`, `~T`, `~N`, `~U` with any of
  `()[]{}<>//||` delimiters and optional modifiers), numbers with
  underscores, integer prefixes (`0x`, `0o`, `0b`), charlists, module
  names (CamelCase), pipe/arrow operators, shallow string
  interpolation, heredocs, and module attributes.
  """

  @behaviour Pyex.Highlighter.Lexer

  @name "elixir"
  @aliases ["elixir", "ex", "exs"]
  @filenames ["*.ex", "*.exs"]
  @mimetypes ["text/x-elixir"]

  def name, do: @name
  def aliases, do: @aliases
  def filenames, do: @filenames
  def mimetypes, do: @mimetypes

  @impl Pyex.Highlighter.Lexer
  def rules do
    %{
      root: [
        # Whitespace & comments
        {~r/\s+/u, :whitespace, :none},
        {~r/#[^\n]*/, :comment_single, :none},

        # Heredocs (triple-quoted)
        {~r/"""[\s\S]*?"""/, :string_heredoc, :none},
        {~r/'''[\s\S]*?'''/, :string_heredoc, :none},

        # Sigils — ~R/~S/~W/etc. Uppercase sigils don't interpolate;
        # lowercase do (we tokenize both identically here).
        {~r/~[a-zA-Z]\((?:\\.|[^)\\])*\)[a-zA-Z]*/, :string_regex, :none},
        {~r/~[a-zA-Z]\[(?:\\.|[^\]\\])*\][a-zA-Z]*/, :string_regex, :none},
        {~r/~[a-zA-Z]\{(?:\\.|[^}\\])*\}[a-zA-Z]*/, :string_regex, :none},
        {~r/~[a-zA-Z]<(?:\\.|[^>\\])*>[a-zA-Z]*/, :string_regex, :none},
        {~r/~[a-zA-Z]\/(?:\\.|[^\/\\])*\/[a-zA-Z]*/, :string_regex, :none},
        {~r/~[a-zA-Z]\|(?:\\.|[^|\\])*\|[a-zA-Z]*/, :string_regex, :none},
        {~r/~[a-zA-Z]"(?:\\.|[^"\\])*"[a-zA-Z]*/, :string_regex, :none},

        # Strings with interpolation — push into a sub-state
        {~r/"/, :string_double, {:push, :dqstring}},

        # Charlist
        {~r/'[^']*'/, :string_char, :none},

        # Module attributes: @moduledoc, @spec, @doc, @my_attr
        {~r/@[a-zA-Z_]\w*/, :name_attribute, :none},

        # Quoted atoms: :"hello world"
        {~r/:"(?:\\.|[^"\\])*"/, :string_symbol, :none},

        # Keyword-list atom shorthand: `style:`, `body:` — but NOT `::`
        # (module resolve operator) and not when followed by `=` (so
        # `x: = 1` stays sensible as cast).
        {~r/[a-zA-Z_]\w*[?!]?:(?!:|=)/, :string_symbol, :none},

        # Atoms: :foo, :foo?, :ok
        {~r/:[a-zA-Z_]\w*[?!]?/, :string_symbol, :none},

        # Operator atoms: :+, :-, :<>
        {~r/:(?:<<|>>|\|\|\||&&&|>>>|<<<|<=|>=|==|!=|=~|<>|<-|->|\|>|\+\+|--|\.\.|&&|\|\||\+|-|\*|\/|=|<|>|!|@|\^|\||&)/,
         :string_symbol, :none},

        # Numbers (float > hex/bin/oct > int)
        {~r/\d(?:_?\d)*\.\d(?:_?\d)*(?:[eE][+-]?\d+)?/, :number_float, :none},
        {~r/0x[0-9a-fA-F](?:_?[0-9a-fA-F])*/, :number_hex, :none},
        {~r/0o[0-7](?:_?[0-7])*/, :number_oct, :none},
        {~r/0b[01](?:_?[01])*/, :number_bin, :none},
        {~r/\?(?:\\.|.)/, :number_integer, :none},
        {~r/\d(?:_?\d)*/, :number_integer, :none},

        # def family — capture `def` and name separately
        {~r/(defmodule|defprotocol|defimpl|defstruct|defexception|defmacrop|defmacro|defguardp|defguard|defdelegate|defp|def)(\s+)([A-Z][\w.]*|[a-z_]\w*[?!]?)/,
         {:bygroups, [:keyword_declaration, :whitespace, :name_function]}, :none},

        # Keywords
        {~r/\b(?:do|end|fn|case|cond|if|else|unless|when|with|for|in|not|and|or|raise|reraise|rescue|try|catch|after|quote|unquote|unquote_splicing|require|import|use|alias)\b/,
         :keyword, :none},

        # Constants
        {~r/\b(?:true|false|nil)\b/, :keyword_constant, :none},

        # Module references (CamelCase), possibly dotted: `MyApp.Sub.Thing`
        {~r/[A-Z][\w]*(?:\.[A-Z][\w]*)*/, :name_class, :none},

        # Function calls: identifier followed by `(`
        {~r/[a-z_][\w]*[?!]?(?=\s*\()/, :name_function, :none},

        # Identifiers
        {~r/[a-z_][\w]*[?!]?/, :name, :none},

        # Multi-char operators first. `::` is the type-spec and
        # binary-pattern size annotation — must come before bare `:`.
        {~r/\|\|\||&&&|>>>|<<<|<=|>=|==|!=|=~|<>|<-|->|\|>|\+\+|--|\.\.\.?|&&|\|\||::|:=|\*\*|[+\-*\/=<>!|&^~@%]/,
         :operator, :none},

        # Punctuation
        {~r/[(){}\[\],;.]/, :punctuation, :none}
      ],
      dqstring: [
        {~r/"/, :string_double, :pop},
        {~r/\\./, :string_escape, :none},
        {~r/\#\{/, :string_interpol, {:push, :interp}},
        {~r/[^"\\#]+/, :string_double, :none},
        {~r/#/, :string_double, :none}
      ],
      interp: [
        # A shallow expression context — nested braces handled via
        # push_same so `#{ %{a: 1} }` survives.
        {~r/\}/, :string_interpol, :pop},
        {~r/\{/, :punctuation, :push_same},
        # Strings (so `#{"foo #{x}"}` in a template works)
        {~r/"(?:\\.|[^"\\])*"/, :string_double, :none},
        {~r/\b(?:true|false|nil)\b/, :keyword_constant, :none},
        {~r/[A-Z][\w]*(?:\.[A-Z][\w]*)*/, :name_class, :none},
        {~r/:[a-zA-Z_]\w*[?!]?/, :string_symbol, :none},
        {~r/[a-z_][\w]*[?!]?(?=\s*\()/, :name_function, :none},
        {~r/[a-z_][\w]*[?!]?/, :name, :none},
        {~r/\d+/, :number_integer, :none},
        {~r/[+\-*\/=<>!|&^~%,.]/, :operator, :none},
        {~r/[()\[\]]/, :punctuation, :none},
        {~r/\s+/, :whitespace, :none}
      ]
    }
  end
end
