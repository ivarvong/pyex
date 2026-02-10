defmodule Pyex.Error do
  @moduledoc """
  Structured error type for the Pyex interpreter.

  Classifies errors so host applications can map them to HTTP
  status codes, log categories, or billing events without
  parsing error message strings.

  ## Kinds

  - `:syntax` -- lexer or parser error (bad Python source)
  - `:python` -- runtime exception raised by user code
  - `:timeout` -- compute budget exceeded
  - `:import` -- failed module import
  - `:io` -- filesystem or I/O error
  - `:route_not_found` -- no matching route in Lambda dispatch
  - `:internal` -- interpreter bug (should never happen)

  ## Example

      case Pyex.run(source) do
        {:ok, result, ctx} -> handle_result(result)
        {:error, %Pyex.Error{kind: :timeout}} -> send_resp(504, "Timeout")
        {:error, %Pyex.Error{kind: :python}} -> send_resp(500, "Runtime error")
        {:error, %Pyex.Error{kind: :syntax}} -> send_resp(400, "Bad request")
      end
  """

  @type kind ::
          :syntax
          | :python
          | :timeout
          | :import
          | :io
          | :route_not_found
          | :internal

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          line: pos_integer() | nil,
          exception_type: String.t() | nil
        }

  defstruct kind: :internal,
            message: "",
            line: nil,
            exception_type: nil

  @doc """
  Classifies a raw error string into a structured error.

  Parses the exception type prefix (e.g. `"TypeError: ..."`)
  and extracts line numbers from `"on line N"` suffixes when
  present.
  """
  @spec from_message(String.t()) :: t()
  def from_message(msg) when is_binary(msg) do
    {kind, exception_type} = classify(msg)
    line = extract_line(msg)
    %__MODULE__{kind: kind, message: msg, line: line, exception_type: exception_type}
  end

  @doc """
  Creates a syntax error (lexer/parser failure).
  """
  @spec syntax(String.t()) :: t()
  def syntax(msg), do: %__MODULE__{kind: :syntax, message: msg, line: extract_line(msg)}

  @doc """
  Creates a timeout error.
  """
  @spec timeout(String.t()) :: t()
  def timeout(msg), do: %__MODULE__{kind: :timeout, message: msg}

  @doc """
  Creates a route-not-found error.
  """
  @spec route_not_found(String.t()) :: t()
  def route_not_found(msg), do: %__MODULE__{kind: :route_not_found, message: msg}

  @doc """
  Creates an I/O error.
  """
  @spec io(String.t()) :: t()
  def io(msg), do: %__MODULE__{kind: :io, message: msg}

  @spec classify(String.t()) :: {kind(), String.t() | nil}
  defp classify(msg) do
    cond do
      String.starts_with?(msg, "SyntaxError:") ->
        {:syntax, "SyntaxError"}

      String.starts_with?(msg, "IndentationError:") ->
        {:syntax, "IndentationError"}

      String.starts_with?(msg, "TimeoutError:") ->
        {:timeout, "TimeoutError"}

      String.contains?(msg, "ComputeTimeout:") ->
        {:timeout, "ComputeTimeout"}

      String.starts_with?(msg, "ImportError:") ->
        {:import, "ImportError"}

      String.starts_with?(msg, "ModuleNotFoundError:") ->
        {:import, "ModuleNotFoundError"}

      String.starts_with?(msg, "IOError:") ->
        {:io, "IOError"}

      String.starts_with?(msg, "FileNotFoundError:") ->
        {:io, "FileNotFoundError"}

      true ->
        {kind, type} = classify_python_exception(msg)
        {kind, type}
    end
  end

  @python_exception_prefixes ~w(
    TypeError ValueError NameError AttributeError IndexError
    KeyError ZeroDivisionError RuntimeError StopIteration
    OverflowError RecursionError NotImplementedError
    AssertionError UnboundLocalError
  )

  @spec classify_python_exception(String.t()) :: {kind(), String.t() | nil}
  defp classify_python_exception(msg) do
    case Enum.find(@python_exception_prefixes, fn prefix ->
           String.starts_with?(msg, prefix <> ":")
         end) do
      nil -> {:python, nil}
      prefix -> {:python, prefix}
    end
  end

  @spec extract_line(String.t()) :: pos_integer() | nil
  defp extract_line(msg) do
    case Regex.run(~r/on line (\d+)/, msg) do
      [_, n] -> String.to_integer(n)
      nil -> nil
    end
  end
end
