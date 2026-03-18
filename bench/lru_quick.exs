Code.require_file("test/support/fixture.ex")

fixture = Pyex.Test.Fixture.load!("lru_cache")
fs = Pyex.Filesystem.Memory.new(fixture.input_fs)
{:ok, ast} = Pyex.compile(fixture.source)

times =
  for _ <- 1..10 do
    {us, {:ok, _, _}} = :timer.tc(fn -> Pyex.run(ast, filesystem: fs) end)
    us / 1000
  end

avg = Enum.sum(times) / length(times)
med = Enum.sort(times) |> Enum.at(div(length(times), 2))
min = Enum.min(times)

IO.puts(
  "LRU Cache: avg=#{Float.round(avg, 1)}ms  med=#{Float.round(med, 1)}ms  min=#{Float.round(min, 1)}ms"
)
