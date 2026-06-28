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
      case Map.fetch(class_attrs, attr) do
        {:ok, value} -> {:ok, value}
        :error -> nil
      end
    end)
  end

  @doc false
  @spec resolve_class_attr_with_owner(Interpreter.pyvalue(), String.t()) ::
          {:ok, Interpreter.pyvalue(), Interpreter.pyvalue()} | :error
  def resolve_class_attr_with_owner(class, attr) do
    mro = c3_linearize(class)

    Enum.find_value(mro, :error, fn {:class, _, _, class_attrs} = current_class ->
      case Map.fetch(class_attrs, attr) do
        {:ok, value} -> {:ok, value, current_class}
        :error -> nil
      end
    end)
  end

  @doc """
  Resolves an attribute accessed *through a class object* (not an
  instance) to its value, the single source of truth shared by the `.`
  operator and the `getattr` builtin.

  Handles the type dunders (`__name__`, `__qualname__`, `__class__`,
  `__mro__`, `__bases__`, `__dict__`) and then walks the MRO, applying
  CPython's class-access descriptor rules: a regular function stays an
  unbound plain function, a `staticmethod` unwraps to its function, and a
  `classmethod` binds to the class. Returns `{:ok, value}` or `:error`.
  """
  @spec class_attribute(Interpreter.pyvalue(), String.t()) ::
          {:ok, Interpreter.pyvalue()} | :error
  def class_attribute({:class, _, _, _}, "__class__"), do: {:ok, Pyex.Builtins.type_class()}

  def class_attribute({:class, name, _, attrs}, "__name__"),
    do: {:ok, Map.get(attrs, "__name__", name)}

  def class_attribute({:class, name, _, attrs}, "__qualname__"),
    do: {:ok, Map.get(attrs, "__qualname__", name)}

  def class_attribute({:class, _, _, _} = class, "__mro__") do
    mro = class |> c3_linearize() |> Enum.filter(&match?({:class, _, _, _}, &1))
    object_class = {:class, "object", [], %{"__name__" => "object"}}

    mro =
      if Enum.any?(mro, fn {:class, n, _, _} -> n == "object" end),
        do: mro,
        else: mro ++ [object_class]

    {:ok, {:tuple, mro}}
  end

  def class_attribute({:class, _, bases, _}, "__bases__"), do: {:ok, {:tuple, bases}}

  def class_attribute({:class, _, _, attrs}, "__dict__") do
    visible = visible_attrs(attrs)
    {:ok, Pyex.PyDict.from_pairs(Enum.map(visible, fn {k, v} -> {k, v} end))}
  end

  def class_attribute({:class, _, _, _} = class, attr) do
    case resolve_class_attr_with_owner(class, attr) do
      {:ok, value, owner} -> {:ok, bind_through_class(class, value, owner)}
      :error -> :error
    end
  end

  # Descriptor rules for access *through a class* (CPython semantics):
  # regular functions are returned unbound, staticmethods unwrap, and
  # classmethods (and kwargs-builtin methods) bind to the class. A classmethod
  # carries its defining `owner` as the bound method's __class__ so a zero-arg
  # `super()` in its body can find the right MRO start.
  @spec bind_through_class(
          Interpreter.pyvalue(),
          Interpreter.pyvalue(),
          Interpreter.pyvalue()
        ) :: Interpreter.pyvalue()
  defp bind_through_class(_class, {:function, _, _, _, _, _, _} = func, _owner), do: func
  defp bind_through_class(class, {:builtin_kw, _} = bkw, _owner), do: {:bound_method, class, bkw}
  defp bind_through_class(_class, {:staticmethod, func}, _owner), do: func

  defp bind_through_class(class, {:classmethod, func}, owner),
    do: {:bound_method, class, func, owner}

  # A lazily-built class constant (e.g. date.max): its thunk is pure, so it can
  # be evaluated on access without the recursion that embedding the instance in
  # the class map would trigger.
  defp bind_through_class(_class, {:class_const, thunk}, _owner), do: thunk.()

  defp bind_through_class(_class, value, _owner), do: value

  @doc "Compute the C3 linearized MRO for a class."
  @spec c3_linearize(Interpreter.pyvalue()) :: [Interpreter.pyvalue()]
  # Cached MRO tail (everything after self) avoids re-running C3 for
  # deeply nested chains. The head is always the live class so attribute
  # lookups still see the most recent attrs map; only the tail (the
  # parents, which can't change once the class is built) is reused.
  def c3_linearize({:class, _, _, %{"__mro_cache__" => tail}} = class), do: [class | tail]

  def c3_linearize({:class, _, [], _} = class), do: [class]

  def c3_linearize({:class, _, bases, _} = class) do
    reified = Enum.map(bases, &reify_base/1)
    parent_mros = Enum.map(reified, &c3_linearize/1)
    [class | c3_merge(parent_mros ++ [reified])]
  end

  # Built-in exception classes are represented as {:exception_class, name}
  # in the environment but participate in class lookup as if they were
  # {:class, name, [parent_exc], %{}} classes.  Reify on demand.
  def c3_linearize({:exception_class, _} = exc) do
    c3_linearize(Interpreter.exception_instance_class(exc))
  end

  # Defense in depth: a base that isn't a class (e.g. a malformed
  # `type(name, (junk,), {})`) contributes nothing to the MRO rather than
  # crashing the linearizer — the host must never raise on guest-shaped data.
  def c3_linearize(_other), do: []

  @internal_class_attrs ["__id__", "__mro_cache__"]

  @doc """
  Strip pyex-internal class attrs (`__id__`, `__mro_cache__`) from a
  user-visible attrs map. Used by `__dict__`, `dir()`, and `vars()` so
  the MRO cache key isn't observable from Python.
  """
  @spec visible_attrs(map()) :: map()
  def visible_attrs(attrs) when is_map(attrs) do
    Map.drop(attrs, @internal_class_attrs)
  end

  @doc """
  Stamp a class with a fresh identity ref and cache its MRO tail.

  - `__id__`: a `make_ref()` used as the cheap MRO-merge hash key.
  - `__mro_cache__`: the linearized MRO with `self` stripped, so future
    `c3_linearize/1` calls are O(1).
  """
  @spec with_mro_cache(Interpreter.pyvalue()) :: Interpreter.pyvalue()
  def with_mro_cache({:class, name, bases, attrs}) do
    attrs_with_id = Map.put(attrs, "__id__", make_ref())
    tagged = {:class, name, bases, attrs_with_id}
    [^tagged | tail] = c3_linearize(tagged)
    {:class, name, bases, Map.put(attrs_with_id, "__mro_cache__", tail)}
  end

  @spec reify_base(Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp reify_base({:exception_class, _} = exc), do: Interpreter.exception_instance_class(exc)
  defp reify_base({:builtin_type, _, _} = bt), do: Interpreter.builtin_type_base_class(bt)
  defp reify_base(other), do: other

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
    # Hash by per-class identity (a `make_ref()` stored in attrs as
    # "__id__") so MapSet ops stay O(1) — without this, hashing a
    # class tuple walks its entire `bases` chain, and merging the MRO
    # for a class at depth n becomes O(n³).
    tails_ids = lists |> Enum.flat_map(&tl_safe/1) |> MapSet.new(&class_identity/1)

    Enum.find_value(lists, :error, fn
      [head | _] ->
        if MapSet.member?(tails_ids, class_identity(head)), do: nil, else: {:ok, head}

      [] ->
        nil
    end)
  end

  @spec class_identity(Interpreter.pyvalue()) :: term()
  defp class_identity({:class, _, _, %{"__id__" => id}}), do: id
  defp class_identity(other), do: other

  @spec tl_safe([Interpreter.pyvalue()]) :: [Interpreter.pyvalue()]
  defp tl_safe([]), do: []
  defp tl_safe([_ | rest]), do: rest
end
