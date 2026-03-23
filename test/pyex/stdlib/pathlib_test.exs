defmodule Pyex.Stdlib.PathlibTest do
  use ExUnit.Case, async: true

  alias Pyex.Filesystem.Memory

  describe "pathlib.Path" do
    test "glob returns path objects with usable stem values" do
      fs = Memory.new(%{"posts/alpha.md" => "", "posts/beta.md" => "", "posts/readme.txt" => ""})

      result =
        Pyex.run!(
          """
          from pathlib import Path
          sorted([path.stem for path in Path("/posts").glob("*.md")])
          """,
          filesystem: fs
        )

      assert result == ["alpha", "beta"]
    end

    test "write_text and read_text persist data" do
      fs = Memory.new()

      result =
        Pyex.run!(
          """
          from pathlib import Path
          path = Path("/dist") / "index.html"
          wrote = path.write_text("hello")
          (wrote, path.read_text(), path.stem)
          """,
          filesystem: fs
        )

      assert result == {:tuple, [5, "hello", "index"]}
    end

    test "path objects work with open" do
      fs = Memory.new(%{"posts/hello.md" => "hello world"})

      result =
        Pyex.run!(
          """
          from pathlib import Path
          path = Path("/posts") / "hello.md"
          with open(path) as f:
              f.read()
          """,
          filesystem: fs
        )

      assert result == "hello world"
    end

    test "exists parent and with_suffix helpers work" do
      fs = Memory.new(%{"posts/hello.md" => "hello world"})

      result =
        Pyex.run!(
          """
          from pathlib import Path
          path = Path("/posts/hello.md")
          (path.exists(), path.is_file(), path.parent.name, str(path.with_suffix(".html")))
          """,
          filesystem: fs
        )

      assert result == {:tuple, [true, true, "posts", "/posts/hello.html"]}
    end

    test "mkdir iterdir and unlink work" do
      fs = Memory.new()

      result =
        Pyex.run!(
          """
          from pathlib import Path
          out = Path("/dist")
          out.mkdir(parents=True, exist_ok=True)
          page = out / "index.html"
          page.write_text("hello")
          names = sorted([child.name for child in out.iterdir()])
          page.unlink()
          (names, out.is_dir(), page.exists())
          """,
          filesystem: fs
        )

      assert result == {:tuple, [["index.html"], true, false]}
    end
  end
end
