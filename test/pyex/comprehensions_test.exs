defmodule Pyex.ComprehensionsTest do
  use ExUnit.Case, async: true

  describe "list comprehension" do
    test "simple comprehension" do
      assert Pyex.run!("[x * 2 for x in [1, 2, 3]]") == [2, 4, 6]
    end

    test "comprehension with filter" do
      assert Pyex.run!("[x for x in [1, 2, 3, 4, 5] if x > 3]") == [4, 5]
    end

    test "comprehension with expression and filter" do
      assert Pyex.run!("[x * x for x in range(6) if x % 2 == 0]") == [0, 4, 16]
    end

    test "comprehension over string" do
      assert Pyex.run!("[ch for ch in \"hello\"]") == ["h", "e", "l", "l", "o"]
    end

    test "comprehension over range" do
      assert Pyex.run!("[i for i in range(5)]") == [0, 1, 2, 3, 4]
    end

    test "comprehension with function call" do
      result =
        Pyex.run!("""
        def square(n):
            return n * n

        [square(x) for x in [1, 2, 3, 4]]
        """)

      assert result == [1, 4, 9, 16]
    end

    test "comprehension assigned to variable" do
      result =
        Pyex.run!("""
        squares = [x * x for x in range(5)]
        squares
        """)

      assert result == [0, 1, 4, 9, 16]
    end
  end

  describe "dict comprehension" do
    test "basic dict comprehension" do
      assert Pyex.run!("{x: x**2 for x in range(4)}") == %{0 => 0, 1 => 1, 2 => 4, 3 => 9}
    end

    test "dict comprehension with filter" do
      assert Pyex.run!("{x: x**2 for x in range(6) if x % 2 == 0}") ==
               %{0 => 0, 2 => 4, 4 => 16}
    end

    test "dict comprehension with tuple unpacking" do
      assert Pyex.run!(~s|{k: v * 2 for k, v in {"a": 1, "b": 2}.items()}|) ==
               %{"a" => 2, "b" => 4}
    end

    test "dict comprehension from list" do
      assert Pyex.run!(~s|{s: len(s) for s in ["hi", "world"]}|) ==
               %{"hi" => 2, "world" => 5}
    end
  end

  describe "set comprehension" do
    test "basic set comprehension" do
      result = Pyex.run!("{x * 2 for x in [1, 2, 3]}")
      assert result == {:set, MapSet.new([2, 4, 6])}
    end

    test "set comprehension with filter" do
      result = Pyex.run!("{x for x in range(10) if x % 2 == 0}")
      assert result == {:set, MapSet.new([0, 2, 4, 6, 8])}
    end

    test "set comprehension deduplicates" do
      result = Pyex.run!("{x % 3 for x in range(9)}")
      assert result == {:set, MapSet.new([0, 1, 2])}
    end

    test "set comprehension over string" do
      result = Pyex.run!("{ch for ch in \"hello\"}")
      assert result == {:set, MapSet.new(["h", "e", "l", "o"])}
    end

    test "set comprehension with tuple unpacking" do
      result = Pyex.run!(~s|{k for k, v in {"a": 1, "b": 2}.items()}|)
      assert result == {:set, MapSet.new(["a", "b"])}
    end

    test "set comprehension assigned to variable" do
      result =
        Pyex.run!("""
        evens = {x for x in range(10) if x % 2 == 0}
        sorted(evens)
        """)

      assert result == [0, 2, 4, 6, 8]
    end
  end

  describe "nested comprehensions" do
    test "flatten nested list" do
      assert Pyex.run!("[x for row in [[1, 2], [3, 4], [5]] for x in row]") ==
               [1, 2, 3, 4, 5]
    end

    test "nested with filter on inner" do
      assert Pyex.run!("[x for row in [[1, 2, 3], [4, 5, 6]] for x in row if x % 2 == 0]") ==
               [2, 4, 6]
    end

    test "nested with filter on outer" do
      code = "[x for row in [[1, 2], [], [3, 4]] if len(row) > 0 for x in row]"
      assert Pyex.run!(code) == [1, 2, 3, 4]
    end

    test "nested with expression" do
      assert Pyex.run!("[x * 2 for row in [[1, 2], [3]] for x in row]") == [2, 4, 6]
    end

    test "triple nesting" do
      code = """
      matrix = [[[1, 2], [3]], [[4], [5, 6]]]
      [x for plane in matrix for row in plane for x in row]
      """

      assert Pyex.run!(code) == [1, 2, 3, 4, 5, 6]
    end

    test "nested list comp with range" do
      assert Pyex.run!("[(i, j) for i in range(3) for j in range(2)]") ==
               [
                 {:tuple, [0, 0]},
                 {:tuple, [0, 1]},
                 {:tuple, [1, 0]},
                 {:tuple, [1, 1]},
                 {:tuple, [2, 0]},
                 {:tuple, [2, 1]}
               ]
    end

    test "nested dict comprehension" do
      code = ~s|{k: v for d in [{"a": 1}, {"b": 2}] for k, v in d.items()}|
      assert Pyex.run!(code) == %{"a" => 1, "b" => 2}
    end

    test "nested set comprehension" do
      result = Pyex.run!("{x for row in [[1, 2, 2], [3, 1]] for x in row}")
      assert result == {:set, MapSet.new([1, 2, 3])}
    end

    test "nested generator expression" do
      assert Pyex.run!("list(x for row in [[1, 2], [3]] for x in row)") == [1, 2, 3]
    end

    test "nested gen expr as function argument" do
      assert Pyex.run!("sum(x for row in [[1, 2], [3, 4]] for x in row)") == 10
    end

    test "nested comprehension with tuple unpacking" do
      code = """
      pairs = [[(1, "a"), (2, "b")], [(3, "c")]]
      [v for group in pairs for k, v in group]
      """

      assert Pyex.run!(code) == ["a", "b", "c"]
    end

    test "nested comprehension with multiple filters" do
      code = "[x for row in [[1,2,3],[4,5,6]] if len(row) == 3 for x in row if x > 2]"
      assert Pyex.run!(code) == [3, 4, 5, 6]
    end
  end

  # CPython grammar allows the primary `for` target of a comprehension to be
  # a parenthesised tuple pattern — exactly the same shape allowed for `for`
  # statements and for secondary `for` clauses inside a comprehension chain.
  #
  # Until the parser was made symmetric with `parse_for` / `parse_comp_for_clause`
  # / `parse_gen_expr_body`, the primary-target case failed with
  # "expected variable name after 'for' in {list,set,dict} comprehension".
  # Bare-comma targets (`for a, b in xs`) were unaffected.  The runtime
  # already handles list-shaped targets via `bind_loop_var/3` and
  # `unpack_for_item/2`, so the fix is purely additive in the parser.
  describe "parenthesised tuple target in primary for clause" do
    test "list comprehension binds (a, b) target" do
      assert Pyex.run!("[a + b for (a, b) in [(1, 2), (3, 4), (5, 6)]]") == [3, 7, 11]
    end

    test "list comprehension re-emits tuples through (a, b) target" do
      assert Pyex.run!("[(a, b) for (a, b) in [(1, 2), (3, 4)]]") ==
               [{:tuple, [1, 2]}, {:tuple, [3, 4]}]
    end

    test "list comprehension binds 3-element tuple target" do
      assert Pyex.run!("[a * b * c for (a, b, c) in [(1, 2, 3), (4, 5, 6)]]") == [6, 120]
    end

    test "list comprehension binds single-element tuple target" do
      assert Pyex.run!("[a for (a,) in [(1,), (2,), (3,)]]") == [1, 2, 3]
    end

    test "list comprehension binds nested tuple target (a, (b, c))" do
      code = "[a + b + c for (a, (b, c)) in [(1, (2, 3)), (4, (5, 6))]]"
      assert Pyex.run!(code) == [6, 15]
    end

    test "list comprehension binds starred tuple target (a, *rest)" do
      assert Pyex.run!("[rest for (a, *rest) in [(1, 2, 3), (4, 5)]]") == [[2, 3], [5]]
    end

    test "list comprehension with paren target also accepts trailing filter" do
      code = "[a + b for (a, b) in [(1, 2), (3, 4), (5, 6)] if a > 1]"
      assert Pyex.run!(code) == [7, 11]
    end

    test "set comprehension binds (a, b) target" do
      result = Pyex.run!("{a for (a, b) in [(1, 2), (3, 4), (1, 9)]}")
      assert result == {:set, MapSet.new([1, 3])}
    end

    test "dict comprehension binds (k, v) target" do
      assert Pyex.run!(~s|{k: v for (k, v) in [("x", 1), ("y", 2)]}|) ==
               %{"x" => 1, "y" => 2}
    end

    test "standalone generator expression binds (a, b) target" do
      # Goes through parse_gen_expr (called when a `(` opens at expression
      # position), not parse_gen_expr_body (called from function-call args).
      # Before the fix, only the latter accepted lparen targets.
      code = """
      g = (a + b for (a, b) in [(1, 2), (3, 4)])
      list(g)
      """

      assert Pyex.run!(code) == [3, 7]
    end

    test "generator expression as function argument with (a, b) target" do
      # parse_gen_expr_body path — was already passing.  Kept as a
      # symmetry / regression check now that parse_gen_expr matches.
      assert Pyex.run!("sum(a * b for (a, b) in [(1, 2), (3, 4), (5, 6)])") == 2 + 12 + 30
    end

    test "primary paren target plus secondary bare-comma clause" do
      code = "[a + b + z for (a, b) in [(1, 2)] for z in [10, 100]]"
      assert Pyex.run!(code) == [13, 103]
    end

    test "primary paren target plus secondary paren target" do
      code = "[a + c for (a, b) in [(1, 2)] for (c, d) in [(10, 20), (30, 40)]]"
      assert Pyex.run!(code) == [11, 31]
    end

    test "bare-comma primary target still works (regression)" do
      assert Pyex.run!("[a + b for a, b in [(1, 2), (3, 4)]]") == [3, 7]
    end
  end

  # The runtime arity / type errors are already produced by
  # `unpack_for_item/2` for secondary `for` clauses.  These tests prove
  # the *primary* paren target reaches the same code path — that the
  # parser fix doesn't silently swallow targets.
  describe "parenthesised tuple target: runtime errors match CPython" do
    test "arity mismatch (too many) raises ValueError at runtime" do
      {:error, %Pyex.Error{message: msg}} =
        Pyex.run("[a + b for (a, b) in [(1, 2, 3)]]")

      assert msg =~ "ValueError"
      assert msg =~ "expected 2"
      assert msg =~ "got 3"
    end

    test "arity mismatch (too few) raises ValueError at runtime" do
      {:error, %Pyex.Error{message: msg}} =
        Pyex.run("[a + b for (a, b) in [(1,)]]")

      assert msg =~ "ValueError"
      assert msg =~ "expected 2"
      assert msg =~ "got 1"
    end

    test "non-iterable element raises TypeError at runtime" do
      {:error, %Pyex.Error{message: msg}} =
        Pyex.run("[a + b for (a, b) in [1, 2]]")

      assert msg =~ "TypeError"
      assert msg =~ "cannot unpack"
    end
  end

  # AST-shape symmetry: parsing the paren-target form must produce the
  # same `:comp_for` target shape that the bare-comma form already
  # produces, so the downstream interpreter sees one shape, not two.
  describe "parenthesised tuple target: AST equivalence" do
    test "list comp: (a, b) target produces same comp_for shape as a, b target" do
      {:ok, paren_ast} = Pyex.compile("[a + b for (a, b) in xs]")
      {:ok, bare_ast} = Pyex.compile("[a + b for a, b in xs]")

      assert comp_for_target(paren_ast) == comp_for_target(bare_ast)
      assert comp_for_target(paren_ast) == ["a", "b"]
    end

    test "dict comp: (k, v) target produces same shape as bare k, v" do
      {:ok, paren_ast} = Pyex.compile("{k: v for (k, v) in xs}")
      {:ok, bare_ast} = Pyex.compile("{k: v for k, v in xs}")

      assert comp_for_target(paren_ast) == comp_for_target(bare_ast)
      assert comp_for_target(paren_ast) == ["k", "v"]
    end

    test "set comp: (a, b) target produces same shape as bare a, b" do
      {:ok, paren_ast} = Pyex.compile("{a for (a, b) in xs}")
      {:ok, bare_ast} = Pyex.compile("{a for a, b in xs}")

      assert comp_for_target(paren_ast) == comp_for_target(bare_ast)
    end

    test "gen expr: (a, b) target produces same shape as bare a, b" do
      {:ok, paren_ast} = Pyex.compile("(a + b for (a, b) in xs)")
      {:ok, bare_ast} = Pyex.compile("(a + b for a, b in xs)")

      assert comp_for_target(paren_ast) == comp_for_target(bare_ast)
    end

    test "list comp: nested paren target preserves nesting" do
      {:ok, ast} = Pyex.compile("[x for (a, (b, c)) in xs]")
      assert comp_for_target(ast) == ["a", ["b", "c"]]
    end
  end

  # Walk the AST to the first `comp_for` clause and return its target.
  # `Pyex.compile/1` returns `{:module, _, [{:expr, _, [inner]}, ...]}`,
  # so peel both wrappers before matching the comprehension itself.
  defp comp_for_target({:module, _meta, stmts}) do
    case stmts do
      [{:expr, _, [inner]} | _] -> comp_for_target(inner)
      [single] -> comp_for_target(single)
      other -> flunk("expected module with comprehension stmt, got: #{inspect(other)}")
    end
  end

  defp comp_for_target({tag, _meta, args})
       when tag in [:list_comp, :set_comp, :gen_expr] do
    [_expr, clauses] = args
    first_comp_for_target(clauses)
  end

  defp comp_for_target({:dict_comp, _meta, [_k, _v, clauses]}) do
    first_comp_for_target(clauses)
  end

  defp comp_for_target(other) do
    flunk("expected comprehension AST, got: #{inspect(other)}")
  end

  defp first_comp_for_target([{:comp_for, target, _iterable} | _]), do: target
  defp first_comp_for_target([_ | rest]), do: first_comp_for_target(rest)
  defp first_comp_for_target([]), do: flunk("no :comp_for clause in AST")
end
