defmodule Pyex.MixTaskPyexTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "reads source from stdin when path is '-'" do
    output =
      capture_io("print('hello from stdin')\n", fn ->
        Mix.Tasks.Pyex.run(["-"])
      end)

    assert output =~ "hello from stdin"
  end

  test "stdin source can span multiple lines (heredoc style)" do
    source = """
    def greet(name):
        return "hi " + name
    print(greet("ivar"))
    """

    output =
      capture_io(source, fn ->
        Mix.Tasks.Pyex.run(["-"])
      end)

    assert output =~ "hi ivar"
  end
end
