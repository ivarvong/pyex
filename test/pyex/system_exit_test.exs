defmodule Pyex.SystemExitTest do
  use ExUnit.Case, async: true

  test "sys.exit() returns ok with nil (clean exit)" do
    assert {:ok, nil, _ctx} =
             Pyex.run("""
             import sys
             sys.exit()
             """)
  end

  test "sys.exit(0) returns ok with nil (clean exit)" do
    assert {:ok, nil, _ctx} =
             Pyex.run("""
             import sys
             sys.exit(0)
             """)
  end

  test "sys.exit(1) is reported as an error" do
    assert {:error, %Pyex.Error{message: msg}} =
             Pyex.run("""
             import sys
             sys.exit(1)
             """)

    assert msg =~ "SystemExit: 1"
  end

  test "sys.exit() preserves prior print output in ctx" do
    assert {:ok, nil, ctx} =
             Pyex.run("""
             import sys
             print("before exit")
             sys.exit()
             """)

    assert Pyex.output(ctx) =~ "before exit"
  end
end
