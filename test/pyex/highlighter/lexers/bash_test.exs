defmodule Pyex.Highlighter.Lexers.BashTest do
  use ExUnit.Case, async: true

  alias Pyex.Highlighter.Lexer
  alias Pyex.Highlighter.Lexers.Bash

  defp tokenize(src), do: Lexer.tokenize(Bash, src)

  defp has_token?(src, type, text) do
    Enum.any?(tokenize(src), fn {t, s} -> t == type and s == text end)
  end

  test "round-trips losslessly" do
    src = """
    #!/bin/bash
    # deploy script
    set -e

    NAME="world"
    echo "hello, $NAME"

    for f in *.txt; do
      cat "$f" | wc -l
    done
    """

    reconstructed = tokenize(src) |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
    assert reconstructed == src
  end

  test "shebang" do
    assert has_token?("#!/bin/bash\nls", :comment_hashbang, "#!/bin/bash")
  end

  test "comments" do
    assert has_token?("# hi\n", :comment_single, "# hi")
  end

  test "keywords" do
    assert has_token?("if x; then y; fi", :keyword, "if")
    assert has_token?("if x; then y; fi", :keyword, "then")
    assert has_token?("if x; then y; fi", :keyword, "fi")
    assert has_token?("for x in 1 2; do echo; done", :keyword, "for")
    assert has_token?("for x in 1 2; do echo; done", :keyword, "do")
    assert has_token?("for x in 1 2; do echo; done", :keyword, "done")
  end

  test "variable assignment" do
    assert has_token?("FOO=bar", :name_variable, "FOO")
    assert has_token?("FOO=bar", :operator, "=")
  end

  test "variable expansion" do
    assert has_token?("echo $USER", :name_variable, "$USER")
    assert has_token?(~s(echo "${HOME}/bin"), :name_variable, "${HOME}")
    assert has_token?("echo $1", :name_variable, "$1")
    assert has_token?("echo $?", :name_variable, "$?")
  end

  test "strings" do
    assert has_token?(~s(echo "hello"), :string_double, ~s("hello"))
    assert has_token?(~s(echo 'literal'), :string_single, ~s('literal'))
  end

  test "backticks" do
    assert has_token?("echo `date`", :string_backtick, "`date`")
  end

  test "command substitution" do
    assert has_token?("x=$(date)", :string_interpol, "$(date)")
  end

  test "builtin commands" do
    assert has_token?("echo hi", :name_builtin, "echo")
    assert has_token?("export PATH=/usr/bin", :name_builtin, "export")
    assert has_token?("cd /tmp", :name_builtin, "cd")
  end

  test "pipes and redirects" do
    assert has_token?("cat f | grep x", :operator, "|")
    assert has_token?("cmd > out", :operator, ">")
    assert has_token?("cmd >> log", :operator, ">>")
    assert has_token?("a && b", :operator, "&&")
    assert has_token?("a || b", :operator, "||")
  end

  test "function definitions" do
    # `function name` form
    tokens = tokenize("function greet() { echo hi; }")
    assert {:keyword, "function"} in tokens
    assert {:name_function, "greet"} in tokens
  end

  test "function POSIX form: name() { ... }" do
    tokens = tokenize("greet() { echo hi; }")
    # POSIX form should still get greet as :name_function
    assert {:name_function, "greet"} in tokens
  end

  test "flags" do
    assert has_token?("ls -la", :name_attribute, "-la")
    assert has_token?("curl --verbose", :name_attribute, "--verbose")
  end
end
