defmodule Pyex.Stdlib.Module do
  @moduledoc """
  Behaviour for Python standard library modules.

  Each stdlib module implements `module_value/0` which returns a
  map of attribute names to values -- typically `{:builtin, fun}`
  tuples for callable functions.
  """

  alias Pyex.Interpreter

  @type module_value :: %{optional(String.t()) => Interpreter.pyvalue()}

  @callback module_value() :: module_value()
end
