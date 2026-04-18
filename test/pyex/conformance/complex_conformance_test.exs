defmodule Pyex.Conformance.ComplexTest do
  @moduledoc """
  Live CPython conformance tests for complex numbers.
  """

  use ExUnit.Case, async: true
  @moduletag :requires_python3

  import Pyex.Test.Oracle

  describe "literal" do
    test "imaginary only" do
      check!("print(2j)")
    end

    test "integer with j" do
      check!("print(0j)")
    end

    @tag :skip
    test "negative imaginary formatting (-0-3j edge case)" do
      check!("print(-3j)")
    end

    test "real + imaginary" do
      check!("print(1 + 2j)")
    end

    test "type name" do
      check!("print(type(2j).__name__)")
    end
  end

  describe "complex() constructor" do
    test "no args" do
      check!("print(complex())")
    end

    test "real only" do
      check!("print(complex(3))")
    end

    test "real and imag" do
      check!("print(complex(3, 4))")
    end
  end

  describe "attributes" do
    test "real" do
      check!("print(complex(3, 4).real)")
    end

    test "imag" do
      check!("print(complex(3, 4).imag)")
    end

    test "conjugate" do
      check!("print(complex(3, 4).conjugate())")
    end
  end

  describe "arithmetic" do
    test "add" do
      check!("print((1+2j) + (3+4j))")
    end

    test "sub" do
      check!("print((5+3j) - (2+1j))")
    end

    test "mul" do
      check!("print((1+2j) * (3+4j))")
    end

    test "int + complex" do
      check!("print(5 + 2j)")
    end

    test "complex - int" do
      check!("print((5+2j) - 3)")
    end
  end
end
