defmodule Pyex.Stdlib.Operator do
  @moduledoc """
  Python `operator` module.

  Provides functional counterparts for built-in operators plus the
  `attrgetter`, `itemgetter`, and `methodcaller` factory functions.
  Most functions are simple wrappers that let users pass operators as
  first-class callables to `sorted`, `map`, `reduce`, etc.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Interpreter

  @doc """
  Returns the module value map.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      # Arithmetic
      "add" => {:builtin, &op_add/1},
      "sub" => {:builtin, &op_sub/1},
      "mul" => {:builtin, &op_mul/1},
      "truediv" => {:builtin, &op_truediv/1},
      "floordiv" => {:builtin, &op_floordiv/1},
      "mod" => {:builtin, &op_mod/1},
      "pow" => {:builtin, &op_pow/1},
      "neg" => {:builtin, &op_neg/1},
      "pos" => {:builtin, &op_pos/1},
      "abs" => {:builtin, &op_abs/1},

      # Bitwise
      "and_" => {:builtin, &op_band/1},
      "or_" => {:builtin, &op_bor/1},
      "xor" => {:builtin, &op_bxor/1},
      "invert" => {:builtin, &op_invert/1},
      "lshift" => {:builtin, &op_lshift/1},
      "rshift" => {:builtin, &op_rshift/1},

      # Comparisons
      "lt" => {:builtin, &op_lt/1},
      "le" => {:builtin, &op_le/1},
      "eq" => {:builtin, &op_eq/1},
      "ne" => {:builtin, &op_ne/1},
      "ge" => {:builtin, &op_ge/1},
      "gt" => {:builtin, &op_gt/1},
      "is_" => {:builtin, &op_is/1},
      "is_not" => {:builtin, &op_is_not/1},

      # Logical
      "not_" => {:builtin, &op_not/1},
      "truth" => {:builtin, &op_truth/1},

      # Sequence / container
      "contains" => {:builtin, &op_contains/1},
      "countOf" => {:builtin, &op_count_of/1},
      "indexOf" => {:builtin, &op_index_of/1},
      "getitem" => {:builtin, &op_getitem/1},
      "setitem" => {:builtin, &op_setitem/1},
      "delitem" => {:builtin, &op_delitem/1},
      "concat" => {:builtin, &op_concat/1},

      # Factory functions
      "attrgetter" => {:builtin, &op_attrgetter/1},
      "itemgetter" => {:builtin, &op_itemgetter/1},
      "methodcaller" => {:builtin, &op_methodcaller/1}
    }
  end

  defp op_add([a, b]) when is_number(a) and is_number(b), do: a + b
  defp op_add([a, b]) when is_binary(a) and is_binary(b), do: a <> b
  defp op_add([a, b]) when is_list(a) and is_list(b), do: a ++ b
  defp op_add([{:py_list, ar, al}, {:py_list, br, bl}]), do: {:py_list, br ++ ar, al + bl}
  defp op_add([{:tuple, a}, {:tuple, b}]), do: {:tuple, a ++ b}
  defp op_add(_), do: {:exception, "TypeError: unsupported operand types for add"}

  defp op_sub([a, b]) when is_number(a) and is_number(b), do: a - b
  defp op_sub(_), do: {:exception, "TypeError: unsupported operand types for sub"}

  defp op_mul([a, b]) when is_number(a) and is_number(b), do: a * b
  defp op_mul([s, n]) when is_binary(s) and is_integer(n), do: String.duplicate(s, max(n, 0))
  defp op_mul([n, s]) when is_integer(n) and is_binary(s), do: String.duplicate(s, max(n, 0))
  defp op_mul(_), do: {:exception, "TypeError: unsupported operand types for mul"}

  defp op_truediv([_, 0]), do: {:exception, "ZeroDivisionError: division by zero"}
  defp op_truediv([_, +0.0]), do: {:exception, "ZeroDivisionError: division by zero"}
  defp op_truediv([_, -0.0]), do: {:exception, "ZeroDivisionError: division by zero"}
  defp op_truediv([a, b]) when is_number(a) and is_number(b), do: a / b
  defp op_truediv(_), do: {:exception, "TypeError: unsupported operand types for truediv"}

  defp op_floordiv([_, 0]), do: {:exception, "ZeroDivisionError: integer division by zero"}
  defp op_floordiv([a, b]) when is_integer(a) and is_integer(b), do: Integer.floor_div(a, b)

  defp op_floordiv([a, b]) when is_number(a) and is_number(b),
    do: :math.floor(a / b) * 1.0

  defp op_floordiv(_), do: {:exception, "TypeError: unsupported operand types for floordiv"}

  defp op_mod([_, 0]), do: {:exception, "ZeroDivisionError: integer division by zero"}
  defp op_mod([a, b]) when is_integer(a) and is_integer(b), do: Integer.mod(a, b)
  defp op_mod([a, b]) when is_number(a) and is_number(b), do: a - :math.floor(a / b) * b
  defp op_mod(_), do: {:exception, "TypeError: unsupported operand types for mod"}

  defp op_pow([a, b]) when is_integer(a) and is_integer(b) and b >= 0,
    do: Integer.pow(a, b)

  defp op_pow([a, b]) when is_number(a) and is_number(b), do: :math.pow(a, b)
  defp op_pow(_), do: {:exception, "TypeError: unsupported operand types for pow"}

  defp op_neg([a]) when is_number(a), do: -a
  defp op_neg(_), do: {:exception, "TypeError: bad operand type for neg"}

  defp op_pos([a]) when is_number(a), do: +a
  defp op_pos(_), do: {:exception, "TypeError: bad operand type for pos"}

  defp op_abs([a]) when is_number(a), do: abs(a)
  defp op_abs(_), do: {:exception, "TypeError: bad operand type for abs"}

  defp op_band([a, b]) when is_integer(a) and is_integer(b), do: Bitwise.band(a, b)
  defp op_band(_), do: {:exception, "TypeError: unsupported operand types for &"}

  defp op_bor([a, b]) when is_integer(a) and is_integer(b), do: Bitwise.bor(a, b)
  defp op_bor(_), do: {:exception, "TypeError: unsupported operand types for |"}

  defp op_bxor([a, b]) when is_integer(a) and is_integer(b), do: Bitwise.bxor(a, b)
  defp op_bxor(_), do: {:exception, "TypeError: unsupported operand types for ^"}

  defp op_invert([a]) when is_integer(a), do: Bitwise.bnot(a)
  defp op_invert(_), do: {:exception, "TypeError: bad operand type for invert"}

  defp op_lshift([a, b]) when is_integer(a) and is_integer(b) and b >= 0,
    do: Bitwise.bsl(a, b)

  defp op_lshift(_), do: {:exception, "TypeError: unsupported operand types for <<"}

  defp op_rshift([a, b]) when is_integer(a) and is_integer(b) and b >= 0,
    do: Bitwise.bsr(a, b)

  defp op_rshift(_), do: {:exception, "TypeError: unsupported operand types for >>"}

  defp op_lt([a, b]), do: compare_values(a, b, :lt)
  defp op_le([a, b]), do: compare_values(a, b, :le)
  defp op_eq([a, b]), do: a == b
  defp op_ne([a, b]), do: a != b
  defp op_ge([a, b]), do: compare_values(a, b, :ge)
  defp op_gt([a, b]), do: compare_values(a, b, :gt)
  defp op_is([a, b]), do: a === b
  defp op_is_not([a, b]), do: a !== b

  defp compare_values(a, b, :lt) when is_number(a) and is_number(b), do: a < b
  defp compare_values(a, b, :le) when is_number(a) and is_number(b), do: a <= b
  defp compare_values(a, b, :ge) when is_number(a) and is_number(b), do: a >= b
  defp compare_values(a, b, :gt) when is_number(a) and is_number(b), do: a > b
  defp compare_values(a, b, :lt), do: a < b
  defp compare_values(a, b, :le), do: a <= b
  defp compare_values(a, b, :ge), do: a >= b
  defp compare_values(a, b, :gt), do: a > b

  defp op_not([a]), do: not Pyex.Builtins.truthy?(a)
  defp op_truth([a]), do: Pyex.Builtins.truthy?(a)

  defp op_contains([container, item]), do: item_in_container?(item, container)

  defp op_count_of([container, item]) do
    container
    |> materialize()
    |> Enum.count(&(&1 == item))
  end

  defp op_index_of([container, item]) do
    case Enum.find_index(materialize(container), &(&1 == item)) do
      nil -> {:exception, "ValueError: not in list"}
      idx -> idx
    end
  end

  defp op_getitem([container, key]) do
    case container do
      {:py_list, reversed, _} ->
        list = Enum.reverse(reversed)

        case Enum.fetch(list, key) do
          {:ok, v} -> v
          :error -> {:exception, "IndexError: list index out of range"}
        end

      list when is_list(list) ->
        case Enum.fetch(list, key) do
          {:ok, v} -> v
          :error -> {:exception, "IndexError: list index out of range"}
        end

      {:tuple, items} ->
        case Enum.fetch(items, key) do
          {:ok, v} -> v
          :error -> {:exception, "IndexError: tuple index out of range"}
        end

      {:py_dict, _, _} = dict ->
        case Pyex.PyDict.fetch(dict, key) do
          {:ok, v} -> v
          :error -> {:exception, "KeyError: #{Pyex.Builtins.py_repr_quoted(key)}"}
        end

      _ ->
        {:exception, "TypeError: 'operator.getitem' requires a sequence or mapping"}
    end
  end

  defp op_setitem(_),
    do: {:exception, "operator.setitem not supported (requires mutation context)"}

  defp op_delitem(_),
    do: {:exception, "operator.delitem not supported (requires mutation context)"}

  defp op_concat([a, b]), do: op_add([a, b])

  # ------- Factories -------

  defp op_attrgetter([name]) when is_binary(name) do
    names = String.split(name, ".")

    {:builtin,
     fn [obj] ->
       fetch_nested_attr(obj, names)
     end}
  end

  defp op_attrgetter(names) when length(names) > 1 do
    paths = Enum.map(names, fn n when is_binary(n) -> String.split(n, ".") end)

    {:builtin,
     fn [obj] ->
       results = Enum.map(paths, &fetch_nested_attr(obj, &1))

       case Enum.find(results, &match?({:exception, _}, &1)) do
         nil -> {:tuple, results}
         err -> err
       end
     end}
  end

  defp op_itemgetter([key]) do
    {:builtin, fn [obj] -> op_getitem([obj, key]) end}
  end

  defp op_itemgetter(keys) when length(keys) > 1 do
    {:builtin,
     fn [obj] ->
       results = Enum.map(keys, &op_getitem([obj, &1]))

       case Enum.find(results, &match?({:exception, _}, &1)) do
         nil -> {:tuple, results}
         err -> err
       end
     end}
  end

  defp op_methodcaller([method_name | pre_args]) when is_binary(method_name) do
    {:builtin,
     fn [obj] ->
       {:method_call_by_name, obj, method_name, pre_args}
     end}
  end

  # ------- Helpers -------

  @spec materialize(Interpreter.pyvalue()) :: [Interpreter.pyvalue()]
  defp materialize({:py_list, reversed, _}), do: Enum.reverse(reversed)
  defp materialize({:tuple, items}), do: items
  defp materialize({:set, s}), do: MapSet.to_list(s)
  defp materialize({:frozenset, s}), do: MapSet.to_list(s)
  defp materialize(list) when is_list(list), do: list
  defp materialize(_), do: []

  @spec item_in_container?(Interpreter.pyvalue(), Interpreter.pyvalue()) :: boolean()
  defp item_in_container?(item, {:py_list, reversed, _}),
    do: Enum.any?(reversed, &(&1 == item))

  defp item_in_container?(item, {:tuple, items}), do: Enum.any?(items, &(&1 == item))
  defp item_in_container?(item, {:set, s}), do: MapSet.member?(s, item)
  defp item_in_container?(item, {:frozenset, s}), do: MapSet.member?(s, item)
  defp item_in_container?(item, list) when is_list(list), do: Enum.any?(list, &(&1 == item))

  defp item_in_container?(item, {:py_dict, _, _} = dict),
    do: match?({:ok, _}, Pyex.PyDict.fetch(dict, item))

  defp item_in_container?(sub, s) when is_binary(s) and is_binary(sub),
    do: String.contains?(s, sub)

  defp item_in_container?(_, _), do: false

  @spec fetch_nested_attr(Interpreter.pyvalue(), [String.t()]) :: Interpreter.pyvalue()
  defp fetch_nested_attr(obj, []), do: obj

  defp fetch_nested_attr({:instance, _, attrs} = inst, [name | rest]) do
    case Map.fetch(attrs, name) do
      {:ok, v} ->
        fetch_nested_attr(v, rest)

      :error ->
        {:exception,
         "AttributeError: '#{Pyex.Interpreter.Helpers.py_type(inst)}' has no attribute '#{name}'"}
    end
  end

  defp fetch_nested_attr(_obj, _),
    do: {:exception, "TypeError: attrgetter target is not an instance"}
end
