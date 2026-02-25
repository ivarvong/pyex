defmodule Pyex.Stdlib do
  @moduledoc """
  Registry of Python standard library modules available to the
  interpreter via `import`.

  Each module is represented as a map of attribute names to values
  (typically `{:builtin, fun}` tuples for callable functions, or
  plain maps for sub-modules).
  """

  @modules %{
    "requests" => Pyex.Stdlib.Requests,
    "json" => Pyex.Stdlib.Json,
    "math" => Pyex.Stdlib.Math,
    "fastapi" => Pyex.Stdlib.FastAPI,
    "random" => Pyex.Stdlib.Random,
    "re" => Pyex.Stdlib.Re,
    "time" => Pyex.Stdlib.Time,
    "datetime" => Pyex.Stdlib.Datetime,
    "collections" => Pyex.Stdlib.Collections,
    "csv" => Pyex.Stdlib.Csv,
    "html" => Pyex.Stdlib.Html,
    "itertools" => Pyex.Stdlib.Itertools,
    "jinja2" => Pyex.Stdlib.Jinja2,
    "markdown" => Pyex.Stdlib.Markdown,
    "unittest" => Pyex.Stdlib.Unittest,
    "uuid" => Pyex.Stdlib.Uuid,
    "sql" => Pyex.Stdlib.Sql,
    "pydantic" => Pyex.Stdlib.Pydantic,
    "boto3" => Pyex.Stdlib.Boto3,
    "hashlib" => Pyex.Stdlib.Hashlib,
    "hmac" => Pyex.Stdlib.Hmac,
    "base64" => Pyex.Stdlib.Base64,
    "secrets" => Pyex.Stdlib.Secrets,
    "pandas" => Pyex.Stdlib.Pandas,
    "yaml" => Pyex.Stdlib.Yaml
  }

  @doc """
  Returns the module value for the given Python module name,
  or `:unknown_module`.
  """
  @spec fetch(String.t()) :: {:ok, Pyex.Stdlib.Module.module_value()} | :unknown_module
  def fetch(name) do
    case Map.fetch(@modules, name) do
      {:ok, mod} -> {:ok, mod.module_value()}
      :error -> :unknown_module
    end
  end

  @doc """
  Returns a sorted list of all available stdlib module names.
  """
  @spec module_names() :: [String.t()]
  def module_names, do: @modules |> Map.keys() |> Enum.sort()
end
