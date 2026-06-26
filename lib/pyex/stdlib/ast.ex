defmodule Pyex.Stdlib.AST do
  @moduledoc """
  Python `ast` module — `literal_eval` (the part that's both common and
  faithful in a sandbox).

  `ast.literal_eval(s)` safely evaluates a string containing *only* Python
  literals (numbers, strings, tuples, lists, dicts, sets, booleans, None,
  and unary/binary number ops). Anything that could execute code — names,
  calls, attribute/subscript access, comprehensions — is rejected with a
  `ValueError`, matching CPython.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Interpreter

  # AST node tags that can execute code or reference the environment, and so
  # must never appear inside a literal.
  @non_literal_tags ~w(var call getattr subscript lambda list_comp set_comp
                       dict_comp gen_expr ternary boolop compare named_expr
                       starred await yield)a

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "__name__" => "ast",
      "literal_eval" => {:builtin, &literal_eval/1}
    }
  end

  @spec literal_eval([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  defp literal_eval([source]) when is_binary(source) do
    {:ctx_call,
     fn env, ctx ->
       with {:ok, tokens} <- Pyex.Lexer.tokenize(source),
            {:ok, {:module, _, [{:expr, _, [expr]}]}} <- Pyex.Parser.parse(tokens),
            true <- literal?(expr) do
         Interpreter.eval(expr, env, ctx)
       else
         false ->
           {{:exception, "ValueError: malformed node or string"}, env, ctx}

         _ ->
           {{:exception, "ValueError: malformed node or string: #{inspect(source)}"}, env, ctx}
       end
     end}
  end

  # `ast.literal_eval` also accepts an already-evaluated container/scalar; pass
  # those straight through (CPython does too).
  defp literal_eval([value]), do: value
  defp literal_eval(_), do: {:exception, "TypeError: literal_eval() takes one argument"}

  # A node tree is a literal if it contains no code-executing nodes.
  @spec literal?(term()) :: boolean()
  defp literal?({tag, _meta, args}) when is_atom(tag) do
    tag not in @non_literal_tags and literal?(args)
  end

  defp literal?(list) when is_list(list), do: Enum.all?(list, &literal?/1)
  defp literal?({key, value}), do: literal?(key) and literal?(value)
  defp literal?(_leaf), do: true
end
