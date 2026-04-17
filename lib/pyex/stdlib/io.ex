defmodule Pyex.Stdlib.Io do
  @moduledoc """
  Python `io` module.

  Provides `StringIO`, `BytesIO`, and `IOBase` stubs.
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
      "StringIO" => {:builtin, &string_io/1},
      "BytesIO" => {:builtin, &bytes_io/1},
      "IOBase" => {:builtin, fn _ -> {:instance, {:class, "IOBase", [], %{}}, %{}} end},
      "RawIOBase" => {:builtin, fn _ -> {:instance, {:class, "RawIOBase", [], %{}}, %{}} end},
      "BufferedIOBase" =>
        {:builtin, fn _ -> {:instance, {:class, "BufferedIOBase", [], %{}}, %{}} end},
      "TextIOWrapper" =>
        {:builtin, fn _ -> {:instance, {:class, "TextIOWrapper", [], %{}}, %{}} end},
      "SEEK_SET" => 0,
      "SEEK_CUR" => 1,
      "SEEK_END" => 2
    }
  end

  @doc false
  @spec string_io([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def string_io([]) do
    make_string_io("")
  end

  def string_io([initial]) when is_binary(initial) do
    make_string_io(initial)
  end

  def string_io([nil]) do
    make_string_io("")
  end

  def string_io(_), do: {:exception, "TypeError: StringIO() takes at most 1 argument"}

  # StringIO values must round-trip through the heap so that mutations
  # performed by held references (e.g. a `csv.writer(buf)` closure
  # writing back to `buf`) propagate to every alias.  Returning a
  # {:ctx_call, fn} signal lets the interpreter perform the allocation
  # and bind the resulting ref to the calling variable.
  @spec make_string_io(String.t()) :: Interpreter.pyvalue()
  defp make_string_io(initial) do
    {:ctx_call,
     fn env, ctx ->
       {ref, ctx} = Pyex.Ctx.heap_alloc(ctx, {:stringio, initial})
       {ref, env, ctx}
     end}
  end

  @doc false
  @spec bytes_io([Interpreter.pyvalue()]) :: Interpreter.pyvalue()
  def bytes_io([]) do
    {:instance, {:class, "BytesIO", [], %{"__name__" => "BytesIO"}}, %{"__buf__" => ""}}
  end

  def bytes_io([_initial]) do
    {:instance, {:class, "BytesIO", [], %{"__name__" => "BytesIO"}}, %{"__buf__" => ""}}
  end

  def bytes_io(_), do: {:exception, "TypeError: BytesIO() takes at most 1 argument"}
end
