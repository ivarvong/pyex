ExUnit.start()

if System.get_env("PYEX_TRACE") == "1" do
  ExUnit.after_suite(fn _results ->
    Process.sleep(50)
    Pyex.Trace.flush()
  end)
end
