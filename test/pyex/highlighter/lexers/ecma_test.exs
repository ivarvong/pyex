defmodule Pyex.Highlighter.Lexers.ECMATest do
  use ExUnit.Case, async: true

  alias Pyex.Highlighter.Lexer
  alias Pyex.Highlighter.Lexers.{Javascript, Typescript, JSX, TSX}

  defp tok(mod, src), do: Lexer.tokenize(mod, src)

  defp has?(mod, src, type, text) do
    Enum.any?(tok(mod, src), fn {t, s} -> t == type and s == text end)
  end

  describe "JavaScript" do
    test "round-trips losslessly" do
      src = """
      import { foo } from './bar';

      const greet = (name) => {
        return `hello, ${name}!`;
      };

      async function run() {
        const n = 42;
        return n * 2;
      }

      class Foo extends Bar {
        #private = 1;
      }
      """

      actual = tok(Javascript, src) |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
      assert actual == src
    end

    test "keywords" do
      assert has?(Javascript, "const x = 1", :keyword, "const")
      assert has?(Javascript, "let y = 2", :keyword, "let")
      assert has?(Javascript, "async function f() {}", :keyword, "async")
      assert has?(Javascript, "await f()", :keyword, "await")
      assert has?(Javascript, "return x", :keyword, "return")
    end

    test "constants" do
      assert has?(Javascript, "x = true", :keyword_constant, "true")
      assert has?(Javascript, "x = null", :keyword_constant, "null")
      assert has?(Javascript, "x = undefined", :keyword_constant, "undefined")
    end

    test "strings and template literals" do
      assert has?(Javascript, ~s("hi"), :string_double, ~s("hi"))
      assert has?(Javascript, ~s('hi'), :string_single, ~s('hi'))

      # Plain template literal: adjacent :string_backtick tokens get
      # merged into one run — assert the whole thing is tagged.
      assert has?(Javascript, "`hello`", :string_backtick, "`hello`")

      tokens = tok(Javascript, "`hi ${name}`")
      assert Enum.any?(tokens, fn {t, s} -> t == :string_interpol and s == "${" end)
      assert Enum.any?(tokens, fn {t, s} -> t == :name and s == "name" end)
      assert Enum.any?(tokens, fn {t, s} -> t == :string_interpol and s == "}" end)
    end

    test "numbers including bigint" do
      assert has?(Javascript, "42", :number_integer, "42")
      assert has?(Javascript, "3.14", :number_float, "3.14")
      assert has?(Javascript, "0xFF", :number_hex, "0xFF")
      assert has?(Javascript, "42n", :number_integer, "42n")
      assert has?(Javascript, "0xFFn", :number_hex, "0xFFn")
    end

    test "regex literals" do
      # After `=`, a `/` should be regex
      assert has?(Javascript, "const r = /abc/g", :string_regex, "/abc/g")
    end

    test "comments" do
      assert has?(Javascript, "// hi", :comment_single, "// hi")
      assert has?(Javascript, "/* hi */", :comment_multiline, "/* hi */")
    end

    test "class definition" do
      tokens = tok(Javascript, "class Foo extends Bar {}")
      assert {:keyword, "class"} in tokens
      assert {:name_class, "Foo"} in tokens
      assert {:keyword, "extends"} in tokens
    end

    test "function definition" do
      tokens = tok(Javascript, "function greet(name) {}")
      assert {:keyword, "function"} in tokens
      assert {:name_function, "greet"} in tokens
    end

    test "arrow functions" do
      assert has?(Javascript, "const f = () => 1", :operator, "=>")
    end
  end

  describe "TypeScript" do
    test "type keywords" do
      assert has?(Typescript, "interface Foo {}", :keyword_declaration, "interface")
      assert has?(Typescript, "type X = number", :keyword_declaration, "type")
      assert has?(Typescript, "enum Color { Red }", :keyword_declaration, "enum")
    end

    test "primitive types" do
      assert has?(Typescript, "let x: string", :keyword_type, "string")
      assert has?(Typescript, "let x: number", :keyword_type, "number")
      assert has?(Typescript, "let x: boolean", :keyword_type, "boolean")
      assert has?(Typescript, "let x: any", :keyword_type, "any")
      assert has?(Typescript, "let x: unknown", :keyword_type, "unknown")
    end

    test "as cast and satisfies" do
      assert has?(Typescript, "x as string", :keyword_declaration, "as")
      assert has?(Typescript, "x satisfies Foo", :keyword_declaration, "satisfies")
    end

    test "does not break JS features" do
      # const/let/async work identically
      assert has?(Typescript, "const x = 1", :keyword, "const")
      assert has?(Typescript, "`hi ${x}`", :string_interpol, "${")
    end
  end

  describe "JSX" do
    test "simple tag" do
      tokens = tok(JSX, "const x = <div>hi</div>")
      assert Enum.any?(tokens, fn {t, s} -> t == :name_tag and s == "<div" end)
    end

    test "self-closing tag" do
      tokens = tok(JSX, "<img />")
      assert Enum.any?(tokens, fn {t, s} -> t == :name_tag and s == "<img" end)
      assert Enum.any?(tokens, fn {t, _} -> t == :punctuation end)
    end

    test "attribute with string value" do
      tokens = tok(JSX, ~s(<div className="foo">))

      assert Enum.any?(tokens, fn {t, s} -> t == :name_attribute and s == "className" end)

      assert Enum.any?(tokens, fn {t, s} ->
               t == :string_double and s == ~s("foo")
             end)
    end

    test "attribute with expression interpolation" do
      tokens = tok(JSX, "<div onClick={handler} />")

      assert Enum.any?(tokens, fn {t, s} ->
               t == :name_attribute and s == "onClick"
             end)

      assert Enum.any?(tokens, fn {t, s} ->
               t == :string_interpol and s == "{"
             end)

      assert Enum.any?(tokens, fn {t, s} -> t == :name and s == "handler" end)
    end

    test "capitalized component name" do
      tokens = tok(JSX, "<MyComponent prop={x} />")
      assert Enum.any?(tokens, fn {t, s} -> t == :name_tag and s == "<MyComponent" end)
    end

    test "closing tags tokenize as a single :name_tag, not operator + name" do
      tokens = tok(JSX, "<div>hi</div>")
      assert {:name_tag, "<div"} in tokens
      assert {:name_tag, "</div"} in tokens

      # No stray operator/name split for `</div`
      refute Enum.any?(tokens, fn {t, s} -> t == :name and s == "div" end)
    end

    test "fragments" do
      # Opening fragment
      assert Enum.any?(tok(JSX, "<>hi</>"), fn {_, s} -> s == "<>" end)
      # Closing fragment
      assert Enum.any?(tok(JSX, "<>hi</>"), fn {_, s} -> s == "</>" end)
    end

    test "dotted component tags (e.g. <Router.Route>)" do
      tokens = tok(JSX, "<Router.Route path=\"/\" />")

      assert Enum.any?(tokens, fn {t, s} ->
               t == :name_tag and s == "<Router.Route"
             end)
    end
  end

  describe "TSX" do
    test "combines TS + JSX" do
      src = ~S"const El: React.FC<{n: number}> = ({n}) => <span>{n}</span>"
      tokens = tok(TSX, src)

      # TS features
      assert Enum.any?(tokens, fn {t, s} ->
               t == :keyword_type and s == "number"
             end)

      # JSX features
      assert Enum.any?(tokens, fn {t, s} -> t == :name_tag and s == "<span" end)
    end
  end
end
