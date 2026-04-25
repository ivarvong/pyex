defmodule Pyex.ExceptionsHierarchy do
  @moduledoc """
  Built-in Python exception class hierarchy.

  Maps each concrete exception name to its direct parent.  Used by the
  interpreter's `except` matcher, by `isinstance` and `issubclass` when
  comparing `{:exception_class, _}` runtime values, and by
  `{:exception_class, _}` runtime class identity checks.

  Sourced from https://docs.python.org/3/library/exceptions.html#exception-hierarchy.
  """

  @parents %{
    "BaseException" => nil,
    "SystemExit" => "BaseException",
    "KeyboardInterrupt" => "BaseException",
    "GeneratorExit" => "BaseException",
    "Exception" => "BaseException",
    "StopIteration" => "Exception",
    "StopAsyncIteration" => "Exception",
    "ArithmeticError" => "Exception",
    "FloatingPointError" => "ArithmeticError",
    "OverflowError" => "ArithmeticError",
    "ZeroDivisionError" => "ArithmeticError",
    "AssertionError" => "Exception",
    "AttributeError" => "Exception",
    "BufferError" => "Exception",
    "EOFError" => "Exception",
    "ImportError" => "Exception",
    "ModuleNotFoundError" => "ImportError",
    "LookupError" => "Exception",
    "IndexError" => "LookupError",
    "KeyError" => "LookupError",
    "MemoryError" => "Exception",
    "NameError" => "Exception",
    "UnboundLocalError" => "NameError",
    "OSError" => "Exception",
    "BlockingIOError" => "OSError",
    "ChildProcessError" => "OSError",
    "ConnectionError" => "OSError",
    "BrokenPipeError" => "ConnectionError",
    "ConnectionAbortedError" => "ConnectionError",
    "ConnectionRefusedError" => "ConnectionError",
    "ConnectionResetError" => "ConnectionError",
    "FileExistsError" => "OSError",
    "FileNotFoundError" => "OSError",
    "InterruptedError" => "OSError",
    "IsADirectoryError" => "OSError",
    "NotADirectoryError" => "OSError",
    "PermissionError" => "OSError",
    "ProcessLookupError" => "OSError",
    "TimeoutError" => "OSError",
    "ReferenceError" => "Exception",
    "RuntimeError" => "Exception",
    "NotImplementedError" => "RuntimeError",
    "RecursionError" => "RuntimeError",
    "SyntaxError" => "Exception",
    "IndentationError" => "SyntaxError",
    "TabError" => "IndentationError",
    "SystemError" => "Exception",
    "TypeError" => "Exception",
    "ValueError" => "Exception",
    "UnicodeError" => "ValueError",
    "UnicodeDecodeError" => "UnicodeError",
    "UnicodeEncodeError" => "UnicodeError",
    "UnicodeTranslateError" => "UnicodeError",
    "Warning" => "Exception",
    "DeprecationWarning" => "Warning",
    "PendingDeprecationWarning" => "Warning",
    "RuntimeWarning" => "Warning",
    "SyntaxWarning" => "Warning",
    "UserWarning" => "Warning",
    "FutureWarning" => "Warning",
    "ImportWarning" => "Warning",
    "UnicodeWarning" => "Warning",
    "BytesWarning" => "Warning",
    "ResourceWarning" => "Warning",
    "DecimalException" => "ArithmeticError",
    "Clamped" => "DecimalException",
    "InvalidOperation" => "ArithmeticError",
    "ConversionSyntax" => "InvalidOperation",
    "DivisionByZero" => "ArithmeticError",
    "DivisionImpossible" => "InvalidOperation",
    "DivisionUndefined" => "InvalidOperation",
    "Inexact" => "DecimalException",
    "InvalidContext" => "InvalidOperation",
    "Rounded" => "DecimalException",
    "Subnormal" => "DecimalException",
    "Overflow" => "DecimalException",
    "Underflow" => "Inexact",
    "FloatOperation" => "DecimalException",
    "BadZipFile" => "Exception",
    "LargeZipFile" => "Exception"
  }

  @doc """
  Returns true when `class_name` is a built-in exception class whose
  parent chain includes `target_name`, or when the two names are equal.
  """
  @spec subclass?(String.t(), String.t()) :: boolean()
  def subclass?(name, name), do: true
  def subclass?(name, target), do: Enum.member?(chain(name), target)

  @doc """
  Returns `true` when `name` is a registered built-in exception class.
  """
  @spec known?(String.t()) :: boolean()
  def known?(name), do: Map.has_key?(@parents, name)

  @doc """
  Returns the direct parent of `name`, or `nil` if `name` is the root
  (`BaseException`) or is not a registered exception class.
  """
  @spec parent(String.t()) :: String.t() | nil
  def parent(name), do: Map.get(@parents, name)

  @doc """
  Returns the full ancestry chain for `name`, starting with the name
  itself and walking to `BaseException`.  Returns `[]` for unknown
  names.
  """
  @spec chain(String.t()) :: [String.t()]
  def chain(name) do
    case Map.fetch(@parents, name) do
      {:ok, nil} -> [name]
      {:ok, parent} -> [name | chain(parent)]
      :error -> []
    end
  end

  @doc """
  Returns the list of all registered exception class names.
  """
  @spec all_names() :: [String.t()]
  def all_names, do: Map.keys(@parents)
end
