defmodule Pyex.FilesystemModuleCompositionTest do
  @moduledoc """
  Tests that exercise sharing Python code across multiple files in the
  virtual filesystem — i.e. building modular, reusable libraries the way
  a real Python project would.

  These go beyond the simple "import X; X.f()" cases in
  `Pyex.FilesystemImportTest` and cover scenarios that matter for
  composition: cross-module classes, inheritance, decorators, shared
  exceptions, diamond imports, package directories, and multi-stage
  pipelines built from independent modules.
  """

  use ExUnit.Case, async: true

  alias Pyex.{Ctx, Error, Filesystem.Memory}

  defp run_with_files!(code, files) do
    fs = Memory.new(files)
    ctx = Ctx.new(filesystem: fs)

    case Pyex.run(code, ctx) do
      {:ok, value, ctx} -> {value, ctx}
      {:error, %Error{message: msg}} -> raise "Pyex error: #{msg}"
    end
  end

  defp run_with_files(code, files) do
    fs = Memory.new(files)
    Pyex.run(code, Ctx.new(filesystem: fs))
  end

  describe "cross-module classes" do
    test "instantiate a class defined in another module" do
      {result, _ctx} =
        run_with_files!(
          """
          from models import User
          u = User("ivar", 30)
          u.greeting()
          """,
          %{
            "models.py" => """
            class User:
                def __init__(self, name, age):
                    self.name = name
                    self.age = age

                def greeting(self):
                    return "hi " + self.name
            """
          }
        )

      assert result == "hi ivar"
    end

    test "subclass in one module extends a base class from another" do
      {result, _ctx} =
        run_with_files!(
          """
          from animals import Dog
          d = Dog("rex")
          d.describe()
          """,
          %{
            "base.py" => """
            class Animal:
                def __init__(self, name):
                    self.name = name

                def describe(self):
                    return self.name + " is a " + self.kind()
            """,
            "animals.py" => """
            from base import Animal

            class Dog(Animal):
                def kind(self):
                    return "dog"
            """
          }
        )

      assert result == "rex is a dog"
    end

    test "isinstance recognizes objects across module boundaries" do
      {result, _ctx} =
        run_with_files!(
          """
          from shapes import Circle
          from base import Shape
          c = Circle(5)
          isinstance(c, Shape)
          """,
          %{
            "base.py" => """
            class Shape:
                pass
            """,
            "shapes.py" => """
            from base import Shape

            class Circle(Shape):
                def __init__(self, r):
                    self.r = r
            """
          }
        )

      assert result == true
    end
  end

  describe "shared exception types" do
    test "exception raised in one module is caught by type in another" do
      {result, _ctx} =
        run_with_files!(
          """
          from service import charge
          from errors import PaymentError

          try:
              charge(-1)
              result = "no error"
          except PaymentError as e:
              result = "caught: " + str(e)

          result
          """,
          %{
            "errors.py" => """
            class PaymentError(Exception):
                pass
            """,
            "service.py" => """
            from errors import PaymentError

            def charge(amount):
                if amount <= 0:
                    raise PaymentError("amount must be positive")
                return amount
            """
          }
        )

      assert result =~ "caught:"
      assert result =~ "amount must be positive"
    end
  end

  describe "shared state via accessor functions" do
    # Pyex modules are immutable maps, not CPython-style singleton dicts,
    # so writing to a module attribute from outside the module doesn't
    # propagate. The portable, cross-implementation pattern is to expose
    # accessor functions that close over a module-local variable — this
    # works in Pyex today.
    test "accessor functions over a closed-over variable share state" do
      {result, _ctx} =
        run_with_files!(
          """
          from counter import bump, get
          bump()
          bump()
          bump()
          get()
          """,
          %{
            "counter.py" => """
            _state = {"n": 0}

            def bump():
                _state["n"] = _state["n"] + 1

            def get():
                return _state["n"]
            """
          }
        )

      assert result == 3
    end

    test "shared counter module used from a second module via accessor functions" do
      {result, _ctx} =
        run_with_files!(
          """
          import counter
          from bumper import bump_twice

          bump_twice()
          bump_twice()
          counter.get()
          """,
          %{
            "counter.py" => """
            _state = {"n": 0}

            def bump():
                _state["n"] = _state["n"] + 1

            def get():
                return _state["n"]
            """,
            "bumper.py" => """
            from counter import bump

            def bump_twice():
                bump()
                bump()
            """
          }
        )

      assert result == 4
    end

    @tag :skip
    test "(KNOWN GAP) writing to a module attribute from outside the module" do
      # CPython treats modules as singleton mutable namespaces, so
      # `counter.value = 1` from outside `counter.py` rebinds the module
      # global. Pyex caches modules as immutable maps in
      # ctx.imported_modules, so external attribute writes are lost.
      # Use accessor functions instead (see tests above).
      {result, _ctx} =
        run_with_files!(
          """
          import counter
          counter.value = 10
          counter.value
          """,
          %{"counter.py" => "value = 0\n"}
        )

      assert result == 10
    end
  end

  describe "diamond imports" do
    test "shared module loaded once even when imported via two paths" do
      {_result, ctx} =
        run_with_files!(
          """
          import left
          import right
          """,
          %{
            "shared.py" => """
            print("shared loaded")
            """,
            "left.py" => """
            import shared
            """,
            "right.py" => """
            import shared
            """
          }
        )

      output = Pyex.output(ctx)
      assert output =~ "shared loaded"
      # Module body must execute exactly once across all import paths.
      assert length(String.split(output, "shared loaded")) == 2
    end
  end

  describe "package directories (dotted imports)" do
    test "import a module nested in a package directory" do
      {result, _ctx} =
        run_with_files!(
          """
          from pkg.math_utils import add
          add(2, 3)
          """,
          %{
            "pkg/math_utils.py" => """
            def add(a, b):
                return a + b
            """
          }
        )

      assert result == 5
    end

    test "nested package module can import a sibling via the package path" do
      {result, _ctx} =
        run_with_files!(
          """
          from pkg.api import compute
          compute(4)
          """,
          %{
            "pkg/core.py" => """
            def square(x):
                return x * x
            """,
            "pkg/api.py" => """
            from pkg.core import square

            def compute(x):
                return square(x) + 1
            """
          }
        )

      assert result == 17
    end
  end

  describe "facade / re-export modules" do
    test "facade module re-exports names from internal modules" do
      {result, _ctx} =
        run_with_files!(
          """
          from mylib import double, triple
          double(5) + triple(5)
          """,
          %{
            "_doubler.py" => """
            def double(x):
                return x * 2
            """,
            "_tripler.py" => """
            def triple(x):
                return x * 3
            """,
            "mylib.py" => """
            from _doubler import double
            from _tripler import triple
            """
          }
        )

      assert result == 25
    end
  end

  describe "decorator defined in one module, applied in another" do
    test "decorator from a helper module wraps a function in a consumer module" do
      {result, _ctx} =
        run_with_files!(
          """
          from app import shout
          shout("hello")
          """,
          %{
            "decorators.py" => """
            def upper(fn):
                def wrapper(*args, **kwargs):
                    return fn(*args, **kwargs).upper()
                return wrapper
            """,
            "app.py" => """
            from decorators import upper

            @upper
            def shout(msg):
                return msg
            """
          }
        )

      assert result == "HELLO"
    end
  end

  describe "multi-stage pipeline composed from independent modules" do
    test "parse → validate → render pipeline assembled in main" do
      {result, _ctx} =
        run_with_files!(
          """
          from parser import parse
          from validator import validate
          from renderer import render

          raw = "name=ivar;age=30"
          parsed = parse(raw)
          validate(parsed)
          render(parsed)
          """,
          %{
            "parser.py" => """
            def parse(s):
                out = {}
                for pair in s.split(";"):
                    k, v = pair.split("=")
                    out[k] = v
                return out
            """,
            "validator.py" => """
            class ValidationError(Exception):
                pass

            def validate(d):
                if "name" not in d:
                    raise ValidationError("missing name")
                return True
            """,
            "renderer.py" => """
            def render(d):
                parts = []
                for k in sorted(d.keys()):
                    parts.append(k + ":" + d[k])
                return ", ".join(parts)
            """
          }
        )

      assert result == "age:30, name:ivar"
    end

    test "pipeline failure surfaces the right exception type at the call site" do
      {result, _ctx} =
        run_with_files!(
          """
          from parser import parse
          from validator import validate, ValidationError

          try:
              validate(parse("age=30"))
              result = "ok"
          except ValidationError as e:
              result = "rejected: " + str(e)

          result
          """,
          %{
            "parser.py" => """
            def parse(s):
                out = {}
                for pair in s.split(";"):
                    k, v = pair.split("=")
                    out[k] = v
                return out
            """,
            "validator.py" => """
            class ValidationError(Exception):
                pass

            def validate(d):
                if "name" not in d:
                    raise ValidationError("missing name")
                return True
            """
          }
        )

      assert result == "rejected: missing name"
    end
  end

  describe "dependency injection across modules" do
    test "main injects a strategy function from one module into another" do
      {result, _ctx} =
        run_with_files!(
          """
          from strategies import double
          from runner import apply_to_all

          apply_to_all(double, [1, 2, 3, 4])
          """,
          %{
            "strategies.py" => """
            def double(x):
                return x * 2

            def negate(x):
                return -x
            """,
            "runner.py" => """
            def apply_to_all(fn, items):
                return [fn(x) for x in items]
            """
          }
        )

      assert result == [2, 4, 6, 8]
    end
  end

  describe "import-time errors propagate clearly" do
    test "broken transitive import names the failing module" do
      {:error, %Error{message: msg}} =
        run_with_files(
          """
          import app
          """,
          %{
            "app.py" => """
            from broken import thing
            """,
            "broken.py" => """
            x = 1 / 0
            """
          }
        )

      assert msg =~ "ImportError"
      assert msg =~ "broken"
    end
  end
end
