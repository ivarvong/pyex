defmodule Pyex.ParserTest do
  use ExUnit.Case, async: true

  alias Pyex.{Lexer, Parser}

  defp parse!(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)
    ast
  end

  defp parse_error(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:error, message} = Parser.parse(tokens)
    message
  end

  describe "expressions" do
    test "integer literal" do
      assert {:module, _, [{:expr, _, [{:lit, [line: 1], [42]}]}]} = parse!("42")
    end

    test "binary operation preserves structure" do
      {:module, _, [{:expr, _, [node]}]} = parse!("1 + 2")
      assert {:binop, [line: 1], [:plus, {:lit, _, [1]}, {:lit, _, [2]}]} = node
    end

    test "precedence: multiplication before addition" do
      {:module, _, [{:expr, _, [node]}]} = parse!("1 + 2 * 3")

      assert {:binop, _,
              [:plus, {:lit, _, [1]}, {:binop, _, [:star, {:lit, _, [2]}, {:lit, _, [3]}]}]} =
               node
    end

    test "parentheses override precedence" do
      {:module, _, [{:expr, _, [node]}]} = parse!("(1 + 2) * 3")

      assert {:binop, _,
              [:star, {:binop, _, [:plus, {:lit, _, [1]}, {:lit, _, [2]}]}, {:lit, _, [3]}]} =
               node
    end

    test "unary negation" do
      {:module, _, [{:expr, _, [node]}]} = parse!("-5")
      assert {:unaryop, [line: 1], [:neg, {:lit, _, [5]}]} = node
    end

    test "function call" do
      {:module, _, [{:expr, _, [node]}]} = parse!("f(1, 2)")
      assert {:call, _, [{:var, _, ["f"]}, [{:lit, _, [1]}, {:lit, _, [2]}]]} = node
    end

    test "nested function calls" do
      {:module, _, [{:expr, _, [node]}]} = parse!("f(g(1))")

      assert {:call, _, [{:var, _, ["f"]}, [{:call, _, [{:var, _, ["g"]}, [{:lit, _, [1]}]]}]]} =
               node
    end
  end

  describe "statements" do
    test "assignment" do
      {:module, _, [node]} = parse!("x = 42")
      assert {:assign, [line: 1], ["x", {:lit, _, [42]}]} = node
    end

    test "function definition" do
      ast = parse!("def f(x):\n    return x")
      {:module, _, [{:def, _, ["f", [{"x", nil}], body]}]} = ast
      assert [{:return, _, [{:var, _, ["x"]}]}] = body
    end

    test "function with default argument" do
      ast = parse!("def f(x, y=10):\n    return x + y")
      {:module, _, [{:def, _, ["f", [{"x", nil}, {"y", {:lit, _, [10]}}], _body]}]} = ast
    end
  end

  describe "control flow" do
    test "if/else structure" do
      source = "if x:\n    1\nelse:\n    2"
      {:module, _, [{:if, _, clauses}]} = parse!(source)

      assert [
               {{:var, _, ["x"]}, [{:expr, _, [{:lit, _, [1]}]}]},
               {:else, [{:expr, _, [{:lit, _, [2]}]}]}
             ] = clauses
    end

    test "while loop structure" do
      source = "while x:\n    y"
      {:module, _, [{:while, _, [condition, body, nil]}]} = parse!(source)
      assert {:var, _, ["x"]} = condition
      assert [{:expr, _, [{:var, _, ["y"]}]}] = body
    end
  end

  describe "new expressions" do
    test "string literal" do
      {:module, _, [{:expr, _, [{:lit, [line: 1], ["hello"]}]}]} = parse!(~s("hello"))
    end

    test "attribute access" do
      {:module, _, [{:expr, _, [node]}]} = parse!("obj.attr")
      assert {:getattr, _, [{:var, _, ["obj"]}, "attr"]} = node
    end

    test "chained attribute access" do
      {:module, _, [{:expr, _, [node]}]} = parse!("a.b.c")
      assert {:getattr, _, [{:getattr, _, [{:var, _, ["a"]}, "b"]}, "c"]} = node
    end

    test "subscript access" do
      {:module, _, [{:expr, _, [node]}]} = parse!(~s(d["key"]))
      assert {:subscript, _, [{:var, _, ["d"]}, {:lit, _, ["key"]}]} = node
    end

    test "method call (attribute + call)" do
      {:module, _, [{:expr, _, [node]}]} = parse!("obj.method(1)")

      assert {:call, _, [{:getattr, _, [{:var, _, ["obj"]}, "method"]}, [{:lit, _, [1]}]]} =
               node
    end

    test "list literal" do
      {:module, _, [{:expr, _, [node]}]} = parse!("[1, 2, 3]")
      assert {:list, _, [elements]} = node
      assert [{:lit, _, [1]}, {:lit, _, [2]}, {:lit, _, [3]}] = elements
    end

    test "empty list literal" do
      {:module, _, [{:expr, _, [node]}]} = parse!("[]")
      assert {:list, _, [[]]} = node
    end

    test "dict literal" do
      {:module, _, [{:expr, _, [node]}]} = parse!(~s({"a": 1, "b": 2}))
      assert {:dict, _, [entries]} = node
      assert [{{:lit, _, ["a"]}, {:lit, _, [1]}}, {{:lit, _, ["b"]}, {:lit, _, [2]}}] = entries
    end

    test "empty dict literal" do
      {:module, _, [{:expr, _, [node]}]} = parse!("{}")
      assert {:dict, _, [[]]} = node
    end
  end

  describe "new statements" do
    test "for loop" do
      source = "for x in items:\n    x"
      {:module, _, [{:for, _, ["x", {:var, _, ["items"]}, body, nil]}]} = parse!(source)
      assert [{:expr, _, [{:var, _, ["x"]}]}] = body
    end

    test "import statement" do
      {:module, _, [{:import, [line: 1], [{"json", nil}]}]} = parse!("import json")
    end

    test "dotted import" do
      {:module, _, [{:import, [line: 1], [{"urllib.request", nil}]}]} =
        parse!("import urllib.request")
    end

    test "dotted import with alias" do
      {:module, _, [{:import, [line: 1], [{"urllib.request", "req"}]}]} =
        parse!("import urllib.request as req")
    end
  end

  describe "error handling" do
    test "unexpected token at top level" do
      assert parse_error(")") =~ "unexpected"
    end

    test "unclosed parentheses" do
      assert parse_error("(1 + 2") =~ "expected ')'"
    end

    test "unexpected end of input in expression" do
      assert parse_error("1 +") =~ "unexpected end of input"
    end

    test "missing colon after function definition" do
      assert parse_error("def f(x)\n    return x") =~ "expected ':'"
    end

    test "missing function name after def" do
      assert parse_error("def (x):\n    pass") =~ "expected function name"
    end

    test "bad token in parameter list" do
      assert parse_error("def f(1):\n    pass") =~ "unexpected token in parameter list"
    end

    test "missing colon after if" do
      assert parse_error("if x\n    y") =~ "expected ':'"
    end

    test "missing colon after while" do
      assert parse_error("while x\n    y") =~ "expected ':'"
    end

    test "missing variable name after for" do
      assert parse_error("for 1 in x:\n    pass") =~ "expected variable name"
    end

    test "missing module name after import" do
      assert parse_error("import") =~ "expected module name"
    end

    test "unclosed subscript bracket" do
      assert parse_error("d[1") =~ "expected ']'"
    end

    test "malformed list literal" do
      assert parse_error("[1 2]") =~ "expected ',' or ']'"
    end

    test "malformed dict literal missing colon" do
      assert parse_error("{1 2}") =~ "expected ':'"
    end

    test "malformed dict literal missing comma or brace" do
      assert parse_error("{1: 2 3}") =~ "expected ',' or '}'"
    end
  end

  describe "slice notation" do
    test "basic slice [1:3]" do
      {:module, _, [{:expr, _, [node]}]} = parse!("x[1:3]")

      assert {:slice, [line: 1], [{:var, _, ["x"]}, {:lit, _, [1]}, {:lit, _, [3]}, nil]} = node
    end

    test "slice with omitted start [:3]" do
      {:module, _, [{:expr, _, [node]}]} = parse!("x[:3]")
      assert {:slice, [line: 1], [{:var, _, ["x"]}, nil, {:lit, _, [3]}, nil]} = node
    end

    test "slice with omitted stop [1:]" do
      {:module, _, [{:expr, _, [node]}]} = parse!("x[1:]")
      assert {:slice, [line: 1], [{:var, _, ["x"]}, {:lit, _, [1]}, nil, nil]} = node
    end

    test "full slice [:]" do
      {:module, _, [{:expr, _, [node]}]} = parse!("x[:]")
      assert {:slice, [line: 1], [{:var, _, ["x"]}, nil, nil, nil]} = node
    end

    test "slice with step [::2]" do
      {:module, _, [{:expr, _, [node]}]} = parse!("x[::2]")
      assert {:slice, [line: 1], [{:var, _, ["x"]}, nil, nil, {:lit, _, [2]}]} = node
    end

    test "full slice with step [1:3:2]" do
      {:module, _, [{:expr, _, [node]}]} = parse!("x[1:3:2]")

      assert {:slice, [line: 1],
              [{:var, _, ["x"]}, {:lit, _, [1]}, {:lit, _, [3]}, {:lit, _, [2]}]} = node
    end
  end

  describe "in and not in" do
    test "x in list parses as binop" do
      {:module, _, [{:expr, _, [node]}]} = parse!("x in items")
      assert {:binop, [line: 1], [:in, {:var, _, ["x"]}, {:var, _, ["items"]}]} = node
    end

    test "x not in list parses as binop" do
      {:module, _, [{:expr, _, [node]}]} = parse!("x not in items")
      assert {:binop, [line: 1], [:not_in, {:var, _, ["x"]}, {:var, _, ["items"]}]} = node
    end
  end

  describe "type annotations" do
    test "parameter type hint is captured" do
      {:module, _, [{:def, _, ["f", params, _body]}]} =
        parse!("def f(x: int):\n    return x")

      assert [{"x", nil, "int"}] = params
    end

    test "parameter type hint with default value" do
      {:module, _, [{:def, _, ["f", params, _body]}]} =
        parse!("def f(x: int = 5):\n    return x")

      assert [{"x", {:lit, _, [5]}, "int"}] = params
    end

    test "multiple typed parameters" do
      {:module, _, [{:def, _, ["f", params, _body]}]} =
        parse!("def f(x: int, y: str, z: float = 3.14):\n    return x")

      assert [{"x", nil, "int"}, {"y", nil, "str"}, {"z", {:lit, _, [3.14]}, "float"}] = params
    end

    test "generic type hint like list[int]" do
      {:module, _, [{:def, _, ["f", params, _body]}]} =
        parse!("def f(x: list[int]):\n    return x")

      assert [{"x", nil, "list[int]"}] = params
    end

    test "nested generic type hint like dict[str, list[int]]" do
      {:module, _, [{:def, _, ["f", params, _body]}]} =
        parse!("def f(x: dict[str, list[int]]):\n    return x")

      assert [{"x", nil, "dict[str, list[int]]"}] = params
    end

    test "return type annotation is silently discarded" do
      {:module, _, [{:def, _, ["f", params, _body]}]} =
        parse!("def f(x) -> int:\n    return x")

      assert [{"x", nil}] = params
    end

    test "return type None annotation" do
      {:module, _, [{:def, _, ["f", _, _body]}]} =
        parse!("def f() -> None:\n    pass")
    end

    test "both parameter and return type annotations" do
      {:module, _, [{:def, _, ["f", params, _body]}]} =
        parse!("def f(x: int, y: str = \"hi\") -> dict:\n    return {}")

      assert [{"x", nil, "int"}, {"y", {:lit, _, ["hi"]}, "str"}] = params
    end
  end

  describe "from_import" do
    test "single name" do
      {:module, _, [{:from_import, [line: 1], ["math", names]}]} =
        parse!("from math import sin")

      assert [{"sin", nil}] = names
    end

    test "multiple names" do
      {:module, _, [{:from_import, [line: 1], ["math", names]}]} =
        parse!("from math import sin, cos, pi")

      assert [{"sin", nil}, {"cos", nil}, {"pi", nil}] = names
    end

    test "aliased import" do
      {:module, _, [{:from_import, [line: 1], ["math", names]}]} =
        parse!("from math import sin as s")

      assert [{"sin", "s"}] = names
    end

    test "mixed aliased and plain" do
      {:module, _, [{:from_import, [line: 1], ["json", names]}]} =
        parse!("from json import loads as parse, dumps")

      assert [{"loads", "parse"}, {"dumps", nil}] = names
    end
  end

  describe "chained comparisons" do
    test "single comparison produces binop" do
      {:module, _, [{:expr, _, [{:binop, _, [:lt, {:lit, _, [1]}, {:lit, _, [2]}]}]}]} =
        parse!("1 < 2")
    end

    test "two-operator chain produces chained_compare" do
      {:module, _, [{:expr, _, [{:chained_compare, _, [ops, operands]}]}]} =
        parse!("1 < 2 < 3")

      assert ops == [:lt, :lt]
      assert length(operands) == 3
    end

    test "mixed operators in chain" do
      {:module, _, [{:expr, _, [{:chained_compare, _, [ops, operands]}]}]} =
        parse!("1 < 2 <= 3")

      assert ops == [:lt, :lte]
      assert length(operands) == 3
    end

    test "three-operator chain" do
      {:module, _, [{:expr, _, [{:chained_compare, _, [ops, operands]}]}]} =
        parse!("1 < 2 < 3 < 4")

      assert ops == [:lt, :lt, :lt]
      assert length(operands) == 4
    end
  end

  describe "match/case" do
    test "simple literal patterns" do
      ast =
        parse!("""
        match x:
            case 1:
                y = "one"
            case 2:
                y = "two"
        """)

      assert {:module, _, [{:match, [line: 1], [subject, cases]}]} = ast
      assert {:var, _, ["x"]} = subject
      assert [{pattern1, nil, body1}, {pattern2, nil, body2}] = cases
      assert {:lit, _, [1]} = pattern1
      assert [{:assign, _, ["y", {:lit, _, ["one"]}]}] = body1
      assert {:lit, _, [2]} = pattern2
      assert [{:assign, _, ["y", {:lit, _, ["two"]}]}] = body2
    end

    test "wildcard pattern" do
      ast =
        parse!("""
        match x:
            case _:
                pass
        """)

      {:module, _, [{:match, _, [_, [{pattern, nil, _}]]}]} = ast
      assert {:match_wildcard, _, []} = pattern
    end

    test "capture pattern" do
      ast =
        parse!("""
        match x:
            case name:
                pass
        """)

      {:module, _, [{:match, _, [_, [{pattern, nil, _}]]}]} = ast
      assert {:match_capture, _, ["name"]} = pattern
    end

    test "OR pattern" do
      ast =
        parse!("""
        match x:
            case 1 | 2 | 3:
                pass
        """)

      {:module, _, [{:match, _, [_, [{pattern, nil, _}]]}]} = ast
      assert {:match_or, _, [_, _, _]} = pattern
    end

    test "guard clause" do
      ast =
        parse!("""
        match x:
            case n if n > 0:
                pass
        """)

      {:module, _, [{:match, _, [_, [{_pattern, guard, _body}]]}]} = ast
      assert guard != nil
    end

    test "sequence pattern" do
      ast =
        parse!("""
        match point:
            case [x, y]:
                pass
        """)

      {:module, _, [{:match, _, [_, [{pattern, nil, _}]]}]} = ast
      assert {:match_sequence, _, [_, _]} = pattern
    end

    test "mapping pattern" do
      ast =
        parse!("""
        match data:
            case {"name": name, "age": age}:
                pass
        """)

      {:module, _, [{:match, _, [_, [{pattern, nil, _}]]}]} = ast
      assert {:match_mapping, _, [{_, _}, {_, _}]} = pattern
    end

    test "match as soft keyword allows assignment" do
      ast = parse!("match = 5")
      assert {:module, _, [{:assign, _, ["match", {:lit, _, [5]}]}]} = ast
    end

    test "match as soft keyword allows expression" do
      ast = parse!("match")
      assert {:module, _, [{:expr, _, [{:var, _, ["match"]}]}]} = ast
    end

    test "class pattern" do
      ast =
        parse!("""
        match point:
            case Point(x=0, y=0):
                pass
        """)

      {:module, _, [{:match, _, [_, [{pattern, nil, _}]]}]} = ast
      assert {:match_class, _, ["Point", [], [{"x", _}, {"y", _}]]} = pattern
    end

    test "star capture in sequence" do
      ast =
        parse!("""
        match items:
            case [first, *rest]:
                pass
        """)

      {:module, _, [{:match, _, [_, [{pattern, nil, _}]]}]} = ast
      assert {:match_sequence, _, [_, {:match_star, _, ["rest"]}]} = pattern
    end

    test "negative number pattern" do
      ast =
        parse!("""
        match x:
            case -1:
                pass
        """)

      {:module, _, [{:match, _, [_, [{pattern, nil, _}]]}]} = ast
      assert {:lit, _, [-1]} = pattern
    end
  end

  describe "nested comprehensions" do
    test "list comp with two for clauses" do
      ast = parse!("[x for row in matrix for x in row]")

      {:module, _,
       [
         {:expr, _,
          [
            {:list_comp, _,
             [
               {:var, _, ["x"]},
               [
                 {:comp_for, "row", {:var, _, ["matrix"]}},
                 {:comp_for, "x", {:var, _, ["row"]}}
               ]
             ]}
          ]}
       ]} = ast
    end

    test "list comp with for and if clauses" do
      ast = parse!("[x for row in matrix if len(row) > 0 for x in row if x > 0]")

      {:module, _,
       [
         {:expr, _,
          [
            {:list_comp, _,
             [
               {:var, _, ["x"]},
               [
                 {:comp_for, "row", {:var, _, ["matrix"]}},
                 {:comp_if, _filter1},
                 {:comp_for, "x", {:var, _, ["row"]}},
                 {:comp_if, _filter2}
               ]
             ]}
          ]}
       ]} = ast
    end

    test "generator expression with two for clauses" do
      ast = parse!("(x for row in matrix for x in row)")

      {:module, _,
       [
         {:expr, _,
          [
            {:gen_expr, _,
             [
               {:var, _, ["x"]},
               [
                 {:comp_for, "row", {:var, _, ["matrix"]}},
                 {:comp_for, "x", {:var, _, ["row"]}}
               ]
             ]}
          ]}
       ]} = ast
    end

    test "single for clause produces single-element clause list" do
      ast = parse!("[x for x in items]")

      {:module, _,
       [
         {:expr, _,
          [
            {:list_comp, _,
             [
               {:var, _, ["x"]},
               [{:comp_for, "x", {:var, _, ["items"]}}]
             ]}
          ]}
       ]} = ast
    end

    test "single for with filter produces for + if clauses" do
      ast = parse!("[x for x in items if x > 0]")

      {:module, _,
       [
         {:expr, _,
          [
            {:list_comp, _,
             [
               {:var, _, ["x"]},
               [
                 {:comp_for, "x", {:var, _, ["items"]}},
                 {:comp_if, _filter}
               ]
             ]}
          ]}
       ]} = ast
    end
  end

  describe "trailing commas" do
    test "trailing comma in dict literal" do
      ast = parse!(~s({"a": 1, "b": 2,}))
      assert {:module, _, [{:expr, _, [{:dict, _, _}]}]} = ast
    end

    test "trailing comma in multiline dict" do
      code = """
      x = {
          "a": 1,
          "b": 2,
      }
      """

      ast = parse!(code)
      assert {:module, _, [{:assign, _, _}]} = ast
    end

    test "trailing comma in single-entry dict" do
      ast = parse!(~s({"a": 1,}))
      assert {:module, _, [{:expr, _, [{:dict, _, _}]}]} = ast
    end
  end
end
