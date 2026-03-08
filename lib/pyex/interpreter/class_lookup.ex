defmodule Pyex.Interpreter.ClassLookup do
  @moduledoc """
  Class attribute lookup and MRO helpers for `Pyex.Interpreter`.

  Keeps C3 linearization and attribute-owner resolution in one place so class
  lookup rules stay separate from evaluation and call dispatch.
  """

  alias Pyex.Interpreter

  @doc false
  @spec resolve_class_attr(Interpreter.pyvalue(), String.t()) ::
          {:ok, Interpreter.pyvalue()} | :error
  def resolve_class_attr(class, attr) do
    mro = c3_linearize(class)

    Enum.find_value(mro, :error, fn {:class, _, _, class_attrs} ->
      case Map.get(class_attrs, attr) do
        nil -> nil
        value -> {:ok, value}
      end
    end)
  end

  @doc false
  @spec resolve_class_attr_with_owner(Interpreter.pyvalue(), String.t()) ::
          {:ok, Interpreter.pyvalue(), Interpreter.pyvalue()} | :error
  def resolve_class_attr_with_owner(class, attr) do
    mro = c3_linearize(class)

    Enum.find_value(mro, :error, fn {:class, _, _, class_attrs} = current_class ->
      case Map.get(class_attrs, attr) do
        nil -> nil
        value -> {:ok, value, current_class}
      end
    end)
  end

  @spec c3_linearize(Interpreter.pyvalue()) :: [Interpreter.pyvalue()]
  defp c3_linearize({:class, _, [], _} = class), do: [class]

  defp c3_linearize({:class, _, bases, _} = class) do
    parent_mros = Enum.map(bases, &c3_linearize/1)
    [class | c3_merge(parent_mros ++ [bases])]
  end

  @spec c3_merge([[Interpreter.pyvalue()]]) :: [Interpreter.pyvalue()]
  defp c3_merge(lists) do
    lists = Enum.reject(lists, &(&1 == []))

    case lists do
      [] ->
        []

      _ ->
        case find_c3_head(lists) do
          {:ok, head} ->
            remaining =
              Enum.map(lists, fn list ->
                case list do
                  [^head | rest] -> rest
                  _ -> Enum.reject(list, &(&1 == head))
                end
              end)

            [head | c3_merge(remaining)]

          :error ->
            lists |> Enum.flat_map(& &1) |> Enum.uniq()
        end
    end
  end

  @spec find_c3_head([[Interpreter.pyvalue()]]) :: {:ok, Interpreter.pyvalue()} | :error
  defp find_c3_head(lists) do
    tails = lists |> Enum.flat_map(&tl_safe/1) |> MapSet.new()

    Enum.find_value(lists, :error, fn
      [head | _] ->
        if MapSet.member?(tails, head), do: nil, else: {:ok, head}

      [] ->
        nil
    end)
  end

  @spec tl_safe([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp tl_safe([]), do: []
  defp tl_safe([_ | rest]), do: rest
end
