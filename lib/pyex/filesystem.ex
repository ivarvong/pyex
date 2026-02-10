defmodule Pyex.Filesystem do
  @moduledoc """
  Behaviour for pluggable filesystem backends.

  The interpreter accesses files through this abstraction,
  allowing different backends per execution: in-memory maps,
  sandboxed local directories, S3 buckets, etc.

  All paths are strings. Implementations must normalize paths
  and enforce any sandboxing constraints.
  """

  @type path :: String.t()
  @type content :: String.t()
  @type mode :: :read | :write | :append

  @doc """
  Reads the full contents of a file. Returns `{:ok, content}`
  or `{:error, reason}`.
  """
  @callback read(impl :: term(), path()) :: {:ok, content()} | {:error, String.t()}

  @doc """
  Writes content to a file, creating it if it doesn't exist.
  Mode `:write` truncates, `:append` appends.
  Returns `{:ok, impl}` with the updated implementation state,
  or `{:error, reason}`.
  """
  @callback write(impl :: term(), path(), content(), mode()) ::
              {:ok, term()} | {:error, String.t()}

  @doc """
  Returns true if the path exists.
  """
  @callback exists?(impl :: term(), path()) :: boolean()

  @doc """
  Lists entries in a directory path. Returns `{:ok, [name]}`
  or `{:error, reason}`.
  """
  @callback list_dir(impl :: term(), path()) :: {:ok, [String.t()]} | {:error, String.t()}

  @doc """
  Deletes a file. Returns `{:ok, impl}` or `{:error, reason}`.
  """
  @callback delete(impl :: term(), path()) :: {:ok, term()} | {:error, String.t()}
end
