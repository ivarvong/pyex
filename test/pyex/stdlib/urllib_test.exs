defmodule Pyex.Stdlib.UrllibTest do
  use ExUnit.Case, async: true

  test "urllib.parse helpers work" do
    result =
      Pyex.run!("""
      import urllib.parse
      (
          urllib.parse.urljoin("https://example.com/blog/", "post"),
          urllib.parse.quote("hello world"),
          urllib.parse.unquote("hello%20world"),
          urllib.parse.urlparse("https://example.com/blog/post?q=1#frag"),
          urllib.parse.urlencode({"q": "hello world", "page": 2})
      )
      """)

    assert result ==
             {:tuple,
              [
                "https://example.com/blog/post",
                "hello%20world",
                "hello world",
                {:tuple, ["https", "example.com", "/blog/post", "q=1", "frag"]},
                "page=2&q=hello+world"
              ]}
  end
end
