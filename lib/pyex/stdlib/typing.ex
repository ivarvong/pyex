defmodule Pyex.Stdlib.Typing do
  @moduledoc """
  Python `typing` module — a no-op stub.

  LLM-generated Python code imports from `typing` constantly, but none of
  the type annotations do anything at runtime.  This module makes those
  imports succeed silently by exporting the commonly-used names as `nil`
  or trivial builtins.
  """

  @behaviour Pyex.Stdlib.Module

  @noop_names ~w(
    Any Union Optional List Dict Set Tuple FrozenSet Type Callable
    Iterator Generator Iterable Sequence Mapping MutableMapping
    MutableSequence MutableSet ClassVar Final Literal Generic Protocol
    runtime_checkable overload no_type_check NoReturn Never TypedDict
  )

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    noop_map = Map.new(@noop_names, fn name -> {name, nil} end)

    builtins = %{
      "TypeVar" => {:builtin, &do_typevar/1},
      "NamedTuple" => {:builtin, &do_namedtuple/1},
      "cast" => {:builtin, &do_cast/1},
      "get_type_hints" => {:builtin, &do_get_type_hints/1}
    }

    Map.merge(noop_map, builtins)
  end

  # TypeVar('T') -> nil
  @spec do_typevar([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_typevar(_args), do: nil

  # NamedTuple(...) -> nil
  @spec do_namedtuple([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_namedtuple(_args), do: nil

  # cast(Type, val) -> val
  @spec do_cast([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_cast([_type, value]), do: value
  defp do_cast(_), do: {:exception, "TypeError: cast() requires exactly two arguments"}

  # get_type_hints(obj) -> {}
  @spec do_get_type_hints([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_get_type_hints(_args), do: %{}
end
