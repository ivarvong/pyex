defmodule Mix.Tasks.Pyex.Bench.Budget do
  @shortdoc "Benchmark make_budget.py and report latency percentiles"
  @moduledoc """
  Runs make_budget.py N times in-process and reports latency stats.

      mix pyex.bench.budget [--runs 100] [--file scratch/make_budget.py]

  Options:
    --runs   Number of iterations (default: 100)
    --file   Path to the Python script (default: scratch/make_budget.py)
  """

  use Mix.Task

  @external_resource "lib/mix/tasks/spreadsheet.py"
  @spreadsheet File.read!("lib/mix/tasks/spreadsheet.py")

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [runs: :integer, file: :string, profile: :boolean],
        aliases: [n: :runs, f: :file, p: :profile]
      )

    n = Keyword.get(opts, :runs, 100)
    path = Keyword.get(opts, :file, "scratch/make_budget.py")
    profile? = Keyword.get(opts, :profile, false)

    source =
      case File.read(path) do
        {:ok, src} ->
          src

        {:error, reason} ->
          Mix.shell().error("Cannot read #{path}: #{:file.format_error(reason)}")
          System.halt(1)
      end

    IO.puts("Benchmarking #{path} × #{n} runs#{if profile?, do: " (profiling)", else: ""}...")
    IO.puts("Warming up...\n")

    fs = Pyex.FS.from_map(%{"spreadsheet.py" => @spreadsheet})

    # Warmup run — discarded
    Pyex.run(source, Pyex.Ctx.new(filesystem: fs))

    base_ctx = Pyex.Ctx.new(filesystem: fs, profile: profile?)

    {times_us, merged_profile} =
      Enum.reduce(1..n, {[], nil}, fn _, {times, prof_acc} ->
        t0 = System.monotonic_time(:microsecond)
        {:ok, _, ctx} = Pyex.run(source, base_ctx)
        elapsed = System.monotonic_time(:microsecond) - t0
        {[elapsed | times], merge_profile(prof_acc, ctx.profile)}
      end)

    sorted = Enum.sort(times_us)
    count = length(sorted)

    pct = fn p ->
      idx = min(round(count * p / 100.0) - 1, count - 1)
      Enum.at(sorted, max(idx, 0))
    end

    fmt = fn us -> "#{Float.round(us / 1000.0, 1)}ms" end

    IO.puts("""
    n=#{count}
      min  #{fmt.(hd(sorted))}
      p50  #{fmt.(pct.(50))}
      p90  #{fmt.(pct.(90))}
      p95  #{fmt.(pct.(95))}
      p99  #{fmt.(pct.(99))}
      max  #{fmt.(List.last(sorted))}
    """)

    if profile? && merged_profile do
      print_profile(merged_profile, n)
    end
  end

  defp merge_profile(nil, nil), do: nil
  defp merge_profile(nil, p), do: p

  defp merge_profile(acc, p) do
    call_counts =
      Map.merge(acc.call_counts, p.call_counts, fn _k, a, b -> a + b end)

    call =
      Map.merge(acc.call, p.call, fn _k, a, b -> a + b end)

    %{acc | call_counts: call_counts, call: call}
  end

  defp print_profile(profile, runs) do
    IO.puts("── Function profile (aggregated × #{runs} runs) ──────────────────\n")

    rows =
      profile.call
      |> Enum.map(fn {name, total_ms} ->
        count = Map.get(profile.call_counts, name, 1)
        avg_us = total_ms / count * 1000
        {name, count, total_ms, avg_us}
      end)
      |> Enum.sort_by(fn {_, _, total_ms, _} -> -total_ms end)
      |> Enum.take(20)

    total_ms = rows |> Enum.map(fn {_, _, t, _} -> t end) |> Enum.sum()

    IO.puts(
      String.pad_trailing("function", 30) <>
        String.pad_leading("calls", 10) <>
        String.pad_leading("total_ms", 12) <>
        String.pad_leading("avg_µs", 10) <>
        String.pad_leading("share%", 9)
    )

    IO.puts(String.duplicate("─", 71))

    Enum.each(rows, fn {name, count, t_ms, avg_us} ->
      share = if total_ms > 0, do: t_ms / total_ms * 100, else: 0.0

      IO.puts(
        String.pad_trailing(truncate(name, 30), 30) <>
          String.pad_leading(Integer.to_string(count), 10) <>
          String.pad_leading(fmt_float(t_ms, 1), 12) <>
          String.pad_leading(fmt_float(avg_us, 1), 10) <>
          String.pad_leading(fmt_float(share, 1) <> "%", 9)
      )
    end)

    IO.puts("")
  end

  defp truncate(s, max) when byte_size(s) > max, do: binary_part(s, 0, max - 1) <> "…"
  defp truncate(s, _), do: s

  defp fmt_float(f, decimals), do: :erlang.float_to_binary(f * 1.0, decimals: decimals)
end
