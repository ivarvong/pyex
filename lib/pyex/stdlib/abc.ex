defmodule Pyex.Stdlib.Abc do
  @moduledoc """
  Python `abc` module.

  Provides `ABC`, `ABCMeta`, `abstractmethod`, and `abstractproperty`.
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
      "abstractmethod" => {:builtin, &abstractmethod/1},
      "abstractproperty" => {:builtin, &abstractproperty/1},
      "abstractclassmethod" => {:builtin, &abstractmethod/1},
      "abstractstaticmethod" => {:builtin, &abstractmethod/1},
      "ABC" => {:class, "ABC", [], %{"__name__" => "ABC"}},
      "ABCMeta" => {:builtin_type, "ABCMeta", &abcmeta_call/1}
    }
  end

  @doc false
  @spec abstractmethod([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def abstractmethod([func]) do
    # Mark the function as abstract — we just pass it through.
    # Real enforcement would require checking at instantiation time.
    case func do
      {:function, name, params, body, env} ->
        {:function, name, params, body, Map.put(env, "__isabstractmethod__", true)}

      {:property, fget, fset, fdel} ->
        {:property, fget, fset, fdel}

      other ->
        other
    end
  end

  def abstractmethod(_), do: {:exception, "TypeError: abstractmethod() takes 1 argument"}

  @doc false
  @spec abstractproperty([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def abstractproperty([func]) do
    {:property, func, nil, nil}
  end

  def abstractproperty(_), do: {:exception, "TypeError: abstractproperty() takes 1 argument"}

  @doc false
  @spec abcmeta_call([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def abcmeta_call([_name, _bases, _namespace]) do
    # Simplified: just return an empty class
    {:class, "ABCMeta_class", [], %{}}
  end

  def abcmeta_call(_), do: {:exception, "TypeError: ABCMeta() arguments wrong"}
end
