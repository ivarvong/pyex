# Source lens: a curated corpus of small, self-contained, deterministic Python programs shaped like
# REAL code (algorithms, data munging, classes, generators, comprehensions…). Real code composes
# features, so it crosses the seams isolation unit tests never reach. Drop a `.py` into corpus/ to add
# a case — the harness diffs it against CPython automatically (no expected-output to maintain).
defmodule Diff.Lens.Corpus do
  @dir Path.join(__DIR__, "../corpus")

  def programs do
    Path.wildcard(Path.join(@dir, "*.py"))
    |> Enum.sort()
    |> Enum.map(fn path ->
      %{id: "corpus:#{Path.basename(path, ".py")}", code: File.read!(path), cpython: true}
    end)
  end
end
