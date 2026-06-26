defmodule Pyex.Stdlib.Logging do
  @moduledoc """
  Python `logging` module — a functional shim.

  LLM-generated code reaches for `logging` reflexively (`getLogger`,
  `basicConfig`, `log.info(...)`). The full machinery (handlers, formatters,
  propagation) has no meaning in the sandbox, and CPython's default output
  goes to stderr — which the sandbox does not surface — so emitting nothing to
  stdout is the *conformant* behaviour. This shim makes the whole common API
  importable and callable without error, with correct level constants and a
  `Logger` object that tracks its level.
  """

  @behaviour Pyex.Stdlib.Module

  @levels %{
    "CRITICAL" => 50,
    "FATAL" => 50,
    "ERROR" => 40,
    "WARNING" => 30,
    "WARN" => 30,
    "INFO" => 20,
    "DEBUG" => 10,
    "NOTSET" => 0
  }

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    Map.merge(@levels, %{
      "__name__" => "logging",
      "getLogger" => {:builtin, &get_logger/1},
      "basicConfig" => {:builtin_kw, fn _args, _kwargs -> nil end},
      "disable" => {:builtin, fn _ -> nil end},
      "getLevelName" => {:builtin, &get_level_name/1},
      "debug" => noop(),
      "info" => noop(),
      "warning" => noop(),
      "warn" => noop(),
      "error" => noop(),
      "critical" => noop(),
      "fatal" => noop(),
      "exception" => noop(),
      "log" => noop()
    })
  end

  @spec noop() :: Pyex.Interpreter.pyvalue()
  defp noop, do: {:builtin_kw, fn _args, _kwargs -> nil end}

  @spec get_logger([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp get_logger(args) do
    name =
      case args do
        [n | _] when is_binary(n) -> n
        _ -> "root"
      end

    logger(name, 0)
  end

  @spec get_level_name([Pyex.Interpreter.pyvalue()]) :: Pyex.Interpreter.pyvalue()
  defp get_level_name([level]) when is_integer(level) do
    Enum.find_value(@levels, "Level #{level}", fn {name, n} ->
      if n == level and name not in ["WARN", "FATAL"], do: name
    end)
  end

  defp get_level_name(_), do: "NOTSET"

  @spec logger(String.t(), integer()) :: Pyex.Interpreter.pyvalue()
  defp logger(name, level) do
    {:instance,
     {:class, "Logger", [],
      %{
        "__name__" => "Logger",
        "debug" => method_noop(),
        "info" => method_noop(),
        "warning" => method_noop(),
        "warn" => method_noop(),
        "error" => method_noop(),
        "critical" => method_noop(),
        "fatal" => method_noop(),
        "exception" => method_noop(),
        "log" => method_noop(),
        "addHandler" => {:builtin, fn _ -> nil end},
        "removeHandler" => {:builtin, fn _ -> nil end},
        "setLevel" => {:builtin, &logger_set_level/1},
        "getEffectiveLevel" => {:builtin, &logger_get_level/1},
        "isEnabledFor" => {:builtin, &logger_is_enabled_for/1}
      }}, %{"name" => name, "level" => level}}
  end

  # Logger.<level>(self, msg, *args, **kwargs) — no stdout, matching stderr.
  @spec method_noop() :: Pyex.Interpreter.pyvalue()
  defp method_noop, do: {:builtin_kw, fn _args, _kwargs -> nil end}

  # setLevel mutates the logger in place; the `{:mutate, ...}` signal writes the
  # updated instance back to the variable bound to the logger.
  defp logger_set_level([{:instance, cls, attrs}, level]) when is_integer(level) do
    {:mutate, {:instance, cls, Map.put(attrs, "level", level)}, nil}
  end

  defp logger_set_level([self | _]), do: self

  defp logger_get_level([{:instance, _, %{"level" => 0}}]), do: 30
  defp logger_get_level([{:instance, _, %{"level" => level}}]), do: level
  defp logger_get_level(_), do: 30

  defp logger_is_enabled_for([{:instance, _, attrs}, level]) when is_integer(level) do
    effective =
      case Map.get(attrs, "level", 0) do
        0 -> 30
        n -> n
      end

    level >= effective
  end

  defp logger_is_enabled_for(_), do: true
end
