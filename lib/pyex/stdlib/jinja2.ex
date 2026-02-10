defmodule Pyex.Stdlib.Jinja2 do
  @moduledoc """
  Python `jinja2` module providing a Jinja2-like template engine.

  Templates are strings containing literal text interspersed with:

  - `{{ expr }}` — evaluate a Python expression and insert (auto-escaped)
  - `{{ expr | safe }}` — insert without escaping
  - `{% for x in expr %}...{% endfor %}` — loop
  - `{% if expr %}...{% elif expr %}...{% else %}...{% endif %}` — conditional
  - `{# comment #}` — discarded

  Expressions are evaluated as pure Python against the variables
  passed to `.render()`. No I/O is permitted inside templates —
  no filesystem, no imports, no side effects.

      from jinja2 import Template
      t = Template("<h1>{{ title }}</h1>")
      t.render(title="Hello")
      # => "<h1>Hello</h1>"
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.{Builtins, Ctx, Interpreter}

  @type token ::
          {:text, String.t()}
          | {:expr, String.t()}
          | {:tag, String.t()}
          | {:comment, String.t()}

  @type tnode ::
          {:text, String.t()}
          | {:expr, Pyex.Parser.ast_node(), boolean()}
          | {:for, String.t(), Pyex.Parser.ast_node(), [tnode()]}
          | {:if, [{Pyex.Parser.ast_node() | :else, [tnode()]}]}

  @doc """
  Returns the module value map.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "Template" => {:builtin, &create_template/1}
    }
  end

  @spec create_template([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp create_template([source]) when is_binary(source) do
    with {:ok, tokens} <- tokenize(source),
         {:ok, tree} <- parse(tokens),
         {:ok, compiled} <- compile_tree(tree) do
      %{
        "render" =>
          {:builtin_kw,
           fn _args, kwargs ->
             render(compiled, kwargs)
           end}
      }
    else
      {:error, msg} ->
        {:exception, "jinja2.TemplateSyntaxError: #{msg}"}
    end
  end

  defp create_template(_) do
    {:exception, "TypeError: Template() argument must be a string"}
  end

  @doc """
  Tokenizes a Jinja2 template string into a list of tokens.

  Tokens are `{:text, string}`, `{:expr, string}`, `{:tag, string}`,
  or `{:comment, string}`.
  """
  @spec tokenize(String.t()) :: {:ok, [token()]} | {:error, String.t()}
  def tokenize(source) do
    tokenize(source, [])
  end

  @spec tokenize(String.t(), [token()]) :: {:ok, [token()]} | {:error, String.t()}
  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize("{#" <> rest, acc) do
    case scan_until(rest, "#}") do
      {:ok, content, rest} -> tokenize(rest, [{:comment, String.trim(content)} | acc])
      :error -> {:error, "unclosed comment tag"}
    end
  end

  defp tokenize("{{" <> rest, acc) do
    case scan_until(rest, "}}") do
      {:ok, content, rest} -> tokenize(rest, [{:expr, String.trim(content)} | acc])
      :error -> {:error, "unclosed expression tag '{{' without '}}'"}
    end
  end

  defp tokenize("{%" <> rest, acc) do
    case scan_until(rest, "%}") do
      {:ok, content, rest} -> tokenize(rest, [{:tag, String.trim(content)} | acc])
      :error -> {:error, "unclosed block tag '{%' without '%}'"}
    end
  end

  defp tokenize(source, acc) do
    case scan_text(source) do
      {text, rest} -> tokenize(rest, [{:text, text} | acc])
    end
  end

  @spec scan_until(String.t(), String.t()) :: {:ok, String.t(), String.t()} | :error
  defp scan_until(source, delimiter) do
    case :binary.match(source, delimiter) do
      {pos, len} ->
        content = binary_part(source, 0, pos)
        rest = binary_part(source, pos + len, byte_size(source) - pos - len)
        {:ok, content, rest}

      :nomatch ->
        :error
    end
  end

  @spec scan_text(String.t()) :: {String.t(), String.t()}
  defp scan_text(source) do
    case :binary.match(source, ["{%", "{{", "{#"]) do
      {pos, _len} ->
        text = binary_part(source, 0, pos)
        rest = binary_part(source, pos, byte_size(source) - pos)
        {text, rest}

      :nomatch ->
        {source, ""}
    end
  end

  @doc """
  Parses a list of Jinja2 tokens into a template node tree.

  The tree contains `:text`, `:expr`, `:if`, `:for`, `:block`,
  `:extends`, and `:include` nodes.
  """
  @spec parse([token()]) :: {:ok, [tnode()]} | {:error, String.t()}
  def parse(tokens) do
    case parse_nodes(tokens, nil) do
      {:ok, nodes, []} -> {:ok, nodes}
      {:ok, _nodes, [{:tag, tag} | _]} -> {:error, "unexpected tag: {% #{tag} %}"}
      {:error, _} = err -> err
    end
  end

  @spec parse_nodes([token()], String.t() | nil) ::
          {:ok, [tnode()], [token()]} | {:error, String.t()}
  defp parse_nodes(tokens, stop_at) do
    parse_nodes(tokens, stop_at, [])
  end

  @spec parse_nodes([token()], String.t() | nil, [tnode()]) ::
          {:ok, [tnode()], [token()]} | {:error, String.t()}
  defp parse_nodes([], nil, acc), do: {:ok, Enum.reverse(acc), []}

  defp parse_nodes([], stop, _acc),
    do: {:error, "expected {% #{stop} %} but reached end of template"}

  defp parse_nodes([{:text, text} | rest], stop, acc) do
    parse_nodes(rest, stop, [{:text, text} | acc])
  end

  defp parse_nodes([{:comment, _} | rest], stop, acc) do
    parse_nodes(rest, stop, acc)
  end

  defp parse_nodes([{:expr, expr} | rest], stop, acc) do
    {raw_expr, safe} = check_safe_filter(expr)
    parse_nodes(rest, stop, [{:expr, raw_expr, not safe} | acc])
  end

  defp parse_nodes([{:tag, tag} | rest], stop, acc) do
    trimmed = String.trim(tag)

    cond do
      stop != nil and trimmed == stop ->
        {:ok, Enum.reverse(acc), rest}

      String.starts_with?(trimmed, "for ") ->
        parse_for(trimmed, rest, acc, stop)

      trimmed == "if " or String.starts_with?(trimmed, "if ") ->
        parse_if(trimmed, rest, acc, stop)

      trimmed == "else" or trimmed == "elif " or String.starts_with?(trimmed, "elif ") ->
        {:ok, Enum.reverse(acc), [{:tag, tag} | rest]}

      trimmed == "endfor" or trimmed == "endif" ->
        {:ok, Enum.reverse(acc), [{:tag, tag} | rest]}

      true ->
        {:error, "unknown tag: {% #{trimmed} %}"}
    end
  end

  @spec parse_for(String.t(), [token()], [tnode()], String.t() | nil) ::
          {:ok, [tnode()], [token()]} | {:error, String.t()}
  defp parse_for(tag, rest, acc, outer_stop) do
    case Regex.run(~r/^for\s+(\S+)\s+in\s+(.+)$/, tag) do
      [_, var_name, iter_expr] ->
        case parse_nodes(rest, "endfor") do
          {:ok, body, rest} ->
            node = {:for, String.trim(var_name), String.trim(iter_expr), body}
            parse_nodes(rest, outer_stop, [node | acc])

          {:error, _} = err ->
            err
        end

      nil ->
        case Regex.run(~r/^for\s+(\S+)\s*,\s*(\S+)\s+in\s+(.+)$/, tag) do
          [_, var_a, var_b, iter_expr] ->
            case parse_nodes(rest, "endfor") do
              {:ok, body, rest} ->
                var_name = "#{String.trim(var_a)},#{String.trim(var_b)}"
                node = {:for, var_name, String.trim(iter_expr), body}
                parse_nodes(rest, outer_stop, [node | acc])

              {:error, _} = err ->
                err
            end

          nil ->
            {:error, "invalid for syntax: {% #{tag} %}"}
        end
    end
  end

  @spec parse_if(String.t(), [token()], [tnode()], String.t() | nil) ::
          {:ok, [tnode()], [token()]} | {:error, String.t()}
  defp parse_if(tag, rest, acc, outer_stop) do
    condition = String.replace_prefix(tag, "if ", "") |> String.trim()

    case parse_if_branches(condition, rest, []) do
      {:ok, branches, rest} ->
        node = {:if, branches}
        parse_nodes(rest, outer_stop, [node | acc])

      {:error, _} = err ->
        err
    end
  end

  @spec parse_if_branches(String.t(), [token()], [{String.t() | :else, [tnode()]}]) ::
          {:ok, [{String.t() | :else, [tnode()]}], [token()]} | {:error, String.t()}
  defp parse_if_branches(condition, tokens, branches) do
    case parse_nodes(tokens, "endif") do
      {:ok, body, rest} ->
        case rest do
          [] ->
            {:ok, Enum.reverse([{condition, body} | branches]), []}

          [{:tag, tag} | tag_rest] ->
            trimmed = String.trim(tag)

            cond do
              trimmed == "else" ->
                case parse_nodes(tag_rest, "endif") do
                  {:ok, else_body, rest2} ->
                    all_branches =
                      Enum.reverse([{:else, else_body}, {condition, body} | branches])

                    {:ok, all_branches, rest2}

                  {:error, _} = err ->
                    err
                end

              String.starts_with?(trimmed, "elif ") ->
                next_cond = String.replace_prefix(trimmed, "elif ", "") |> String.trim()
                parse_if_branches(next_cond, tag_rest, [{condition, body} | branches])

              true ->
                {:error, "unexpected tag in if block: {% #{trimmed} %}"}
            end

          _ ->
            {:ok, Enum.reverse([{condition, body} | branches]), rest}
        end

      {:error, _} = err ->
        err
    end
  end

  @spec check_safe_filter(String.t()) :: {String.t(), boolean()}
  defp check_safe_filter(expr) do
    if String.ends_with?(expr, "| safe") do
      {expr |> String.replace_trailing("| safe", "") |> String.trim(), true}
    else
      {expr, false}
    end
  end

  @spec compile_tree([tnode()]) :: {:ok, [tnode()]} | {:error, String.t()}
  defp compile_tree(nodes) do
    compile_nodes(nodes, [])
  end

  @spec compile_nodes([tnode()], [tnode()]) :: {:ok, [tnode()]} | {:error, String.t()}
  defp compile_nodes([], acc), do: {:ok, Enum.reverse(acc)}

  defp compile_nodes([{:text, _} = node | rest], acc) do
    compile_nodes(rest, [node | acc])
  end

  defp compile_nodes([{:expr, expr_str, escape} | rest], acc) do
    case Pyex.compile(expr_str) do
      {:ok, ast} -> compile_nodes(rest, [{:expr, ast, escape} | acc])
      {:error, _} -> {:error, "invalid expression '#{expr_str}'"}
    end
  end

  defp compile_nodes([{:for, var_name, iter_str, body} | rest], acc) do
    with {:ok, iter_ast} <- Pyex.compile(iter_str),
         {:ok, compiled_body} <- compile_tree(body) do
      compile_nodes(rest, [{:for, var_name, iter_ast, compiled_body} | acc])
    else
      {:error, _} -> {:error, "invalid expression in for loop: '#{iter_str}'"}
    end
  end

  defp compile_nodes([{:if, branches} | rest], acc) do
    case compile_branches(branches, []) do
      {:ok, compiled} -> compile_nodes(rest, [{:if, compiled} | acc])
      {:error, _} = err -> err
    end
  end

  @spec compile_branches(
          [{String.t() | :else, [tnode()]}],
          [{Pyex.Parser.ast_node() | :else, [tnode()]}]
        ) ::
          {:ok, [{Pyex.Parser.ast_node() | :else, [tnode()]}]} | {:error, String.t()}
  defp compile_branches([], acc), do: {:ok, Enum.reverse(acc)}

  defp compile_branches([{:else, body} | rest], acc) do
    case compile_tree(body) do
      {:ok, compiled} -> compile_branches(rest, [{:else, compiled} | acc])
      {:error, _} = err -> err
    end
  end

  defp compile_branches([{cond_str, body} | rest], acc) do
    with {:ok, cond_ast} <- Pyex.compile(cond_str),
         {:ok, compiled_body} <- compile_tree(body) do
      compile_branches(rest, [{cond_ast, compiled_body} | acc])
    else
      {:error, _} -> {:error, "invalid expression in if condition: '#{cond_str}'"}
    end
  end

  @doc """
  Renders a compiled template tree with the given keyword arguments.

  Returns the rendered string, or an `{:exception, message}` tuple
  on render errors.
  """
  @spec render([tnode()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          Interpreter.pyvalue()
  def render(tree, kwargs) do
    env = build_env(kwargs)
    ctx = %Ctx{mode: :noop}

    case render_nodes(tree, env, ctx) do
      {:ok, parts} -> IO.iodata_to_binary(parts)
      {:error, msg} -> {:exception, "jinja2.TemplateRenderError: #{msg}"}
    end
  end

  @spec build_env(%{optional(String.t()) => Interpreter.pyvalue()}) :: Pyex.Env.t()
  defp build_env(kwargs) do
    base = Builtins.env()

    Enum.reduce(kwargs, base, fn {k, v}, env ->
      Pyex.Env.put(env, k, v)
    end)
  end

  @spec render_nodes([tnode()], Pyex.Env.t(), Ctx.t()) ::
          {:ok, iodata()} | {:error, String.t()}
  defp render_nodes(nodes, env, ctx) do
    render_nodes(nodes, env, ctx, [])
  end

  @spec render_nodes([tnode()], Pyex.Env.t(), Ctx.t(), iodata()) ::
          {:ok, iodata()} | {:error, String.t()}
  defp render_nodes([], _env, _ctx, acc), do: {:ok, Enum.reverse(acc)}

  defp render_nodes([{:text, text} | rest], env, ctx, acc) do
    render_nodes(rest, env, ctx, [text | acc])
  end

  defp render_nodes([{:expr, ast, auto_escape} | rest], env, ctx, acc) do
    case eval_ast(ast, env, ctx) do
      {:ok, value, _env, _ctx} ->
        str = to_str(value)
        output = if auto_escape, do: html_escape(str), else: str
        render_nodes(rest, env, ctx, [output | acc])

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp render_nodes([{:for, var_name, iter_ast, body} | rest], env, ctx, acc) do
    case eval_ast(iter_ast, env, ctx) do
      {:ok, iterable, _env, _ctx} ->
        items = to_list(iterable)

        case render_for_items(items, var_name, body, env, ctx, acc) do
          {:ok, acc} -> render_nodes(rest, env, ctx, acc)
          {:error, _} = err -> err
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp render_nodes([{:if, branches} | rest], env, ctx, acc) do
    case render_if_branches(branches, env, ctx) do
      {:ok, parts} -> render_nodes(rest, env, ctx, [parts | acc])
      {:error, _} = err -> err
    end
  end

  @spec render_for_items(
          [Interpreter.pyvalue()],
          String.t(),
          [tnode()],
          Pyex.Env.t(),
          Ctx.t(),
          iodata()
        ) :: {:ok, iodata()} | {:error, String.t()}
  defp render_for_items([], _var, _body, _env, _ctx, acc), do: {:ok, acc}

  defp render_for_items([item | items], var_name, body, env, ctx, acc) do
    loop_env = bind_loop_var(env, var_name, item)

    case render_nodes(body, loop_env, ctx) do
      {:ok, parts} -> render_for_items(items, var_name, body, env, ctx, [parts | acc])
      {:error, _} = err -> err
    end
  end

  @spec bind_loop_var(Pyex.Env.t(), String.t(), Interpreter.pyvalue()) :: Pyex.Env.t()
  defp bind_loop_var(env, var_name, value) do
    if String.contains?(var_name, ",") do
      vars = String.split(var_name, ",") |> Enum.map(&String.trim/1)
      items = unpack(value, length(vars))

      Enum.zip(vars, items)
      |> Enum.reduce(env, fn {name, val}, env -> Pyex.Env.put(env, name, val) end)
    else
      Pyex.Env.put(env, var_name, value)
    end
  end

  @spec unpack(Interpreter.pyvalue(), non_neg_integer()) :: [Interpreter.pyvalue()]
  defp unpack({:tuple, items}, _n), do: items
  defp unpack(list, _n) when is_list(list), do: list
  defp unpack(val, n), do: List.duplicate(val, n)

  @spec render_if_branches([{String.t() | :else, [tnode()]}], Pyex.Env.t(), Ctx.t()) ::
          {:ok, iodata()} | {:error, String.t()}
  defp render_if_branches([], _env, _ctx), do: {:ok, []}

  defp render_if_branches([{:else, body} | _], env, ctx) do
    render_nodes(body, env, ctx)
  end

  defp render_if_branches([{cond_ast, body} | rest], env, ctx) do
    case eval_ast(cond_ast, env, ctx) do
      {:ok, value, _env, _ctx} ->
        if truthy?(value) do
          render_nodes(body, env, ctx)
        else
          render_if_branches(rest, env, ctx)
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  @spec eval_ast(Pyex.Parser.ast_node(), Pyex.Env.t(), Ctx.t()) ::
          {:ok, Interpreter.pyvalue(), Pyex.Env.t(), Ctx.t()} | {:error, String.t()}
  defp eval_ast(ast, env, ctx) do
    case Interpreter.eval(ast, env, ctx) do
      {{:exception, msg}, _env, _ctx} -> {:error, msg}
      {value, env, ctx} -> {:ok, value, env, ctx}
    end
  end

  @spec to_str(Interpreter.pyvalue()) :: String.t()
  defp to_str(nil), do: ""
  defp to_str(s) when is_binary(s), do: s
  defp to_str(true), do: "True"
  defp to_str(false), do: "False"
  defp to_str(n) when is_integer(n), do: Integer.to_string(n)

  defp to_str(f) when is_float(f) do
    if f == Float.round(f, 0) and abs(f) < 1.0e15 do
      :erlang.float_to_binary(f, [:compact, decimals: 1])
    else
      :erlang.float_to_binary(f, [:compact, decimals: 12])
    end
  end

  defp to_str(list) when is_list(list), do: inspect(list)
  defp to_str(map) when is_map(map), do: inspect(map)
  defp to_str({:tuple, items}), do: "(#{Enum.map_join(items, ", ", &to_str/1)})"
  defp to_str(_), do: ""

  @spec to_list(Interpreter.pyvalue()) :: [Interpreter.pyvalue()]
  defp to_list(list) when is_list(list), do: list
  defp to_list(map) when is_map(map), do: Map.keys(Builtins.visible_dict(map))
  defp to_list({:tuple, items}), do: items
  defp to_list({:set, s}), do: MapSet.to_list(s)
  defp to_list({:range, start, stop, step}), do: Enum.to_list(start..(stop - 1)//step)
  defp to_list(s) when is_binary(s), do: String.codepoints(s)
  defp to_list(_), do: []

  @spec truthy?(Interpreter.pyvalue()) :: boolean()
  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(0), do: false
  defp truthy?(+0.0), do: false
  defp truthy?(""), do: false
  defp truthy?([]), do: false
  defp truthy?(map) when is_map(map) and map_size(map) == 0, do: false
  defp truthy?(_), do: true

  @spec html_escape(String.t()) :: String.t()
  defp html_escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#x27;")
  end
end
