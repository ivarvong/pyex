defmodule Pyex.Stdlib.DataclassesTest do
  use ExUnit.Case, async: true

  test "module-level annotated constants do not leak into dataclass fields" do
    # Regression: an annotated module-level binding (e.g.
    # `_DEFAULT: Tuple[int, ...] = (1, 2, 3)`) was being inherited
    # by class bodies via the scope walk, so dataclasses treated the
    # constant name as one of their own fields.
    result =
      Pyex.run!("""
      from dataclasses import dataclass
      from typing import Sequence, Tuple

      _DEFAULT_PRIORS: Tuple[int, ...] = (1, 2, 3)

      @dataclass
      class Cfg:
          priors: Sequence[int] = _DEFAULT_PRIORS

      Cfg().priors
      """)

    assert result == {:tuple, [1, 2, 3]}
  end

  test "field default_factory invokes user-defined lambda" do
    # Regression: run_default_factory only knew how to invoke builtins,
    # so a user lambda fell through and was stored as the field value
    # itself instead of being called.
    result =
      Pyex.run!("""
      from dataclasses import dataclass, field

      @dataclass
      class C:
          items: list = field(default_factory=lambda: [1, 2, 3])

      C().items
      """)

    assert result == [1, 2, 3]
  end

  test "field default_factory invokes user-defined def" do
    result =
      Pyex.run!("""
      from dataclasses import dataclass, field

      def make():
          return {"a": 1}

      @dataclass
      class C:
          data: dict = field(default_factory=make)

      C().data
      """)

    assert result == %{"a" => 1}
  end

  test "field default_factory produces independent values per instance" do
    # Each call to the factory must yield a fresh object — otherwise
    # mutating one instance leaks into the next, which is the whole
    # reason default_factory exists instead of `default=[]`.
    result =
      Pyex.run!("""
      from dataclasses import dataclass, field

      @dataclass
      class C:
          items: list = field(default_factory=lambda: [])

      a = C()
      b = C()
      a.items.append(1)
      (a.items, b.items, a.items is b.items)
      """)

    assert result == {:tuple, [[1], [], false]}
  end

  test "dataclass decorator, field, asdict, and replace work" do
    result =
      Pyex.run!("""
      from dataclasses import dataclass, field, asdict, replace

      @dataclass
      class Post:
          title: str
          slug: str
          tags: list = field(default_factory=list)

      post = Post(title="Hello", slug="hello")
      updated = replace(post, slug="updated")
      (asdict(post), asdict(updated), post == Post(title="Hello", slug="hello"), repr(post))
      """)

    assert result ==
             {:tuple,
              [
                %{"slug" => "hello", "tags" => [], "title" => "Hello"},
                %{"slug" => "updated", "tags" => [], "title" => "Hello"},
                true,
                "Post(title='Hello', slug='hello', tags=[])"
              ]}
  end
end
