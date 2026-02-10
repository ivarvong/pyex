defmodule Pyex.CustomModulesTest do
  use ExUnit.Case, async: true

  alias Pyex.Error

  describe "custom modules via plain map" do
    test "import and call a custom function" do
      result =
        Pyex.run!(
          """
          import mylib
          mylib.add(3, 4)
          """,
          modules: %{
            "mylib" => %{
              "add" => {:builtin, fn [a, b] -> a + b end}
            }
          }
        )

      assert result == 7
    end

    test "from import a custom function" do
      result =
        Pyex.run!(
          """
          from mylib import greet
          greet("world")
          """,
          modules: %{
            "mylib" => %{
              "greet" => {:builtin, fn [name] -> "hello " <> name end}
            }
          }
        )

      assert result == "hello world"
    end

    test "custom module with constants" do
      result =
        Pyex.run!(
          """
          import config
          config.VERSION
          """,
          modules: %{
            "config" => %{
              "VERSION" => "2.0.1"
            }
          }
        )

      assert result == "2.0.1"
    end

    test "custom module with mixed functions and constants" do
      result =
        Pyex.run!(
          """
          import mymath
          mymath.double(mymath.BASE)
          """,
          modules: %{
            "mymath" => %{
              "BASE" => 21,
              "double" => {:builtin, fn [x] -> x * 2 end}
            }
          }
        )

      assert result == 42
    end

    test "multiple custom modules" do
      result =
        Pyex.run!(
          """
          import auth
          import db
          user = auth.get_user()
          db.save(user)
          """,
          modules: %{
            "auth" => %{
              "get_user" => {:builtin, fn [] -> "alice" end}
            },
            "db" => %{
              "save" => {:builtin, fn [name] -> "saved:" <> name end}
            }
          }
        )

      assert result == "saved:alice"
    end

    test "custom module coexists with stdlib" do
      result =
        Pyex.run!(
          """
          import math
          import mylib
          mylib.scale(math.pi, 2)
          """,
          modules: %{
            "mylib" => %{
              "scale" => {:builtin, fn [x, factor] -> x * factor end}
            }
          }
        )

      assert_in_delta result, :math.pi() * 2, 0.0001
    end

    test "custom module overrides stdlib" do
      result =
        Pyex.run!(
          """
          import json
          json.parse("test")
          """,
          modules: %{
            "json" => %{
              "parse" => {:builtin, fn [s] -> "custom:" <> s end}
            }
          }
        )

      assert result == "custom:test"
    end

    test "from import with alias" do
      result =
        Pyex.run!(
          """
          from mylib import calculate as calc
          calc(10)
          """,
          modules: %{
            "mylib" => %{
              "calculate" => {:builtin, fn [x] -> x * x end}
            }
          }
        )

      assert result == 100
    end

    test "import with alias" do
      result =
        Pyex.run!(
          """
          import mylib as ml
          ml.value
          """,
          modules: %{
            "mylib" => %{
              "value" => 42
            }
          }
        )

      assert result == 42
    end

    test "ImportError for missing name in custom module" do
      {:error, %Error{message: msg}} =
        Pyex.run(
          """
          from mylib import nonexistent
          """,
          modules: %{
            "mylib" => %{
              "exists" => 1
            }
          }
        )

      assert msg =~ "ImportError"
      assert msg =~ "nonexistent"
    end

    test "custom module with keyword-aware function" do
      result =
        Pyex.run!(
          """
          import mylib
          mylib.format("hello", prefix=">> ")
          """,
          modules: %{
            "mylib" => %{
              "format" =>
                {:builtin_kw,
                 fn [text], kwargs ->
                   prefix = Map.get(kwargs, "prefix", "")
                   prefix <> text
                 end}
            }
          }
        )

      assert result == ">> hello"
    end
  end

  describe "custom modules via behaviour" do
    defmodule TestModule do
      @behaviour Pyex.Stdlib.Module

      @impl Pyex.Stdlib.Module
      def module_value do
        %{
          "multiply" => {:builtin, fn [a, b] -> a * b end},
          "MAGIC" => 42
        }
      end
    end

    test "import behaviour module" do
      result =
        Pyex.run!(
          """
          import testmod
          testmod.multiply(testmod.MAGIC, 2)
          """,
          modules: %{"testmod" => TestModule}
        )

      assert result == 84
    end

    test "from import behaviour module" do
      result =
        Pyex.run!(
          """
          from testmod import multiply, MAGIC
          multiply(MAGIC, 3)
          """,
          modules: %{"testmod" => TestModule}
        )

      assert result == 126
    end
  end

  describe "custom modules via run" do
    test "modules passed through Ctx" do
      ctx =
        Pyex.Ctx.new(
          modules: %{
            "mylib" => %{
              "value" => 99
            }
          }
        )

      {:ok, result, _ctx} =
        Pyex.run(
          """
          import mylib
          mylib.value
          """,
          ctx
        )

      assert result == 99
    end
  end

  describe "edge cases" do
    test "empty custom modules map" do
      result = Pyex.run!("1 + 2", modules: %{})
      assert result == 3
    end

    test "custom module with no functions" do
      result =
        Pyex.run!(
          """
          import empty
          type(empty)
          """,
          modules: %{"empty" => %{}}
        )

      assert result != nil
    end

    test "custom function returning complex types" do
      result =
        Pyex.run!(
          """
          import mylib
          mylib.get_data()
          """,
          modules: %{
            "mylib" => %{
              "get_data" =>
                {:builtin,
                 fn [] ->
                   %{"name" => "test", "values" => [1, 2, 3]}
                 end}
            }
          }
        )

      assert result == %{"name" => "test", "values" => [1, 2, 3]}
    end

    test "custom function interacting with Python code" do
      result =
        Pyex.run!(
          """
          from mylib import transform
          data = [1, 2, 3, 4, 5]
          result = []
          for item in data:
              result.append(transform(item))
          result
          """,
          modules: %{
            "mylib" => %{
              "transform" => {:builtin, fn [x] -> x * x end}
            }
          }
        )

      assert result == [1, 4, 9, 16, 25]
    end
  end
end
