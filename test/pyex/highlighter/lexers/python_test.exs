defmodule Pyex.Highlighter.Lexers.PythonTest do
  use ExUnit.Case, async: true

  alias Pyex.Highlighter.Lexer
  alias Pyex.Highlighter.Lexers.Python

  defp tokenize(src), do: Lexer.tokenize(Python, src)
  defp types(src), do: src |> tokenize() |> Enum.map(&elem(&1, 0))

  defp has_token?(src, type, text) do
    Enum.any?(tokenize(src), fn {t, s} -> t == type and s == text end)
  end

  test "round-trips losslessly" do
    src = """
    import re
    from x import y

    @decorator
    def hello(name: str = "world") -> str:
        '''docstring'''
        return f"Hello, {name}!"

    class Foo(Bar):
        def __init__(self):
            self.x = 42
    """

    tokens = tokenize(src)
    reconstructed = tokens |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
    assert reconstructed == src
  end

  test "keywords" do
    assert has_token?("import foo", :keyword, "import")
    assert has_token?("def f(): pass", :keyword, "pass")
    assert has_token?("if x:", :keyword, "if")
    assert has_token?("async def f(): pass", :keyword, "async")
    assert has_token?("match x:", :keyword, "match")
  end

  test "keyword constants" do
    assert has_token?("x = True", :keyword_constant, "True")
    assert has_token?("x = None", :keyword_constant, "None")
    assert has_token?("x = False", :keyword_constant, "False")
  end

  test "operator words" do
    assert has_token?("x and y", :operator_word, "and")
    assert has_token?("not x", :operator_word, "not")
    assert has_token?("a or b", :operator_word, "or")
  end

  test "function definition: def, name, param" do
    tokens = tokenize("def greet(name):")
    assert {:keyword, "def"} in tokens
    assert {:name_function, "greet"} in tokens
  end

  test "class definition" do
    tokens = tokenize("class Foo:")
    assert {:keyword, "class"} in tokens
    assert {:name_class, "Foo"} in tokens
  end

  test "decorators" do
    assert has_token?("@app.get", :name_decorator, "@app.get")
    assert has_token?("@staticmethod", :name_decorator, "@staticmethod")
  end

  test "strings" do
    assert has_token?(~s("hello"), :string_double, ~s("hello"))
    assert has_token?(~s('hello'), :string_single, ~s('hello'))
    assert has_token?(~s(b"bytes"), :string_double, ~s(b"bytes"))
    assert has_token?(~s(r"raw"), :string_double, ~s(r"raw"))
    assert has_token?(~s(f"fstr"), :string_double, ~s(f"fstr"))
  end

  test "triple-quoted strings are doc strings" do
    assert has_token?(~s("""docstring"""), :string_doc, ~s("""docstring"""))
    assert has_token?(~s('''ok'''), :string_doc, ~s('''ok'''))
  end

  test "numbers" do
    assert has_token?("42", :number_integer, "42")
    assert has_token?("3.14", :number_float, "3.14")
    assert has_token?("1_000_000", :number_integer, "1_000_000")
    assert has_token?("0xff", :number_hex, "0xff")
    assert has_token?("0b1010", :number_bin, "0b1010")
    assert has_token?("0o755", :number_oct, "0o755")
    assert has_token?("1j", :number_float, "1j")
    assert has_token?("1e10", :number_float, "1e10")
  end

  test "builtins" do
    assert has_token?("print(x)", :name_builtin, "print")
    assert has_token?("len(s)", :name_builtin, "len")
    assert has_token?("isinstance(x, int)", :name_builtin, "isinstance")
  end

  test "exceptions" do
    assert has_token?("raise ValueError", :name_exception, "ValueError")
    assert has_token?("except Exception:", :name_exception, "Exception")
  end

  test "self and cls as pseudo-builtins" do
    assert has_token?("self.x", :name_builtin_pseudo, "self")
    assert has_token?("cls.y", :name_builtin_pseudo, "cls")
  end

  test "dunder names" do
    assert has_token?("__init__", :name_function_magic, "__init__")
    assert has_token?("__all__", :name_function_magic, "__all__")
  end

  test "comments" do
    assert has_token?("# comment here", :comment_single, "# comment here")
  end

  test "function calls mark callee as :name_function" do
    assert has_token?("foo(1)", :name_function, "foo")
  end

  test "attribute access does not shadow builtins" do
    # `x.print` → `print` is an attribute ref, not the builtin.
    # Lookbehind `(?<![\w.])` blocks the builtin rule; no trailing `(`
    # means it's not :name_function either.
    assert Enum.find(tokenize("x.print"), fn {_t, s} -> s == "print" end) ==
             {:name, "print"}

    # But `x.print(...)` DOES get :name_function because of the call.
    assert Enum.find(tokenize("x.print(1)"), fn {_t, s} -> s == "print" end) ==
             {:name_function, "print"}
  end

  test "whitespace and comments don't break keyword matching" do
    t =
      types("""
      def hello():
          # a comment
          pass
      """)

    assert :keyword in t
    assert :comment_single in t
    assert :whitespace in t
  end
end
