#!/usr/bin/env bash
#
# Proves pyex installs and runs the way a real consumer gets it: from the built
# HEX PACKAGE (only the files in `package/0`'s `:files` list), with none of its
# optional backends (:postgrex for `sql`, :explorer for `pandas`, :cmark for
# `markdown`) installed.
#
# This catches two regression classes pyex's own build cannot:
#   1. Uses-but-doesn't-declare / can't-compile-without an optional dep — pyex's
#      own build always has the optional deps present.
#   2. A compile-time file (an @external_resource, a data dir) left out of the
#      package's `:files` — invisible to a path dep, which ships the whole repo.
set -euo pipefail

PYEX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$PYEX_DIR"/pyex-*.tar' EXIT

# 1. Build the package exactly as `mix hex.publish` would, and unpack the
#    contents so we depend on the shipped files, not the working tree.
cd "$PYEX_DIR"
mix deps.get >/dev/null
mix hex.build >/dev/null
tar xf pyex-*.tar -C "$WORK"
mkdir -p "$WORK/pkg"
tar xzf "$WORK/contents.tar.gz" -C "$WORK/pkg"

# 2. A throwaway consumer depending on the unpacked package and nothing else.
cat > "$WORK/mix.exs" <<EOF
defmodule ConsumerSmoke.MixProject do
  use Mix.Project

  def project do
    [
      app: :consumer_smoke,
      version: "0.0.0",
      elixir: "~> 1.18",
      deps: [{:pyex, path: "$WORK/pkg"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
EOF
mkdir -p "$WORK/lib" "$WORK/config"
cp "$PYEX_DIR/.tool-versions" "$WORK/" 2>/dev/null || true

cd "$WORK"
echo "==> resolving + compiling the packaged pyex as a bare dependency"
mix deps.get
mix compile

echo "==> asserting behavior with no optional backends present"
mix run -e '
  # The optional backends must genuinely be absent for this to mean anything.
  false = Code.ensure_loaded?(Explorer)
  false = Code.ensure_loaded?(Postgrex)
  false = Code.ensure_loaded?(Cmark)

  # Core interpreter runs (incl. a stdlib that touches zoneinfo data).
  {:ok, [1, 2, 3], _} = Pyex.run("sorted([3, 1, 2])")
  {:ok, ~s({"a": 1}), _} = Pyex.run("import json\njson.dumps({\"a\": 1})")
  {:ok, _, _} = Pyex.run("from datetime import datetime, timezone\ndatetime.now(timezone.utc).year")

  # Optional features degrade to a clean ImportError — never a host crash.
  {:error, %Pyex.Error{kind: :import}} = Pyex.run("import pandas")
  {:error, %Pyex.Error{kind: :import}} = Pyex.run("import sql")
  {:error, %Pyex.Error{kind: :import}} = Pyex.run("import markdown")

  IO.puts("consumer smoke: OK — the hex package compiles + runs with no optional deps")
'
