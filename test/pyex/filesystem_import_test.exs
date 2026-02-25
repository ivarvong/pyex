defmodule Pyex.FilesystemImportTest do
  use ExUnit.Case, async: true

  alias Pyex.{Ctx, Error, Filesystem.Memory}

  defp run_with_fs!(code, files) do
    fs = Memory.new(files)
    ctx = Ctx.new(filesystem: fs)

    case Pyex.run(code, ctx) do
      {:ok, value, ctx} -> {value, ctx}
      {:error, %Error{message: msg}} -> raise "Pyex error: #{msg}"
    end
  end

  defp run_with_fs(code, files) do
    fs = Memory.new(files)
    ctx = Ctx.new(filesystem: fs)
    Pyex.run(code, ctx)
  end

  describe "basic import from filesystem" do
    test "import a module with a function" do
      {result, _ctx} =
        run_with_fs!(
          """
          import helpers
          helpers.double(21)
          """,
          %{
            "helpers.py" => """
            def double(x):
                return x * 2
            """
          }
        )

      assert result == 42
    end

    test "import a module with a constant" do
      {result, _ctx} =
        run_with_fs!(
          """
          import config
          config.VERSION
          """,
          %{
            "config.py" => """
            VERSION = "1.0.0"
            """
          }
        )

      assert result == "1.0.0"
    end

    test "import a module with a class" do
      {result, _ctx} =
        run_with_fs!(
          """
          import models
          p = models.Point(3, 4)
          p.x + p.y
          """,
          %{
            "models.py" => """
            class Point:
                def __init__(self, x, y):
                    self.x = x
                    self.y = y
            """
          }
        )

      assert result == 7
    end
  end

  describe "from-import from filesystem" do
    test "from module import specific name" do
      {result, _ctx} =
        run_with_fs!(
          """
          from helpers import double
          double(21)
          """,
          %{
            "helpers.py" => """
            def double(x):
                return x * 2

            def triple(x):
                return x * 3
            """
          }
        )

      assert result == 42
    end

    test "from module import multiple names" do
      {result, _ctx} =
        run_with_fs!(
          """
          from helpers import double, triple
          double(10) + triple(10)
          """,
          %{
            "helpers.py" => """
            def double(x):
                return x * 2

            def triple(x):
                return x * 3
            """
          }
        )

      assert result == 50
    end

    test "from module import with alias" do
      {result, _ctx} =
        run_with_fs!(
          """
          from helpers import double as d
          d(21)
          """,
          %{
            "helpers.py" => """
            def double(x):
                return x * 2
            """
          }
        )

      assert result == 42
    end

    test "from module import nonexistent name" do
      {:error, %Error{message: msg}} =
        run_with_fs(
          """
          from helpers import nonexistent
          """,
          %{
            "helpers.py" => """
            def double(x):
                return x * 2
            """
          }
        )

      assert msg =~ "ImportError"
      assert msg =~ "nonexistent"
    end
  end

  describe "import as alias from filesystem" do
    test "import module as alias" do
      {result, _ctx} =
        run_with_fs!(
          """
          import helpers as h
          h.double(21)
          """,
          %{
            "helpers.py" => """
            def double(x):
                return x * 2
            """
          }
        )

      assert result == 42
    end
  end

  describe "module caching" do
    test "importing same module twice uses cache" do
      {result, _ctx} =
        run_with_fs!(
          """
          import helpers
          a = helpers.double(10)
          import helpers
          b = helpers.double(20)
          a + b
          """,
          %{
            "helpers.py" => """
            counter = 0

            def double(x):
                return x * 2
            """
          }
        )

      assert result == 60
    end

    test "from-import after import uses cache" do
      {result, _ctx} =
        run_with_fs!(
          """
          import helpers
          a = helpers.double(10)
          from helpers import double
          b = double(20)
          a + b
          """,
          %{
            "helpers.py" => """
            def double(x):
                return x * 2
            """
          }
        )

      assert result == 60
    end
  end

  describe "module with side effects" do
    test "module-level code executes on import" do
      {_result, ctx} =
        run_with_fs!(
          """
          import greeter
          """,
          %{
            "greeter.py" => """
            print("module loaded")
            """
          }
        )

      assert ctx |> Pyex.output() |> IO.iodata_to_binary() =~ "module loaded"
    end

    test "module-level code executes only once with caching" do
      {_result, ctx} =
        run_with_fs!(
          """
          import greeter
          import greeter
          """,
          %{
            "greeter.py" => """
            print("module loaded")
            """
          }
        )

      assert ctx |> Pyex.output() |> IO.iodata_to_binary() |> String.split("\n") |> length() == 1
    end
  end

  describe "module importing another module" do
    test "chained imports work" do
      {result, _ctx} =
        run_with_fs!(
          """
          import app
          app.run()
          """,
          %{
            "app.py" => """
            import utils
            def run():
                return utils.add(1, 2)
            """,
            "utils.py" => """
            def add(a, b):
                return a + b
            """
          }
        )

      assert result == 3
    end

    test "from-import in imported module" do
      {result, _ctx} =
        run_with_fs!(
          """
          import app
          app.run()
          """,
          %{
            "app.py" => """
            from utils import multiply
            def run():
                return multiply(6, 7)
            """,
            "utils.py" => """
            def multiply(a, b):
                return a * b
            """
          }
        )

      assert result == 42
    end
  end

  describe "error handling" do
    test "import nonexistent file" do
      {:error, %Error{message: msg}} =
        run_with_fs(
          """
          import nonexistent
          """,
          %{}
        )

      assert msg =~ "ImportError"
      assert msg =~ "nonexistent"
    end

    test "import file with syntax error" do
      {:error, %Error{message: msg}} =
        run_with_fs(
          """
          import broken
          """,
          %{
            "broken.py" => """
            def incomplete(
            """
          }
        )

      assert msg =~ "SyntaxError"
      assert msg =~ "broken"
    end

    test "import file with runtime error" do
      {:error, %Error{message: msg}} =
        run_with_fs(
          """
          import broken
          """,
          %{
            "broken.py" => """
            x = 1 / 0
            """
          }
        )

      assert msg =~ "ImportError"
      assert msg =~ "broken"
    end
  end

  describe "no filesystem configured" do
    test "falls back to ImportError when no filesystem" do
      {:error, _} = Pyex.run("import custom_thing")
    end
  end

  describe "dunder names are excluded" do
    test "module bindings skip __dunder__ names" do
      {result, _ctx} =
        run_with_fs!(
          """
          import mymod
          mymod.visible
          """,
          %{
            "mymod.py" => """
            __private__ = "hidden"
            visible = "shown"
            """
          }
        )

      assert result == "shown"
    end
  end

  describe "builtin modules take precedence" do
    test "import math still works" do
      {result, _ctx} =
        run_with_fs!(
          """
          import math
          math.pi > 3
          """,
          %{
            "math.py" => """
            pi = 0
            """
          }
        )

      assert result == true
    end

    test "custom ctx modules take precedence over filesystem" do
      fs = Memory.new(%{"mymod.py" => "value = 'from_file'"})

      ctx =
        Ctx.new(
          filesystem: fs,
          modules: %{"mymod" => %{"value" => "from_ctx"}}
        )

      {:ok, result, _ctx} = Pyex.run("import mymod; mymod.value", ctx)
      assert result == "from_ctx"
    end
  end

  describe "realistic scenarios" do
    test "utility library with multiple functions" do
      {result, _ctx} =
        run_with_fs!(
          """
          from stringutils import capitalize, reverse
          capitalize("hello") + " " + reverse("dlrow")
          """,
          %{
            "stringutils.py" => """
            def capitalize(s):
                if len(s) == 0:
                    return s
                return s[0].upper() + s[1:]

            def reverse(s):
                result = ""
                for ch in s:
                    result = ch + result
                return result
            """
          }
        )

      assert result == "Hello world"
    end

    test "data processing pipeline" do
      {result, _ctx} =
        run_with_fs!(
          """
          import processor
          data = [1, 2, 3, 4, 5]
          processor.sum_squares(data)
          """,
          %{
            "processor.py" => """
            def square(x):
                return x * x

            def sum_squares(items):
                return sum([square(x) for x in items])
            """
          }
        )

      assert result == 55
    end

    test "configuration module" do
      {_result, ctx} =
        run_with_fs!(
          """
          import config
          print(config.DB_HOST + ":" + str(config.DB_PORT))
          """,
          %{
            "config.py" => """
            DB_HOST = "localhost"
            DB_PORT = 5432
            DEBUG = True
            """
          }
        )

      assert ctx |> Pyex.output() |> IO.iodata_to_binary() =~ "localhost:5432"
    end
  end
end
