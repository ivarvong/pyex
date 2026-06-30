#!/usr/bin/env bash
#
# Proves pyex compiles AND runs as a *bare* dependency — with none of its
# optional backends (:postgrex for `sql`, :explorer for `pandas`) installed.
#
# pyex's own build always has the optional deps present (they're `optional: true`,
# which still fetches them in the defining project), so its own compile/tests
# cannot catch the "references an undeclared or optional dep at compile time"
# regression class. A throwaway consumer that depends on pyex and nothing else
# can. This is the guard that keeps `{:pyex, "~> x"}` actually installable.
set -euo pipefail

PYEX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > mix.exs <<EOF
defmodule ConsumerSmoke.MixProject do
  use Mix.Project

  def project do
    [
      app: :consumer_smoke,
      version: "0.0.0",
      elixir: "~> 1.18",
      deps: [{:pyex, path: "$PYEX_DIR"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
EOF
mkdir -p lib config
cp "$PYEX_DIR/.tool-versions" . 2>/dev/null || true

echo "==> resolving + compiling pyex as a bare dependency"
mix deps.get
mix compile

echo "==> asserting behavior with no optional backends present"
mix run -e '
  # The optional backends must genuinely be absent for this to mean anything.
  false = Code.ensure_loaded?(Explorer)
  false = Code.ensure_loaded?(Postgrex)

  # Core interpreter runs.
  {:ok, [1, 2, 3], _} = Pyex.run("sorted([3, 1, 2])")
  {:ok, ~s({"a": 1}), _} = Pyex.run("import json\njson.dumps({\"a\": 1})")

  # Optional features degrade to a clean ImportError — never a host crash.
  {:error, %Pyex.Error{kind: :import}} = Pyex.run("import pandas")
  {:error, %Pyex.Error{kind: :import}} = Pyex.run("import sql")

  IO.puts("consumer smoke: OK — pyex compiles + runs with no optional deps")
'
