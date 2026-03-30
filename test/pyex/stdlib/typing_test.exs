defmodule Pyex.Stdlib.TypingTest do
  use ExUnit.Case, async: true

  describe "typing imports" do
    test "from typing import List, Dict, Optional" do
      Pyex.run!("from typing import List, Dict, Optional")
    end

    test "from typing import Any, Union, Callable" do
      Pyex.run!("from typing import Any, Union, Callable")
    end

    test "complex import with many names" do
      Pyex.run!("""
      from typing import List, Dict, Optional, Tuple, Any, Union, Callable, TypeVar, Generic
      """)
    end
  end

  describe "TypeVar" do
    test "TypeVar('T') does not crash" do
      result = Pyex.run!("from typing import TypeVar\nT = TypeVar('T')\nT")
      assert result == nil
    end
  end

  describe "cast" do
    test "cast returns its second argument" do
      result = Pyex.run!(~s|from typing import cast\ncast(int, "hello")|)
      assert result == "hello"
    end
  end

  describe "type annotations" do
    test "annotations in function signatures are ignored" do
      result =
        Pyex.run!("""
        def foo(x: int, y: str = "hi") -> bool:
            return True
        foo(1)
        """)

      assert result == true
    end

    test "annotations on class attributes" do
      result =
        Pyex.run!("""
        from typing import Optional
        class Foo:
            name: Optional[str] = "default"
        f = Foo()
        f.name
        """)

      assert result == "default"
    end
  end
end
