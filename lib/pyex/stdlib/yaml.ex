defmodule Pyex.Stdlib.Yaml do
  @moduledoc """
  Python `yaml` module backed by `Pyex.Stdlib.YamlParser`.

  Provides `yaml.safe_load(string)` for parsing YAML documents into
  Python values. Keys are always returned as strings -- atoms are
  never interned from user-provided content.

  Raises `yaml.YAMLError` on parse failures or when nesting depth
  exceeds 100 levels. Raises `ValueError` if the input exceeds the
  size limit.

      import yaml
      data = yaml.safe_load("name: alice\\nscores:\\n  - 10\\n  - 20")
      # {"name": "alice", "scores": [10, 20]}
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.Stdlib.YamlParser

  @max_bytes 1_000_000

  @doc """
  Returns the module value -- a map with callable attributes.
  """
  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "safe_load" => {:builtin, &do_safe_load/1},
      "YAMLError" => "yaml.YAMLError"
    }
  end

  @spec do_safe_load([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp do_safe_load([string]) when is_binary(string) do
    if byte_size(string) > @max_bytes do
      {:exception, "ValueError: yaml.safe_load input exceeds maximum size of #{@max_bytes} bytes"}
    else
      case YamlParser.parse(string) do
        {:ok, value} -> to_python(value)
        {:error, reason} -> {:exception, "yaml.YAMLError: #{reason}"}
      end
    end
  end

  defp do_safe_load(_args) do
    {:exception, "TypeError: yaml.safe_load() argument must be a string"}
  end

  @spec to_python(YamlParser.yaml_value()) :: Pyex.Interpreter.pyvalue()
  defp to_python(nil), do: nil
  defp to_python(true), do: true
  defp to_python(false), do: false
  defp to_python(n) when is_integer(n), do: n
  defp to_python(f) when is_float(f), do: f
  defp to_python(s) when is_binary(s), do: s

  defp to_python(:nan),
    do: {:exception, "yaml.YAMLError: .nan is not supported as a Python value"}

  defp to_python(:infinity),
    do: {:exception, "yaml.YAMLError: .inf is not supported as a Python value"}

  defp to_python(:neg_infinity),
    do: {:exception, "yaml.YAMLError: -.inf is not supported as a Python value"}

  defp to_python(list) when is_list(list), do: Enum.map(list, &to_python/1)

  defp to_python(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, to_python(v)} end)
  end
end
