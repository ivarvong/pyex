defmodule Pyex.Stdlib.Jinja2Test do
  use ExUnit.Case, async: true

  describe "basic interpolation" do
    test "simple variable" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("Hello {{ name }}!").render(name="World")
             """) == "Hello World!"
    end

    test "integer variable" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("Count: {{ n }}").render(n=42)
             """) == "Count: 42"
    end

    test "expression evaluation" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{{ a + b }}").render(a=3, b=4)
             """) == "7"
    end

    test "method call in expression" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{{ name.upper() }}").render(name="hello")
             """) == "HELLO"
    end

    test "subscript in expression" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{{ d[\"key\"] }}").render(d={"key": "value"})
             """) == "value"
    end

    test "None renders as empty" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("x{{ val }}y").render(val=None)
             """) == "xy"
    end

    test "multiple expressions" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{{ a }}-{{ b }}-{{ c }}").render(a="x", b="y", c="z")
             """) == "x-y-z"
    end
  end

  describe "auto-escaping" do
    test "escapes HTML in variables" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{{ s }}").render(s="<script>alert(1)</script>")
             """) == "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "escapes ampersands" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{{ s }}").render(s="AT&T")
             """) == "AT&amp;T"
    end

    test "escapes quotes" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{{ s }}").render(s="he said \"hi\"")
             """) == "he said &quot;hi&quot;"
    end

    test "safe filter bypasses escaping" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{{ html | safe }}").render(html="<b>bold</b>")
             """) == "<b>bold</b>"
    end

    test "literal text is not escaped" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("<h1>Title</h1>").render()
             """) == "<h1>Title</h1>"
    end
  end

  describe "for loops" do
    test "simple list iteration" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{% for x in items %}[{{ x }}]{% endfor %}").render(items=["a", "b", "c"])
             """) == "[a][b][c]"
    end

    test "empty list produces no output" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{% for x in items %}X{% endfor %}").render(items=[])
             """) == ""
    end

    test "nested for loops" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             t = Template("{% for row in grid %}{% for cell in row %}{{ cell }}{% endfor %}\n{% endfor %}")
             t.render(grid=[[1, 2], [3, 4]])
             """) == "12\n34\n"
    end

    test "tuple unpacking in for" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{% for k, v in items %}{{ k }}={{ v }} {% endfor %}").render(items=[("a", 1), ("b", 2)])
             """) == "a=1 b=2 "
    end

    test "for over dict items" do
      result =
        Pyex.run!(~S"""
        from jinja2 import Template
        Template("{% for k, v in data.items() %}{{ k }}:{{ v }} {% endfor %}").render(data={"x": 1})
        """)

      assert result == "x:1 "
    end

    test "for over range" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{% for i in range(3) %}{{ i }}{% endfor %}").render()
             """) == "012"
    end
  end

  describe "conditionals" do
    test "if true" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{% if show %}YES{% endif %}").render(show=True)
             """) == "YES"
    end

    test "if false" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{% if show %}YES{% endif %}").render(show=False)
             """) == ""
    end

    test "if/else" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             t = Template("{% if admin %}Admin{% else %}User{% endif %}")
             t.render(admin=False)
             """) == "User"
    end

    test "if/elif/else" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             t = Template("{% if x > 0 %}pos{% elif x < 0 %}neg{% else %}zero{% endif %}")
             t.render(x=0)
             """) == "zero"
    end

    test "elif match" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             t = Template("{% if x > 0 %}pos{% elif x < 0 %}neg{% else %}zero{% endif %}")
             t.render(x=-5)
             """) == "neg"
    end

    test "multiple elif" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             t = Template("{% if s > 90 %}A{% elif s > 80 %}B{% elif s > 70 %}C{% else %}F{% endif %}")
             t.render(s=75)
             """) == "C"
    end

    test "nested if inside for" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             t = Template("{% for n in nums %}{% if n > 0 %}+{% else %}-{% endif %}{% endfor %}")
             t.render(nums=[1, -2, 3, -4])
             """) == "+-+-"
    end

    test "for inside if" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             t = Template("{% if items %}{% for x in items %}{{ x }}{% endfor %}{% else %}empty{% endif %}")
             t.render(items=["a", "b"])
             """) == "ab"
    end
  end

  describe "comments" do
    test "comments are stripped" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("before{# this is a comment #}after").render()
             """) == "beforeafter"
    end

    test "comment between tags" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{{ a }}{# ignored #}{{ b }}").render(a="x", b="y")
             """) == "xy"
    end
  end

  describe "whitespace" do
    test "preserves literal whitespace" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("  hello  ").render()
             """) == "  hello  "
    end

    test "template with newlines" do
      result =
        Pyex.run!(~S"""
        from jinja2 import Template
        t = Template("line1\nline2\n")
        t.render()
        """)

      assert result == "line1\nline2\n"
    end
  end

  describe "no I/O allowed" do
    test "open() is not available in template expressions" do
      assert_raise RuntimeError, ~r/TemplateRenderError/, fn ->
        Pyex.run!(~S"""
        from jinja2 import Template
        Template("{{ open('file.txt') }}").render()
        """)
      end
    end

    test "import is not available in template expressions" do
      assert_raise RuntimeError, ~r/TemplateRenderError/, fn ->
        Pyex.run!(~S"""
        from jinja2 import Template
        Template("{{ __import__('os') }}").render()
        """)
      end
    end
  end

  describe "error handling" do
    test "Template with non-string raises TypeError" do
      assert_raise RuntimeError, ~r/TypeError/, fn ->
        Pyex.run!(~S"""
        from jinja2 import Template
        Template(42)
        """)
      end
    end

    test "unclosed expression tag" do
      assert_raise RuntimeError, ~r/TemplateSyntaxError/, fn ->
        Pyex.run!(~S"""
        from jinja2 import Template
        Template("{{ unclosed")
        """)
      end
    end

    test "unclosed block tag" do
      assert_raise RuntimeError, ~r/TemplateSyntaxError/, fn ->
        Pyex.run!(~S"""
        from jinja2 import Template
        Template("{% if x")
        """)
      end
    end

    test "missing endfor" do
      assert_raise RuntimeError, ~r/TemplateSyntaxError/, fn ->
        Pyex.run!(~S"""
        from jinja2 import Template
        Template("{% for x in items %}hello")
        """)
      end
    end

    test "missing endif" do
      assert_raise RuntimeError, ~r/TemplateSyntaxError/, fn ->
        Pyex.run!(~S"""
        from jinja2 import Template
        Template("{% if x %}hello")
        """)
      end
    end

    test "undefined variable in expression" do
      assert_raise RuntimeError, ~r/TemplateRenderError/, fn ->
        Pyex.run!(~S"""
        from jinja2 import Template
        Template("{{ undefined_var }}").render()
        """)
      end
    end

    test "invalid expression syntax" do
      assert_raise RuntimeError, ~r/TemplateSyntaxError|TemplateRenderError/, fn ->
        Pyex.run!(~S"""
        from jinja2 import Template
        Template("{{ 1 + }}").render()
        """)
      end
    end
  end

  describe "realistic templates" do
    test "blog post list" do
      result =
        Pyex.run!(~S"""
        from jinja2 import Template
        t = Template(\"""<html>
        <body>
        {% for post in posts %}
        <article>
          <h2>{{ post["title"] }}</h2>
          <p>{{ post["body"] }}</p>
        </article>
        {% endfor %}
        </body>
        </html>\""")
        t.render(posts=[
            {"title": "First Post", "body": "Hello world"},
            {"title": "Second Post", "body": "More content"}
        ])
        """)

      assert result =~ "<h2>First Post</h2>"
      assert result =~ "<h2>Second Post</h2>"
      assert result =~ "<p>Hello world</p>"
      assert result =~ "<p>More content</p>"
      assert result =~ "<html>"
    end

    test "nav with active class" do
      result =
        Pyex.run!(~S"""
        from jinja2 import Template
        t = Template("{% for page in pages %}<a{% if page == current %} class=\"active\"{% endif %}>{{ page }}</a>{% endfor %}")
        t.render(pages=["Home", "About", "Blog"], current="About")
        """)

      assert result == ~S|<a>Home</a><a class="active">About</a><a>Blog</a>|
    end

    test "XSS prevention in user content" do
      result =
        Pyex.run!(~S"""
        from jinja2 import Template
        t = Template("<span>{{ username }}</span>")
        t.render(username="<script>alert('xss')</script>")
        """)

      assert result == "<span>&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;</span>"
      refute result =~ "<script>"
    end
  end

  describe "from_import" do
    test "from jinja2 import Template" do
      assert Pyex.run!(~S"""
             from jinja2 import Template
             Template("{{ x }}").render(x="ok")
             """) == "ok"
    end
  end
end
