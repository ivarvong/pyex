defmodule Pyex.Stdlib.DataclassesTest do
  use ExUnit.Case, async: true

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
