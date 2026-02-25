defmodule Pyex.Stdlib.YamlParserTest do
  @moduledoc """
  Tests for the hand-rolled block-YAML parser.

  Every deterministic test is also verified against yamerl (via YamlElixir) to
  ensure our output matches the reference implementation for the subset we claim
  to support.  yamerl is used only in this test file -- the production parser
  has no dependency on it.
  """

  use ExUnit.Case, async: true

  alias Pyex.Stdlib.YamlParser

  # ---------------------------------------------------------------------------
  # Reference helper: parse with yamerl and normalise to our output format.
  # We use this only to pin expected values in tests, not in production.
  # ---------------------------------------------------------------------------

  defp yamerl_parse(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, value} -> normalise(value)
      {:error, _} -> :yamerl_error
    end
  end

  # yamerl returns charlists for strings; convert to binaries.
  # yamerl returns keyword-list-style mappings [{charlist, value}]; convert to string-keyed maps.
  # yamerl returns :null for null; we return nil.
  defp normalise(nil), do: nil
  defp normalise(:null), do: nil
  defp normalise(:nan), do: :nan
  defp normalise(:"+inf"), do: :infinity
  defp normalise(:"-inf"), do: :neg_infinity
  defp normalise(true), do: true
  defp normalise(false), do: false
  defp normalise(n) when is_integer(n), do: n
  defp normalise(f) when is_float(f), do: f
  defp normalise(s) when is_binary(s), do: s
  defp normalise([]), do: []

  defp normalise(list) when is_list(list) do
    case list do
      [{k, _} | _] when is_list(k) or is_atom(k) ->
        # keyword-list mapping: [{charlist_key, value}, ...]
        Map.new(list, fn {k, v} ->
          key = if is_list(k), do: List.to_string(k), else: to_string(k)
          {key, normalise(v)}
        end)

      _ ->
        # plain list -- normalise each element individually
        Enum.map(list, fn
          s when is_list(s) and s != [] and is_integer(hd(s)) -> List.to_string(s)
          other -> normalise(other)
        end)
    end
  end

  defp normalise(other), do: other

  # Assert our parser matches yamerl for the given text.
  defp assert_matches_yamerl(text) do
    our_result = YamlParser.parse(text)
    ref = yamerl_parse(text)

    assert ref != :yamerl_error,
           "yamerl could not parse: #{inspect(text)}"

    assert our_result == {:ok, ref},
           "Parser mismatch for:\n#{text}\nours:   #{inspect(our_result)}\nyamerl: #{inspect({:ok, ref})}"
  end

  # ---------------------------------------------------------------------------
  # Frontmatter -- the primary use case
  # ---------------------------------------------------------------------------

  describe "frontmatter" do
    test "parses hello-world post frontmatter" do
      yaml = """
      title: Hello World
      date: 2026-01-15
      tags:
        - intro
        - elixir
      """

      assert_matches_yamerl(yaml)

      assert YamlParser.parse(yaml) ==
               {:ok,
                %{"title" => "Hello World", "date" => "2026-01-15", "tags" => ["intro", "elixir"]}}
    end

    test "parses single-tag post frontmatter" do
      yaml = """
      title: A Deep Dive
      date: 2026-02-10
      tags:
        - tutorial
      """

      assert_matches_yamerl(yaml)
    end

    test "parses config frontmatter" do
      yaml = """
      site_name: My Blog
      author: Ada
      """

      assert_matches_yamerl(yaml)
      assert YamlParser.parse(yaml) == {:ok, %{"site_name" => "My Blog", "author" => "Ada"}}
    end

    test "preserves date strings as strings" do
      yaml = "date: 2026-01-15\n"
      assert YamlParser.parse(yaml) == {:ok, %{"date" => "2026-01-15"}}
      assert_matches_yamerl(yaml)
    end
  end

  # ---------------------------------------------------------------------------
  # Scalars
  # ---------------------------------------------------------------------------

  describe "scalar coercion" do
    test "integers" do
      for {input, expected} <- [
            {"42", 42},
            {"0", 0},
            {"-1", -1},
            {"0o17", 0o17},
            {"0x1F", 0x1F}
          ] do
        yaml = "k: #{input}\n"
        assert YamlParser.parse(yaml) == {:ok, %{"k" => expected}}, "failed for #{input}"
        assert_matches_yamerl(yaml)
      end
    end

    test "floats" do
      for {input, expected} <- [
            {"3.14", 3.14},
            {"-2.5", -2.5},
            {"1.0e3", 1.0e3}
          ] do
        yaml = "k: #{input}\n"
        assert YamlParser.parse(yaml) == {:ok, %{"k" => expected}}, "failed for #{input}"
        assert_matches_yamerl(yaml)
      end
    end

    test "special float values" do
      assert YamlParser.parse("k: .inf\n") == {:ok, %{"k" => :infinity}}
      assert YamlParser.parse("k: -.inf\n") == {:ok, %{"k" => :neg_infinity}}
      assert YamlParser.parse("k: .nan\n") == {:ok, %{"k" => :nan}}
    end

    test "booleans" do
      for {input, expected} <- [
            {"true", true},
            {"True", true},
            {"TRUE", true},
            {"false", false},
            {"False", false},
            {"FALSE", false}
          ] do
        yaml = "k: #{input}\n"
        assert YamlParser.parse(yaml) == {:ok, %{"k" => expected}}, "failed for #{input}"
        assert_matches_yamerl(yaml)
      end
    end

    test "nulls" do
      for input <- ["null", "Null", "NULL", "~", ""] do
        yaml = "k: #{input}\n"
        assert YamlParser.parse(yaml) == {:ok, %{"k" => nil}}, "failed for #{inspect(input)}"
        assert_matches_yamerl(yaml)
      end
    end

    test "plain strings" do
      for input <- ["yes", "no", "on", "off", "Hello World", "v1.2.3"] do
        yaml = "k: #{input}\n"
        assert YamlParser.parse(yaml) == {:ok, %{"k" => input}}, "failed for #{inspect(input)}"
        assert_matches_yamerl(yaml)
      end
    end

    test "double-quoted strings" do
      assert YamlParser.parse(~s(k: "hello world"\n)) == {:ok, %{"k" => "hello world"}}
      assert YamlParser.parse(~s(k: "42"\n)) == {:ok, %{"k" => "42"}}
      assert YamlParser.parse(~s(k: "true"\n)) == {:ok, %{"k" => "true"}}
      assert YamlParser.parse(~s(k: "null"\n)) == {:ok, %{"k" => "null"}}
      assert YamlParser.parse(~s(k: "with: colon"\n)) == {:ok, %{"k" => "with: colon"}}
      assert YamlParser.parse(~s(k: "line1\\nline2"\n)) == {:ok, %{"k" => "line1\nline2"}}
    end

    test "single-quoted strings" do
      assert YamlParser.parse("k: 'hello world'\n") == {:ok, %{"k" => "hello world"}}
      assert YamlParser.parse("k: 'it''s a test'\n") == {:ok, %{"k" => "it's a test"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Mappings
  # ---------------------------------------------------------------------------

  describe "mappings" do
    test "simple flat mapping" do
      yaml = "name: alice\nage: 30\n"
      assert_matches_yamerl(yaml)
      assert YamlParser.parse(yaml) == {:ok, %{"name" => "alice", "age" => 30}}
    end

    test "empty value treated as null" do
      yaml = "k:\n"
      assert YamlParser.parse(yaml) == {:ok, %{"k" => nil}}
      assert_matches_yamerl(yaml)
    end

    test "nested mapping" do
      yaml = "outer:\n  inner: value\n"
      assert_matches_yamerl(yaml)
      assert YamlParser.parse(yaml) == {:ok, %{"outer" => %{"inner" => "value"}}}
    end
  end

  # ---------------------------------------------------------------------------
  # Sequences
  # ---------------------------------------------------------------------------

  describe "sequences" do
    test "top-level sequence of scalars" do
      yaml = "- 1\n- 2\n- 3\n"
      assert_matches_yamerl(yaml)
      assert YamlParser.parse(yaml) == {:ok, [1, 2, 3]}
    end

    test "top-level sequence of strings" do
      yaml = "- a\n- b\n- c\n"
      assert_matches_yamerl(yaml)
      assert YamlParser.parse(yaml) == {:ok, ["a", "b", "c"]}
    end

    test "sequence of mixed scalars" do
      yaml = "- 1\n- true\n- null\n"
      assert_matches_yamerl(yaml)
      assert YamlParser.parse(yaml) == {:ok, [1, true, nil]}
    end

    test "mapping value is a sequence" do
      yaml = "tags:\n  - intro\n  - elixir\n"
      assert_matches_yamerl(yaml)
      assert YamlParser.parse(yaml) == {:ok, %{"tags" => ["intro", "elixir"]}}
    end

    test "sequence of mappings" do
      yaml = "users:\n  - name: alice\n    score: 10\n  - name: bob\n    score: 20\n"
      assert_matches_yamerl(yaml)

      assert YamlParser.parse(yaml) ==
               {:ok,
                %{
                  "users" => [
                    %{"name" => "alice", "score" => 10},
                    %{"name" => "bob", "score" => 20}
                  ]
                }}
    end
  end

  # ---------------------------------------------------------------------------
  # Comments
  # ---------------------------------------------------------------------------

  describe "comments" do
    test "full-line comments are ignored" do
      yaml = "# comment\nk: v\n"
      assert_matches_yamerl(yaml)
      assert YamlParser.parse(yaml) == {:ok, %{"k" => "v"}}
    end

    test "inline comments are stripped" do
      yaml = "k: v  # inline comment\n"
      assert_matches_yamerl(yaml)
      assert YamlParser.parse(yaml) == {:ok, %{"k" => "v"}}
    end

    test "hash inside double-quoted string is not a comment" do
      assert YamlParser.parse(~s(k: "hello # world"\n)) == {:ok, %{"k" => "hello # world"}}
    end

    test "hash inside single-quoted string is not a comment" do
      assert YamlParser.parse("k: 'hello # world'\n") == {:ok, %{"k" => "hello # world"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Block scalars
  # ---------------------------------------------------------------------------

  describe "block scalars" do
    test "literal block scalar preserves newlines" do
      yaml = "body: |\n  line one\n  line two\n"
      assert_matches_yamerl(yaml)
      assert YamlParser.parse(yaml) == {:ok, %{"body" => "line one\nline two\n"}}
    end

    test "folded block scalar joins with spaces" do
      yaml = "body: >\n  line one\n  line two\n"
      assert_matches_yamerl(yaml)
      assert YamlParser.parse(yaml) == {:ok, %{"body" => "line one line two\n"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  describe "edge cases" do
    test "empty document returns nil" do
      assert YamlParser.parse("") == {:ok, nil}
      assert YamlParser.parse("   \n  \n") == {:ok, nil}
    end

    test "deeply nested beyond limit returns error" do
      deep = Enum.map_join(1..101, "", fn i -> String.duplicate(" ", i * 2) <> "x:\n" end)
      assert {:error, msg} = YamlParser.parse(deep)
      assert msg =~ "depth"
    end
  end

  # ---------------------------------------------------------------------------
  # Benchmark (printed but not asserted -- informational only)
  # ---------------------------------------------------------------------------

  @tag :benchmark
  test "frontmatter parse speed vs yamerl" do
    yaml = """
    title: Hello World
    date: 2026-01-15
    tags:
      - intro
      - elixir
    """

    n = 10_000

    {us_ours, _} = :timer.tc(fn -> for _ <- 1..n, do: YamlParser.parse(yaml) end)
    {us_yamerl, _} = :timer.tc(fn -> for _ <- 1..n, do: :yamerl_constr.string(yaml) end)

    IO.puts("""

    YAML parse benchmark (#{n} iterations):
      YamlParser (ours) : #{Float.round(us_ours / n, 2)} µs/op
      yamerl_constr     : #{Float.round(us_yamerl / n, 2)} µs/op
      speedup           : #{Float.round(us_yamerl / us_ours, 1)}x
    """)

    assert us_ours < us_yamerl, "our parser should be faster than yamerl_constr"
  end
end
