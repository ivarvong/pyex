defmodule Pyex.Stdlib.Boto3.DynamoDB.Expr do
  @moduledoc """
  A focused evaluator for the DynamoDB expression sub-languages used by the
  resource and low-level client: ConditionExpression and UpdateExpression,
  with `:value` / `#name` substitution from ExpressionAttributeValues /
  ExpressionAttributeNames.

  Operates on *plain* pyex item maps (`%{name => pyvalue}`) — callers unmarshal
  the typed wire format at the boundary. Supports the common surface real apps
  use: `attribute_(not_)exists`, `begins_with`, the comparators `= <> < <= > >=`
  combined with `AND` / `OR` / parentheses; and `SET` (with `a + :v` / `a - :v`),
  `ADD` (atomic numeric counter), and `REMOVE`.
  """

  alias Pyex.Interpreter

  @typep item :: %{optional(String.t()) => Interpreter.pyvalue()}
  @typep subs :: %{values: item(), names: %{optional(String.t()) => String.t()}}

  # ── ConditionExpression ────────────────────────────────────────────────────

  @doc "Evaluates a ConditionExpression against `item`. Returns a boolean or {:error, msg}."
  @spec condition(String.t() | nil, item(), subs()) :: boolean() | {:error, String.t()}
  def condition(nil, _item, _subs), do: true

  def condition(expr, item, subs) when is_binary(expr) do
    with {:ok, tokens} <- tokenize(expr),
         {:ok, ast, []} <- parse_or(tokens) do
      eval_cond(ast, item, subs)
    else
      {:ok, _ast, rest} -> {:error, "unexpected tokens in ConditionExpression: #{inspect(rest)}"}
      {:error, _} = err -> err
    end
  end

  defp eval_cond({:and, a, b}, item, subs),
    do: bool_and(eval_cond(a, item, subs), fn -> eval_cond(b, item, subs) end)

  defp eval_cond({:or, a, b}, item, subs),
    do: bool_or(eval_cond(a, item, subs), fn -> eval_cond(b, item, subs) end)

  defp eval_cond({:func, "attribute_exists", [path]}, item, subs),
    do: Map.has_key?(item, resolve_name(path, subs))

  defp eval_cond({:func, "attribute_not_exists", [path]}, item, subs),
    do: not Map.has_key?(item, resolve_name(path, subs))

  defp eval_cond({:func, "begins_with", [path, val]}, item, subs) do
    with v when is_binary(v) <- operand(path, item, subs),
         p when is_binary(p) <- operand(val, item, subs) do
      String.starts_with?(v, p)
    else
      _ -> false
    end
  end

  defp eval_cond({:cmp, op, l, r}, item, subs) do
    compare(op, operand(l, item, subs), operand(r, item, subs))
  end

  defp eval_cond({:func, name, _}, _item, _subs),
    do: {:error, "unsupported condition function: #{name}"}

  # ── UpdateExpression ───────────────────────────────────────────────────────

  @doc "Applies an UpdateExpression to `item`, returning the updated item or {:error, msg}."
  @spec update(String.t() | nil, item(), subs()) :: {:ok, item()} | {:error, String.t()}
  def update(nil, item, _subs), do: {:ok, item}

  def update(expr, item, subs) when is_binary(expr) do
    case parse_update_clauses(expr) do
      {:ok, clauses} -> apply_clauses(clauses, item, subs)
      {:error, _} = err -> err
    end
  end

  defp apply_clauses(clauses, item, subs) do
    Enum.reduce_while(clauses, {:ok, item}, fn clause, {:ok, item} ->
      case apply_clause(clause, item, subs) do
        {:ok, item} -> {:cont, {:ok, item}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp apply_clause({:set, path, value_expr}, item, subs) do
    name = resolve_name(path, subs)

    case set_value(value_expr, item, subs) do
      {:ok, v} -> {:ok, Map.put(item, name, v)}
      {:error, _} = err -> err
    end
  end

  defp apply_clause({:add, path, val}, item, subs) do
    name = resolve_name(path, subs)
    delta = operand(val, item, subs)
    current = Map.get(item, name, num(0))

    case add_numbers(current, delta) do
      {:ok, sum} -> {:ok, Map.put(item, name, sum)}
      {:error, _} = err -> err
    end
  end

  defp apply_clause({:remove, path}, item, subs),
    do: {:ok, Map.delete(item, resolve_name(path, subs))}

  # SET right-hand side: an operand, or `operand +/- operand` (counter math).
  defp set_value({:plus, a, b}, item, subs),
    do: add_numbers(operand(a, item, subs), operand(b, item, subs))

  defp set_value({:minus, a, b}, item, subs),
    do: add_numbers(operand(a, item, subs), negate(operand(b, item, subs)))

  defp set_value(operand, item, subs), do: {:ok, operand(operand, item, subs)}

  # ── operands / substitution ────────────────────────────────────────────────

  defp operand({:value_ref, ref}, _item, subs), do: Map.get(subs.values, ref)
  defp operand({:name, path}, item, subs), do: Map.get(item, resolve_name({:name, path}, subs))

  defp resolve_name({:name, "#" <> _ = ref}, subs), do: Map.get(subs.names, ref, ref)
  defp resolve_name({:name, name}, _subs), do: name
  defp resolve_name(name, _subs) when is_binary(name), do: name

  # ── value comparison / arithmetic (Elixir-side, over pyex values) ──────────

  defp compare(op, a, b) do
    case {a, b} do
      {nil, _} -> op in ["<>"] and not is_nil(b)
      {_, nil} -> op in ["<>"]
      _ -> apply_cmp(op, cmp(a, b))
    end
  end

  defp apply_cmp("=", :eq), do: true
  defp apply_cmp("=", _), do: false
  defp apply_cmp("<>", :eq), do: false
  defp apply_cmp("<>", _), do: true
  defp apply_cmp("<", o), do: o == :lt
  defp apply_cmp("<=", o), do: o in [:lt, :eq]
  defp apply_cmp(">", o), do: o == :gt
  defp apply_cmp(">=", o), do: o in [:gt, :eq]

  # Three-way compare of two pyex values (numbers via Decimal, then strings).
  defp cmp(a, b) do
    case {to_decimal(a), to_decimal(b)} do
      {{:ok, da}, {:ok, db}} -> decimal_cmp(da, db)
      _ -> str_cmp(a, b)
    end
  end

  defp decimal_cmp(da, db) do
    case Decimal.compare(da, db) do
      :lt -> :lt
      :gt -> :gt
      :eq -> :eq
    end
  end

  defp str_cmp(a, b) when is_binary(a) and is_binary(b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  defp str_cmp(a, b), do: if(a == b, do: :eq, else: :ne)

  defp to_decimal({:pyex_decimal, d}), do: {:ok, d}
  defp to_decimal(n) when is_integer(n), do: {:ok, Decimal.new(n)}
  defp to_decimal(n) when is_float(n), do: {:ok, Decimal.from_float(n)}
  defp to_decimal(_), do: :error

  defp add_numbers(a, b) do
    case {to_decimal(a), to_decimal(b)} do
      {{:ok, da}, {:ok, db}} -> {:ok, {:pyex_decimal, Decimal.add(da, db)}}
      _ -> {:error, "ADD/arithmetic requires numbers"}
    end
  end

  defp negate({:pyex_decimal, d}), do: {:pyex_decimal, Decimal.negate(d)}
  defp negate(n) when is_integer(n), do: -n
  defp negate(n) when is_float(n), do: -n
  defp negate(other), do: other

  defp num(n), do: {:pyex_decimal, Decimal.new(n)}

  defp bool_and({:error, _} = e, _f), do: e
  defp bool_and(false, _f), do: false
  defp bool_and(true, f), do: f.()

  defp bool_or({:error, _} = e, _f), do: e
  defp bool_or(true, _f), do: true
  defp bool_or(false, f), do: f.()

  # ── tokenizer (shared by both expression grammars) ─────────────────────────

  @spec tokenize(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def tokenize(expr) do
    # Stash the two-char operators as placeholders so padding the single-char
    # `=` / `<` / `>` doesn't split them, then restore.
    toks =
      expr
      |> String.replace("<=", " ~LE~ ")
      |> String.replace(">=", " ~GE~ ")
      |> String.replace("<>", " ~NE~ ")
      |> String.replace(~r/([()=<>,])/, " \\1 ")
      |> String.replace("~LE~", "<=")
      |> String.replace("~GE~", ">=")
      |> String.replace("~NE~", "<>")
      |> String.split(~r/\s+/, trim: true)

    {:ok, toks}
  end

  # ── ConditionExpression parser (precedence: OR < AND < primary) ────────────

  defp parse_or(tokens) do
    case parse_and(tokens) do
      {:ok, left, ["OR" | rest]} ->
        with {:ok, right, rest} <- parse_or(rest), do: {:ok, {:or, left, right}, rest}

      other ->
        other
    end
  end

  defp parse_and(tokens) do
    case parse_primary(tokens) do
      {:ok, left, ["AND" | rest]} ->
        with {:ok, right, rest} <- parse_and(rest), do: {:ok, {:and, left, right}, rest}

      other ->
        other
    end
  end

  defp parse_primary(["(" | rest]) do
    case parse_or(rest) do
      {:ok, inner, [")" | rest]} -> {:ok, inner, rest}
      {:ok, _, rest} -> {:error, "expected ) in ConditionExpression near #{inspect(rest)}"}
      err -> err
    end
  end

  defp parse_primary([fname, "(" | rest])
       when fname in ~w(attribute_exists attribute_not_exists begins_with) do
    {args, rest} = parse_func_args(rest, [])
    {:ok, {:func, fname, args}, rest}
  end

  defp parse_primary([a, op, b | rest]) when op in ~w(= <> < <= > >=),
    do: {:ok, {:cmp, op, term(a), term(b)}, rest}

  defp parse_primary(rest), do: {:error, "cannot parse ConditionExpression near #{inspect(rest)}"}

  defp parse_func_args([")" | rest], acc), do: {Enum.reverse(acc), rest}
  defp parse_func_args(["," | rest], acc), do: parse_func_args(rest, acc)
  defp parse_func_args([tok | rest], acc), do: parse_func_args(rest, [term(tok) | acc])
  defp parse_func_args([], acc), do: {Enum.reverse(acc), []}

  defp term(":" <> _ = ref), do: {:value_ref, ref}
  defp term(name), do: {:name, name}

  # ── UpdateExpression parser ────────────────────────────────────────────────

  defp parse_update_clauses(expr) do
    # Split into SET / ADD / REMOVE / DELETE sections, keeping the keyword.
    sections =
      Regex.split(~r/\b(SET|ADD|REMOVE|DELETE)\b/, expr, include_captures: true, trim: true)
      |> Enum.map(&String.trim/1)
      |> chunk_sections()

    Enum.reduce_while(sections, {:ok, []}, fn {kw, body}, {:ok, acc} ->
      case parse_section(kw, body) do
        {:ok, clauses} -> {:cont, {:ok, acc ++ clauses}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp chunk_sections([kw, body | rest]) when kw in ~w(SET ADD REMOVE DELETE),
    do: [{kw, body} | chunk_sections(rest)]

  defp chunk_sections([]), do: []
  defp chunk_sections(_), do: []

  defp parse_section("SET", body) do
    body
    |> split_top_commas()
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case String.split(part, "=", parts: 2) do
        [path, rhs] ->
          {:cont, {:ok, acc ++ [{:set, {:name, String.trim(path)}, parse_value_expr(rhs)}]}}

        _ ->
          {:halt, {:error, "bad SET action: #{part}"}}
      end
    end)
  end

  defp parse_section("ADD", body) do
    body
    |> split_top_commas()
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case String.split(String.trim(part), ~r/\s+/, parts: 2) do
        [path, val] -> {:cont, {:ok, acc ++ [{:add, {:name, path}, term(String.trim(val))}]}}
        _ -> {:halt, {:error, "bad ADD action: #{part}"}}
      end
    end)
  end

  defp parse_section("REMOVE", body),
    do: {:ok, body |> split_top_commas() |> Enum.map(&{:remove, {:name, String.trim(&1)}})}

  defp parse_section(kw, _body), do: {:error, "unsupported update action: #{kw}"}

  defp parse_value_expr(rhs) do
    rhs = String.trim(rhs)

    cond do
      String.contains?(rhs, "+") ->
        [a, b] = String.split(rhs, "+", parts: 2)
        {:plus, term(String.trim(a)), term(String.trim(b))}

      String.contains?(rhs, "-") ->
        [a, b] = String.split(rhs, "-", parts: 2)
        {:minus, term(String.trim(a)), term(String.trim(b))}

      true ->
        term(rhs)
    end
  end

  defp split_top_commas(s), do: s |> String.split(",") |> Enum.map(&String.trim/1)
end
