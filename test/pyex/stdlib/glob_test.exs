defmodule Pyex.Stdlib.GlobTest do
  use ExUnit.Case, async: true

  alias Pyex.Filesystem.Memory

  describe "glob.glob" do
    test "matches files in an absolute directory" do
      fs = Memory.new(%{"posts/a.md" => "", "posts/b.md" => "", "posts/c.txt" => ""})

      result =
        Pyex.run!(
          """
          import glob
          sorted(glob.glob("/posts/*.md"))
          """,
          filesystem: fs
        )

      assert result == ["/posts/a.md", "/posts/b.md"]
    end

    test "returns empty list when nothing matches" do
      fs = Memory.new(%{"posts/a.txt" => ""})

      result =
        Pyex.run!(
          """
          import glob
          glob.glob("posts/*.md")
          """,
          filesystem: fs
        )

      assert result == []
    end
  end
end
