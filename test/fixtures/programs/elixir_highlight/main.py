"""
Pure-Python syntax highlighter for Elixir → HTML + CSS.

Usage:
    from elixir_highlight import highlight, CSS

    html = highlight('defmodule Foo do\\n  def bar, do: :ok\\nend')
    page = f"<style>{CSS}</style><pre><code>{html}</code></pre>"
"""

import re
from html import escape

# --- Token types & patterns (order matters: first match wins) ---

_TOKENS: list[tuple[str, str]] = [
    ("comment", r"#[^\n]*"),
    ("heredoc", r'"""[\s\S]*?"""|\'\'\'[\s\S]*?\'\'\''),
    ("string", r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\''),
    (
        "sigil",
        r"~[a-zA-Z](?:"
        r"\((?:\\.|[^)\\])*\)|"
        r"\[(?:\\.|[^\]\\])*\]|"
        r"\{(?:\\.|[^}\\])*\}|"
        r"<(?:\\.|[^>\\])*>|"
        r"/(?:\\.|[^/\\])*/|"
        r"\|(?:\\.|[^|\\])*\|"
        r")[a-zA-Z]*",
    ),
    (
        "number",
        r"0[xX][0-9a-fA-F](?:_?[0-9a-fA-F])*"
        r"|0[oO][0-7](?:_?[0-7])*"
        r"|0[bB][01](?:_?[01])*"
        r"|\d(?:_?\d)*\.(?!\.)\d(?:_?\d)*(?:[eE][+-]?\d+)?"
        r"|\d(?:_?\d)*",
    ),
    ("atom_str", r':"(?:\\.|[^"\\])*"'),
    ("atom", r":[a-zA-Z_]\w*[?!]?"),
    ("module", r"[A-Z]\w*"),
    (
        "keyword",
        r"\b(?:def|defp|defmodule|defprotocol|defimpl|defstruct"
        r"|defmacro|defmacrop|defguard|defguardp|defdelegate"
        r"|do|end|fn|case|cond|if|else|unless|when|with"
        r"|for|in|raise|reraise|rescue|try|catch|after"
        r"|quote|unquote|unquote_splicing"
        r"|require|import|use|alias"
        r"|and|or|not|true|false|nil)\b",
    ),
    ("operator", r"=>|->|<-|\|>|<>|\.\.\.?|\+\+|--|&&|\|\||[!=<>]=?|[+\-*/|&^~@]"),
    ("punct", r"[(){}\[\],.;%]"),
    ("ident", r"[a-z_]\w*[?!]?"),
    ("space", r"\s+"),
]

_MASTER_RE = re.compile("|".join(f"(?P<{name}>{pat})" for name, pat in _TOKENS))

# Keyword set for fast second-pass check (identifiers that matched 'ident'
# before 'keyword' can't happen because keyword comes first, but we guard
# against edge cases with a set).
_KEYWORDS = {
    "def",
    "defp",
    "defmodule",
    "defprotocol",
    "defimpl",
    "defstruct",
    "defmacro",
    "defmacrop",
    "defguard",
    "defguardp",
    "defdelegate",
    "do",
    "end",
    "fn",
    "case",
    "cond",
    "if",
    "else",
    "unless",
    "when",
    "with",
    "for",
    "in",
    "raise",
    "reraise",
    "rescue",
    "try",
    "catch",
    "after",
    "quote",
    "unquote",
    "unquote_splicing",
    "require",
    "import",
    "use",
    "alias",
    "and",
    "or",
    "not",
    "true",
    "false",
    "nil",
}

# --- CSS theme (Elixir-inspired purple palette) ---

CSS = """\
.ex .c  { color: #6b7280; font-style: italic }  /* comment   */
.ex .s  { color: #22863a }                       /* string    */
.ex .sg { color: #22863a; font-weight: 500 }     /* sigil     */
.ex .k  { color: #8b5cf6; font-weight: 600 }     /* keyword   */
.ex .a  { color: #0ea5e9 }                       /* atom      */
.ex .n  { color: #d97706 }                       /* number    */
.ex .m  { color: #e04f8b }                       /* module    */
.ex .o  { color: #9ca3af }                       /* operator  */
.ex .i  { color: #d4d4d8 }                       /* ident     */
.ex .p  { color: #9ca3af }                       /* punct     */
.ex     { color: #d4d4d8; background: #1e1e2e;
          padding: 1em; border-radius: 8px;
          font-family: 'JetBrains Mono', 'Fira Code', monospace;
          font-size: 14px; line-height: 1.6; overflow-x: auto }
"""

_CLASS_MAP = {
    "comment": "c",
    "heredoc": "s",
    "string": "s",
    "sigil": "sg",
    "number": "n",
    "atom_str": "a",
    "atom": "a",
    "module": "m",
    "keyword": "k",
    "operator": "o",
    "punct": "p",
    "ident": "i",
}


def highlight(source: str) -> str:
    """Return an HTML string with <span> tags for syntax highlighting."""
    parts: list[str] = []
    pos = 0
    for m in _MASTER_RE.finditer(source):
        # emit any unmatched gap as plain escaped text
        if m.start() > pos:
            parts.append(escape(source[pos : m.start()]))
        token_type = m.lastgroup
        text = escape(m.group())
        css_cls = _CLASS_MAP.get(token_type)  # type: ignore[arg-type]
        if css_cls:
            parts.append(f'<span class="{css_cls}">{text}</span>')
        else:
            parts.append(text)
        pos = m.end()
    # trailing text
    if pos < len(source):
        parts.append(escape(source[pos:]))
    return "".join(parts)


def highlight_full(source: str) -> str:
    """Return a complete HTML page with embedded CSS."""
    return (
        f'<style>{CSS}</style>\n<pre class="ex"><code>{highlight(source)}</code></pre>'
    )


# --- Quick demo ---

if __name__ == "__main__":
    sample = '''\
defmodule MyApp.Greeter do
  @moduledoc """
  A simple greeter module.
  """

  @greeting :hello

  # Public API
  def greet(name) when is_binary(name) do
    message = "#{@greeting}, #{name}!"
    IO.puts(message)
    {:ok, message}
  end

  defp format_name(name) do
    name
    |> String.trim()
    |> String.capitalize()
  end

  def run do
    ~r/^[a-z]+$/i
    nums = for x <- 1..10, rem(x, 2) == 0, do: x * 0xFF
    result = Enum.map(nums, fn n -> n + 1_000 end)
    {:ok, result}
  end
end\
'''
    with open("demo.html", "w") as f:
        f.write(
            f"<!DOCTYPE html><html><head><meta charset='utf-8'>"
            f"<title>Elixir Highlight</title></head><body>\n"
            f"{highlight_full(sample)}\n</body></html>"
        )
    print("Wrote demo.html")
    print(highlight_full(sample))
