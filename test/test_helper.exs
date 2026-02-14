ExUnit.start(exclude: [:postgres, :r2])

if System.get_env("PYEX_TRACE") == "1" do
  trace = Pyex.Trace.attach()

  ExUnit.after_suite(fn _results ->
    Pyex.Trace.flush(trace)
  end)
end
