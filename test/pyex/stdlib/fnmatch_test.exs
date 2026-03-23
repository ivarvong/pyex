defmodule Pyex.Stdlib.FnmatchTest do
  use ExUnit.Case, async: true

  test "fnmatch and filter work" do
    result =
      Pyex.run!("""
      import fnmatch
      (
          fnmatch.fnmatch("hello.md", "*.md"),
          fnmatch.fnmatchcase("HELLO.md", "*.md"),
          fnmatch.filter(["a.md", "b.txt", "c.md"], "*.md")
      )
      """)

    assert result == {:tuple, [true, true, ["a.md", "c.md"]]}
  end
end
