defmodule Pyex.Highlighter.Lexers.Python do
  @moduledoc """
  Python 3 lexer.

  Handles the usual suspects: keywords, builtins, string prefixes
  (`r`, `b`, `f`, `rb`, `u`, etc.), triple-quoted strings, f-string
  interpolation (shallow — no nested `{…}`), decorators, function
  and class definitions, numbers with underscores / `j` suffix,
  exceptions, and dunder names.
  """

  @behaviour Pyex.Highlighter.Lexer

  @name "python"
  @aliases ["python", "py", "python3", "py3"]
  @filenames ["*.py", "*.pyw"]
  @mimetypes ["text/x-python", "application/x-python"]

  def name, do: @name
  def aliases, do: @aliases
  def filenames, do: @filenames
  def mimetypes, do: @mimetypes

  @keywords ~w(
    assert async await break continue del elif else except finally for from
    global if import in is lambda nonlocal pass raise return try while with
    yield match case
  )

  @keyword_constants ~w(True False None NotImplemented Ellipsis)

  @keyword_operators ~w(and or not)

  @builtins ~w(
    abs all any ascii bin bool bytearray bytes callable chr classmethod compile
    complex delattr dict dir divmod enumerate eval exec filter float format
    frozenset getattr globals hasattr hash help hex id input int isinstance
    issubclass iter len list locals map max memoryview min next object oct open
    ord pow print property range repr reversed round set setattr slice sorted
    staticmethod str sum super tuple type vars zip __import__
  )

  @exceptions ~w(
    ArithmeticError AssertionError AttributeError BaseException BlockingIOError
    BrokenPipeError BufferError BytesWarning ChildProcessError ConnectionAbortedError
    ConnectionError ConnectionRefusedError ConnectionResetError DeprecationWarning
    EOFError EnvironmentError Exception FileExistsError FileNotFoundError
    FloatingPointError FutureWarning GeneratorExit IOError ImportError ImportWarning
    IndentationError IndexError InterruptedError IsADirectoryError KeyError
    KeyboardInterrupt LookupError MemoryError ModuleNotFoundError NameError
    NotADirectoryError NotImplementedError OSError OverflowError PendingDeprecationWarning
    PermissionError ProcessLookupError RecursionError ReferenceError ResourceWarning
    RuntimeError RuntimeWarning StopAsyncIteration StopIteration SyntaxError
    SyntaxWarning SystemError SystemExit TabError TimeoutError TypeError
    UnboundLocalError UnicodeDecodeError UnicodeEncodeError UnicodeError
    UnicodeTranslateError UnicodeWarning UserWarning ValueError Warning
    WindowsError ZeroDivisionError
  )

  @impl Pyex.Highlighter.Lexer
  def rules do
    %{
      root: [
        # Whitespace & comments
        {~r/\s+/u, :whitespace, :none},
        {~r/#[^\n]*/, :comment_single, :none},

        # Decorators
        {~r/@[\w.]+/, :name_decorator, :none},

        # def name(   → emit `def` as keyword, ` ` as whitespace, name as :name_function
        {~r/(def)(\s+)([a-zA-Z_]\w*)/, {:bygroups, [:keyword, :whitespace, :name_function]},
         :none},

        # class Name(
        {~r/(class)(\s+)([a-zA-Z_]\w*)/, {:bygroups, [:keyword, :whitespace, :name_class]},
         :none},

        # String prefixes + triple and single quoted. Order matters:
        # triple-quoted must come before single so `"""..."""` is not
        # parsed as empty-string + content + empty-string.
        {~r/(?:[bBrRuUfF]|[bB][rR]|[rR][bB]|[fF][rR]|[rR][fF])?"""(?:\\.|[^\\])*?"""/s,
         :string_doc, :none},
        {~r/(?:[bBrRuUfF]|[bB][rR]|[rR][bB]|[fF][rR]|[rR][fF])?'''(?:\\.|[^\\])*?'''/s,
         :string_doc, :none},
        {~r/(?:[bBrRuUfF]|[bB][rR]|[rR][bB]|[fF][rR]|[rR][fF])?"(?:\\.|[^"\\\n])*"/,
         :string_double, :none},
        {~r/(?:[bBrRuUfF]|[bB][rR]|[rR][bB]|[fF][rR]|[rR][fF])?'(?:\\.|[^'\\\n])*'/,
         :string_single, :none},

        # Numbers — order: complex > float > hex/oct/bin > int (with underscores)
        {~r/\d(?:_?\d)*\.(?:\d(?:_?\d)*)?(?:[eE][+-]?\d(?:_?\d)*)?[jJ]?/, :number_float, :none},
        {~r/\.\d(?:_?\d)*(?:[eE][+-]?\d(?:_?\d)*)?[jJ]?/, :number_float, :none},
        {~r/\d(?:_?\d)*[eE][+-]?\d(?:_?\d)*[jJ]?/, :number_float, :none},
        {~r/0[xX][0-9a-fA-F](?:_?[0-9a-fA-F])*[lL]?/, :number_hex, :none},
        {~r/0[oO][0-7](?:_?[0-7])*/, :number_oct, :none},
        {~r/0[bB][01](?:_?[01])*/, :number_bin, :none},
        {~r/\d(?:_?\d)*[jJ]/, :number_float, :none},
        {~r/\d(?:_?\d)*/, :number_integer, :none},

        # Keywords before generic identifiers. Word boundaries matter.
        {Regex.compile!("(?<![\\w.])(?:" <> Enum.join(@keyword_constants, "|") <> ")\\b"),
         :keyword_constant, :none},
        {Regex.compile!("(?<![\\w.])(?:" <> Enum.join(@keyword_operators, "|") <> ")\\b"),
         :operator_word, :none},
        {Regex.compile!("(?<![\\w.])(?:" <> Enum.join(@keywords, "|") <> ")\\b"), :keyword,
         :none},
        {Regex.compile!("(?<![\\w.])(?:" <> Enum.join(@exceptions, "|") <> ")\\b"),
         :name_exception, :none},
        {Regex.compile!("(?<![\\w.])(?:" <> Enum.join(@builtins, "|") <> ")\\b"), :name_builtin,
         :none},

        # self and cls are pseudo-builtins
        {~r/(?<![\w.])(?:self|cls)\b/, :name_builtin_pseudo, :none},

        # Magic / dunder names
        {~r/__[a-zA-Z_]\w*__/, :name_function_magic, :none},

        # Function calls: identifier immediately followed by `(`
        {~r/[a-zA-Z_]\w*(?=\s*\()/, :name_function, :none},

        # Plain identifiers
        {~r/[a-zA-Z_]\w*/, :name, :none},

        # Multi-char operators first (longest-first within this group)
        {~r/\*\*=|\/\/=|<<=|>>=|!=|==|<=|>=|\+=|-=|\*=|\/=|%=|&=|\|=|\^=|:=|->|\*\*|\/\/|<<|>>|&&|\|\||\.\.\.|\*|\+|-|\/|%|&|\||\^|~|<|>|=/,
         :operator, :none},

        # Punctuation
        {~r/[()\[\]{}:;,.@]/, :punctuation, :none}
      ]
    }
  end
end
