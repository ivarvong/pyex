default_excludes = [:postgres, :r2, :external_http]

extra_excludes =
  if Pyex.Test.Oracle.python3_available?() do
    []
  else
    IO.puts(:stderr, "python3 not found on PATH — excluding :requires_python3 tests")
    [:requires_python3]
  end

ExUnit.start(exclude: default_excludes ++ extra_excludes)

if System.get_env("PYEX_TRACE") == "1" do
  trace = Pyex.Trace.attach()

  ExUnit.after_suite(fn _results ->
    Pyex.Trace.flush(trace)
  end)
end
