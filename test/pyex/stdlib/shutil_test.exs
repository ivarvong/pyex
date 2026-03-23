defmodule Pyex.Stdlib.ShutilTest do
  use ExUnit.Case, async: true

  alias Pyex.Filesystem.Memory

  test "copytree move and rmtree work" do
    fs =
      Memory.new(%{
        "src/posts/a.md" => "A",
        "src/posts/nested/b.md" => "B"
      })

    result =
      Pyex.run!(
        """
        import os
        import shutil
        shutil.copytree("/src/posts", "/dist/posts")
        shutil.move("/dist/posts/a.md", "/dist/index.md")
        before = sorted([name for root, dirs, files in os.walk("/dist") for name in files])
        shutil.rmtree("/src")
        after = sorted([name for root, dirs, files in os.walk("/dist") for name in files])
        (before, after)
        """,
        filesystem: fs
      )

    assert result == {:tuple, [["b.md", "index.md"], ["b.md", "index.md"]]}
  end
end
