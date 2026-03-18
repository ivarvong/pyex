Code.require_file("test/support/fixture.ex")

alias Pyex.Test.Fixture

fixtures =
  Fixture.list_all()
  |> Enum.map(fn name ->
    fixture = Fixture.load!(name)
    fs = Pyex.Filesystem.Memory.new(fixture.input_fs)
    {:ok, ast} = Pyex.compile(fixture.source)
    {name, ast, fs}
  end)

benches =
  Map.new(fixtures, fn {name, ast, fs} ->
    {name, fn -> Pyex.run(ast, filesystem: fs) end}
  end)

Benchee.run(benches,
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: true, benchmarking: true]
)
