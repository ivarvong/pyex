defmodule Pyex.Stdlib.Dataclasses do
  @moduledoc """
  Minimal `dataclasses` support for common structured-data workflows.
  """

  @behaviour Pyex.Stdlib.Module

  alias Pyex.{Builtins, PyDict}
  alias Pyex.Interpreter

  @field_marker "__dataclass_field__"

  @impl Pyex.Stdlib.Module
  @spec module_value() :: Pyex.Stdlib.Module.module_value()
  def module_value do
    %{
      "dataclass" => {:builtin_kw, &dataclass/2},
      "field" => {:builtin_kw, &field/2},
      "asdict" => {:builtin, &asdict/1},
      "replace" => {:builtin_kw, &replace/2}
    }
  end

  @spec dataclass([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          Interpreter.pyvalue()
  defp dataclass([{:class, _, _, _} = class], kwargs), do: decorate_class(class, kwargs)

  defp dataclass([], kwargs) do
    {:builtin_kw, fn [class], _inner_kwargs -> decorate_class(class, kwargs) end}
  end

  defp dataclass(_args, _kwargs),
    do: {:exception, "TypeError: dataclass decorator expects a class"}

  @spec field([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          map() | {:exception, String.t()}
  defp field(args, kwargs) do
    cond do
      args != [] ->
        {:exception, "TypeError: field() does not accept positional arguments"}

      Map.has_key?(kwargs, "default") and Map.has_key?(kwargs, "default_factory") ->
        {:exception, "ValueError: cannot specify both default and default_factory"}

      true ->
        %{
          @field_marker => true,
          "default" => Map.get(kwargs, "default", :__missing__),
          "default_factory" => Map.get(kwargs, "default_factory", :__missing__)
        }
    end
  end

  @spec asdict([Interpreter.pyvalue()]) :: map() | {:exception, String.t()}
  defp asdict([{:instance, {:class, _, _, attrs}, inst_attrs}]) do
    fields = Map.get(attrs, "__dataclass_fields__", [])
    Map.new(fields, fn field -> {field, deep_asdict(Map.get(inst_attrs, field))} end)
  end

  defp asdict(_args), do: {:exception, "TypeError: asdict() expects a dataclass instance"}

  @spec replace([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          Interpreter.pyvalue()
  defp replace([{:instance, {:class, _, _, attrs} = class, inst_attrs}], kwargs) do
    fields = Map.get(attrs, "__dataclass_fields__", [])
    allowed = MapSet.new(fields)

    case Enum.find(Map.keys(kwargs), fn key -> not MapSet.member?(allowed, key) end) do
      nil -> {:instance, class, Map.merge(inst_attrs, kwargs)}
      key -> {:exception, "TypeError: replace() got an unexpected field '#{key}'"}
    end
  end

  defp replace(_args, _kwargs),
    do: {:exception, "TypeError: replace() expects a dataclass instance"}

  @spec decorate_class(Interpreter.pyvalue(), %{optional(String.t()) => Interpreter.pyvalue()}) ::
          Interpreter.pyvalue()
  defp decorate_class({:class, name, bases, class_attrs}, _kwargs) do
    field_names =
      case Map.get(class_attrs, "__annotations_order__") do
        names when is_list(names) -> Enum.reverse(names)
        _ -> class_attrs |> Map.get("__annotations__", %{}) |> Map.keys()
      end

    defaults =
      Enum.reduce(field_names, %{}, fn field, acc ->
        case Map.get(class_attrs, field, :__missing__) do
          :__missing__ -> acc
          value -> Map.put(acc, field, value)
        end
      end)

    generated = %{
      "__dataclass_fields__" => field_names,
      "__dataclass_defaults__" => defaults,
      "__init__" => {:builtin_kw, &dataclass_init/2},
      "__repr__" => {:builtin, &dataclass_repr/1},
      "__eq__" => {:builtin, &dataclass_eq/1}
    }

    {:class, name, bases, Map.merge(class_attrs, generated)}
  end

  @spec dataclass_init([Interpreter.pyvalue()], %{optional(String.t()) => Interpreter.pyvalue()}) ::
          Interpreter.pyvalue()
  defp dataclass_init(
         [{:instance, {:class, _, _, attrs} = class, _old_attrs} | args],
         kwargs
       ) do
    field_names = Map.get(attrs, "__dataclass_fields__", [])
    defaults = Map.get(attrs, "__dataclass_defaults__", %{})

    cond do
      length(args) > length(field_names) ->
        {:exception, "TypeError: too many positional arguments for dataclass __init__"}

      true ->
        positional = Enum.zip(Enum.take(field_names, length(args)), args) |> Map.new()

        case duplicate_keyword(field_names, positional, kwargs) do
          nil ->
            case unknown_keyword(field_names, kwargs) do
              nil ->
                if needs_factory_dispatch?(field_names, defaults, positional, kwargs) do
                  {:ctx_call,
                   fn env, ctx ->
                     build_dataclass_attrs_with_ctx(
                       class,
                       field_names,
                       defaults,
                       positional,
                       kwargs,
                       env,
                       ctx
                     )
                   end}
                else
                  case build_dataclass_attrs(field_names, defaults, positional, kwargs) do
                    {:ok, values} -> {:instance, class, values}
                    {:error, msg} -> {:exception, msg}
                  end
                end

              key ->
                {:exception, "TypeError: got an unexpected keyword argument '#{key}'"}
            end

          key ->
            {:exception, "TypeError: got multiple values for argument '#{key}'"}
        end
    end
  end

  defp dataclass_init(_args, _kwargs),
    do: {:exception, "TypeError: invalid dataclass initialization"}

  @spec needs_factory_dispatch?([String.t()], map(), map(), map()) :: boolean()
  defp needs_factory_dispatch?(field_names, defaults, positional, kwargs) do
    Enum.any?(field_names, fn field ->
      not Map.has_key?(positional, field) and not Map.has_key?(kwargs, field) and
        case Map.get(defaults, field) do
          %{@field_marker => true, "default_factory" => factory} when factory != :__missing__ ->
            user_callable?(factory)

          _ ->
            false
        end
    end)
  end

  @spec user_callable?(Interpreter.pyvalue()) :: boolean()
  defp user_callable?({:function, _, _, _, _, _}), do: true
  defp user_callable?({:lambda, _, _, _}), do: true
  defp user_callable?({:bound_method, _, _}), do: true
  defp user_callable?({:bound_method, _, _, _}), do: true
  defp user_callable?({:class, _, _, _}), do: true
  defp user_callable?(_), do: false

  @spec build_dataclass_attrs_with_ctx(
          Interpreter.pyvalue(),
          [String.t()],
          map(),
          map(),
          map(),
          Pyex.Env.t(),
          Pyex.Ctx.t()
        ) :: {Interpreter.pyvalue(), Pyex.Env.t(), Pyex.Ctx.t()}
  defp build_dataclass_attrs_with_ctx(class, field_names, defaults, positional, kwargs, env, ctx) do
    Enum.reduce_while(field_names, {:ok, %{}, env, ctx}, fn field, {:ok, acc, env, ctx} ->
      cond do
        Map.has_key?(positional, field) ->
          {:cont, {:ok, Map.put(acc, field, Map.fetch!(positional, field)), env, ctx}}

        Map.has_key?(kwargs, field) ->
          {:cont, {:ok, Map.put(acc, field, Map.fetch!(kwargs, field)), env, ctx}}

        Map.has_key?(defaults, field) ->
          case resolve_default_with_ctx(Map.fetch!(defaults, field), env, ctx) do
            {{:exception, _} = signal, env, ctx} ->
              {:halt, {:error, signal, env, ctx}}

            {value, env, ctx} ->
              {:cont, {:ok, Map.put(acc, field, value), env, ctx}}
          end

        true ->
          {:halt,
           {:error, {:exception, "TypeError: missing required argument '#{field}'"}, env, ctx}}
      end
    end)
    |> case do
      {:ok, values, env, ctx} -> {{:instance, class, values}, env, ctx}
      {:error, signal, env, ctx} -> {signal, env, ctx}
    end
  end

  @spec resolve_default_with_ctx(Interpreter.pyvalue(), Pyex.Env.t(), Pyex.Ctx.t()) ::
          {Interpreter.pyvalue(), Pyex.Env.t(), Pyex.Ctx.t()}
  defp resolve_default_with_ctx(
         %{@field_marker => true, "default_factory" => factory},
         env,
         ctx
       )
       when factory != :__missing__ do
    if user_callable?(factory) do
      # call_function may return either {val, env, ctx} or
      # {val, env, ctx, updated_func} (closure-refresh path).
      case Interpreter.call_function(factory, [], %{}, env, ctx) do
        {{:exception, _} = signal, env, ctx} -> {signal, env, ctx}
        {{:exception, _} = signal, env, ctx, _func} -> {signal, env, ctx}
        {value, env, ctx} -> {value, env, ctx}
        {value, env, ctx, _updated_func} -> {value, env, ctx}
      end
    else
      {run_default_factory(factory), env, ctx}
    end
  end

  defp resolve_default_with_ctx(value, env, ctx), do: {resolve_default(value), env, ctx}

  @spec dataclass_repr([Interpreter.pyvalue()]) :: String.t() | {:exception, String.t()}
  defp dataclass_repr([{:instance, {:class, name, _, attrs}, inst_attrs}]) do
    fields = Map.get(attrs, "__dataclass_fields__", [])

    rendered =
      fields
      |> Enum.map(fn field -> "#{field}=#{render_repr(Map.get(inst_attrs, field))}" end)
      |> Enum.join(", ")

    "#{name}(#{rendered})"
  end

  defp dataclass_repr(_args), do: {:exception, "TypeError: repr() expects a dataclass instance"}

  @spec dataclass_eq([Interpreter.pyvalue()]) :: boolean() | {:exception, String.t()}
  defp dataclass_eq([
         {:instance, {:class, name, _, attrs}, left},
         {:instance, {:class, other, _, _}, right}
       ]) do
    if name == other do
      Enum.all?(Map.get(attrs, "__dataclass_fields__", []), fn field ->
        Map.get(left, field) == Map.get(right, field)
      end)
    else
      false
    end
  end

  defp dataclass_eq([_left, _right]), do: false

  @spec build_dataclass_attrs([String.t()], map(), map(), map()) ::
          {:ok, map()} | {:error, String.t()}
  defp build_dataclass_attrs(field_names, defaults, positional, kwargs) do
    Enum.reduce_while(field_names, {:ok, %{}}, fn field, {:ok, acc} ->
      cond do
        Map.has_key?(positional, field) ->
          {:cont, {:ok, Map.put(acc, field, Map.fetch!(positional, field))}}

        Map.has_key?(kwargs, field) ->
          {:cont, {:ok, Map.put(acc, field, Map.fetch!(kwargs, field))}}

        Map.has_key?(defaults, field) ->
          {:cont, {:ok, Map.put(acc, field, resolve_default(Map.fetch!(defaults, field)))}}

        true ->
          {:halt, {:error, "TypeError: missing required argument '#{field}'"}}
      end
    end)
  end

  @spec resolve_default(Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp resolve_default(%{@field_marker => true, "default_factory" => factory})
       when factory != :__missing__ do
    run_default_factory(factory)
  end

  defp resolve_default(%{@field_marker => true, "default" => default})
       when default != :__missing__, do: default

  defp resolve_default(value), do: value

  @spec run_default_factory(Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp run_default_factory({:builtin_type, _, fun}), do: fun.([])
  defp run_default_factory({:builtin, fun}), do: fun.([])

  defp run_default_factory({:py_dict, _, _} = dict),
    do: PyDict.from_map(Builtins.visible_dict(dict))

  defp run_default_factory(map) when is_map(map), do: Map.new(map)
  defp run_default_factory(list) when is_list(list), do: Enum.map(list, & &1)
  defp run_default_factory(other), do: other

  @spec duplicate_keyword([String.t()], map(), map()) :: String.t() | nil
  defp duplicate_keyword(field_names, positional, kwargs) do
    Enum.find(field_names, fn field ->
      Map.has_key?(positional, field) and Map.has_key?(kwargs, field)
    end)
  end

  @spec unknown_keyword([String.t()], map()) :: String.t() | nil
  defp unknown_keyword(field_names, kwargs) do
    allowed = MapSet.new(field_names)
    Enum.find(Map.keys(kwargs), fn key -> not MapSet.member?(allowed, key) end)
  end

  @spec deep_asdict(Interpreter.pyvalue()) :: Interpreter.pyvalue()
  defp deep_asdict({:instance, {:class, _, _, attrs}, inst_attrs}) do
    case Map.get(attrs, "__dataclass_fields__") do
      fields when is_list(fields) ->
        Map.new(fields, fn field -> {field, deep_asdict(Map.get(inst_attrs, field))} end)

      _ ->
        inst_attrs
    end
  end

  defp deep_asdict({:py_dict, _, _} = dict) do
    dict
    |> Builtins.visible_dict()
    |> Map.new(fn {k, v} -> {k, deep_asdict(v)} end)
  end

  defp deep_asdict(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, deep_asdict(v)} end)
  defp deep_asdict(list) when is_list(list), do: Enum.map(list, &deep_asdict/1)
  defp deep_asdict({:tuple, items}), do: {:tuple, Enum.map(items, &deep_asdict/1)}
  defp deep_asdict(other), do: other

  @spec render_repr(Interpreter.pyvalue()) :: String.t()
  defp render_repr(value) when is_binary(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")
    "'" <> escaped <> "'"
  end

  defp render_repr(value), do: Builtins.py_repr(value)
end
