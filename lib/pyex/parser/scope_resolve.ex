defmodule Pyex.Parser.ScopeResolve do
  @moduledoc """
  Annotates `:var` AST nodes with a scope hint so the interpreter
  can skip walking the scope chain on every name lookup.

  ## What this pass does

  Walks the AST tracking a stack of scope frames.  Each frame is
  introduced by a `:def`, `:lambda`, or comprehension
  (`:list_comp`, `:set_comp`, `:dict_comp`, `:gen_expr`) and
  carries:

  - `:locals` — names bound in this frame (params + assignment LHS
    + comp iter vars).
  - `:globals` — names explicitly declared `global x` in this
    frame.

  For each `:var` read inside the function/comp body, the analyzer
  classifies the name as:

  - `:global` — read from `env.global` (module scope + builtins).
    Applies when the name is `global`-declared, when there's no
    enclosing scope, or when the name isn't bound anywhere in the
    visible stack.
  - `:local` — read from the topmost scope.  Applies when the name
    is bound in the innermost frame.

  Names bound in an outer (but not innermost) frame stay unannotated
  so the interpreter walks normally — closure / nonlocal reads.

  ## Safety contract with the interpreter

  The fast paths in `Pyex.Interpreter.eval/3` for `:var` **must
  fall back to the full scope walk on a miss**.  This makes a
  wrong annotation harmless (one wasted hash lookup, no behaviour
  change).
  """

  alias Pyex.Parser

  @doc """
  Walks a top-level `:module` AST and annotates reachable `:var`
  nodes with a scope hint where one can be proven.
  """
  @spec resolve(Parser.ast_node()) :: Parser.ast_node()
  def resolve({:module, meta, stmts}) when is_list(stmts) do
    {:module, meta, Enum.map(stmts, &walk(&1, []))}
  end

  def resolve(other), do: other

  # ── Variable reads ───────────────────────────────────────────

  defp walk({:var, meta, [name]}, scope_stack) when is_binary(name) do
    case classify(name, scope_stack) do
      nil -> {:var, meta, [name]}
      hint -> {:var, [{:scope, hint} | meta], [name]}
    end
  end

  # ── Scope-introducing nodes ─────────────────────────────────

  defp walk({:def, meta, [name, params, body]}, scope_stack) do
    frame = function_frame(params, body)
    new_body = Enum.map(body, &walk(&1, [frame | scope_stack]))
    {:def, meta, [name, params, new_body]}
  end

  defp walk({:lambda, meta, [params, body_expr]}, scope_stack) do
    frame = function_frame(params, [body_expr])
    new_body_expr = walk(body_expr, [frame | scope_stack])
    {:lambda, meta, [params, new_body_expr]}
  end

  defp walk({:class, meta, [name, base_names, body]}, scope_stack) do
    # Class scope is unusual: bare `:var` reads in the class body
    # see the enclosing function/module, not class members.  Methods
    # inside push their own frame as normal `:def` walks.  Don't
    # treat class as an additional scope frame.
    new_body = Enum.map(body, &walk(&1, scope_stack))
    {:class, meta, [name, base_names, new_body]}
  end

  defp walk({tag, meta, [expr, clauses]}, scope_stack)
       when tag in [:list_comp, :set_comp, :gen_expr] do
    frame = comp_frame(clauses)
    new_stack = [frame | scope_stack]
    new_expr = walk(expr, new_stack)
    new_clauses = Enum.map(clauses, &walk_clause(&1, scope_stack, new_stack))
    {tag, meta, [new_expr, new_clauses]}
  end

  defp walk({:dict_comp, meta, [key_expr, val_expr, clauses]}, scope_stack) do
    frame = comp_frame(clauses)
    new_stack = [frame | scope_stack]
    new_clauses = Enum.map(clauses, &walk_clause(&1, scope_stack, new_stack))

    {:dict_comp, meta, [walk(key_expr, new_stack), walk(val_expr, new_stack), new_clauses]}
  end

  # ── Generic recursion ───────────────────────────────────────

  defp walk({tag, meta, args}, scope_stack) when is_atom(tag) and is_list(args) do
    {tag, meta, walk_args(args, scope_stack)}
  end

  defp walk(other, _scope_stack), do: other

  defp walk_args(args, stack) when is_list(args) do
    Enum.map(args, &walk_arg(&1, stack))
  end

  defp walk_arg(arg, stack) when is_tuple(arg) and tuple_size(arg) == 3 do
    walk(arg, stack)
  end

  defp walk_arg(arg, stack) when is_list(arg) do
    walk_args(arg, stack)
  end

  defp walk_arg({key, value}, stack) when is_tuple(value) and tuple_size(value) == 3 do
    {key, walk(value, stack)}
  end

  defp walk_arg(arg, _stack), do: arg

  # The first `comp_for` clause's iterable is evaluated in the
  # ENCLOSING scope (a CPython quirk: `[x for x in y]` evaluates
  # `y` outside the comp).  Subsequent clauses, and the comp body,
  # evaluate inside the new scope.
  defp walk_clause({:comp_for, target, iter_expr}, outer_stack, _inner_stack) do
    # CPython evaluates each comp_for's iterable in the ENCLOSING
    # scope (the outermost iter is `y` in `[x for x in y]` and `y`
    # is resolved outside the comp).  Walking in the outer stack
    # matches that and avoids accidentally treating the iter target
    # as bound while resolving the iterable.
    {:comp_for, target, walk(iter_expr, outer_stack)}
  end

  defp walk_clause({:comp_if, expr}, _outer_stack, inner_stack) do
    {:comp_if, walk(expr, inner_stack)}
  end

  # ── Classification ──────────────────────────────────────────

  defp classify(_name, []) do
    # Module-level read: the env's scope chain is just `[module_scope]`,
    # so `Env.get` already finds it in one hop.  Don't bother annotating.
    nil
  end

  defp classify(name, [innermost | rest]) do
    cond do
      MapSet.member?(innermost.globals, name) ->
        :global

      MapSet.member?(innermost.locals, name) ->
        :local

      bound_in_any?(name, rest) ->
        # Closure / nonlocal — let the interpreter walk.
        nil

      true ->
        # Read-only access to module (or builtins, since builtins are
        # in env.global).
        :global
    end
  end

  defp bound_in_any?(_name, []), do: false

  defp bound_in_any?(name, [frame | rest]) do
    MapSet.member?(frame.locals, name) or
      MapSet.member?(frame.globals, name) or
      bound_in_any?(name, rest)
  end

  # ── Frame builders ──────────────────────────────────────────

  defp function_frame(params, body) do
    param_names = params |> Enum.map(&param_name/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
    body_locals = collect_assigns(body)
    locals = MapSet.union(param_names, body_locals)
    globals = collect_global_decls(body)
    # `global x` overrides the local binding for classification.
    %{locals: MapSet.difference(locals, globals), globals: globals}
  end

  defp comp_frame(clauses) do
    iter_names =
      Enum.reduce(clauses, MapSet.new(), fn
        {:comp_for, target, _iter}, acc -> MapSet.union(acc, target_names(target))
        _, acc -> acc
      end)

    %{locals: iter_names, globals: MapSet.new()}
  end

  defp param_name({name, _default}) when is_binary(name), do: name
  # Typed params carry a third element (the annotation); without this clause
  # they aren't counted as locals, so a param named like a builtin (`id`,
  # `list`) is misclassified `:global` and reads the builtin instead.
  defp param_name({name, _default, _type}) when is_binary(name), do: name
  defp param_name({:positional, name}) when is_binary(name), do: name
  defp param_name({:keyword, name}) when is_binary(name), do: name
  defp param_name({:starred, name}) when is_binary(name), do: name
  defp param_name({:double_starred, name}) when is_binary(name), do: name
  defp param_name(name) when is_binary(name), do: name
  defp param_name(_), do: nil

  # ── Local-binding extraction ────────────────────────────────

  @spec collect_assigns([term()]) :: MapSet.t(String.t())
  defp collect_assigns(stmts) when is_list(stmts) do
    Enum.reduce(stmts, MapSet.new(), fn stmt, acc ->
      MapSet.union(acc, find_local_binds(stmt))
    end)
  end

  @spec find_local_binds(term()) :: MapSet.t(String.t())
  defp find_local_binds({:assign, _, [name, _]}) when is_binary(name) do
    MapSet.new([name])
  end

  defp find_local_binds({:assign, _, [{:tuple, _, [items]}, _]}) when is_list(items) do
    target_names_from_list(items)
  end

  defp find_local_binds({:assign, _, [{:list, _, [items]}, _]}) when is_list(items) do
    target_names_from_list(items)
  end

  defp find_local_binds({:aug_assign, _, [name, _, _]}) when is_binary(name) do
    MapSet.new([name])
  end

  defp find_local_binds({:annotated_assign, _, [name, _, _]}) when is_binary(name) do
    MapSet.new([name])
  end

  defp find_local_binds({:walrus, _, [name, _]}) when is_binary(name) do
    MapSet.new([name])
  end

  defp find_local_binds({:multi_assign, _, [names, _]}) when is_list(names) do
    target_names_from_list(names)
  end

  defp find_local_binds({:chained_assign, _, [names, _]}) when is_list(names) do
    MapSet.new(Enum.filter(names, &is_binary/1))
  end

  defp find_local_binds({:for, _, args}) when is_list(args) do
    [target | _] = args
    target_set = target_names(target)

    rest_assigns =
      args
      |> tl()
      |> Enum.flat_map(fn
        body when is_list(body) -> MapSet.to_list(collect_assigns(body))
        _ -> []
      end)
      |> MapSet.new()

    MapSet.union(target_set, rest_assigns)
  end

  defp find_local_binds({:while, _, args}) when is_list(args) do
    args
    |> Enum.flat_map(fn
      body when is_list(body) -> MapSet.to_list(collect_assigns(body))
      _ -> []
    end)
    |> MapSet.new()
  end

  defp find_local_binds({:if, _, clauses}) when is_list(clauses) do
    Enum.reduce(clauses, MapSet.new(), fn clause, acc ->
      body =
        case clause do
          {_cond, body} when is_list(body) -> body
          body when is_list(body) -> body
          _ -> []
        end

      MapSet.union(acc, collect_assigns(body))
    end)
  end

  defp find_local_binds({:with, _, [_expr, as_name, body]}) do
    base = if is_binary(as_name), do: MapSet.new([as_name]), else: MapSet.new()
    body_set = if is_list(body), do: collect_assigns(body), else: MapSet.new()
    MapSet.union(base, body_set)
  end

  defp find_local_binds({:try, _, [body, handlers, else_body, finally_body]}) do
    handlers_set =
      Enum.reduce(handlers, MapSet.new(), fn
        {_, name, hbody}, acc ->
          base = if is_binary(name), do: MapSet.new([name]), else: MapSet.new()
          MapSet.union(acc, MapSet.union(base, collect_assigns(hbody || [])))

        _, acc ->
          acc
      end)

    [body, else_body, finally_body]
    |> Enum.reduce(handlers_set, fn part, acc ->
      MapSet.union(acc, collect_assigns(List.wrap(part)))
    end)
  end

  defp find_local_binds({:import, _, imports}) when is_list(imports) do
    Enum.reduce(imports, MapSet.new(), fn
      {name, nil}, acc when is_binary(name) -> MapSet.put(acc, top_dot(name))
      {_name, alias}, acc when is_binary(alias) -> MapSet.put(acc, alias)
      _, acc -> acc
    end)
  end

  defp find_local_binds({:from_import, _, [_module, names]}) when is_list(names) do
    Enum.reduce(names, MapSet.new(), fn
      {name, nil}, acc when is_binary(name) -> MapSet.put(acc, name)
      {_name, alias}, acc when is_binary(alias) -> MapSet.put(acc, alias)
      _, acc -> acc
    end)
  end

  defp find_local_binds({:def, _, [name, _, _]}) when is_binary(name) do
    MapSet.new([name])
  end

  defp find_local_binds({:class, _, [name, _, _]}) when is_binary(name) do
    MapSet.new([name])
  end

  defp find_local_binds({:expr, _, [inner]}), do: find_walrus(inner)

  # Nested scopes don't contribute bindings to the enclosing function.
  defp find_local_binds({tag, _, _})
       when tag in [:lambda, :list_comp, :dict_comp, :set_comp, :gen_expr] do
    MapSet.new()
  end

  defp find_local_binds(_), do: MapSet.new()

  @spec find_walrus(term()) :: MapSet.t(String.t())
  defp find_walrus({:walrus, _, [name, _]}) when is_binary(name), do: MapSet.new([name])
  defp find_walrus(_), do: MapSet.new()

  @spec target_names(term()) :: MapSet.t(String.t())
  defp target_names(target) when is_binary(target), do: MapSet.new([target])
  defp target_names({:starred, name}) when is_binary(name), do: MapSet.new([name])
  defp target_names(targets) when is_list(targets), do: target_names_from_list(targets)
  defp target_names(_), do: MapSet.new()

  @spec target_names_from_list([term()]) :: MapSet.t(String.t())
  defp target_names_from_list(items) do
    Enum.reduce(items, MapSet.new(), fn item, acc ->
      MapSet.union(acc, target_names(item))
    end)
  end

  defp top_dot(name) do
    case :binary.split(name, ".") do
      [first | _] -> first
      _ -> name
    end
  end

  # ── `global x` declaration collection ───────────────────────

  @spec collect_global_decls([term()]) :: MapSet.t(String.t())
  defp collect_global_decls(stmts) when is_list(stmts) do
    Enum.reduce(stmts, MapSet.new(), fn stmt, acc ->
      MapSet.union(acc, find_global_decls(stmt))
    end)
  end

  @spec find_global_decls(term()) :: MapSet.t(String.t())
  defp find_global_decls({:global, _, [names]}) when is_list(names) do
    MapSet.new(Enum.filter(names, &is_binary/1))
  end

  defp find_global_decls({:if, _, clauses}) when is_list(clauses) do
    Enum.reduce(clauses, MapSet.new(), fn clause, acc ->
      body =
        case clause do
          {_cond, body} when is_list(body) -> body
          body when is_list(body) -> body
          _ -> []
        end

      MapSet.union(acc, collect_global_decls(body))
    end)
  end

  defp find_global_decls({:for, _, args}) when is_list(args) do
    args
    |> Enum.filter(&is_list/1)
    |> Enum.flat_map(&MapSet.to_list(collect_global_decls(&1)))
    |> MapSet.new()
  end

  defp find_global_decls({:while, _, args}) when is_list(args) do
    args
    |> Enum.filter(&is_list/1)
    |> Enum.flat_map(&MapSet.to_list(collect_global_decls(&1)))
    |> MapSet.new()
  end

  defp find_global_decls({:try, _, [body, handlers, else_body, finally_body]}) do
    handler_globals =
      Enum.reduce(handlers, MapSet.new(), fn
        {_, _, hbody}, acc -> MapSet.union(acc, collect_global_decls(hbody || []))
        _, acc -> acc
      end)

    [body, else_body, finally_body]
    |> Enum.reduce(handler_globals, fn part, acc ->
      MapSet.union(acc, collect_global_decls(List.wrap(part)))
    end)
  end

  defp find_global_decls({:with, _, [_expr, _as, body]}) when is_list(body) do
    collect_global_decls(body)
  end

  # Nested function bodies have their own `global` scope — don't
  # leak inwards.
  defp find_global_decls({tag, _, _})
       when tag in [:def, :lambda, :class, :list_comp, :dict_comp, :set_comp, :gen_expr] do
    MapSet.new()
  end

  defp find_global_decls(_), do: MapSet.new()
end
