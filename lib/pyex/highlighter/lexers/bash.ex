defmodule Pyex.Highlighter.Lexers.Bash do
  @moduledoc """
  Bash / POSIX shell lexer.

  Handles keywords, built-in commands, variables (`$var`, `${var}`,
  `$(cmd)`, `$((expr))`, `$1`…`$9`, `$@`, `$*`, `$?`), single- and
  double-quoted strings with interpolation, backticks, heredocs (a
  subset — the opening `<<WORD` triggers a heredoc state that ends on
  a line matching `WORD`), pipes / redirects, numbers, and comments.
  """

  @behaviour Pyex.Highlighter.Lexer

  @name "bash"
  @aliases ["bash", "sh", "shell", "zsh"]
  @filenames ["*.sh", "*.bash", "*.zsh", ".bashrc", ".zshrc", ".profile"]
  @mimetypes ["application/x-sh", "application/x-shellscript"]

  def name, do: @name
  def aliases, do: @aliases
  def filenames, do: @filenames
  def mimetypes, do: @mimetypes

  @impl Pyex.Highlighter.Lexer
  def rules do
    %{
      root: [
        # Shebang
        {~r/\A#![^\n]*/, :comment_hashbang, :none},
        # Comments
        {~r/#[^\n]*/, :comment_single, :none},
        # Whitespace
        {~r/\s+/, :whitespace, :none},

        # Heredoc — skip into heredoc body state. We match the full
        # `<<WORD` or `<<-WORD` (optionally quoted) and push a heredoc
        # state that consumes until a line matching WORD.
        # NOTE: We approximate this. Proper heredocs would need
        # post-match state tracking of WORD; for now we emit the
        # marker and tokenize the body as :string_heredoc until we see
        # the next occurrence of WORD on its own line — which requires
        # the capture group. Since our engine's state can't carry data,
        # we do a best-effort: match the marker and immediately match
        # the body greedily.
        {~r/<<-?\s*['"]?([A-Z_]+)['"]?\n[\s\S]*?\n\1\n?/, {:bygroups, [:string_heredoc]}, :none},

        # Function definitions: `function name` or `name() {`
        {~r/(function)(\s+)([a-zA-Z_][\w-]*)/,
         {:bygroups, [:keyword, :whitespace, :name_function]}, :none},
        {~r/([a-zA-Z_][\w-]*)(\s*\(\s*\))/, {:bygroups, [:name_function, :punctuation]}, :none},

        # Variable assignment: `FOO=` — emit name as variable
        {~r/([a-zA-Z_][\w]*)(=)/, {:bygroups, [:name_variable, :operator]}, :none},

        # Double-quoted strings push into a sub-state so interpolations
        # (`$var`, `${var}`, `$(cmd)`) get their own tokens.
        {~r/"/, :string_double, {:push, :dqstring}},
        {~r/'[^']*'/, :string_single, :none},

        # Backticks (command substitution) — strip-to-backtick
        {~r/`[^`]*`/, :string_backtick, :none},

        # Command substitution: $(...) / Arithmetic: $((...))
        {~r/\$\(\([^)]*\)\)/, :string_interpol, :none},
        {~r/\$\([^)]*\)/, :string_interpol, :none},

        # Variables
        {~r/\$\{[^}]+\}/, :name_variable, :none},
        {~r/\$[a-zA-Z_][\w]*/, :name_variable, :none},
        {~r/\$[0-9@*#?!$-]/, :name_variable, :none},

        # Numbers
        {~r/\b\d+\b/, :number_integer, :none},

        # Keywords
        {~r/\b(?:if|then|else|elif|fi|case|esac|for|select|while|until|do|done|in|function|time|coproc)\b/,
         :keyword, :none},

        # Builtins (word boundary on both sides)
        {~r/\b(?:alias|bg|bind|break|builtin|caller|cd|command|compgen|complete|compopt|continue|declare|dirs|disown|echo|enable|eval|exec|exit|export|false|fc|fg|getopts|hash|help|history|jobs|kill|let|local|logout|mapfile|popd|printf|pushd|pwd|read|readarray|readonly|return|set|shift|shopt|source|suspend|test|times|trap|true|type|typeset|ulimit|umask|unalias|unset|wait)\b/,
         :name_builtin, :none},

        # Operators: pipes, redirects, logical
        {~r/\|\||&&|<<|>>|>&|<&|<>|<<<|\||&|>|<|;|!/, :operator, :none},

        # Flags: -f, --file
        {~r/(?<=\s)-{1,2}[\w-]+/, :name_attribute, :none},

        # Identifiers (commands, arguments)
        {~r/[a-zA-Z_][\w-]*/, :name, :none},

        # Numbers that weren't caught
        {~r/\d+/, :number_integer, :none},

        # Misc punctuation
        {~r/[()\[\]{},]/, :punctuation, :none},

        # Anything else
        {~r/./, :text, :none}
      ],
      dqstring: [
        {~r/"/, :string_double, :pop},
        {~r/\\./, :string_escape, :none},
        {~r/\$\{[^}]+\}/, :name_variable, :none},
        {~r/\$\([^)]*\)/, :string_interpol, :none},
        {~r/\$[a-zA-Z_][\w]*/, :name_variable, :none},
        {~r/\$[0-9@*#?!$-]/, :name_variable, :none},
        {~r/[^"\\$]+/, :string_double, :none}
      ]
    }
  end
end
