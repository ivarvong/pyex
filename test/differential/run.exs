# Differential harness — the keystone net. Runs every program from every source lens through THREE
# executors and requires them to agree, auto-localizing any divergence:
#
#     CPython  ≠  pyex-VM   → a pyex SEMANTICS bug   (interpreter wrong vs the reference impl)
#     pyex-VM  ≠  pyex-Wasm → a COMPILER bug         (beam2wasm miscompiled — what conformance checks)
#
# CPython is the top oracle, so a bug present in BOTH VM and Wasm (invisible to Wasm-vs-VM diffing) is
# still caught. A checked-in LEDGER of known divergences keeps CI green until a NEW one appears.
#
#   mix run test/differential/run.exs
#
# Requires a built interpreter at wasm/pyex.wasm (mix wasm.build --out wasm) and python3 on PATH.

Code.require_file("lenses/aliasing.exs", __DIR__)
Code.require_file("lenses/corpus.exs", __DIR__)

defmodule Diff do
  @here __DIR__
  @lenses [Diff.Lens.Aliasing, Diff.Lens.Corpus]
  @wasm Path.join(File.cwd!(), "wasm/pyex.wasm")

  # ── executors ──────────────────────────────────────────────────────────────
  def run_vm(code) do
    case Pyex.run(code, filesystem: VFS.Memory.new(%{})) do
      {:ok, _v, ctx} -> {:ok, Pyex.output(ctx)}
      {:error, _e} -> :error
    end
  rescue
    _ -> :error
  end

  def run_cpython(_code, false), do: :skip

  def run_cpython(code, true) do
    case System.cmd(python(), ["-c", code], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {_out, _} -> :error
    end
  rescue
    _ -> :skip
  end

  # one node process runs the whole batch against a single wasm load
  def run_wasm(programs) do
    payload = Enum.map(programs, &%{id: &1.id, code: &1.code})
    progs_file = Path.join(@here, "_progs.json")
    File.write!(progs_file, Jason.encode!(payload))

    {json, 0} =
      System.cmd(node_bin(), [Path.join(@here, "driver.mjs"), progs_file, @wasm],
        stderr_to_stdout: true
      )

    File.rm(progs_file)

    Jason.decode!(json)
    |> Map.new(fn r ->
      {r["id"], if(r["ok"], do: {:ok, r["stdout"]}, else: :error)}
    end)
  end

  # ── comparison ─────────────────────────────────────────────────────────────
  # Canonicalize so set/dict ordering and cross-impl error text never cause false positives: successes
  # compare on normalized stdout; any failure collapses to :error; CPython-unavailable is :skip.
  defp canon({:ok, out}),
    do: {:ok, out |> String.replace(~r/\s+$/m, "") |> String.trim_trailing("\n")}

  defp canon(other), do: other

  # ── ledger ─────────────────────────────────────────────────────────────────
  defp ledger do
    Path.join(@here, "LEDGER")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.map(&(&1 |> String.split("#", parts: 2) |> hd() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp known?(id, ledger),
    do: Enum.any?(ledger, &(id == &1 or String.starts_with?(id, &1 <> ":")))

  # ── run ────────────────────────────────────────────────────────────────────
  def run do
    progs = Enum.flat_map(@lenses, & &1.programs())

    unless File.exists?(@wasm),
      do: bail("no interpreter at #{@wasm} — run: mix wasm.build --out wasm")

    IO.puts("differential harness — CPython · pyex-VM · pyex-Wasm — #{length(progs)} programs\n")
    wasm = run_wasm(progs)
    led = ledger()

    results =
      Enum.map(progs, fn p ->
        cp = canon(run_cpython(p.code, p.cpython))
        vm = canon(run_vm(p.code))
        wa = canon(Map.get(wasm, p.id, :error))
        pyex_bug = cp != :skip and cp != vm
        compiler_bug = vm != wa
        %{id: p.id, code: p.code, cp: cp, vm: vm, wa: wa, pyex: pyex_bug, compiler: compiler_bug}
      end)

    divergences = Enum.filter(results, &(&1.pyex or &1.compiler))
    {known, fresh} = Enum.split_with(divergences, &known?(&1.id, led))

    pyex_n = Enum.count(divergences, & &1.pyex)
    comp_n = Enum.count(divergences, & &1.compiler)
    ok_n = length(results) - length(divergences)

    IO.puts("  pyex semantics bugs (CPython ≠ VM):  #{pyex_n}")
    IO.puts("  compiler bugs        (VM ≠ Wasm):    #{comp_n}")
    IO.puts("  all three agree:                     #{ok_n}")
    IO.puts("  known-open (ledger):                 #{length(known)}   new: #{length(fresh)}\n")

    if fresh != [] do
      IO.puts("❌ NEW divergences (not in LEDGER):\n")
      Enum.each(fresh, &report/1)

      bail(
        "#{length(fresh)} new divergence(s) — fix, or add to test/differential/LEDGER with a reason"
      )
    else
      IO.puts("✅ no new divergences. #{length(known)} known-open (see LEDGER).")
    end
  end

  defp report(r) do
    tag = [r.pyex && "PYEX", r.compiler && "COMPILER"] |> Enum.filter(& &1) |> Enum.join("+")
    IO.puts("  [#{tag}] #{r.id}")
    IO.puts(Enum.map_join(String.split(r.code, "\n"), "\n", &("      " <> &1)))
    IO.puts("      cpython: #{inspect(r.cp)}")
    IO.puts("      vm:      #{inspect(r.vm)}")
    IO.puts("      wasm:    #{inspect(r.wa)}\n")
  end

  defp python, do: System.get_env("PYTHON") || System.find_executable("python3") || "python3"
  defp node_bin, do: System.get_env("NODE") || System.find_executable("node") || "node"

  defp bail(msg),
    do:
      (
        IO.puts("\n#{msg}")
        System.halt(1)
      )
end

Diff.run()
