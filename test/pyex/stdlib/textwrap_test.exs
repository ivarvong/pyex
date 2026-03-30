defmodule Pyex.Stdlib.TextwrapTest do
  use ExUnit.Case, async: true

  describe "textwrap.dedent" do
    test "removes uniform indentation" do
      result =
        Pyex.run!("""
        import textwrap
        textwrap.dedent("    hello\\n    world")
        """)

      assert result == "hello\nworld"
    end

    test "handles mixed tabs and spaces by finding common prefix" do
      result =
        Pyex.run!("""
        import textwrap
        textwrap.dedent("\\thello\\n\\tworld")
        """)

      assert result == "hello\nworld"
    end

    test "preserves relative indentation" do
      result =
        Pyex.run!("""
        import textwrap
        textwrap.dedent("    hello\\n        world")
        """)

      assert result == "hello\n    world"
    end

    test "already-dedented text is a no-op" do
      result =
        Pyex.run!("""
        import textwrap
        textwrap.dedent("hello\\nworld")
        """)

      assert result == "hello\nworld"
    end

    test "real-world triple-quoted style dedent" do
      result =
        Pyex.run!("""
        import textwrap
        textwrap.dedent("\\n    hello\\n    world\\n")
        """)

      assert result == "\nhello\nworld\n"
    end
  end

  describe "textwrap.indent" do
    test "adds prefix to non-empty lines" do
      result =
        Pyex.run!("""
        import textwrap
        textwrap.indent("hello\\n\\nworld", "  ")
        """)

      assert result == "  hello\n\n  world"
    end
  end

  describe "textwrap.wrap" do
    test "wraps text at default width" do
      long_text = String.duplicate("word ", 20) |> String.trim()

      result =
        Pyex.run!("""
        import textwrap
        textwrap.wrap("#{long_text}")
        """)

      assert is_list(result)
      assert Enum.all?(result, fn line -> String.length(line) <= 70 end)
    end

    test "wraps text at custom width" do
      result =
        Pyex.run!("""
        import textwrap
        textwrap.wrap("hello world foo bar", width=10)
        """)

      assert is_list(result)
      assert Enum.all?(result, fn line -> String.length(line) <= 10 end)
    end
  end

  describe "textwrap.fill" do
    test "returns a single string with newlines" do
      result =
        Pyex.run!("""
        import textwrap
        textwrap.fill("hello world foo bar baz", width=10)
        """)

      assert is_binary(result)
      assert String.contains?(result, "\n")

      for line <- String.split(result, "\n") do
        assert String.length(line) <= 10
      end
    end
  end
end
